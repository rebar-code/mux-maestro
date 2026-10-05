import Foundation

/// What the voice-model download is doing. Rendered as the "Voice models" row
/// in the Settings window and polled by the voice self-test.
enum VoiceModelState: Equatable {
    case checking
    /// `stage` names the engine being fetched ("Kokoro", "Whisper"); `fraction` is 0…1.
    case downloading(stage: String, fraction: Double)
    /// First load after a download: CoreML compiles the models once for this Mac.
    case compiling
    case ready
    case failed(String)
}

/// Where the voice models live and which files make them complete. Pure —
/// paths and file lists only — so the completeness check is unit-tested
/// against a fixture directory and the app never links the engines to ask
/// "is voice ready?".
///
/// Layout under `~/Library/Application Support/MuxMaestro/models/`:
///
///     argmaxinc/whisperkit-coreml/openai_whisper-base/   WhisperKit STT
///     openai/whisper-base/                               its tokenizer
///     kokoro-82m-coreml/ANE/                             Kokoro TTS + voice packs
///
/// The Whisper paths are WhisperKit's own `<downloadBase>/models/<org>/<repo>`
/// convention, so `supportDirectory` (one level up) is the download base and
/// both engines land side by side under `models/`. FluidAudio's shared G2P
/// assets (~24 MB) are pinned by the library to `~/.cache/fluidaudio/Models/kokoro`
/// and cannot be redirected; they are fetched during the same download.
enum VoiceModelStore {
    /// Measured 2026-09-11 on a 6.9 s take: `base` and `small` gave the
    /// same words; `base` was warm in 0.23–0.25 s, `small` in 0.67–1.0 s.
    static let whisperVariant = "base"
    static let kokoroVoice = "bm_fable"
    static let kokoroSpeed: Float = 1.2

    /// `~/Library/Application Support/MuxMaestro` — WhisperKit's download base.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuxMaestro", isDirectory: true)
    }

    /// `<supportDirectory>/models`, the root every relative path below hangs off.
    static var directory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static let whisperFolder = "argmaxinc/whisperkit-coreml/openai_whisper-\(whisperVariant)"
    static let whisperTokenizerFolder = "openai/whisper-\(whisperVariant)"
    static let kokoroFolder = "kokoro-82m-coreml/ANE"
    /// Shipped in the bundle (`Resources/voice/`): FluidAudio 0.15.6 downloads
    /// only `af_heart`, so the app installs this pack itself.
    static let voicePackFile = "\(kokoroVoice).bin"

    /// Every file `VoiceEngine` opens, relative to `directory`. Missing any one
    /// means "not ready" and triggers the download, which skips files it has.
    static let requiredFiles: [String] = [
        "\(whisperFolder)/AudioEncoder.mlmodelc",
        "\(whisperFolder)/TextDecoder.mlmodelc",
        "\(whisperFolder)/MelSpectrogram.mlmodelc",
        "\(whisperFolder)/config.json",
        "\(whisperTokenizerFolder)/tokenizer.json",
        "\(kokoroFolder)/KokoroAlbert.mlmodelc",
        "\(kokoroFolder)/KokoroPostAlbert.mlmodelc",
        "\(kokoroFolder)/KokoroAlignment.mlmodelc",
        "\(kokoroFolder)/KokoroProsody.mlmodelc",
        "\(kokoroFolder)/KokoroNoise_v2.mlmodelc",
        "\(kokoroFolder)/KokoroVocoder.mlmodelc",
        "\(kokoroFolder)/KokoroTail.mlmodelc",
        "\(kokoroFolder)/vocab.json",
        "\(kokoroFolder)/af_heart.bin",
        "\(kokoroFolder)/\(voicePackFile)",
    ]

    /// The required files not present under `directory`, in `requiredFiles` order.
    static func missing(
        in directory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        requiredFiles.filter { !fileExists(directory.appendingPathComponent($0).path) }
    }

    /// The Settings window's status text for `state`. Label only.
    static func label(for state: VoiceModelState) -> String {
        switch state {
        case .checking: return "…"
        case .downloading(let stage, let fraction):
            return "\(stage) \(Int((fraction * 100).rounded(.down)))%"
        case .compiling: return "Compiling"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}
