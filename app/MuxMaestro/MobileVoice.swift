import Foundation

// The voice half of the phone API: the request, the audio in and out, the
// limits, and one voice turn. Pure, like MobileAPI.swift. It adds no speech
// logic: a take is transcribed and read back by the same `VoiceSpeech` the Mac
// rail uses, and its text goes down the same path as typed text.

enum MobileVoiceMode: String, CaseIterable {
    /// Hands-free: speech starts a take and a silence sends it.
    case auto
    /// One tap starts a take and the next sends it.
    case manual
}

/// What a phone starts with until its own controls are used.
struct MobileVoiceDefaults: Equatable {
    var mode = MobileVoiceMode.manual
    /// On: the reply is spoken (two-way). Off: input only.
    var speaker = true

    var json: [String: Any] {
        ["mode": mode.rawValue, "speaker": speaker, "maxSeconds": Int(MobileVoice.maxSeconds)]
    }
}

/// Where a take goes once it is text.
enum MobileVoiceTarget: Hashable {
    case manager
    /// One thread's pane, by its phone id.
    case thread(String)
}

/// The query of a voice request: `?target=manager&speaker=1`, and for a take
/// `&take=<id>`, with `&heard=1` when the body is the take's words.
struct MobileVoiceRequest: Equatable {
    var target: MobileVoiceTarget
    /// Off means input only: nothing is synthesized.
    var speaker: Bool
    /// The phone's name for the take. It keeps the take until the Mac says
    /// the text is sent, and may send it again under the same name.
    var take: String?
    /// The body is `{"text": "…"}`, what the Mac heard in this take before,
    /// not audio.
    var heard = false

    init(target: MobileVoiceTarget, speaker: Bool) {
        self.target = target
        self.speaker = speaker
    }

    init?(query: [String: String]) {
        guard let target = query["target"], !target.isEmpty else { return nil }
        self.target = target == "manager" ? .manager : .thread(target)
        speaker = query["speaker"] == "1"
        if let take = query["take"] {
            guard MobileVoiceTakes.isID(take) else { return nil }
            self.take = take
        }
        heard = query["heard"] == "1"
    }
}

/// The takes whose text went to a target, by the phone's id for each. A phone
/// that lost the answer sends its take again; the Mac may have typed the text
/// already, and must not type it twice. Held in memory: the newest `limit`
/// ids, for as long as the app runs. Safe on any queue.
final class MobileVoiceTakes {
    enum State: Equatable {
        /// The text is on its way to the target: not known yet to be there.
        case sending
        case sent
    }

    private let limit: Int
    private let lock = NSLock()
    /// Oldest first.
    private var ids: [String] = []
    private var states: [String: State] = [:]

    init(limit: Int = 64) {
        self.limit = limit
    }

    /// An id is a short word of letters, digits and dashes (a UUID).
    static func isID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.utf8.allSatisfy { $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    func state(of id: String) -> State? {
        lock.lock()
        defer { lock.unlock() }
        return states[id]
    }

    /// The text of take `id` is about to go to its target. False when it is
    /// on its way or there already: it must not go again.
    func begin(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard states[id] == nil else { return false }
        states[id] = .sending
        ids.append(id)
        while ids.count > limit { states[ids.removeFirst()] = nil }
        return true
    }

    func sent(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if states[id] != nil { states[id] = .sent }
    }

    /// The target did not take the text: the phone may send the take again.
    func forget(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard states[id] == .sending else { return }
        states[id] = nil
        ids.removeAll { $0 == id }
    }
}

enum MobileVoice {
    /// The longest take the server transcribes.
    static let maxSeconds: Double = 120
    /// A take shorter than this is a tap, not speech.
    static let minSeconds: Double = 0.3
    /// The rate speech-to-text takes, and the rate the phone is asked to send.
    static let sampleRate: Double = 16_000
    /// `maxSeconds` of 16-bit mono at `sampleRate`, with room for the header.
    /// A phone that sends its device rate without resampling goes over it.
    static let maxBodyBytes = 4_194_304
    /// The longest clip one `audio` event carries. A longer sentence is cut
    /// into clips, so no single event outgrows a stream's send buffer.
    static let maxClipSeconds: Double = 10

    /// The most of a reply Replay reads again, in characters: about three
    /// minutes of speech. A longer reply is read from its start.
    static let maxReplayCharacters = 3000

    static let heardNothing = "Heard nothing"
    static let modelsNotReady = "Voice models not ready"
    static let unavailable = "Voice is not available"
    static let busy = "A voice turn is running"
    static let nothingToReplay = "Nothing to replay"
    static let speechFailed = "Could not speak the reply"
    static let notText = "Could not use what was heard"
    static let tooMuchText = "Too much to send in one turn"
    static let sending = "Still sending"

    /// What was heard, held to the rules typed text is held to: the same check,
    /// `MobileManager.text`, on the same request body. Speech has no way
    /// around the filter and the size cap that guard the manager's pane.
    static func text(heard: String) -> MobileManager.Field {
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": heard]) else {
            return .invalid
        }
        return MobileManager.text(in: body)
    }

    enum Take: Equatable {
        case samples([Float])
        /// The words of a take that was heard before: nothing to transcribe.
        case heard(String)
        /// Why the audio is refused, as the response the phone shows.
        case refused(MobileResponse)
    }

    /// The take a request carries: its audio, or with `heard` its words.
    static func take(body: Data, heard: Bool) -> Take {
        guard heard else { return take(wav: body) }
        let field = MobileManager.text(in: body)
        guard case .value(let text) = field else {
            return .refused(field.refusal ?? .error(400, "bad_request"))
        }
        return .heard(text)
    }

    /// The whole stream for a take whose text is in the chat already: `sent`,
    /// then `end`. Nothing is typed and nothing is read.
    static let alreadySent: MobileResponse = {
        var body = MobileServer.event("sent", Data("{}".utf8))
        let end = (try? JSONSerialization.data(
            withJSONObject: MobileManager.end(.done(reply: "")), options: [.sortedKeys])) ?? Data("{}".utf8)
        body.append(MobileServer.event("end", end))
        return MobileResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-store"],
            body: body)
    }()

    /// The take in a WAV body as mono floats at `sampleRate`, or the refusal.
    static func take(wav: Data) -> Take {
        guard let audio = decode(wav: wav) else {
            return .refused(.error(400, "bad_audio", message: "Not a WAV recording"))
        }
        let seconds = Double(audio.samples.count) / audio.sampleRate
        if seconds > maxSeconds {
            return .refused(.error(
                413, "too_long", message: "Recording is longer than \(Int(maxSeconds)) seconds"))
        }
        if seconds < minSeconds {
            return .refused(.error(400, "too_short", message: "Recording too short"))
        }
        return .samples(resample(audio.samples, from: audio.sampleRate, to: sampleRate))
    }

    // MARK: WAV

    /// Decode a RIFF/WAVE file: 16-bit PCM or 32-bit float, any channel count,
    /// mixed down to mono. nil for anything else.
    static func decode(wav data: Data) -> (samples: [Float], sampleRate: Double)? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }

        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var format: (code: Int, channels: Int, rate: Int, bits: Int)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = tag(offset)
            let start = offset + 8
            // A writer that streams leaves the data size at 0 or at its maximum.
            let size = min(u32(offset + 4), bytes.count - start)
            if id == "fmt ", size >= 16 {
                var code = u16(start)
                // WAVE_FORMAT_EXTENSIBLE keeps the real code in its sub-format.
                if code == 0xFFFE, size >= 26 { code = u16(start + 24) }
                format = (code, u16(start + 2), u32(start + 4), u16(start + 14))
            } else if id == "data" {
                guard let format, format.channels >= 1, format.channels <= 8,
                      (8000...192_000).contains(format.rate)
                else { return nil }
                let width: Int
                switch (format.code, format.bits) {
                case (1, 16): width = 2
                case (3, 32): width = 4
                default: return nil
                }
                let frames = size / (width * format.channels)
                var samples = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<format.channels {
                        let at = start + (frame * format.channels + channel) * width
                        if width == 2 {
                            sum += Float(Int16(truncatingIfNeeded: u16(at))) / 32768
                        } else {
                            let value = Float(bitPattern: UInt32(truncatingIfNeeded: u32(at)))
                            sum += value.isFinite ? max(-1, min(1, value)) : 0
                        }
                    }
                    samples[frame] = sum / Float(format.channels)
                }
                return (samples, Double(format.rate))
            }
            // Chunks are padded to an even length.
            offset = start + size + (size & 1)
        }
        return nil
    }

    /// Mono floats as a 16-bit PCM WAV file.
    static func wav(samples: [Float], sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count * 2))
        for sample in samples {
            let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
            append(Int16(clipped * (clipped < 0 ? 32768 : 32767)))
        }
        return data
    }

    /// Change the sample rate. Going down, each output sample is the mean of
    /// the input it covers, which keeps speech clear of aliasing; going up is a
    /// straight line between neighbours.
    static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !samples.isEmpty else { return samples }
        let step = from / to
        let count = Int(Double(samples.count) / step)
        var out = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let start = Double(index) * step
            if step > 1 {
                let first = Int(start)
                let last = min(samples.count, max(first + 1, Int(start + step)))
                var sum: Float = 0
                for at in first..<last { sum += samples[at] }
                out[index] = sum / Float(last - first)
            } else {
                let left = min(Int(start), samples.count - 1)
                let right = min(left + 1, samples.count - 1)
                let mix = Float(start - Double(left))
                out[index] = samples[left] * (1 - mix) + samples[right] * mix
            }
        }
        return out
    }

    // MARK: Events

    /// The `audio` events for one synthesized sentence: one clip, or several
    /// when it runs past `maxClipSeconds`. Only the first carries the text.
    static func audioEvents(
        _ audio: SpeechAudio, text: String, firstSeq: Int
    ) -> [[String: Any]] {
        let limit = max(1, Int(audio.sampleRate * maxClipSeconds))
        var events: [[String: Any]] = []
        var start = 0
        while start < audio.samples.count {
            let end = min(audio.samples.count, start + limit)
            let clip = wav(samples: Array(audio.samples[start..<end]), sampleRate: audio.sampleRate)
            events.append([
                "seq": firstSeq + events.count, "text": start == 0 ? text : "",
                "wav": clip.base64EncodedString(),
            ])
            start = end
        }
        return events
    }

    /// The last event of a voice stream that never reached the target.
    static func end(_ outcome: String, message: String) -> [String: Any] {
        ["outcome": outcome, "reply": "", "message": message]
    }

    /// The last thing the manager said, for Replay: the newest assistant row of
    /// its transcript.
    static func lastReply(in chat: MobileChatPage?) -> String? {
        (chat?.messages.last { $0.role == .assistant }?.text).map { String($0.prefix(maxReplayCharacters)) }
    }

    /// The text of one chat row for the play button: an agent's row only,
    /// cut to Replay's limit.
    static func sayText(of row: MobileChatMessage?) -> String? {
        guard let row, row.role == .assistant else { return nil }
        return String(row.text.prefix(maxReplayCharacters))
    }

    static let modelsMissing = MobileResponse.error(503, "models", message: modelsNotReady)

    /// The sentence of a refusal response, for a turn that is refused after
    /// its stream has begun.
    static func message(of refusal: MobileResponse) -> String {
        let body = (try? JSONSerialization.jsonObject(with: refusal.body)) as? [String: Any]
        return body?["message"] as? String ?? unavailable
    }
}

/// One clip of a read-aloud, as its `audio` event carries it.
struct MobileVoiceClip: Equatable {
    let text: String
    /// The WAV file, base64.
    let wav: String

    init(text: String, wav: String) {
        self.text = text
        self.wav = wav
    }

    init?(event: [String: Any]) {
        guard let text = event["text"] as? String, let wav = event["wav"] as? String else { return nil }
        self.init(text: text, wav: wav)
    }

    func event(seq: Int) -> [String: Any] {
        ["seq": seq, "text": text, "wav": wav]
    }
}

/// A message read aloud to its end: its text and every clip, in order.
struct MobileSpokenReply: Equatable {
    let text: String
    let clips: [MobileVoiceClip]

    var bytes: Int { clips.reduce(text.utf8.count) { $0 + $1.text.utf8.count + $1.wav.utf8.count } }
}

/// Read-alouds already synthesized, so a second play of a message starts at
/// once. The least recently used goes first once there are more than
/// `entryLimit` or they hold more than `byteLimit` bytes.
struct MobileSpeechCache {
    /// One message in one voice: a change of voice or speed is a miss.
    struct Key: Hashable {
        let target: MobileVoiceTarget
        let n: UInt64
        let voice: String
        let speed: Float
    }

    let entryLimit: Int
    let byteLimit: Int
    /// Least recently used first.
    private(set) var keys: [Key] = []
    private(set) var bytes = 0
    private var replies: [Key: MobileSpokenReply] = [:]

    init(entryLimit: Int = 16, byteLimit: Int = 32 << 20) {
        self.entryLimit = entryLimit
        self.byteLimit = byteLimit
    }

    /// The reply for `key`, which becomes the most recently used.
    mutating func reply(for key: Key) -> MobileSpokenReply? {
        guard let reply = replies[key] else { return nil }
        keys.removeAll { $0 == key }
        keys.append(key)
        return reply
    }

    /// Keep `reply`, then let the oldest go until both limits hold. A reply
    /// larger than the whole cache is not kept.
    mutating func store(_ reply: MobileSpokenReply, for key: Key) {
        remove(key)
        guard !reply.clips.isEmpty, reply.bytes <= byteLimit else { return }
        replies[key] = reply
        keys.append(key)
        bytes += reply.bytes
        while keys.count > entryLimit || bytes > byteLimit { remove(keys[0]) }
    }

    private mutating func remove(_ key: Key) {
        guard let old = replies.removeValue(forKey: key) else { return }
        keys.removeAll { $0 == key }
        bytes -= old.bytes
    }
}

/// One voice turn from the phone. The take becomes text, the text goes to the
/// target the way typed text does, and the reply comes back as text and, with
/// the speaker on, as one clip per sentence. Every step is an event:
/// `transcript`, `sent`, `delta`, `audio`, then one `end`.
///
/// `sent` says the text is in the target's chat. Until it comes the phone
/// keeps the take, and may send it again; see `MobileVoiceTakes`.
///
/// With the speaker off nothing is synthesized: `VoiceSpeech.synthesize` is
/// never called, so the read-back model is not even loaded.
final class MobileVoiceTurn {
    /// `last` marks the event that ends the stream. Called on any queue.
    typealias Emit = (_ event: String, _ data: [String: Any], _ last: Bool) -> Void
    /// The target's own turn: `MobileServer.Manager.send`. `onSent` is for a
    /// target that knows the text is in its chat before the reply starts; a
    /// reply that starts, or an outcome that is a reply, says so too.
    typealias Send = (
        _ text: String, _ onSent: @escaping () -> Void, _ onDelta: @escaping (String) -> Void,
        _ completion: @escaping (ManagerTurnOutcome) -> Void
    ) -> Void

    private let speech: VoiceSpeech
    private let speaker: Bool
    /// The phone's id for this take, and where the sent ones are remembered.
    private let take: (id: String, takes: MobileVoiceTakes)?
    private let emit: Emit

    private let lock = NSLock()
    /// What `cancel` stops: the turn's task and the read-back's.
    private var cancels: [() -> Void] = []
    private var cancelled = false
    private var seq = 0
    private var streamed = false
    /// The text is in the target's chat, and the phone was told.
    private var submitted = false
    /// The clips sent so far, kept only for a read-aloud.
    private var kept: [MobileVoiceClip]?

    init(
        speech: VoiceSpeech, speaker: Bool, take: (id: String, takes: MobileVoiceTakes)? = nil,
        emit: @escaping Emit
    ) {
        self.speech = speech
        self.speaker = speaker
        self.take = take
        self.emit = emit
    }

    /// Transcribe `samples`, hand the text to `send`, and stream what comes back.
    func start(samples: [Float], send: @escaping Send) {
        run { await self.turn(samples: samples, send: send) }
    }

    /// Hand `text`, what an earlier try of this take was heard as, to `send`.
    /// Nothing is transcribed.
    func start(heard text: String, send: @escaping Send) {
        run { await self.deliver(text, send: send) }
    }

    /// Read `text` back and send nothing anywhere: the Replay button.
    func replay(_ text: String) {
        run {
            let (stream, continuation) = AsyncStream.makeStream(of: String.self)
            continuation.yield(text)
            continuation.finish()
            var end = MobileManager.end(.done(reply: text))
            if await !self.synthesize(stream) { end["message"] = MobileVoice.speechFailed }
            self.finish(end)
        }
    }

    /// Read one message aloud for the play button, like `replay`. `done`
    /// gets the clips once the whole text is synthesized; a read that was
    /// cancelled or failed gives it nothing.
    func say(_ text: String, done: @escaping (MobileSpokenReply) -> Void) {
        lock.lock()
        kept = []
        lock.unlock()
        run {
            let (stream, continuation) = AsyncStream.makeStream(of: String.self)
            continuation.yield(text)
            continuation.finish()
            var end = MobileManager.end(.done(reply: text))
            if await self.synthesize(stream) {
                if let clips = self.keptClips { done(MobileSpokenReply(text: text, clips: clips)) }
            } else {
                end["message"] = MobileVoice.speechFailed
            }
            self.finish(end)
        }
    }

    /// Send a read-aloud's clips again, then `end`. The engine is not asked.
    func play(_ reply: MobileSpokenReply) {
        for (index, clip) in reply.clips.enumerated() where !isCancelled {
            emit("audio", clip.event(seq: index), false)
        }
        finish(MobileManager.end(.done(reply: reply.text)))
    }

    /// The phone hung up or pressed Stop. Transcription and read-back stop;
    /// the target's own turn carries on, and its text lands where it always does.
    func cancel() {
        lock.lock()
        cancelled = true
        let running = cancels
        lock.unlock()
        running.forEach { $0() }
    }

    /// The clips a read-aloud sent, unless it was cancelled.
    private var keptClips: [MobileVoiceClip]? {
        lock.lock()
        defer { lock.unlock() }
        return cancelled ? nil : kept
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func run(_ body: @escaping () async -> Void) {
        let task = Task { await body() }
        track { task.cancel() }
    }

    private func track(_ cancel: @escaping () -> Void) {
        lock.lock()
        cancels.append(cancel)
        let late = cancelled
        lock.unlock()
        if late { cancel() }
    }

    private func finish(_ end: [String: Any]) {
        guard !isCancelled else { return }
        emit("end", end, true)
    }

    private func turn(samples: [Float], send: @escaping Send) async {
        let heard: String
        do {
            heard = try await speech.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return finish(MobileVoice.end("failed", message: error.localizedDescription))
        }
        guard !isCancelled else { return }
        await deliver(heard, send: send)
    }

    /// The text is in the target's chat: remember the take and tell the phone, once.
    private func markSent() {
        lock.lock()
        let first = !submitted
        submitted = true
        lock.unlock()
        guard first else { return }
        if let take { take.takes.sent(take.id) }
        emit("sent", [:], false)
    }

    /// What the target's turn came to, for the take: a reply means the text
    /// was sent. A turn that was refused, or a pane that could not be typed
    /// into, did not take it as far as the Mac can tell: the phone may try again.
    private func settle(_ outcome: ManagerTurnOutcome) {
        switch outcome {
        case .done, .permission, .timeout:
            markSent()
        case .refused, .unreachable:
            lock.lock()
            let submitted = self.submitted
            lock.unlock()
            if !submitted, let take { take.takes.forget(take.id) }
        }
    }

    private func deliver(_ heard: String, send: @escaping Send) async {
        guard !heard.isEmpty else {
            return finish(MobileVoice.end("empty", message: MobileVoice.heardNothing))
        }
        let text: String
        switch MobileVoice.text(heard: heard) {
        case .value(let value): text = value
        case .tooLong: return finish(MobileVoice.end("failed", message: MobileVoice.tooMuchText))
        case .invalid: return finish(MobileVoice.end("failed", message: MobileVoice.notText))
        }
        emit("transcript", ["text": text], false)
        // From here the text may reach the chat. A second try of this take
        // that comes while this one runs must not type it too.
        if let take, !take.takes.begin(take.id) {
            return finish(MobileVoice.end("refused", message: MobileVoice.sending))
        }

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        var spoken: Task<Bool, Never>?
        if speaker {
            let task = Task { await self.synthesize(stream) }
            spoken = task
            track { task.cancel() }
        }
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<ManagerTurnOutcome, Never>) in
            send(
                text,
                { [weak self] in self?.markSent() },
                { [weak self] delta in
                    guard let self, !delta.isEmpty else { return }
                    // A reply has started: the text is in the chat.
                    self.markSent()
                    self.lock.lock()
                    self.streamed = true
                    self.lock.unlock()
                    self.emit("delta", ["text": delta], false)
                    continuation.yield(delta)
                },
                { [weak self] outcome in
                    self?.settle(outcome)
                    // A reply that never streamed is still read back whole.
                    if let self, let reply = outcome.readback {
                        self.lock.lock()
                        let streamed = self.streamed
                        self.lock.unlock()
                        if !streamed { continuation.yield(reply) }
                    }
                    continuation.finish()
                    done.resume(returning: outcome)
                })
        }
        var end = MobileManager.end(outcome)
        // The reply is already on screen as text; a failed read-back is a note.
        if let spoken, await !spoken.value, end["message"] is NSNull {
            end["message"] = MobileVoice.speechFailed
        }
        finish(end)
    }

    /// Synthesize the reply sentence by sentence and emit each clip in order.
    /// False when the engine failed.
    private func synthesize(_ text: AsyncStream<String>) async -> Bool {
        do {
            try await speech.synthesize(text) { [weak self] audio, sentence in
                guard let self, !self.isCancelled else { return }
                self.lock.lock()
                let first = self.seq
                let events = MobileVoice.audioEvents(audio, text: sentence, firstSeq: first)
                self.seq += events.count
                self.kept?.append(contentsOf: events.compactMap(MobileVoiceClip.init(event:)))
                self.lock.unlock()
                for event in events { self.emit("audio", event, false) }
            }
            return true
        } catch {
            return isCancelled
        }
    }
}
