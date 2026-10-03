import Foundation

/// `MUXMAESTRO_VOICE_SELFTEST=<file.wav>`: wait for the models, run the file
/// through STT twice (cold, warm), speak a fixed reply twice, print one timing
/// line per step to stderr, and exit 0. Non-zero on any failure.
///
/// Run it on a second instance of the built app, never the one in use:
///
///     MUXMAESTRO_VOICE_SELFTEST=/path/take.wav MUXMAESTRO_DIAG=1 \
///       build/Release/MuxMaestro.app/Contents/MacOS/MuxMaestro -NSAppSleepDisabled YES
///
/// `MUXMAESTRO_VOICE_MUTE=1` keeps the speakers quiet; timing is unchanged.
enum VoiceSelfTest {
    static let envKey = "MUXMAESTRO_VOICE_SELFTEST"

    static let reply = "Okay, I checked pull request one oh two, and CI is green. "
        + "I merged it with a merge commit. The front range windows import failed "
        + "because the vendor file had a new column."

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment[envKey], !path.isEmpty else { return }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "voice self-test")
        Task.detached {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await run(URL(fileURLWithPath: path))
                log("PASS")
                exit(0)
            } catch {
                log("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    private static let start = Date()

    private static func log(_ line: String) {
        let elapsed = String(format: "%7.2f", Date().timeIntervalSince(start))
        FileHandle.standardError.write(Data("VOICE-SELFTEST [\(elapsed)s] \(line)\n".utf8))
    }

    private static func seconds(_ t0: Date) -> String {
        String(format: "%.3f", Date().timeIntervalSince(t0))
    }

    private static func run(_ file: URL) async throws {
        log("file=\(file.path) models=\(VoiceModelStore.directory.path)")
        try await waitForModels()

        var t = Date()
        try await VoiceEngine.shared.loadIfNeeded()
        log("load cold s=\(seconds(t))")

        for label in ["cold", "warm"] {
            t = Date()
            let text = try await VoiceEngine.shared.transcribe(file: file)
            log("stt \(label) s=\(seconds(t)) text=\(text.debugDescription)")
        }

        for label in ["cold", "warm"] {
            let report = try await VoiceEngine.shared.speak(reply)
            let first = report.firstAudio.map { String(format: "%.3f", $0) } ?? "-"
            log("tts \(label) first_audio_s=\(first) total_s=\(String(format: "%.3f", report.total)) "
                + "audio_s=\(String(format: "%.2f", report.audioSeconds)) chunks=\(report.chunks)")
        }

        await VoiceEngine.shared.release()
        t = Date()
        try await VoiceEngine.shared.loadIfNeeded()
        log("load warm s=\(seconds(t))")
        await VoiceEngine.shared.release()
        log("peak_rss_mb=\(String(format: "%.0f", peakRSSMB()))")
    }

    /// Poll `VoiceModels` until it reads ready, logging each state change.
    private static func waitForModels() async throws {
        var last: VoiceModelState?
        let deadline = Date().addingTimeInterval(1800)
        while true {
            let state = await MainActor.run { VoiceModels.shared.state }
            if state != last {
                log("models \(VoiceModelStore.label(for: state))"
                    + { if case .failed(let m) = state { return " \(m)" } else { return "" } }())
                last = state
            }
            if state == .ready { return }
            if Date() > deadline { throw TimeoutError() }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private struct TimeoutError: LocalizedError {
        var errorDescription: String? { "models not ready after 30 minutes" }
    }

    private static func peakRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1e6
    }
}
