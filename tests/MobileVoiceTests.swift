import Network
import XCTest

// MobileVoice.swift (Foundation only) compiles into this test target. The WAV
// reader, the limits and one voice turn are asserted with a fake engine; the
// routes are then driven over a real loopback socket, as a phone would.

/// The engine, scripted. It never loads a model: it counts what was asked.
private final class FakeSpeech: VoiceSpeech {
    private let lock = NSLock()
    private var _transcribed: [Int] = []
    private var _synthesized: [String] = []
    private var _synthCalls = 0

    var modelsReady = true
    var transcript = "what needs me"
    var failTranscribe = false
    var failSynthesize = false
    /// Runs while a take is being transcribed: what changes in that time.
    var whileTranscribing: (() -> Void)?
    /// When set, transcription does not finish until this is signalled.
    var gate: DispatchSemaphore?

    /// The sample count of each take that was transcribed.
    var transcribed: [Int] { lock.lock(); defer { lock.unlock() }; return _transcribed }
    var synthesized: [String] { lock.lock(); defer { lock.unlock() }; return _synthesized }
    var synthCalls: Int { lock.lock(); defer { lock.unlock() }; return _synthCalls }

    struct Failed: LocalizedError {
        var errorDescription: String? { "Engine failed" }
    }

    func prepare() async {}

    func transcribe(_ samples: [Float]) async throws -> String {
        lock.lock(); _transcribed.append(samples.count); lock.unlock()
        whileTranscribing?()
        if let gate {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    gate.wait()
                    done.resume()
                }
            }
        }
        if failTranscribe { throw Failed() }
        return transcript
    }

    func speak(_ text: AsyncStream<String>) async throws {
        XCTFail("a phone turn must never play on the Mac")
    }

    func stopSpeaking() async {}

    /// One clip per piece of text, 0.1 s each.
    func synthesize(
        _ text: AsyncStream<String>, onAudio: @escaping (SpeechAudio, String) -> Void
    ) async throws {
        lock.lock(); _synthCalls += 1; lock.unlock()
        for await piece in text {
            try Task.checkCancellation()
            if failSynthesize { throw Failed() }
            let sentence = piece.trimmingCharacters(in: .whitespaces)
            lock.lock(); _synthesized.append(sentence); lock.unlock()
            onAudio(SpeechAudio(samples: [Float](repeating: 0.25, count: 2400), sampleRate: 24_000), sentence)
        }
    }
}

/// What a turn emitted, in order.
private final class Events {
    private let lock = NSLock()
    private var _all: [(name: String, data: [String: Any], last: Bool)] = []

    var all: [(name: String, data: [String: Any], last: Bool)] {
        lock.lock(); defer { lock.unlock() }; return _all
    }
    var names: [String] { all.map(\.name) }
    var ended: Bool { all.contains { $0.last } }

    func add(_ name: String, _ data: [String: Any], _ last: Bool) {
        lock.lock(); _all.append((name, data, last)); lock.unlock()
    }
}

private func tone(seconds: Double, rate: Double = 16_000) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.5 }
}

final class MobileVoiceTests: XCTestCase {
    // MARK: request, config, routing

    func testReadsTheTargetAndTheSpeakerFromTheQuery() {
        XCTAssertEqual(
            MobileVoiceRequest(query: ["target": "manager", "speaker": "1"]),
            MobileVoiceRequest(target: .manager, speaker: true))
        XCTAssertEqual(
            MobileVoiceRequest(query: ["target": "local:12"]),
            MobileVoiceRequest(target: .thread("local:12"), speaker: false))
        XCTAssertNil(MobileVoiceRequest(query: ["speaker": "1"]))
    }

    func testConfigCarriesTheVoiceDefaults() throws {
        var config = MobileConfig(capabilities: [.voice])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: config.json()) as? [String: Any])
        XCTAssertEqual(object["voice"] as? NSDictionary, ["mode": "manual", "speaker": true, "maxSeconds": 120])
        config.voice = MobileVoiceDefaults(mode: .auto, speaker: false)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: config.json()) as? [String: Any])
        XCTAssertEqual(object["voice"] as? NSDictionary, ["mode": "auto", "speaker": false, "maxSeconds": 120])
    }

    func testVoiceSettingsRoundTripIntoTheServerConfig() throws {
        let suite = "mobile-voice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Settings.phoneVoice(defaults: defaults), MobileVoiceDefaults(mode: .manual, speaker: true))
        XCTAssertFalse(Settings.phoneConfig(defaults: defaults).allows(.voice))

        Settings.setPhoneCapability(.voice, true, defaults: defaults)
        Settings.setPhoneVoice(MobileVoiceDefaults(mode: .auto, speaker: false), defaults: defaults)
        let config = Settings.phoneConfig(defaults: defaults)
        XCTAssertTrue(config.allows(.voice))
        XCTAssertEqual(config.voice, MobileVoiceDefaults(mode: .auto, speaker: false))
    }

    func testRoutesTheVoiceAPIAndRefusesItWhileTheSwitchIsOff() {
        let on = MobileConfig(capabilities: [.voice])
        for (path, route) in [
            ("/api/voice", MobileRoute.api(.voice)), ("/api/voice/replay", .api(.voiceReplay)),
            ("/api/voice/warm", .api(.voiceWarm)),
        ] {
            let post = MobileRequest(method: "POST", path: path)
            XCTAssertEqual(MobileAPI.route(post, config: on), route)
            XCTAssertEqual(MobileAPI.route(MobileRequest(method: "GET", path: path), config: on), .methodNotAllowed)
            XCTAssertEqual(MobileAPI.route(post, config: MobileConfig()), .disabled(.voice))
            // The manager's switch does not open voice.
            XCTAssertEqual(
                MobileAPI.route(post, config: MobileConfig(capabilities: [.manager])), .disabled(.voice))
        }
        XCTAssertEqual(MobileAPI.route(MobileRequest(method: "POST", path: "/api/voice/other"), config: on), .notFound)
        // Each voice route names the Voice capability and is a write.
        for endpoint in [MobileEndpoint.voice, .voiceReplay, .voiceWarm] {
            XCTAssertEqual(endpoint.capability, .voice)
            XCTAssertEqual(endpoint.method, "POST")
        }
    }

    func testWhatWasHeardIsHeldToTheRulesOfTypedText() {
        XCTAssertEqual(MobileVoice.text(heard: "what needs me"), .value("what needs me"))
        XCTAssertEqual(MobileVoice.text(heard: "line one\nline two"), .value("line one\nline two"))
        // A control character is a key press in a terminal, not text.
        XCTAssertEqual(MobileVoice.text(heard: "stop\u{1B}[A"), .invalid)
        XCTAssertEqual(MobileVoice.text(heard: "go\u{03}"), .invalid)
        XCTAssertEqual(MobileVoice.text(heard: "enter\rnow"), .invalid)
        XCTAssertEqual(
            MobileVoice.text(heard: String(repeating: "a", count: MobileManager.maxTextBytes + 1)), .tooLong)
    }

    func testOnlyAVoiceTakeMayCarryMoreThanTheUsualBody() {
        func parse(_ path: String, length: Int) -> MobileHTTP.Parsed {
            MobileHTTP.parse(Data("POST \(path) HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8))
        }
        XCTAssertEqual(parse("/api/voice?target=manager", length: 2_000_000), .incomplete)
        XCTAssertEqual(parse("/api/voice", length: MobileVoice.maxBodyBytes + 1), .invalid(413))
        XCTAssertEqual(parse("/api/manager/text", length: 2_000_000), .invalid(413))
        XCTAssertEqual(parse("/api/voice/replay", length: 2_000_000), .invalid(413))
        // The limit holds the longest take the server accepts, at the rate it asks for.
        XCTAssertGreaterThan(
            MobileVoice.maxBodyBytes, Int(MobileVoice.maxSeconds * MobileVoice.sampleRate) * 2 + 44)
    }

    // MARK: audio

    func testAWAVRoundTripsThroughTheReader() throws {
        let samples = tone(seconds: 0.5)
        let wav = MobileVoice.wav(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        let decoded = try XCTUnwrap(MobileVoice.decode(wav: wav))
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.samples.count, samples.count)
        for (a, b) in zip(decoded.samples, samples) { XCTAssertEqual(a, b, accuracy: 0.001) }
    }

    func testReadsStereoFloatAndAStreamedDataSize() throws {
        // 32-bit float, two channels, 48 kHz, with the data size left at its maximum.
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        append(UInt32.max)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(3)); append(UInt16(2)); append(UInt32(48_000))
        append(UInt32(48_000 * 8)); append(UInt16(8)); append(UInt16(32))
        wav.append(Data("data".utf8))
        append(UInt32.max)
        for _ in 0..<100 {
            append(Float(0.5).bitPattern)
            append(Float(-0.25).bitPattern)
        }
        let decoded = try XCTUnwrap(MobileVoice.decode(wav: wav))
        XCTAssertEqual(decoded.sampleRate, 48_000)
        XCTAssertEqual(decoded.samples.count, 100)
        XCTAssertEqual(decoded.samples[0], 0.125, accuracy: 0.0001)
    }

    func testATakeIsResampledToTheRateSpeechToTextTakes() {
        let wav = MobileVoice.wav(samples: tone(seconds: 1, rate: 48_000), sampleRate: 48_000)
        guard case .samples(let samples) = MobileVoice.take(wav: wav) else { return XCTFail("refused") }
        XCTAssertEqual(samples.count, 16_000)
        // Still the same tone: about 220 upward zero crossings in one second.
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings), 220, accuracy: 2)
        XCTAssertEqual(MobileVoice.resample([0, 1], from: 8000, to: 16_000), [0, 0.5, 1, 1])
    }

    func testRefusesAudioThatIsNotAWAVOrIsTooShortOrTooLong() {
        func refusal(_ data: Data) -> (Int, String)? {
            guard case .refused(let response) = MobileVoice.take(wav: data) else { return nil }
            return (response.status, String(decoding: response.body, as: UTF8.self))
        }
        XCTAssertEqual(refusal(Data("not audio".utf8))?.0, 400)
        XCTAssertEqual(refusal(Data())?.0, 400)
        // A compressed recording (format 85) is not read.
        var mp3 = MobileVoice.wav(samples: tone(seconds: 1), sampleRate: 16_000)
        mp3[20] = 85
        XCTAssertEqual(refusal(mp3)?.0, 400)

        let short = refusal(MobileVoice.wav(samples: tone(seconds: 0.1), sampleRate: 16_000))
        XCTAssertEqual(short?.0, 400)
        XCTAssertEqual(short?.1, #"{"error":"too_short","message":"Recording too short"}"#)

        // 121 s at 8 kHz fits the body limit and is still refused by its length.
        let long = MobileVoice.wav(
            samples: [Float](repeating: 0, count: 121 * 8000), sampleRate: 8000)
        XCTAssertLessThan(long.count, MobileVoice.maxBodyBytes)
        XCTAssertEqual(refusal(long)?.0, 413)
        XCTAssertEqual(
            refusal(long)?.1, #"{"error":"too_long","message":"Recording is longer than 120 seconds"}"#)
    }

    func testALongSentenceIsCutIntoClipsThatEachDecode() throws {
        let audio = SpeechAudio(samples: [Float](repeating: 0.1, count: 24_000 * 25), sampleRate: 24_000)
        let events = MobileVoice.audioEvents(audio, text: "A long sentence.", firstSeq: 4)
        XCTAssertEqual(events.map { $0["seq"] as? Int }, [4, 5, 6])
        XCTAssertEqual(events.map { $0["text"] as? String }, ["A long sentence.", "", ""])
        let seconds = try events.map { event -> Double in
            let wav = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(event["wav"] as? String)))
            let clip = try XCTUnwrap(MobileVoice.decode(wav: wav))
            XCTAssertEqual(clip.sampleRate, 24_000)
            return Double(clip.samples.count) / clip.sampleRate
        }
        XCTAssertEqual(seconds, [10, 10, 5])
    }

    func testReplayReadsNoMoreThanItsLimit() {
        var page = MobileChatPage()
        page.messages = [MobileChatMessage(
            n: 1, role: .assistant, text: String(repeating: "word ", count: 1500))]
        XCTAssertEqual(MobileVoice.lastReply(in: page)?.count, MobileVoice.maxReplayCharacters)
    }

    func testAHeavyTakeIsCheckedOnItsHeadersBeforeItsBodyIsHeld() {
        let head = Data("POST /api/voice HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n".utf8)
        // Refused with nothing of the body read.
        XCTAssertEqual(MobileHTTP.parse(head) { _ in 401 }, .invalid(401))
        XCTAssertEqual(MobileHTTP.parse(head) { _ in nil }, .incomplete)
        // The check sees the request's headers and query.
        var seen: MobileRequest?
        _ = MobileHTTP.parse(Data(
            "POST /api/voice?target=manager HTTP/1.1\r\nX-MuxMaestro-Token: t\r\nContent-Length: 2000000\r\n\r\n".utf8)) {
            seen = $0
            return nil
        }
        XCTAssertEqual(seen?.header("x-muxmaestro-token"), "t")
        XCTAssertEqual(seen?.query["target"], "manager")
        // A request of ordinary size is not asked about: its route checks it.
        let small = Data("POST /api/voice HTTP/1.1\r\nContent-Length: 4\r\n\r\nRIFF".utf8)
        guard case .request = MobileHTTP.parse(small, precheck: { _ in 401 }) else {
            return XCTFail("a small request must parse")
        }
    }

    func testReplayReadsTheLastThingTheManagerSaid() {
        var page = MobileChatPage()
        XCTAssertNil(MobileVoice.lastReply(in: nil))
        XCTAssertNil(MobileVoice.lastReply(in: page))
        page.messages = [
            MobileChatMessage(n: 1, role: .assistant, text: "Nothing needs you."),
            MobileChatMessage(n: 2, role: .user, text: "and now?"),
            MobileChatMessage(n: 3, role: .assistant, text: "Two threads need you."),
            MobileChatMessage(n: 4, role: .tool, text: "ls", tool: "Bash"),
        ]
        XCTAssertEqual(MobileVoice.lastReply(in: page), "Two threads need you.")
    }

    // MARK: one turn

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Run one turn against a target that streams `deltas` and ends with `outcome`.
    private func turn(
        speech: FakeSpeech, speaker: Bool, deltas: [String], outcome: ManagerTurnOutcome
    ) async -> (events: Events, sent: [String]) {
        let events = Events()
        let sent = Events()
        let turn = MobileVoiceTurn(speech: speech, speaker: speaker, emit: events.add)
        turn.start(samples: tone(seconds: 1)) { text, onDelta, completion in
            sent.add(text, [:], false)
            DispatchQueue.global().async {
                deltas.forEach(onDelta)
                completion(outcome)
            }
        }
        await settle { events.ended }
        return (events, sent.names)
    }

    func testATwoWayTurnSendsTheTranscriptThenTheReplyAsTextAndAudio() async throws {
        let speech = FakeSpeech()
        let (events, sent) = await turn(
            speech: speech, speaker: true, deltas: ["Two threads need you. ", "Checkout fix is one."],
            outcome: .done(reply: "Two threads need you. Checkout fix is one."))
        XCTAssertEqual(sent, ["what needs me"])
        XCTAssertEqual(speech.transcribed, [16_000])
        XCTAssertEqual(speech.synthesized, ["Two threads need you.", "Checkout fix is one."])

        let all = events.all
        XCTAssertEqual(all.first?.name, "transcript")
        XCTAssertEqual(all.first?.data["text"] as? String, "what needs me")
        XCTAssertEqual(all.filter { $0.name == "delta" }.compactMap { $0.data["text"] as? String },
                       ["Two threads need you. ", "Checkout fix is one."])
        let audio = all.filter { $0.name == "audio" }
        XCTAssertEqual(audio.map { $0.data["seq"] as? Int }, [0, 1])
        XCTAssertEqual(audio.map { $0.data["text"] as? String },
                       ["Two threads need you.", "Checkout fix is one."])
        let wav = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(audio[0].data["wav"] as? String)))
        XCTAssertEqual(MobileVoice.decode(wav: wav)?.samples.count, 2400)

        // The end comes last, after every clip, and only it closes the stream.
        XCTAssertEqual(all.last?.name, "end")
        XCTAssertEqual(all.filter(\.last).count, 1)
        XCTAssertEqual(all.last?.data["outcome"] as? String, "done")
        XCTAssertEqual(all.last?.data["reply"] as? String, "Two threads need you. Checkout fix is one.")
        XCTAssertTrue(all.last?.data["message"] is NSNull)
    }

    func testWithTheSpeakerOffNothingIsSynthesized() async {
        let speech = FakeSpeech()
        let (events, sent) = await turn(
            speech: speech, speaker: false, deltas: ["Two threads need you."],
            outcome: .done(reply: "Two threads need you."))
        XCTAssertEqual(sent, ["what needs me"])
        XCTAssertEqual(speech.synthCalls, 0)
        XCTAssertEqual(speech.synthesized, [])
        XCTAssertEqual(events.names, ["transcript", "delta", "end"])
    }

    func testAReplyThatNeverStreamedIsStillReadBackWhole() async {
        let speech = FakeSpeech()
        let (events, _) = await turn(
            speech: speech, speaker: true, deltas: [], outcome: .done(reply: "Nothing needs you."))
        XCTAssertEqual(speech.synthesized, ["Nothing needs you."])
        XCTAssertEqual(events.names, ["transcript", "audio", "end"])
    }

    func testATakeWithNoWordsEndsBeforeTheTargetSeesIt() async {
        let speech = FakeSpeech()
        speech.transcript = "  "
        let (events, sent) = await turn(speech: speech, speaker: true, deltas: [], outcome: .done(reply: ""))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(speech.synthCalls, 0)
        XCTAssertEqual(events.names, ["end"])
        XCTAssertEqual(events.all.last?.data["outcome"] as? String, "empty")
        XCTAssertEqual(events.all.last?.data["message"] as? String, "Heard nothing")
    }

    func testAnEngineFailureIsAnEndEventNotSpeech() async {
        let speech = FakeSpeech()
        speech.failTranscribe = true
        var (events, sent) = await turn(speech: speech, speaker: true, deltas: [], outcome: .done(reply: ""))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(events.all.last?.data["outcome"] as? String, "failed")
        XCTAssertEqual(events.all.last?.data["message"] as? String, "Engine failed")

        // A read-back that fails leaves the reply as text, with a note.
        speech.failTranscribe = false
        speech.failSynthesize = true
        (events, sent) = await turn(
            speech: speech, speaker: true, deltas: ["Two threads need you."],
            outcome: .done(reply: "Two threads need you."))
        XCTAssertEqual(sent, ["what needs me"])
        XCTAssertEqual(events.names, ["transcript", "delta", "end"])
        XCTAssertEqual(events.all.last?.data["outcome"] as? String, "done")
        XCTAssertEqual(events.all.last?.data["message"] as? String, "Could not speak the reply")
    }

    func testWordsThatAreNotTextNeverReachTheTarget() async {
        let speech = FakeSpeech()
        speech.transcript = "approve it\u{1B}[B\r"
        var (events, sent) = await turn(speech: speech, speaker: true, deltas: [], outcome: .done(reply: ""))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(events.names, ["end"])
        XCTAssertEqual(events.all.last?.data["outcome"] as? String, "failed")
        XCTAssertEqual(events.all.last?.data["message"] as? String, "Could not use what was heard")

        speech.transcript = String(repeating: "word ", count: 2000)
        (events, sent) = await turn(speech: speech, speaker: true, deltas: [], outcome: .done(reply: ""))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(events.all.last?.data["message"] as? String, "Too much to send in one turn")
        XCTAssertEqual(speech.synthCalls, 0)
    }

    func testARefusedTurnSaysWhyAndReadsNothingBack() async {
        let speech = FakeSpeech()
        let (events, _) = await turn(
            speech: speech, speaker: true, deltas: [], outcome: .refused("Manager is waiting on a prompt"))
        XCTAssertEqual(speech.synthesized, [])
        XCTAssertEqual(events.names, ["transcript", "end"])
        XCTAssertEqual(events.all.last?.data["outcome"] as? String, "refused")
        XCTAssertEqual(events.all.last?.data["message"] as? String, "Manager is waiting on a prompt")
    }

    func testACancelledTurnEmitsNothingMore() async {
        let speech = FakeSpeech()
        let events = Events()
        var finish: ((ManagerTurnOutcome) -> Void)?
        var reply: ((String) -> Void)?
        let turn = MobileVoiceTurn(speech: speech, speaker: true, emit: events.add)
        turn.start(samples: tone(seconds: 1)) { _, onDelta, completion in
            reply = onDelta
            finish = completion
        }
        await settle { finish != nil }
        XCTAssertEqual(events.names, ["transcript"])
        turn.cancel()
        // The target's own turn carries on; the phone that hung up hears none of it.
        reply?("Two threads need you.")
        finish?(.done(reply: "Two threads need you."))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(events.names.contains("audio"))
        XCTAssertFalse(events.ended)
    }

    func testReplaySynthesizesTheTextAndSendsNothing() async {
        let speech = FakeSpeech()
        let events = Events()
        MobileVoiceTurn(speech: speech, speaker: true, emit: events.add).replay("Two threads need you.")
        await settle { events.ended }
        XCTAssertEqual(speech.transcribed, [])
        XCTAssertEqual(speech.synthesized, ["Two threads need you."])
        XCTAssertEqual(events.names, ["audio", "end"])
        XCTAssertEqual(events.all.last?.data["reply"] as? String, "Two threads need you.")
    }
}

// MARK: - Model loads

final class SerialLoadsTests: XCTestCase {
    /// A stand-in for the engine: what is loaded, and how the loads ran.
    private actor Models {
        var loaded: Set<String> = []
        var running = 0
        var overlapped = false
        var loads: [Set<String>] = []
        var failNext = false

        func has(_ wanted: Set<String>) -> Bool { wanted.isSubset(of: loaded) }

        func load(_ wanted: Set<String>) async throws {
            running += 1
            if running > 1 { overlapped = true }
            loads.append(wanted)
            try? await Task.sleep(nanoseconds: 20_000_000)
            running -= 1
            if failNext {
                failNext = false
                throw CancellationError()
            }
            loaded.formUnion(wanted)
        }

        func fail() { failNext = true }
    }

    private func ensure(_ loads: SerialLoads, _ models: Models, _ wanted: Set<String>) async throws {
        try await loads.ensure(ready: { await models.has(wanted) }, load: { try await models.load(wanted) })
    }

    /// Finish within `seconds`, or fail: the bug this guards was a wait that
    /// never ended.
    private func finishes(_ seconds: Double = 5, _ body: @escaping () async throws -> Void) async {
        let done = expectation(description: "finished")
        let task = Task {
            try? await body()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: seconds)
        task.cancel()
    }

    func testAWaiterThatNeedsADifferentModelLoadsItAfterTheRunningLoad() async {
        let loads = SerialLoads(), models = Models()
        // Replay loads the read-back model; a take a moment later needs the other one.
        await finishes {
            async let replay: Void = self.ensure(loads, models, ["kokoro"])
            async let take: Void = self.ensure(loads, models, ["whisper"])
            _ = try await (replay, take)
        }
        let loaded = await models.loaded, overlapped = await models.overlapped, count = await models.loads.count
        XCTAssertEqual(loaded, ["kokoro", "whisper"])
        XCTAssertFalse(overlapped)
        XCTAssertEqual(count, 2)
    }

    func testManyMixedCallersAllFinishWithOneLoadAtATime() async {
        let loads = SerialLoads(), models = Models()
        let wanted: [Set<String>] = [["whisper"], ["kokoro"], ["whisper", "kokoro"], ["kokoro"], ["whisper"]]
        await finishes {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for round in 0..<40 {
                    group.addTask { try await self.ensure(loads, models, wanted[round % wanted.count]) }
                }
                try await group.waitForAll()
            }
        }
        let loaded = await models.loaded, overlapped = await models.overlapped, count = await models.loads.count
        XCTAssertEqual(loaded, ["kokoro", "whisper"])
        XCTAssertFalse(overlapped)
        // No caller loaded what was already there.
        XCTAssertLessThanOrEqual(count, 3)
    }

    func testWhatIsAlreadyLoadedLoadsNothing() async throws {
        let loads = SerialLoads(), models = Models()
        try await ensure(loads, models, ["whisper"])
        try await ensure(loads, models, ["whisper"])
        let count = await models.loads.count
        XCTAssertEqual(count, 1)
    }

    func testAFailedLoadFailsItsCallerAndAWaiterLoadsForItself() async {
        let loads = SerialLoads(), models = Models()
        await models.fail()
        var firstFailed = false
        await finishes {
            async let first: Void = self.ensure(loads, models, ["whisper"])
            try? await Task.sleep(nanoseconds: 5_000_000)
            async let second: Void = self.ensure(loads, models, ["whisper"])
            do { try await first } catch { firstFailed = true }
            try await second
        }
        XCTAssertTrue(firstFailed)
        let loaded = await models.loaded
        XCTAssertEqual(loaded, ["whisper"])
    }
}

// MARK: - Over the socket

final class MobileVoiceServerTests: XCTestCase {
    private let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")
    private var server: MobileServer!
    private var port = 0
    private var root: URL!
    private let speech = FakeSpeech()
    private let pane = FakePane()
    private var threadTranscript: URL { root.appendingPathComponent("thread.jsonl") }
    private let lock = NSLock()
    private var sent: [String] = []
    private var warmed: [Bool] = []
    private var status = MobileManagerStatus.idle
    private var transcript: String?
    private var script: (deltas: [String], outcome: ManagerTurnOutcome) =
        (["Two threads need you."], .done(reply: "Two threads need you."))

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = MobileServer(
            staticRoot: nil,
            sources: MobileServer.Sources(
                screen: { _, _ in nil },
                transcript: { [unowned self] _ in (threadTranscript.path, false) },
                pane: { [pane] _ in pane.io }),
            manager: MobileServer.Manager(
                pane: { [unowned self] in locked { (status, transcript) } },
                send: { [unowned self] text, onDelta, completion in
                    let script = locked { () -> (deltas: [String], outcome: ManagerTurnOutcome) in
                        sent.append(text)
                        return self.script
                    }
                    DispatchQueue.global().async {
                        script.deltas.forEach(onDelta)
                        completion(script.outcome)
                    }
                },
                dismiss: { _ in }, screen: { _ in nil }),
            voice: MobileServer.Voice(
                speech: speech, warm: { [unowned self] speaker in locked { warmed.append(speaker) } }))
        let started = expectation(description: "listening")
        server.start(port: 0, identity: identity, token: Self.token) { result in
            if case .success(let bound) = result { self.port = bound }
            started.fulfill()
        }
        wait(for: [started], timeout: 5)
        server.configure(MobileConfig(capabilities: [.manager, .voice]))
        var agent = TmuxPane(id: "%12", index: 0, command: "claude", title: "", active: true)
        agent.claudeSessionId = "c1"
        agent.attention = .idle
        server.update(MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: "acme-app", attached: true, windows: [
                TmuxWindow(index: 1, name: "deploy-fix", active: true, panes: [agent]),
            ])])]))
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private static let take = MobileVoice.wav(samples: tone(seconds: 1), sampleRate: 16_000)
    private static let token = "demo-token"
    private static let appHeaders = [
        "Origin": "https://devmac.example.ts.net:7433", "X-MuxMaestro": "1",
        "X-MuxMaestro-Token": token,
    ]

    /// A POST as the app sends it. `headers` replaces the app's own, to be a
    /// page from somewhere else. Reads until the reply is whole.
    private func post(
        _ path: String, body: Data = Data(),
        headers: [String: String] = appHeaders,
        contentLength: Int? = nil
    ) -> (status: Int, body: String) {
        var raw = "POST \(path) HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
            + "Tailscale-User-Login: me@example.com\r\nContent-Type: audio/wav\r\n"
            + "Content-Length: \(contentLength ?? body.count)\r\n"
        for (name, value) in headers { raw += "\(name): \(value)\r\n" }
        var data = Data((raw + "\r\n").utf8)
        data.append(body)

        func whole(_ received: Data) -> Bool {
            let text = String(decoding: received, as: UTF8.self)
            guard let head = text.range(of: "\r\n\r\n") else { return false }
            if text.contains("text/event-stream") {
                return text.contains("event: end") && text.hasSuffix("\n\n")
            }
            let length = text[..<head.lowerBound].components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            return text[head.upperBound...].utf8.count >= length
        }
        let text = String(
            decoding: LoopbackClient.exchange(
                port: port, send: data, label: "mobile-voice-tests", maximumLength: 1_048_576,
                until: whole),
            as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        return (Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0,
                parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func events(_ body: String) -> [(name: String, data: [String: Any])] {
        body.components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { block in
            let lines = block.components(separatedBy: "\n")
            let json = lines.first { $0.hasPrefix("data: ") }.map { Data($0.dropFirst(6).utf8) }
            return (
                String(lines.first { $0.hasPrefix("event: ") }?.dropFirst(7) ?? ""),
                json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
        }
    }

    func testATwoWayTakeStreamsTranscriptReplyAndAudio() {
        let turn = post("/api/voice?target=manager&speaker=1", body: Self.take)
        XCTAssertEqual(turn.status, 200)
        let all = events(turn.body)
        XCTAssertEqual(all.map(\.name), ["transcript", "delta", "audio", "end"])
        XCTAssertEqual(all[0].data["text"] as? String, "what needs me")
        XCTAssertEqual(all[1].data["text"] as? String, "Two threads need you.")
        XCTAssertEqual(all[2].data["text"] as? String, "Two threads need you.")
        XCTAssertNotNil((all[2].data["wav"] as? String).flatMap { Data(base64Encoded: $0) }
            .flatMap { MobileVoice.decode(wav: $0) })
        XCTAssertEqual(all[3].data["outcome"] as? String, "done")
        // The text went down the same path as typed text.
        XCTAssertEqual(locked { sent }, ["what needs me"])
        XCTAssertEqual(speech.transcribed, [16_000])
    }

    func testAnInputOnlyTakeRunsNoSynthesis() {
        let turn = post("/api/voice?target=manager&speaker=0", body: Self.take)
        XCTAssertEqual(turn.status, 200)
        XCTAssertEqual(events(turn.body).map(\.name), ["transcript", "delta", "end"])
        XCTAssertEqual(locked { sent }, ["what needs me"])
        XCTAssertEqual(speech.synthCalls, 0)
    }

    func testVoiceAnswers403WhileItsSwitchOrTheManagersIsOff() {
        server.configure(MobileConfig(capabilities: [.manager]))
        for path in ["/api/voice?target=manager&speaker=1", "/api/voice/replay?target=manager", "/api/voice/warm"] {
            let off = post(path, body: Self.take)
            XCTAssertEqual(off.status, 403, path)
            XCTAssertEqual(off.body, #"{"error":"disabled"}"#, path)
        }
        // Voice on, but its target's own switch off.
        server.configure(MobileConfig(capabilities: [.voice]))
        XCTAssertEqual(post("/api/voice?target=manager&speaker=1", body: Self.take).status, 403)
        XCTAssertEqual(speech.transcribed, [])
        XCTAssertEqual(locked { sent }, [])
    }

    func testATakeFromAnotherOriginIsRefusedAndTranscribesNothing() {
        XCTAssertEqual(
            post("/api/voice?target=manager&speaker=1", body: Self.take,
                 headers: ["X-MuxMaestro-Token": Self.token]).status, 403)
        XCTAssertEqual(
            post("/api/voice?target=manager&speaker=1", body: Self.take,
                 headers: ["Origin": "https://elsewhere.example", "X-MuxMaestro": "1",
                           "X-MuxMaestro-Token": Self.token]).status, 403)
        XCTAssertEqual(speech.transcribed, [])
    }

    func testEveryVoiceRouteAnswers401WithoutThePairingToken() {
        var unpaired = Self.appHeaders
        unpaired["X-MuxMaestro-Token"] = nil
        var wrong = Self.appHeaders
        wrong["X-MuxMaestro-Token"] = "another-token"
        for path in ["/api/voice?target=manager&speaker=1", "/api/voice/replay?target=manager", "/api/voice/warm"] {
            for headers in [unpaired, wrong] {
                let refused = post(path, body: Self.take, headers: headers)
                XCTAssertEqual(refused.status, 401, path)
                XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#, path)
            }
        }
        XCTAssertEqual(speech.transcribed, [])
        XCTAssertEqual(locked { sent }, [])
        XCTAssertEqual(locked { warmed }, [])
    }

    func testOversizedAndOverlongAudioIsRefused() {
        // Too many bytes: refused on the header, before any of the body is read.
        let big = post("/api/voice?target=manager&speaker=1", contentLength: MobileVoice.maxBodyBytes + 1)
        XCTAssertEqual(big.status, 413)
        // Few enough bytes, too many seconds.
        let long = post(
            "/api/voice?target=manager&speaker=1",
            body: MobileVoice.wav(samples: [Float](repeating: 0, count: 121 * 8000), sampleRate: 8000))
        XCTAssertEqual(long.status, 413)
        XCTAssertTrue(long.body.contains("too_long"))
        XCTAssertEqual(post("/api/voice?target=manager&speaker=1", body: Data("nope".utf8)).status, 400)
        XCTAssertEqual(speech.transcribed, [])
        XCTAssertEqual(locked { sent }, [])
    }

    func testATakeIsRefusedWhileTheManagerIsBusyOrWaitsOnAPrompt() {
        locked { status = .waiting }
        let waiting = post("/api/voice?target=manager&speaker=1", body: Self.take)
        XCTAssertEqual(waiting.status, 409)
        XCTAssertEqual(waiting.body, #"{"error":"waiting","message":"Manager is waiting on a prompt"}"#)

        locked { status = .idle }
        server.managerTurnBegan("summarise the morning")
        let busy = post("/api/voice?target=manager&speaker=1", body: Self.take)
        XCTAssertEqual(busy.status, 409)
        XCTAssertEqual(busy.body, #"{"error":"busy","message":"A turn is running"}"#)

        // The pane is busy with something no one here started.
        server.managerTurnEnded()
        locked { status = .busy }
        let pane = post("/api/voice?target=manager&speaker=1", body: Self.take)
        XCTAssertEqual(pane.status, 409)
        XCTAssertEqual(pane.body, #"{"error":"busy","message":"Manager is busy"}"#)

        locked { status = .off }
        XCTAssertEqual(post("/api/voice?target=manager&speaker=1", body: Self.take).status, 503)
        // A refused take costs nothing: the engine was never asked.
        XCTAssertEqual(speech.transcribed, [])
        XCTAssertEqual(locked { sent }, [])
    }

    func testATakeWithoutTheTokenIsRefusedOnItsHeadersAlone() {
        // Two megabytes announced and none sent: the answer must not wait for them.
        var unpaired = Self.appHeaders
        unpaired["X-MuxMaestro-Token"] = nil
        let started = Date()
        let refused = post("/api/voice?target=manager&speaker=1", headers: unpaired, contentLength: 2_000_000)
        XCTAssertEqual(refused.status, 401)
        XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // The same for a page from another origin.
        let foreign = post(
            "/api/voice?target=manager&speaker=1",
            headers: ["Origin": "https://elsewhere.example", "X-MuxMaestro": "1",
                      "X-MuxMaestro-Token": Self.token],
            contentLength: 2_000_000)
        XCTAssertEqual(foreign.status, 403)
        XCTAssertEqual(foreign.body, #"{"error":"forbidden"}"#)
    }

    func testASecondTakeWhileOneRunsIs409() {
        let gate = DispatchSemaphore(value: 0)
        speech.gate = gate
        let first = expectation(description: "first take")
        var firstStatus = 0
        DispatchQueue.global().async {
            firstStatus = self.post("/api/voice?target=manager&speaker=0", body: Self.take).status
            first.fulfill()
        }
        // The first take is being transcribed.
        let deadline = Date().addingTimeInterval(5)
        while speech.transcribed.isEmpty, Date() < deadline { usleep(5000) }
        XCTAssertEqual(speech.transcribed.count, 1)
        let second = post("/api/voice?target=manager&speaker=0", body: Self.take)
        XCTAssertEqual(second.status, 409)
        XCTAssertEqual(second.body, #"{"error":"busy","message":"A voice turn is running"}"#)
        XCTAssertEqual(post("/api/voice/replay?target=manager").status, 409)

        gate.signal()
        speech.gate = nil
        wait(for: [first], timeout: 5)
        XCTAssertEqual(firstStatus, 200)
        // Only the first take was transcribed and sent.
        XCTAssertEqual(speech.transcribed.count, 1)
        XCTAssertEqual(locked { sent }, ["what needs me"])
    }

    func testAPaneThatStopsBeingIdleDuringTranscriptionGetsNothing() {
        for (after, message) in [
            (MobileManagerStatus.waiting, "Manager is waiting on a prompt"), (.busy, "Manager is busy"),
        ] {
            locked { status = .idle }
            // Idle when the take arrives; not idle once the words are ready.
            speech.whileTranscribing = { [unowned self] in locked { status = after } }
            let turn = post("/api/voice?target=manager&speaker=1", body: Self.take)
            XCTAssertEqual(turn.status, 200)
            let all = events(turn.body)
            XCTAssertEqual(all.map(\.name), ["transcript", "end"])
            XCTAssertEqual(all.last?.data["outcome"] as? String, "refused")
            XCTAssertEqual(all.last?.data["message"] as? String, message)
        }
        XCTAssertEqual(locked { sent }, [])
        XCTAssertEqual(speech.synthesized, [])
    }

    private static let threadTake = "/api/voice?target=localhost%3A12&speaker=0"

    func testATakeIntoAThreadNeedsTheRepliesSwitchAndALiveThread() {
        // Voice is on; typing into a thread is its own switch.
        let off = post(Self.threadTake, body: Self.take)
        XCTAssertEqual(off.status, 403)
        XCTAssertEqual(off.body, #"{"error":"disabled"}"#)
        XCTAssertEqual(post("/api/voice/replay?target=localhost%3A12").status, 403)

        server.configure(MobileConfig(capabilities: [.voice, .replies]))
        XCTAssertEqual(post("/api/voice?target=localhost%3A99&speaker=0", body: Self.take).status, 404)
        // Replies alone do not turn voice on.
        server.configure(MobileConfig(capabilities: [.replies]))
        XCTAssertEqual(post(Self.threadTake, body: Self.take).status, 403)
        XCTAssertEqual(speech.transcribed, [])
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testATakeIntoAThreadGoesDownTheTypedTextPath() {
        server.configure(MobileConfig(capabilities: [.voice, .replies]))
        speech.transcript = "run the tests"
        let turn = post(Self.threadTake, body: Self.take)
        XCTAssertEqual(turn.status, 200)
        let all = events(turn.body)
        XCTAssertEqual(all.map(\.name), ["transcript", "end"])
        XCTAssertEqual(all.last?.data["outcome"] as? String, "done")
        // One bracketed paste and one Enter, as a typed reply.
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%12"), "\(pane.argv)")
        XCTAssertEqual(pane.calls[1].stdin, "run the tests")
        XCTAssertEqual(speech.synthCalls, 0)
        // Nothing went to the manager.
        XCTAssertEqual(locked { sent }, [])
    }

    func testATakeIntoABusyOrWaitingThreadIsRefusedBeforeItCostsAnything() {
        server.configure(MobileConfig(capabilities: [.voice, .replies]))
        for (status, code) in [(AttentionStatus.busy, "busy"), (.waiting, "waiting")] {
            pane.status = status
            let refused = post(Self.threadTake, body: Self.take)
            XCTAssertEqual(refused.status, 409)
            XCTAssertTrue(refused.body.contains(#""error":"\#(code)""#), refused.body)
        }
        XCTAssertEqual(speech.transcribed, [])
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testWordsThatAreNotTextNeverReachAThreadsPane() {
        server.configure(MobileConfig(capabilities: [.voice, .replies]))
        speech.transcript = "stop\u{03}now"
        let turn = post(Self.threadTake, body: Self.take)
        XCTAssertEqual(events(turn.body).last?.data["outcome"] as? String, "failed")
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testAPromptThatComesUpWhileATakeIsHeardGetsNoEnter() {
        server.configure(MobileConfig(capabilities: [.voice, .replies]))
        pane.status = .idle
        pane.statusAfterPaste = .waiting
        let turn = post(Self.threadTake, body: Self.take)
        let end = events(turn.body).last
        XCTAssertEqual(end?.data["outcome"] as? String, "refused")
        XCTAssertEqual(end?.data["message"] as? String, "Thread is waiting on a prompt")
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
        // A prompt is in front: no key goes to it, not even one that clears.
        XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
    }

    func testReplayReadsAThreadsLastReplyAgain() throws {
        server.configure(MobileConfig(capabilities: [.voice, .replies]))
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All 12 pass."}]}}"#
        try Data((line + "\n").utf8).write(to: threadTranscript)
        let replay = post("/api/voice/replay?target=localhost%3A12")
        XCTAssertEqual(replay.status, 200)
        XCTAssertEqual(events(replay.body).first?.data["text"] as? String, "All 12 pass.")
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testRefusesABadQueryAndMissingModels() {
        XCTAssertEqual(post("/api/voice", body: Self.take).status, 400)

        speech.modelsReady = false
        let models = post("/api/voice?target=manager&speaker=1", body: Self.take)
        XCTAssertEqual(models.status, 503)
        XCTAssertEqual(models.body, #"{"error":"models","message":"Voice models not ready"}"#)
        XCTAssertEqual(speech.transcribed, [])
    }

    func testReplayReadsTheManagersLastReplyAgain() throws {
        let none = post("/api/voice/replay?target=manager")
        XCTAssertEqual(none.status, 404)
        XCTAssertEqual(none.body, #"{"error":"nothing","message":"Nothing to replay"}"#)

        let file = root.appendingPathComponent("manager.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"what needs me?"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Two threads need you."}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        locked { transcript = file.path }
        let replay = post("/api/voice/replay?target=manager")
        XCTAssertEqual(replay.status, 200)
        let all = events(replay.body)
        XCTAssertEqual(all.map(\.name), ["audio", "end"])
        XCTAssertEqual(all[0].data["text"] as? String, "Two threads need you.")
        // Nothing was sent to the manager, and nothing was transcribed.
        XCTAssertEqual(locked { sent }, [])
        XCTAssertEqual(speech.transcribed, [])
    }

    func testWarmLoadsOnlyWhatTheTakeWillNeed() {
        XCTAssertEqual(post("/api/voice/warm?speaker=0").status, 200)
        XCTAssertEqual(post("/api/voice/warm?speaker=1").status, 200)
        XCTAssertEqual(locked { warmed }, [false, true])
    }
}
