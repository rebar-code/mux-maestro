import Foundation

/// `MUXMAESTRO_VOICE_SELFTEST=<file.wav>`: wait for the models, run the file
/// through STT twice (cold, warm), speak a fixed reply twice, run the file as a
/// phone take (input only, then two-way), print one timing line per step to
/// stderr, and exit 0. Non-zero on any failure.
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
        + "I merged it with a merge commit. The acme app import failed "
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

        // The phone's path: the file as a posted take, first input only (the
        // read-back model must stay unloaded), then two-way (clips, not playback).
        await VoiceEngine.shared.release()
        guard case .samples(let take) = MobileVoice.take(wav: try Data(contentsOf: file)) else {
            throw PhoneTakeRefused()
        }
        for speaker in [false, true] {
            let turn = try await phoneTurn(take, speaker: speaker)
            let loaded = await VoiceEngine.shared.isLoaded
            log("phone speaker=\(speaker) transcript_s=\(turn.transcript) first_audio_s=\(turn.firstAudio) "
                + "end_s=\(turn.end) clips=\(turn.clips) both_models_loaded=\(loaded)")
            if !speaker, turn.clips > 0 || loaded { throw InputOnlySynthesized() }
            if speaker, turn.clips == 0 { throw NoClips() }
        }

        await VoiceEngine.shared.release()
        t = Date()
        try await VoiceEngine.shared.loadIfNeeded()
        log("load warm s=\(seconds(t))")
        await VoiceEngine.shared.release()
        log("peak_rss_mb=\(String(format: "%.0f", peakRSSMB()))")
    }

    private struct PhoneTakeRefused: LocalizedError {
        var errorDescription: String? { "the file is not a take the phone API accepts" }
    }

    private struct InputOnlySynthesized: LocalizedError {
        var errorDescription: String? { "an input-only take loaded or ran the read-back model" }
    }

    private struct NoClips: LocalizedError {
        var errorDescription: String? { "a two-way take returned no audio" }
    }

    /// One `MobileVoiceTurn` with the real engine and a target that answers
    /// `reply` at once: seconds from the start to each event, and the clips.
    private static func phoneTurn(
        _ take: [Float], speaker: Bool
    ) async throws -> (transcript: String, firstAudio: String, end: String, clips: Int) {
        let t0 = Date()
        let lock = NSLock()
        var transcript = "-", firstAudio = "-", clips = 0
        let end: String = await withCheckedContinuation { done in
            let turn = MobileVoiceTurn(speech: EngineSpeech(), speaker: speaker) { name, _, last in
                lock.lock()
                if name == "transcript" { transcript = seconds(t0) }
                if name == "audio" {
                    if clips == 0 { firstAudio = seconds(t0) }
                    clips += 1
                }
                lock.unlock()
                if last { done.resume(returning: seconds(t0)) }
            }
            turn.start(samples: take) { _, onDelta, completion in
                onDelta(reply)
                completion(.done(reply: reply))
            }
        }
        lock.lock()
        defer { lock.unlock() }
        return (transcript, firstAudio, end, clips)
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
