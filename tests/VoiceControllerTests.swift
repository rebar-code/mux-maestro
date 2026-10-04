import XCTest

/// `VoiceController` with a fake mic and engine: the press sequence, what reaches
/// the target, what gets spoken, and every way a take ends early.
@MainActor
final class VoiceControllerTests: XCTestCase {
    private final class FakeRecorder: VoiceRecorder {
        var granted = true
        var started = 0

        func requestAccess() async -> Bool { granted }
        func start() throws { started += 1 }
        func stop() -> [Float] { [0.1, 0.2] }
    }

    private struct SpeakFailed: Error {}

    private final class FakeSpeech: VoiceSpeech {
        var modelsReady = true
        var transcript = "what needs me"
        var failSpeak = false
        var spoken: [String] = []
        var speakCalls = 0
        var stops = 0

        func prepare() async {}
        func transcribe(_ samples: [Float]) async throws -> String { transcript }
        func speak(_ text: AsyncStream<String>) async throws {
            speakCalls += 1
            for await chunk in text { spoken.append(chunk) }
            if failSpeak { throw SpeakFailed() }
        }
        func stopSpeaking() async { stops += 1 }
        func synthesize(
            _ text: AsyncStream<String>, onAudio: @escaping (SpeechAudio, String) -> Void
        ) async throws {}
    }

    private var recorder = FakeRecorder()
    private var speech = FakeSpeech()
    private var notes: [String] = []
    private var speechFailures = 0

    private func makeController() -> VoiceController {
        let voice = VoiceController(recorder: recorder, speech: speech)
        voice.onNote = { [unowned self] in self.notes.append($0) }
        voice.onSpeechFailed = { [unowned self] _ in self.speechFailures += 1 }
        return voice
    }

    /// Let the controller's tasks run until `condition` holds (or give up).
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// A target that records what it was handed and lets the test answer.
    private final class Pane {
        var acknowledgement: String?
        var received: [String] = []
        var onReply: ((String) -> Void)?
        var done: ((String?) -> Void)?

        var target: VoiceTarget {
            VoiceTarget(acknowledgement: acknowledgement) { [unowned self] text, onReply, done in
                self.received.append(text)
                self.onReply = onReply
                self.done = done
            }
        }
    }

    /// Press, wait for the mic, press again, wait for the target.
    private func talk(_ voice: VoiceController, to pane: Pane) async {
        voice.press(target: pane.target)
        await settle { voice.state == .listening }
        XCTAssertEqual(voice.state, .listening)
        voice.press(target: pane.target)
        await settle { voice.state == .replying }
    }

    func testTakeReachesTargetAndStreamedReplyIsSpoken() async {
        let voice = makeController()
        let pane = Pane()
        var states: [VoiceController.State] = []
        voice.onState = { states.append($0) }

        await talk(voice, to: pane)
        XCTAssertEqual(pane.received, ["what needs me"])
        XCTAssertEqual(recorder.started, 1)

        pane.onReply?("Two agents wait. ")
        pane.onReply?("One PR is green.")
        pane.done?("Two agents wait. One PR is green.")
        await settle { voice.state == .idle }

        XCTAssertEqual(speech.spoken, ["Two agents wait. ", "One PR is green."])
        XCTAssertEqual(states, [.starting, .listening, .transcribing, .replying, .idle])
        XCTAssertEqual(notes, [])
    }

    func testAcknowledgementIsSpokenBeforeTheReply() async {
        let voice = makeController()
        let pane = Pane()
        pane.acknowledgement = "Got it, checking. "
        await talk(voice, to: pane)
        await settle { speech.spoken.count == 1 }
        XCTAssertEqual(speech.spoken, ["Got it, checking. "], "spoken before any reply text")
        pane.onReply?("All quiet.")
        pane.done?("All quiet.")
        await settle { voice.state == .idle }
        XCTAssertEqual(speech.spoken, ["Got it, checking. ", "All quiet."])
    }

    /// The streaming chunker must release the acknowledgement on its own, not
    /// hold it until the reply's first sentence arrives.
    func testAcknowledgementIsACompleteChunk() {
        let (chunks, rest) = SpeechChunker.drain("Got it, checking. ", started: false)
        XCTAssertEqual(chunks.map { $0.trimmingCharacters(in: .whitespaces) }, ["Got it, checking."])
        XCTAssertEqual(rest, "")
    }

    func testReplyWithNoDeltasIsSpokenWhole() async {
        let voice = makeController()
        let pane = Pane()
        await talk(voice, to: pane)
        pane.done?("All quiet.")
        await settle { voice.state == .idle }
        XCTAssertEqual(speech.spoken, ["All quiet."])
    }

    /// The dictation shape: the target answers nil and nothing is read back.
    func testTargetWithNoReplySpeaksNothing() async {
        let voice = makeController()
        let pane = Pane()
        await talk(voice, to: pane)
        pane.done?(nil)
        await settle { voice.state == .idle }
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(speech.speakCalls, 0)
    }

    func testSpeechFailureIsReported() async {
        speech.failSpeak = true
        let voice = makeController()
        let pane = Pane()
        await talk(voice, to: pane)
        pane.onReply?("Reply text.")
        pane.done?("Reply text.")
        await settle { voice.state == .idle }
        XCTAssertEqual(speechFailures, 1)
        XCTAssertEqual(voice.state, .idle)
    }

    func testPressWhileReplyingStopsReadbackAndIgnoresTheRest() async {
        let voice = makeController()
        let pane = Pane()
        await talk(voice, to: pane)
        pane.onReply?("First sentence. ")
        voice.press(target: pane.target)
        XCTAssertEqual(voice.state, .idle)
        await settle { speech.stops == 1 }
        XCTAssertEqual(speech.stops, 1)

        pane.onReply?("Second sentence.")
        pane.done?("First sentence. Second sentence.")
        await settle { speech.speakCalls == 1 && voice.state == .idle }
        XCTAssertEqual(speech.spoken, ["First sentence. "])
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(speechFailures, 0)
    }

    func testModelsNotReadyNeverOpensTheMic() {
        speech.modelsReady = false
        let voice = makeController()
        voice.press(target: Pane().target)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.started, 0)
        XCTAssertEqual(notes, [VoiceController.modelsNotReady])
    }

    func testMicDeniedEndsTheTake() async {
        recorder.granted = false
        let voice = makeController()
        voice.press(target: Pane().target)
        await settle { voice.state == .idle }
        XCTAssertEqual(voice.state, .idle)
        XCTAssertEqual(recorder.started, 0)
        XCTAssertEqual(notes, [MicCapture.CaptureError.denied.localizedDescription])
    }

    func testEmptyTranscriptNeverReachesTheTarget() async {
        speech.transcript = ""
        let voice = makeController()
        let pane = Pane()
        voice.press(target: pane.target)
        await settle { voice.state == .listening }
        voice.press(target: pane.target)
        await settle { voice.state == .idle }
        XCTAssertEqual(pane.received, [])
        XCTAssertEqual(notes, [VoiceController.heardNothing])
    }

    func testReadbackFromTurnOutcome() {
        XCTAssertEqual(ManagerTurnOutcome.done(reply: "Hi").readback, "Hi")
        XCTAssertEqual(ManagerTurnOutcome.permission(reply: "Before").readback, "Before")
        XCTAssertEqual(ManagerTurnOutcome.timeout(reply: "").readback, nil)
        XCTAssertEqual(ManagerTurnOutcome.refused("busy").readback, nil)
        XCTAssertEqual(ManagerTurnOutcome.unreachable("gone").readback, nil)
    }
}
