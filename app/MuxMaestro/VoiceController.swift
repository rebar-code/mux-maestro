import Foundation

/// Where a push-to-talk take goes once it is text. The manager rail hands its
/// pane over as one; a dictation target would type the text into a terminal and
/// answer `done(nil)` at once, so nothing is read back.
struct VoiceTarget {
    /// Spoken the moment the transcript is handed over, so the human hears that
    /// the take landed before the reply starts. nil for a target with no reply.
    var acknowledgement: String?
    /// Hand over the transcript. Stream reply text through `onReply` as it lands,
    /// then call `done` exactly once with the whole reply, or nil when there is
    /// nothing to read back. Both are called on the main thread.
    let deliver: (
        _ transcript: String,
        _ onReply: @escaping (String) -> Void,
        _ done: @escaping (String?) -> Void
    ) -> Void
}

/// The mic side of a take. `MicCapture` in the app; a fake in tests.
protocol VoiceRecorder: AnyObject {
    /// Ask once for the mic; later calls answer from the stored grant.
    func requestAccess() async -> Bool
    func start() throws
    /// Stop the mic and return the take as 16 kHz mono floats.
    func stop() -> [Float]
}

/// The engine side of a take. `VoiceEngine` in the app; a fake in tests.
protocol VoiceSpeech: AnyObject {
    /// Whether the models are on disk. A take is not started without them.
    var modelsReady: Bool { get }
    /// Load the models; called while the human talks so the load overlaps it.
    func prepare() async
    func transcribe(_ samples: [Float]) async throws -> String
    func speak(_ text: AsyncStream<String>) async throws
    func stopSpeaking() async
    /// Synthesize a reply as it streams in and hand over each sentence's audio
    /// with its text, in order, instead of playing it. The phone plays it.
    func synthesize(
        _ text: AsyncStream<String>, onAudio: @escaping (SpeechAudio, String) -> Void
    ) async throws
}

/// Synthesized speech: mono floats and their rate.
struct SpeechAudio: Equatable {
    let samples: [Float]
    let sampleRate: Double
    var seconds: Double { Double(samples.count) / sampleRate }
}

/// Push-to-talk: one press starts a take, the next ends it. The take goes
/// through speech-to-text to a `VoiceTarget`, and the target's reply is spoken
/// as it streams in. A press while the reply plays stops the readback; the
/// target's own turn carries on.
///
/// The target is a parameter of each take, not of the controller, so one
/// controller serves every target and only one take runs at a time.
///
/// Errors never become speech. A take that fails before the target sees it is
/// reported through `onNote`; a reply that cannot be spoken goes to
/// `onSpeechFailed`, and the caller shows it as text.
@MainActor
final class VoiceController {
    enum State: Equatable {
        case idle
        /// Asking for the mic or opening it.
        case starting
        case listening
        case transcribing
        /// The target has the transcript; its reply is streaming and being read.
        case replying
    }

    static let modelsNotReady = "Voice models not ready"
    static let heardNothing = "Heard nothing"

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    var onState: ((State) -> Void)?
    var onNote: ((String) -> Void)?
    var onSpeechFailed: ((Error) -> Void)?

    private let recorder: VoiceRecorder
    private let speech: VoiceSpeech
    private var target: VoiceTarget?
    /// Bumped by every new take and by a stop, so callbacks from a dead take do
    /// nothing when they land.
    private var take = 0
    private var readback: AsyncStream<String>.Continuation?

    init(recorder: VoiceRecorder, speech: VoiceSpeech) {
        self.recorder = recorder
        self.speech = speech
    }

    /// The talk button and the hotkey. What a press does depends on the state.
    func press(target: VoiceTarget) {
        switch state {
        case .idle: start(target: target)
        case .listening: finish()
        case .replying: stopReadback()
        case .starting, .transcribing: break
        }
    }

    private func start(target: VoiceTarget) {
        guard speech.modelsReady else {
            onNote?(Self.modelsNotReady)
            return
        }
        take += 1
        let mine = take
        self.target = target
        state = .starting
        Task {
            let granted = await recorder.requestAccess()
            guard mine == take, state == .starting else { return }
            do {
                guard granted else { throw MicCapture.CaptureError.denied }
                try recorder.start()
            } catch {
                fail(error.localizedDescription)
                return
            }
            state = .listening
            let speech = self.speech
            Task { await speech.prepare() }
        }
    }

    private func finish() {
        let samples = recorder.stop()
        let mine = take
        state = .transcribing
        Task {
            let text: String
            do {
                text = try await speech.transcribe(samples)
            } catch {
                guard mine == take else { return }
                fail(error.localizedDescription)
                return
            }
            guard mine == take else { return }
            guard !text.isEmpty, let target else {
                fail(Self.heardNothing)
                return
            }
            deliver(text, to: target, take: mine)
        }
    }

    private func deliver(_ text: String, to target: VoiceTarget, take mine: Int) {
        state = .replying
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        var speaking: Task<Void, Error>?
        var streamed = false

        func feed(_ text: String) {
            guard mine == take, !text.isEmpty else { return }
            if speaking == nil {
                readback = continuation
                let speech = self.speech
                speaking = Task { try await speech.speak(stream) }
            }
            continuation.yield(text)
        }

        if let acknowledgement = target.acknowledgement { feed(acknowledgement) }
        target.deliver(
            text,
            { delta in
                streamed = true
                feed(delta)
            },
            { [weak self] reply in
                if !streamed, let reply { feed(reply) }
                continuation.finish()
                guard let self, mine == self.take else { return }
                guard let speaking else {
                    self.end()
                    return
                }
                Task {
                    do {
                        try await speaking.value
                    } catch {
                        if mine == self.take { self.onSpeechFailed?(error) }
                    }
                    if mine == self.take { self.end() }
                }
            })
    }

    /// Stop reading the reply. The target's turn is not cancelled; its text
    /// still lands wherever the target puts it.
    private func stopReadback() {
        take += 1
        readback?.finish()
        let speech = self.speech
        Task { await speech.stopSpeaking() }
        end()
    }

    private func fail(_ message: String) {
        onNote?(message)
        end()
    }

    private func end() {
        readback = nil
        target = nil
        state = .idle
    }
}

extension ManagerTurnOutcome {
    /// What a voice take reads back: the reply text the turn got to, or nil when
    /// the turn never reached the pane. The rail shows the reason as a note.
    var readback: String? {
        switch self {
        case .done(let reply), .permission(let reply), .timeout(let reply):
            return reply.isEmpty ? nil : reply
        case .refused, .unreachable:
            return nil
        }
    }
}
