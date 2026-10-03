import AVFoundation
import FluidAudio
import WhisperKit

/// Local speech, both directions: Whisper `base` (WhisperKit) turns audio into
/// text; Kokoro `bm_fable` ×1.2 (FluidAudio) turns text into audio and plays it.
///
/// Every Kokoro stage runs on the CPU: FluidAudio's default Neural Engine
/// routing crashed the vocoder on the M1 Max (`tasks/local-voice.md`). Models
/// load on demand — the first call after `release` pays about 3 s — and are
/// released after `idleRelease` without use, because this Mac runs short on
/// memory. One silent synthesis after load absorbs Kokoro's ~1 s first-call
/// cost. Nothing here talks to the manager pane; that is `ManagerPaneDriver`'s
/// job (task F), and G1b joins the two.
actor VoiceEngine {
    static let shared = VoiceEngine()

    /// Input format for `transcribe(_:)`: mono float samples at this rate.
    static let sampleRate: Double = 16_000
    static let idleRelease: TimeInterval = 300
    static let minimumClip: TimeInterval = 0.3

    enum EngineError: LocalizedError {
        case modelsNotReady([String])
        case tooShort
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .modelsNotReady(let files):
                return "Voice models are not downloaded yet (\(files.count) files missing)"
            case .tooShort:
                return "Recording too short"
            case .notLoaded:
                return "Voice engine is not loaded"
            }
        }
    }

    /// What one `speak` call did, for the self-test's timing lines.
    struct SpeakReport {
        /// Seconds from the call until the first chunk was handed to the player.
        var firstAudio: TimeInterval?
        var total: TimeInterval = 0
        var audioSeconds: Double = 0
        var chunks = 0
    }

    static let kokoroComputeUnits = KokoroAneComputeUnits(
        albert: .cpuOnly, postAlbert: .cpuOnly, alignment: .cpuOnly,
        prosody: .cpuOnly, noise: .cpuOnly, vocoder: .cpuOnly, tail: .cpuOnly)

    private var whisper: WhisperKit?
    private var kokoro: KokoroAneManager?
    private let player = SpeechPlayer()
    /// Bumped on every use; an idle timer releases only if nothing bumped it since.
    private var generation = 0
    /// The load in flight, shared by every caller that needs the models.
    private var loading: Task<Void, Error>?

    var isLoaded: Bool { whisper != nil && kokoro != nil }

    // MARK: Lifecycle

    /// Load both engines if they are not resident. Throws `modelsNotReady`
    /// until `VoiceModels` has finished its download. Callers that arrive while
    /// a load is running wait for it: the actor is re-entrant across the load's
    /// awaits, and a second load would hold both models twice.
    func loadIfNeeded() async throws {
        touch()
        guard !isLoaded else { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.load() }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func load() async throws {
        let missing = VoiceModelStore.missing(in: VoiceModelStore.directory)
        guard missing.isEmpty else { throw EngineError.modelsNotReady(missing) }

        if whisper == nil {
            let t0 = Date()
            let config = WhisperKitConfig(
                downloadBase: VoiceModelStore.supportDirectory,
                modelFolder: VoiceModelStore.directory.appendingPathComponent(VoiceModelStore.whisperFolder).path,
                verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
            whisper = try await WhisperKit(config)
            Diag.log("voice", "whisper loaded \(Self.ms(since: t0))")
        }
        if kokoro == nil {
            let t0 = Date()
            let manager = KokoroAneManager(
                defaultVoice: VoiceModelStore.kokoroVoice,
                directory: VoiceModelStore.directory,
                computeUnits: Self.kokoroComputeUnits)
            try await manager.initialize(preloadVoices: [VoiceModelStore.kokoroVoice])
            let loaded = Date()
            _ = try await manager.synthesizeDetailed(
                text: "Warm up.", voice: VoiceModelStore.kokoroVoice, speed: VoiceModelStore.kokoroSpeed)
            kokoro = manager
            Diag.log("voice", "kokoro loaded \(Self.ms(since: t0)) warm-up \(Self.ms(since: loaded))")
        }
    }

    /// Unload both engines and stop playback. The next call reloads.
    func release() async {
        generation += 1
        player.stop()
        if let whisper {
            await whisper.unloadModels()
            self.whisper = nil
        }
        if let kokoro {
            await kokoro.cleanup()
            self.kokoro = nil
        }
        Diag.log("voice", "released")
    }

    private func touch() {
        generation += 1
        let mine = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleRelease * 1_000_000_000))
            await self?.releaseIfIdle(since: mine)
        }
    }

    private func releaseIfIdle(since mark: Int) async {
        guard generation == mark, isLoaded else { return }
        await release()
    }

    // MARK: Speech to text

    /// Transcribe mono float samples at `sampleRate`.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await loadIfNeeded()
        guard let whisper else { throw EngineError.notLoaded }
        guard Double(samples.count) >= Self.sampleRate * Self.minimumClip else { throw EngineError.tooShort }
        let t0 = Date()
        let options = DecodingOptions(language: "en", temperature: 0)
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Diag.log("voice", "stt \(Self.ms(since: t0)) for \(String(format: "%.1f", Double(samples.count) / Self.sampleRate))s: \(text)")
        return text
    }

    /// Transcribe an audio file; any format AVFoundation reads, resampled.
    func transcribe(file url: URL) async throws -> String {
        try await transcribe(try AudioResample.samples(from: url))
    }

    // MARK: Text to speech

    /// Speak a complete reply: clean it, chunk it into sentences, synthesize
    /// each and play them back to back. Returns when the last chunk has played.
    @discardableResult
    func speak(_ text: String) async throws -> SpeakReport {
        try await loadIfNeeded()
        let run = SpeakRun(player: player)
        for chunk in SpeechChunker.chunks(for: Speechify.clean(text)) {
            try await run.add(chunk, synthesize: synthesize)
        }
        return try await run.finish()
    }

    /// Speak a reply as it streams in. Sentences are cut as soon as they are
    /// complete, fenced code is skipped, and the next sentence synthesizes
    /// while the current one plays.
    @discardableResult
    func speak(_ deltas: AsyncStream<String>) async throws -> SpeakReport {
        try await loadIfNeeded()
        let run = SpeakRun(player: player)
        let fence = FenceFilter()
        var buffer = ""
        for await delta in deltas {
            buffer += fence.feed(delta)
            let (chunks, rest) = SpeechChunker.drain(buffer, started: run.started)
            buffer = rest
            for chunk in chunks {
                try await run.add(chunk, synthesize: synthesize)
            }
        }
        try await run.add(buffer + fence.flush(), synthesize: synthesize)
        return try await run.finish()
    }

    /// Cut playback short. Synthesis already in flight finishes and is dropped.
    func stopSpeaking() {
        player.stop()
    }

    private func synthesize(_ text: String) async throws -> SpeechAudio {
        touch()
        guard let kokoro else { throw EngineError.notLoaded }
        let t0 = Date()
        let result = try await kokoro.synthesizeDetailed(
            text: text, voice: VoiceModelStore.kokoroVoice, speed: VoiceModelStore.kokoroSpeed)
        let audio = SpeechAudio(samples: result.samples, sampleRate: Double(result.sampleRate))
        Diag.log("voice", "tts \(Self.ms(since: t0)) for \(String(format: "%.1f", audio.seconds))s: \(text)")
        return audio
    }

    private static func ms(since t0: Date) -> String {
        String(format: "%.0fms", Date().timeIntervalSince(t0) * 1000)
    }
}

struct SpeechAudio {
    let samples: [Float]
    let sampleRate: Double
    var seconds: Double { Double(samples.count) / sampleRate }
}

/// One `speak` call: cleans each chunk, synthesizes it, and queues it behind
/// the chunk before it, so synthesis and playback overlap.
private final class SpeakRun {
    private let player: SpeechPlayer
    /// The player's stop count when this run began: a stop ends the whole run,
    /// including chunks that are still synthesizing.
    private let epoch: Int
    private let t0 = Date()
    private var report = VoiceEngine.SpeakReport()
    private var playback: Task<Void, Error>?
    private(set) var started = false

    init(player: SpeechPlayer) {
        self.player = player
        epoch = player.epoch
    }

    func add(_ chunk: String, synthesize: (String) async throws -> SpeechAudio) async throws {
        let clean = Speechify.clean(chunk)
        guard !clean.isEmpty else { return }
        started = true
        let audio = try await synthesize(clean)
        if report.firstAudio == nil { report.firstAudio = Date().timeIntervalSince(t0) }
        report.audioSeconds += audio.seconds
        report.chunks += 1
        let previous = playback
        let player = self.player
        let epoch = self.epoch
        playback = Task {
            try await previous?.value
            try await player.play(audio, epoch: epoch)
        }
    }

    func finish() async throws -> VoiceEngine.SpeakReport {
        try await playback?.value
        report.total = Date().timeIntervalSince(t0)
        return report
    }
}

/// Plays synthesized chunks in order through the default output device.
/// `MUXMAESTRO_VOICE_MUTE=1` keeps the timing path real but silent, for tests.
final class SpeechPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var pending: [Completion] = []
    private var stops = 0

    /// Bumped by every `stop`. A chunk queued before a stop does not play after it.
    var epoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    /// Resumes at most once: the player calls it when the buffer finished
    /// playing, and `stop` calls it for everything still queued.
    private final class Completion: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ c: CheckedContinuation<Void, Never>) { continuation = c }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    enum PlayerError: LocalizedError {
        case badFormat
        var errorDescription: String? { "Unsupported audio format" }
    }

    func play(_ audio: SpeechAudio, epoch: Int) async throws {
        guard !audio.samples.isEmpty, epoch == self.epoch else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count))
        else { throw PlayerError.badFormat }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: audio.samples.count)
        }
        try prepare(format)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let completion = Completion(c)
            lock.lock()
            pending.append(completion)
            lock.unlock()
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.forget(completion)
                completion.resume()
            }
        }
    }

    func stop() {
        lock.lock()
        let waiting = pending
        pending = []
        stops += 1
        lock.unlock()
        if node.isPlaying { node.stop() }
        waiting.forEach { $0.resume() }
    }

    private func forget(_ completion: Completion) {
        lock.lock()
        pending.removeAll { $0 === completion }
        lock.unlock()
    }

    private func prepare(_ format: AVAudioFormat) throws {
        if self.format == nil {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.format = format
            if ProcessInfo.processInfo.environment["MUXMAESTRO_VOICE_MUTE"] == "1" {
                engine.mainMixerNode.outputVolume = 0
            }
        } else if self.format?.sampleRate != format.sampleRate {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        if !engine.isRunning { try engine.start() }
        if !node.isPlaying { node.play() }
    }
}

/// The app's `VoiceSpeech`: the shared engine, models from `VoiceModelStore`.
final class EngineSpeech: VoiceSpeech {
    var modelsReady: Bool { VoiceModelStore.missing(in: VoiceModelStore.directory).isEmpty }

    func prepare() async {
        try? await VoiceEngine.shared.loadIfNeeded()
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await VoiceEngine.shared.transcribe(samples)
    }

    func speak(_ text: AsyncStream<String>) async throws {
        try await VoiceEngine.shared.speak(text)
    }

    func stopSpeaking() async {
        await VoiceEngine.shared.stopSpeaking()
    }
}
