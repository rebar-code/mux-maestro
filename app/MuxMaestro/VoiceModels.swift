import Foundation
import FluidAudio
import WhisperKit

enum VoiceModelsError: LocalizedError {
    case incomplete([String])
    case bundleMissing(String)

    var errorDescription: String? {
        switch self {
        case .incomplete(let files):
            return "Download finished but files are missing: \(files.joined(separator: ", "))"
        case .bundleMissing(let name):
            return "\(name) is not in the app bundle"
        }
    }
}

/// Fetches the voice models once, in the background, when the app opens.
///
/// Whisper `base` (WhisperKit, ~142 MB) and Kokoro (FluidAudio, ~103 MB plus
/// ~24 MB of shared G2P assets) go to `VoiceModelStore.directory`. Files
/// already there are skipped, so an interrupted download resumes where it
/// stopped; a failed attempt is retried with backoff for as long as the app
/// runs, and the Setup window's Retry button forces one now. After the first
/// full download the engines are loaded once and released, so CoreML's
/// per-Mac compile (about 84 s for Whisper on the M1 Max) happens here, not
/// on the first talk press.
///
/// `state` is read on the main thread; `stateDidChange` posts there too.
final class VoiceModels {
    static let shared = VoiceModels()
    static let stateDidChange = Notification.Name("MuxMaestro.VoiceModels.stateDidChange")

    private(set) var state: VoiceModelState = .checking
    private var task: Task<Void, Never>?
    private let backoff: [TimeInterval] = [15, 30, 60, 120, 300]
    /// Progress posts only on a whole-percent change, so the UI is not flooded.
    private var lastPercent = -1

    /// Start the download if it is not running. Safe to call repeatedly.
    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [self] in await run() }
    }

    /// Drop any backoff wait and try again now.
    func retry() {
        task?.cancel()
        task = nil
        start()
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await ensureAll()
                set(.ready)
                return
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                NSLog("MuxMaestro: voice model download failed: \(message)")
                Diag.log("voice", "download failed: \(message)")
                set(.failed(message))
                let delay = backoff[min(attempt, backoff.count - 1)]
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func ensureAll() async throws {
        let directory = VoiceModelStore.directory
        if VoiceModelStore.missing(in: directory).isEmpty {
            Diag.log("voice", "models present at \(directory.path)")
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let t0 = Date()

        set(.downloading(stage: "Kokoro", fraction: 0))
        try await KokoroAneResourceDownloader.ensureModels(variant: .english, directory: directory) { [weak self] p in
            self?.set(.downloading(stage: "Kokoro", fraction: p.fractionCompleted))
        }
        try Task.checkCancellation()
        // The English G2P assets are pinned by FluidAudio to ~/.cache/fluidaudio;
        // fetching them here keeps the first load offline.
        try await KokoroAneResourceDownloader.ensureG2PAssets(directory: nil) { [weak self] p in
            self?.set(.downloading(stage: "Kokoro G2P", fraction: p.fractionCompleted))
        }
        _ = await KokoroAneResourceDownloader.ensureEnglishLexicon(directory: nil)
        try installVoicePack(into: directory)

        try Task.checkCancellation()
        set(.downloading(stage: "Whisper", fraction: 0))
        let folder = try await WhisperKit.download(
            variant: VoiceModelStore.whisperVariant,
            downloadBase: VoiceModelStore.supportDirectory
        ) { [weak self] p in
            self?.set(.downloading(stage: "Whisper", fraction: p.fractionCompleted))
        }
        Diag.log("voice", "whisper folder \(folder.path)")
        // The tokenizer is a separate Hugging Face repo that WhisperKit would
        // otherwise fetch on first load.
        _ = try await ModelUtilities.loadTokenizer(for: .base, tokenizerFolder: VoiceModelStore.supportDirectory)

        let missing = VoiceModelStore.missing(in: directory)
        guard missing.isEmpty else { throw VoiceModelsError.incomplete(missing) }
        Diag.log("voice", "download done in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

        try Task.checkCancellation()
        set(.compiling)
        let t1 = Date()
        try await VoiceEngine.shared.loadIfNeeded()
        await VoiceEngine.shared.release()
        Diag.log("voice", "first compile+load in \(String(format: "%.1f", Date().timeIntervalSince(t1)))s")
    }

    /// Copy the bundled `bm_fable` pack beside the downloaded Kokoro models.
    /// FluidAudio's `ensureVoicePack` returns early when the file exists.
    private func installVoicePack(into directory: URL) throws {
        let target = directory
            .appendingPathComponent(VoiceModelStore.kokoroFolder, isDirectory: true)
            .appendingPathComponent(VoiceModelStore.voicePackFile)
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent(VoiceModelStore.voicePackFile),
            FileManager.default.fileExists(atPath: source.path)
        else { throw VoiceModelsError.bundleMissing(VoiceModelStore.voicePackFile) }
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path), fm.contentsEqual(atPath: source.path, andPath: target.path) {
            return
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(VoiceModelStore.voicePackFile).staging-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staged)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: target)
        }
    }

    private func set(_ new: VoiceModelState) {
        if case .downloading(_, let fraction) = new {
            let percent = Int(fraction * 100)
            if case .downloading = state, percent == lastPercent { return }
            lastPercent = percent
        } else {
            lastPercent = -1
        }
        DispatchQueue.main.async { [self] in
            guard state != new else { return }
            state = new
            Diag.log("voice", "state \(VoiceModelStore.label(for: new))")
            NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        }
    }
}
