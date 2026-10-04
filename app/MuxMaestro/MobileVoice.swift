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
enum MobileVoiceTarget: Equatable {
    case manager
    /// One thread's pane, by its phone id.
    case thread(String)
}

/// The query of a voice request: `?target=manager&speaker=1`.
struct MobileVoiceRequest: Equatable {
    var target: MobileVoiceTarget
    /// Off means input only: nothing is synthesized.
    var speaker: Bool

    init(target: MobileVoiceTarget, speaker: Bool) {
        self.target = target
        self.speaker = speaker
    }

    init?(query: [String: String]) {
        guard let target = query["target"], !target.isEmpty else { return nil }
        self.target = target == "manager" ? .manager : .thread(target)
        speaker = query["speaker"] == "1"
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
    static let managerOnly = "Voice goes to the manager only"
    static let nothingToReplay = "Nothing to replay"
    static let speechFailed = "Could not speak the reply"
    static let notText = "Could not use what was heard"
    static let tooMuchText = "Too much to send in one turn"

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
        /// Why the audio is refused, as the response the phone shows.
        case refused(MobileResponse)
    }

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

    static let modelsMissing = MobileResponse.error(503, "models", message: modelsNotReady)

    /// The sentence of a refusal response, for a turn that is refused after
    /// its stream has begun.
    static func message(of refusal: MobileResponse) -> String {
        let body = (try? JSONSerialization.jsonObject(with: refusal.body)) as? [String: Any]
        return body?["message"] as? String ?? unavailable
    }
}

/// One voice turn from the phone. The take becomes text, the text goes to the
/// target the way typed text does, and the reply comes back as text and, with
/// the speaker on, as one clip per sentence. Every step is an event:
/// `transcript`, `delta`, `audio`, then one `end`.
///
/// With the speaker off nothing is synthesized: `VoiceSpeech.synthesize` is
/// never called, so the read-back model is not even loaded.
final class MobileVoiceTurn {
    /// `last` marks the event that ends the stream. Called on any queue.
    typealias Emit = (_ event: String, _ data: [String: Any], _ last: Bool) -> Void
    /// The target's own turn: `MobileServer.Manager.send`.
    typealias Send = (
        _ text: String, _ onDelta: @escaping (String) -> Void,
        _ completion: @escaping (ManagerTurnOutcome) -> Void
    ) -> Void

    private let speech: VoiceSpeech
    private let speaker: Bool
    private let emit: Emit

    private let lock = NSLock()
    /// What `cancel` stops: the turn's task and the read-back's.
    private var cancels: [() -> Void] = []
    private var cancelled = false
    private var seq = 0
    private var streamed = false

    init(speech: VoiceSpeech, speaker: Bool, emit: @escaping Emit) {
        self.speech = speech
        self.speaker = speaker
        self.emit = emit
    }

    /// Transcribe `samples`, hand the text to `send`, and stream what comes back.
    func start(samples: [Float], send: @escaping Send) {
        run { await self.turn(samples: samples, send: send) }
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

    /// The phone hung up or pressed Stop. Transcription and read-back stop;
    /// the target's own turn carries on, and its text lands where it always does.
    func cancel() {
        lock.lock()
        cancelled = true
        let running = cancels
        lock.unlock()
        running.forEach { $0() }
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
                { [weak self] delta in
                    guard let self, !delta.isEmpty else { return }
                    self.lock.lock()
                    self.streamed = true
                    self.lock.unlock()
                    self.emit("delta", ["text": delta], false)
                    continuation.yield(delta)
                },
                { [weak self] outcome in
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
                self.lock.unlock()
                for event in events { self.emit("audio", event, false) }
            }
            return true
        } catch {
            return isCancelled
        }
    }
}
