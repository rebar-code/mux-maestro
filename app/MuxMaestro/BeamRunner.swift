import AppKit
import Foundation

/// Runs the vendored `beam.sh` for a `BeamTransfer.Request` — off the hot path,
/// with a working directory (beam runs from the repo), a PATH-corrected
/// environment, and a generous timeout (beam does rsync + git + Claude-history
/// sync over ssh, well past the 4s ceiling the poll's `ProcessCommandRunner`
/// uses). Its own `Process` so a slow beam never rides the status poll.
final class BeamRunner {
    private let lock = NSLock()
    private var proc: Process?
    private var cancelled = false

    /// Run beam for `req`, blocking until it finishes — call this OFF the main
    /// thread. Returns whether beam succeeded (exit 0) and its merged
    /// stdout+stderr (shown to the user on failure). On the takeover path beam
    /// ends by `exec`ing `tmux respawn-pane`, which issues the pane swap and exits
    /// 0, so a clean run reports success and the source pane becomes the remote
    /// session.
    func run(req: BeamTransfer.Request, scriptPath: String,
             timeout: TimeInterval = 600) -> (ok: Bool, output: String) {
        let (path, args) = BeamTransfer.invocation(scriptPath: scriptPath, req: req)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = URL(
            fileURLWithPath: (req.localDir as NSString).expandingTildeInPath)
        var env = ProcessCommandRunner.childEnvironment
        for (k, v) in BeamTransfer.env(for: req) { env[k] = v }
        p.environment = env

        // Capture stdout+stderr to a temp file: no pipe-buffer capacity to
        // deadlock on, and beam's progress/error text is exactly what we show on
        // failure.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("beam-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return (false, "Couldn’t create a log file for the beam.")
        }
        p.standardOutput = logHandle
        p.standardError = logHandle

        // terminationHandler + semaphore — never `async { waitUntilExit() }`,
        // which lost-wakeup-leaks a thread in this codebase (see the force-quit
        // hang fix). The handler signals; we wait with a deadline.
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
            return (false, "Couldn’t launch beam: \(error.localizedDescription)")
        }
        lock.lock(); proc = p; lock.unlock()

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)  // reap
            }
        }
        lock.lock(); proc = nil; let wasCancelled = cancelled; lock.unlock()

        try? logHandle.close()
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: logURL)

        if wasCancelled { return (false, output) }
        if timedOut { return (false, output + "\n\nBeam timed out after \(Int(timeout))s.") }
        return (p.terminationStatus == 0, output)
    }

    /// Whether this beam was cancelled by the user (so the caller can suppress a
    /// spurious "failed" alert).
    var didCancel: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Cancel an in-flight beam (best-effort). The takeover only respawns the
    /// local pane *after* the remote is confirmed up, so cancelling mid-transport
    /// never touches the local session.
    func cancel() {
        lock.lock()
        cancelled = true
        let p = proc
        lock.unlock()
        p?.terminate()
    }
}

/// A non-blocking sheet shown while a beam runs: an indeterminate progress bar +
/// a Cancel button. `end()` dismisses it on completion. Main-thread only.
final class BeamProgressSheet {
    /// Invoked when the user clicks Cancel — not when `end()` dismisses the sheet.
    var onCancel: (() -> Void)?
    private let alert = NSAlert()
    private weak var parent: NSWindow?
    private var ended = false

    init(host: String) {
        alert.messageText = "Beaming to \(host)…"
        alert.informativeText = "Moving the repo and Claude session, then handing "
            + "this window over to \(host). This can take a moment."
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        alert.accessoryView = bar
        alert.addButton(withTitle: "Cancel")
    }

    func begin(over window: NSWindow) {
        parent = window
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, !self.ended else { return }
            self.ended = true
            if resp == .alertFirstButtonReturn { self.onCancel?() }
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        if let parent { parent.endSheet(alert.window) }
    }
}
