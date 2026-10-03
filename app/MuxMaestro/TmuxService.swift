import Foundation

/// Abstraction over "run a subprocess and capture its stdout". Isolated behind a
/// protocol so the selection / action command sequences can be asserted against
/// a fake in tests without spawning real processes.
protocol CommandRunner {
    /// Run `path` with `args`, optionally writing `stdin` to the process. Returns
    /// raw stdout on a clean (exit 0) run, or nil on launch failure, timeout, or
    /// non-zero exit. Callers that need it trim trailing whitespace themselves.
    func run(_ path: String, _ args: [String], stdin: Data?) -> String?

    /// Run capturing **stdout+stderr merged** and whether it succeeded (exit 0),
    /// with a generous timeout — for the commit panel's write ops (commit / push /
    /// pr create) that hit the network and whose error text we want to show.
    func runCapturing(_ path: String, _ args: [String]) -> (ok: Bool, text: String)
}

extension CommandRunner {
    func run(_ path: String, _ args: [String]) -> String? { run(path, args, stdin: nil) }
    /// Default derives from `run` (no stderr, no exit detail) so test fakes that
    /// only implement `run` keep working.
    func runCapturing(_ path: String, _ args: [String]) -> (ok: Bool, text: String) {
        if let out = run(path, args, stdin: nil) { return (true, out) }
        return (false, "")
    }
}

/// Drain everything readable from `handle` until EOF or `deadline`, whichever
/// comes first, and return the bytes collected. Reads the fd at the POSIX level
/// (non-blocking `poll`/`read`) rather than `FileHandle.readDataToEndOfFile()`
/// so it is:
///
///   • **Leak-proof.** `readDataToEndOfFile()` blocks until *every* copy of the
///     pipe's write end is closed. A spawned `node`/`claude`/`gh` routinely
///     forks a grandchild that inherits stdout, so killing the direct child
///     doesn't close the pipe — the reader thread (and the fd it holds) then
///     blocks forever. Enough of those pile up and the process blows past the
///     GCD 64-thread soft limit and exhausts its fd table. `deadline` caps the
///     wait, the thread returns, and ARC closes the pipe fd.
///
///   • **Crash-proof.** An OS-level read failure (`EBADF`/`EMFILE`, which is
///     what fd exhaustion produces) makes `readDataToEndOfFile()` throw an
///     Objective-C `NSFileHandleOperationException`. Swift can't `catch` it, so
///     it propagated to `abort()` (SIGABRT). `read(2)` just returns `-1`; we
///     stop and hand back whatever we already have.
///
/// Closes `handle` before returning: Foundation doesn't release a `Pipe`'s read
/// fd promptly on its own (each `run()` otherwise leaked one), and closing the
/// FileHandle marks it closed so its later dealloc won't double-close a
/// since-reused fd. `handle` is the sole reader, so nothing else touches it.
/// - Returns: the bytes read, and `complete` — true **only** when the read ended at
///   a real EOF. Every other exit (deadline, poll/read error, fd yanked away) leaves
///   `complete` false, because the bytes returned may be a prefix of the real output
///   — or nothing at all.
///
///   Callers must not treat an incomplete drain as output. A child can exit 0 while
///   this reader is still starved of a thread; returning its empty buffer as success
///   made `tmux list-sessions` look like "no sessions" and blanked the sidebar.
func drainToEnd(_ handle: FileHandle, deadline: DispatchTime) -> (data: Data, complete: Bool) {
    let fd = handle.fileDescriptor
    defer { if fd >= 0 { try? handle.close() } }
    // Non-blocking so a `read()` in the gap between chunks never parks past the
    // deadline while the pipe is held open with no bytes pending.
    let flags = fcntl(fd, F_GETFL)
    if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

    var out = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let now = DispatchTime.now()
        if now >= deadline { return (out, false) }
        // Re-check the deadline at least every 200ms so a held-open, idle pipe
        // can't keep us past it.
        let remainingMs = (deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000
        let waitMs = Int32(min(remainingMs, 200))

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, waitMs)
        if ready < 0 {
            if errno == EINTR { continue }
            return (out, false)  // poll error — return what we have, never throw
        }
        if ready == 0 { continue }  // slice timed out; loop re-checks the deadline
        if pfd.revents & Int16(POLLNVAL) != 0 { return (out, false) }  // fd yanked away

        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            out.append(buf, count: n)
        } else if n == 0 {
            return (out, true)  // EOF: all write ends closed — this is the whole output
        } else if errno != EAGAIN && errno != EINTR {
            return (out, false)  // read error (EBADF etc.) — never crash
        }
    }
}

/// A semaphore signalled when `proc` exits. **Install before `proc.run()`** — it
/// works by setting `terminationHandler`, which Foundation only honors on a
/// not-yet-launched process.
///
/// Replaces the obvious `DispatchQueue.global().async { proc.waitUntilExit() }`,
/// which is unsafe here. `waitUntilExit()` parks the calling thread in a
/// CFRunLoop wait, and under *concurrent* spawns Foundation drops that wakeup
/// roughly 1% of the time: the child exits and is reaped, but the waiter never
/// returns — not on `terminate()`, not on `SIGKILL`. Each dropped wakeup strands
/// a global-pool thread forever; at 64 the process hits GCD's dispatch-thread
/// soft limit and every queue starves, which is the "MuxMaestro stalls after a
/// while and has to be force-quit" hang (a spindump caught 61 threads parked in
/// `waitUntilExit`). Measured on this pattern: 21 stranded threads per 1200
/// spawns at 50-way concurrency; zero with this helper.
///
/// `terminationHandler` is invoked from Foundation's own child-reaping queue and
/// never touches the runloop, so it can't drop the wakeup — and it needs no
/// helper thread at all.
func exitSignal(for proc: Process) -> DispatchSemaphore {
    let exited = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in exited.signal() }
    return exited
}

/// Runs a real subprocess. A `timeout` bounds how long any single command may
/// block — a slow or hung `sessions.py`/`tmux` can't wedge the caller. On
/// timeout the process is terminated and nil is returned.
struct ProcessCommandRunner: CommandRunner {
    /// Hard ceiling on a single command's wall-clock time.
    var timeout: TimeInterval = 4.0

    /// Environment for spawned children with a usable `PATH`. A Finder/Xcode-
    /// launched GUI app inherits a minimal PATH (no `/opt/homebrew/bin`), so a
    /// child that shells out to a tool by bare name fails to find it. The most
    /// load-bearing case: `sessions.py` calls `tmux list-panes` by name to map
    /// Claude PIDs → tmux sessions; without tmux on PATH that mapping silently
    /// comes back empty and every session shows as `.unknown` (grey dot). Prepend
    /// the standard bin dirs so by-name lookups resolve, keeping any inherited PATH.
    static let childEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let standardBins = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (standardBins + inherited.filter { !standardBins.contains($0) })
            .joined(separator: ":")
        return env
    }()

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        let started = Date()
        defer {
            Diag.recordSpawn(
                (path as NSString).lastPathComponent,
                ms: Date().timeIntervalSince(started) * 1000)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = Self.childEnvironment
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        var inPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            proc.standardInput = p
            inPipe = p
        }
        let exited = exitSignal(for: proc)  // must be armed before run()
        do {
            try proc.run()
        } catch {
            return nil
        }
        if let stdin, let inPipe {
            // Modern throwing API + try?: writing to a child that already exited
            // fails with a *catchable* Swift error, not the old
            // `FileHandle.write(_:)`'s uncatchable NSFileHandleOperationException.
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain stdout on a background thread, bounded by the same deadline as the
        // exit wait. `drainToEnd` reads at the POSIX level so a grandchild holding
        // the pipe open can't wedge the thread (the fd/thread leak that eventually
        // aborted the app) — see its doc comment.
        let deadline = DispatchTime.now() + timeout
        let outHandle = outPipe.fileHandleForReading
        let dataBox = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            dataBox.store(drainToEnd(outHandle, deadline: deadline))
            readDone.signal()
        }

        if exited.wait(timeout: deadline) == .timedOut {
            // Escalate: SIGTERM, brief grace, then SIGKILL if still alive so a
            // child that ignores terminate() can't outlive the timeout.
            proc.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)  // reap the killed child
            }
            // The reader self-bounds at `deadline`, so it can't leak; give it a
            // beat to settle before returning.
            _ = readDone.wait(timeout: .now() + 0.5)
            return nil
        }
        // The reader must have published before we read its box — otherwise we'd
        // race it, and under the thread-starvation that makes this timeout fire at
        // all, we'd read `nil` and call it output.
        guard readDone.wait(timeout: .now() + 0.5) == .success else { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        // Exit status alone is not enough: a clean exit whose stdout drain was cut
        // short yields a prefix of the real output — usually empty. Callers key
        // behavior off "" vs nil (an empty `list-sessions` blanks the sidebar; nil
        // preserves the last good tree), so a partial read must report failure.
        guard let read = dataBox.load(), read.complete else { return nil }
        return String(data: read.data, encoding: .utf8)
    }

    /// Run capturing stdout+stderr merged and the success flag, with a generous
    /// 30s timeout (git push / gh pr create hit the network). Mirrors `run`'s
    /// deadlock-safe read + timeout escalation, but keeps stderr so the commit
    /// panel can surface the real git/gh error message on failure.
    func runCapturing(_ path: String, _ args: [String]) -> (ok: Bool, text: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = Self.childEnvironment
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe  // merge stderr → same pipe
        let exited = exitSignal(for: proc)  // must be armed before run()
        do { try proc.run() } catch { return (false, "") }

        let deadline = DispatchTime.now() + 30
        let outHandle = outPipe.fileHandleForReading
        let dataBox = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            dataBox.store(drainToEnd(outHandle, deadline: deadline))
            readDone.signal()
        }
        if exited.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            _ = readDone.wait(timeout: .now() + 0.5)
            return (false, "timed out")
        }
        // Unlike `run`, a truncated capture is still worth showing — the commit panel
        // surfaces it as the git/gh error text — but it must never read as success.
        let published = readDone.wait(timeout: .now() + 0.5) == .success
        let read = published ? dataBox.load() : nil
        let text = (read.map { String(data: $0.data, encoding: .utf8) ?? "" } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = proc.terminationStatus == 0 && (read?.complete ?? false)
        return (ok, text)
    }

    /// Box so the reader closure can hand bytes back across threads. Locked: the
    /// reader may still be writing when a timed-out waiter gives up and reads.
    private final class DataBox {
        private let lock = NSLock()
        private var value: (data: Data, complete: Bool)?

        func store(_ v: (data: Data, complete: Bool)) {
            lock.lock(); defer { lock.unlock() }
            value = v
        }

        func load() -> (data: Data, complete: Bool)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}

/// Supplies attention statuses keyed by tmux session name. Isolated behind a
/// protocol so the (currently shell-based) implementation can be swapped for a
/// native one later without touching the sidebar.
protocol AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus]
    /// tmux session name → last-message/response epoch **seconds** (from the Claude
    /// session `updatedAt`), for the Most Recent sort. Empty when unavailable.
    func activity() -> [String: Int]
    /// pane id (e.g. "%30") → AttentionStatus, so window/pane rows show which exact
    /// pane is running/waiting. Empty when unavailable.
    func paneStatuses() -> [String: AttentionStatus]
    /// All three views, read together. See `StatusSnapshot`.
    func snapshot() -> StatusSnapshot
}

/// The three status views `loadTree` needs. They come from one underlying query in
/// both real providers, so reading them together lets each pay for a single
/// `sessions.py` run (local) or SSH round-trip (remote) instead of three.
struct StatusSnapshot {
    var statuses: [String: AttentionStatus] = [:]
    var activity: [String: Int] = [:]
    var paneStatuses: [String: AttentionStatus] = [:]
    /// pane id → Claude session UUID, for "Beam to server". Rides the same single
    /// `sessions.py` run as the other views (no extra subprocess per poll).
    var paneSessionIds: [String: String] = [:]
    /// pane id → epoch seconds its session entered its status, for 💤.
    var paneStatusSince: [String: Int] = [:]
    /// Claude session UUID → cwd, to find its transcript for 🥱. Local host only.
    var sessionCwds: [String: String] = [:]
    /// codex process pid → codex conversation UUID, and the whole pid → ppid
    /// table, from `CodexSessions.scan`. Kept as pids rather than pane ids because
    /// the join needs the tmux tree (`TmuxModel.sorted` owns it). Local host only —
    /// the remote provider leaves both empty.
    var codexByPid: [Int: String] = [:]
    var ppids: [Int: Int] = [:]
    /// codex conversation UUID → its own rollout file, for its last prompt.
    var codexRollouts: [String: String] = [:]
}

extension AttentionStatusProvider {
    /// Default so providers (and test fakes) that don't supply recency data still
    /// conform — those sessions fall back to their tmux activity value.
    func activity() -> [String: Int] { [:] }
    /// Default so providers/fakes without per-pane data conform — window/pane rows
    /// simply fall back to `.unknown` (no dot).
    func paneStatuses() -> [String: AttentionStatus] { [:] }
    /// Default: three independent reads. Correct for any provider; the two
    /// `sessions.py`-backed ones override it to read once.
    func snapshot() -> StatusSnapshot {
        StatusSnapshot(statuses: statuses(), activity: activity(), paneStatuses: paneStatuses())
    }
}

/// Reads Claude Code session status by shelling to the app's bundled
/// `python3 sessions.py list` (see `BundledTools`) and joining on tmux name.
///
/// Graceful degradation: when the status tool (python3 or the script) is
/// missing, this logs **once** and returns nil from `statuses()` so callers can
/// tell "tool unavailable" apart from "tool ran, no statuses". The tree still
/// renders; sessions simply show as `.unknown` rather than silently collapsing
/// every session to unknown with no signal.
final class SessionsPyStatusProvider: AttentionStatusProvider {
    /// Candidate python3 paths (a Finder-launched app has a minimal PATH).
    private static let pythonPaths = [
        "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
    ]
    private let scriptPath: String
    private let runner: CommandRunner
    /// The codex-id scan, injectable so tests and fakes can pass `nil` (skip it)
    /// rather than shelling out to `ps`/`lsof` on the test host.
    private let codexScan: (() -> (codexByPid: [Int: String], ppids: [Int: Int], rollouts: [String: String]))?
    /// Guards the one-time "status tool missing" log. `statusesOrNil()` runs on
    /// the background poll queue, so this flag is flipped under a lock to stay
    /// race-free (TSan-clean) and emit the warning exactly once.
    private let warnLock = NSLock()
    private var warnedMissing = false

    /// Flip `warnedMissing` true and report whether THIS call was the first to
    /// do so, atomically — so concurrent poll ticks log at most once.
    private func claimFirstWarning() -> Bool {
        warnLock.lock()
        defer { warnLock.unlock() }
        if warnedMissing { return false }
        warnedMissing = true
        return true
    }

    /// `scriptPath` is injectable so tests can point at a known-missing path and
    /// assert the unavailable-tool degrade deterministically (independent of the
    /// installed copy).
    init(
        runner: CommandRunner = ProcessCommandRunner(),
        scriptPath: String = BundledTools.path(.sessions),
        codexScan: ((CommandRunner) -> (codexByPid: [Int: String], ppids: [Int: Int], rollouts: [String: String]))?
            = CodexSessions.scan(runner:)
    ) {
        self.runner = runner
        self.scriptPath = scriptPath
        self.codexScan = codexScan.map { scan in { scan(runner) } }
    }

    /// One `sessions.py list` run. `nil` means the tool is unavailable (python3 or
    /// the script is missing) — distinct from a run that produced nothing usable,
    /// which yields `.some(nil)` data so callers degrade quietly rather than warn.
    private func readSessions() -> (available: Bool, data: Data?) {
        let python = Self.pythonPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard FileManager.default.fileExists(atPath: scriptPath), let python else {
            if claimFirstWarning() {
                NSLog("MuxMaestro: status tool unavailable (sessions.py or python3 missing); "
                    + "sessions will show as unknown attention until it's reachable")
            }
            return (false, nil)
        }
        return (true, runner.run(python, [scriptPath, "list"])?.data(using: .utf8))
    }

    /// Statuses keyed by tmux name, or nil when the status tool is unavailable
    /// (so the caller can degrade with a signal rather than silently).
    func statusesOrNil() -> [String: AttentionStatus]? {
        let read = readSessions()
        guard read.available else { return nil }
        guard let data = read.data else { return [:] }  // tool ran but produced nothing usable
        return TmuxModel.parseStatuses(fromSessionsJSON: data)
    }

    func statuses() -> [String: AttentionStatus] { statusesOrNil() ?? [:] }

    /// Last-message/response time per tmux session (Claude `updatedAt`), for the
    /// Most Recent sort.
    func activity() -> [String: Int] {
        guard let data = readSessions().data else { return [:] }
        return TmuxModel.parseActivity(fromSessionsJSON: data)
    }

    /// Per-pane status keyed by pane id, for window/pane row dots (same source as
    /// `statuses()`, keyed by pane).
    func paneStatuses() -> [String: AttentionStatus] {
        guard let data = readSessions().data else { return [:] }
        return TmuxModel.parsePaneStatuses(fromSessionsJSON: data)
    }

    /// All three views from ONE `sessions.py` run — python startup is ~200ms, and
    /// the default three-call path paid it three times per poll — plus the codex
    /// scan's two subprocesses. The codex half is computed even when `sessions.py`
    /// is unavailable: the two sources are independent, so a missing status tool
    /// must not also hide codex ids.
    func snapshot() -> StatusSnapshot {
        let codex = codexScan?() ?? (codexByPid: [:], ppids: [:], rollouts: [:])
        guard let data = readSessions().data else {
            return StatusSnapshot(
                codexByPid: codex.codexByPid, ppids: codex.ppids, codexRollouts: codex.rollouts)
        }
        return StatusSnapshot(
            statuses: TmuxModel.parseStatuses(fromSessionsJSON: data),
            activity: TmuxModel.parseActivity(fromSessionsJSON: data),
            paneStatuses: TmuxModel.parsePaneStatuses(fromSessionsJSON: data),
            paneSessionIds: TmuxModel.parsePaneSessionIds(fromSessionsJSON: data),
            paneStatusSince: TmuxModel.parsePaneStatusSince(fromSessionsJSON: data),
            sessionCwds: TmuxModel.parseSessionCwds(fromSessionsJSON: data),
            codexByPid: codex.codexByPid, ppids: codex.ppids, codexRollouts: codex.rollouts)
    }
}

/// Remote attention status: runs the app's bundled `sessions.py` **on the
/// remote**, pushing it to `~/.muxmaestro/tools/` over the shared ssh connection
/// on first contact, so a server needs only python3. If the run fails, it
/// DEGRADES explicitly — logging the reason once and returning nil so the
/// caller falls back to tmux-level info (attached/activity) with a neutral dot,
/// rather than hanging or silently marking everything unknown.
final class RemoteSessionsPyStatusProvider: AttentionStatusProvider {
    private let host: String
    private let scriptPath: String
    /// The bundled script to push; nil skips the push and runs whatever is there.
    private let script: Data?
    private let runner: CommandRunner
    private let warnLock = NSLock()
    private var warned = false
    /// Whether the last read succeeded. Until one does, reads push the script
    /// first — so a host that was offline, or lost the file, gets it again.
    private let pushLock = NSLock()
    private var pushed = false

    init(
        host: String,
        runner: CommandRunner,
        scriptPath: String = BundledTools.remotePath(.sessions),
        script: Data? = BundledTools.contents(.sessions)
    ) {
        self.host = host
        self.runner = runner
        self.scriptPath = scriptPath
        self.script = script
    }

    /// Writes stdin to `scriptPath` through a temp file and a rename, so a run
    /// never reads a half-written script.
    static func pushCommand(scriptPath: String) -> String {
        let dir = (scriptPath as NSString).deletingLastPathComponent
        return "mkdir -p \(dir) && cat > \(scriptPath).tmp && mv -f \(scriptPath).tmp \(scriptPath)"
    }

    private func warnOnce(_ message: String) {
        warnLock.lock()
        defer { warnLock.unlock() }
        guard !warned else { return }
        warned = true
        NSLog("MuxMaestro: \(message)")
    }

    /// One ssh round-trip. Until a read has succeeded it pipes the bundled script
    /// in and runs it (`<push> && python3 <path> list`); after that it only runs
    /// it (`test -f <path> && python3 <path> list`). Any failure exits non-zero,
    /// so `run` returns nil → explicit degrade, and the next read pushes again.
    private func readRemoteSessions() -> Data? {
        pushLock.lock()
        let push = script != nil && !pushed
        pushLock.unlock()
        let list = "python3 \(scriptPath) list"
        let remoteCmd = push
            ? "\(Self.pushCommand(scriptPath: scriptPath)) && \(list)"
            : "test -f \(scriptPath) && \(list)"
        let args = Ssh.opts(host: host) + ["sh", "-c", Ssh.shellQuote(remoteCmd)]
        let out = runner.run(Ssh.sshPath, args, stdin: push ? script : nil)
        let ok = !(out ?? "").isEmpty
        pushLock.lock()
        pushed = ok
        pushLock.unlock()
        guard ok, let out else { return nil }
        return out.data(using: .utf8)
    }

    /// Statuses keyed by tmux name, or nil when the remote status tool is
    /// unavailable (so the caller degrades to tmux-level info with a signal).
    func statusesOrNil() -> [String: AttentionStatus]? {
        guard let data = readRemoteSessions() else {
            warnOnce("remote status tool unavailable on \(host) "
                + "(sessions.py missing or unreachable); remote sessions show "
                + "tmux-level info with a neutral dot")
            return nil
        }
        return TmuxModel.parseStatuses(fromSessionsJSON: data)
    }

    func statuses() -> [String: AttentionStatus] { statusesOrNil() ?? [:] }

    /// Last-message/response time per tmux session on the remote (Claude
    /// `updatedAt`), for the Most Recent sort. One ssh round-trip; empty on failure.
    func activity() -> [String: Int] {
        guard let data = readRemoteSessions() else { return [:] }
        return TmuxModel.parseActivity(fromSessionsJSON: data)
    }

    /// Per-pane status keyed by pane id on the remote, for window/pane row dots.
    /// One ssh round-trip; empty on failure.
    func paneStatuses() -> [String: AttentionStatus] {
        guard let data = readRemoteSessions() else { return [:] }
        return TmuxModel.parsePaneStatuses(fromSessionsJSON: data)
    }

    /// All three views from ONE ssh round-trip. The default three-call path paid a
    /// full remote python startup — over the network — three times per poll.
    ///
    /// `codexByPid`/`ppids` stay empty: resolving codex ids needs an `lsof` on the
    /// far host, an extra SSH round-trip per poll that isn't worth it yet. Remote
    /// panes still get their Claude ids from `sessions.py` above.
    func snapshot() -> StatusSnapshot {
        guard let data = readRemoteSessions() else {
            warnOnce("remote status tool unavailable on \(host) "
                + "(sessions.py missing or unreachable); remote sessions show "
                + "tmux-level info with a neutral dot")
            return StatusSnapshot()
        }
        return StatusSnapshot(
            statuses: TmuxModel.parseStatuses(fromSessionsJSON: data),
            activity: TmuxModel.parseActivity(fromSessionsJSON: data),
            paneStatuses: TmuxModel.parsePaneStatuses(fromSessionsJSON: data),
            paneSessionIds: TmuxModel.parsePaneSessionIds(fromSessionsJSON: data),
            paneStatusSince: TmuxModel.parsePaneStatusSince(fromSessionsJSON: data))
    }
}

/// Wraps a status provider in a short TTL so attention data stops riding the
/// tree poll's cadence.
///
/// The tmux tree is cheap — three `list-*` calls, ~25ms. The status snapshot
/// decorating it is not: `sessions.py` pays python startup (~180ms measured) on
/// the local host, and a full ssh round-trip plus *remote* python startup on
/// every other one. `loadTree` used to block on that once per host per 1.5s
/// tick forever, which is where most of the app's background load came from.
///
/// So: serve the last snapshot immediately, and when it ages past `ttl`, kick a
/// single background refresh. A poll then pays ~0ms for status in the steady
/// state and the underlying tool runs at most once per `ttl` per host. The
/// dots lag reality by at most `ttl`; the session tree itself stays live.
///
/// The very first read is synchronous on purpose — at launch there is nothing to
/// serve, and an empty snapshot would paint every session with no dot and then
/// correct itself a beat later.
final class CachedStatusProvider: AttentionStatusProvider {
    private let base: AttentionStatusProvider
    private let ttl: TimeInterval
    /// Injectable clock so TTL behavior is testable without sleeping.
    private let now: () -> Date

    private let lock = NSLock()
    private var cached: StatusSnapshot?
    private var cachedAt = Date.distantPast
    /// True while a background refresh is in flight, so a burst of polls can't
    /// stack up several concurrent `sessions.py` runs — the exact pile-up this
    /// class exists to prevent.
    private var refreshing = false

    init(
        _ base: AttentionStatusProvider,
        ttl: TimeInterval = 5,
        now: @escaping () -> Date = Date.init
    ) {
        self.base = base
        self.ttl = ttl
        self.now = now
    }

    func snapshot() -> StatusSnapshot {
        lock.lock()
        let current = cached
        let stale = now().timeIntervalSince(cachedAt) >= ttl
        let shouldRefresh = stale && !refreshing
        if shouldRefresh { refreshing = true }
        lock.unlock()

        // Cold start: block once so the first paint has real dots.
        guard let current else {
            let fresh = shouldRefresh ? base.snapshot() : StatusSnapshot()
            if shouldRefresh { store(fresh) }
            return fresh
        }
        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async { [self] in store(base.snapshot()) }
        }
        return current
    }

    private func store(_ snapshot: StatusSnapshot) {
        lock.lock()
        cached = snapshot
        cachedAt = now()
        refreshing = false
        lock.unlock()
    }

    // The three single-view reads are served from the same cache, so a caller
    // that asks for them individually can't sneak past the TTL.
    func statuses() -> [String: AttentionStatus] { snapshot().statuses }
    func activity() -> [String: Int] { snapshot().activity }
    func paneStatuses() -> [String: AttentionStatus] { snapshot().paneStatuses }
}

/// Talks to a live tmux server — local or remote — building the
/// session→window→pane tree and driving selection (switch session / select
/// window / select pane / zoom).
///
/// Host-agnostic by construction: every tmux invocation is built as an argv and
/// dispatched through a `TmuxTransport`. The local transport runs `tmux <argv>`;
/// the ssh transport runs `ssh <opts> <host> tmux <argv>`. So a remote host
/// behaves exactly like the local one — the only difference is the transport.
enum TopologyRestoreMode {
    /// User-initiated restore: preserve any live session and choose a free name.
    case uniqueNames
    /// Journaled restore. Automatic boot recovery preserves exact names and
    /// reports collisions; a user-confirmed restore chooses free names.
    case resume(
        completed: [String: String], inProgress: [String: String], token: String,
        uniqueNames: Bool)
}

struct TopologyRestoreFailure: Equatable {
    let session: String
    let reason: String
}

struct TopologyRestoreReport: Equatable {
    var created: [String] = []
    var alreadyPresent: [String] = []
    var failures: [TopologyRestoreFailure] = []

    var completedCount: Int { created.count + alreadyPresent.count }
    var isComplete: Bool { failures.isEmpty }
}

private struct PendingAgentResume {
    let pane: String
    let command: String
}

final class TmuxService {
    /// The host this service talks to (local or a remote ssh alias).
    let host: Host
    private let transport: TmuxTransport
    private let statusProvider: AttentionStatusProvider
    private let runner: CommandRunner
    /// Hook-reported agent state (`agent_state`), local host only — the hooks
    /// write this Mac's manager DB. nil for remote hosts and test services.
    private let agentStates: (() -> [AgentStateRow])?
    /// Prompt-cache clocks and last prompts from this Mac's Claude transcripts and
    /// Codex rollouts, given Claude session id → cwd and Codex session id →
    /// rollout path (see `TranscriptTailReader`). Local host only; nil elsewhere,
    /// so remote panes keep the status-time 💤 and one-line rows.
    private let transcripts: (([String: String], [String: String]) -> TranscriptTails)?

    /// Runner for the two commands that legitimately outlive `runner`'s 4s ceiling:
    /// `docker ps` (over five minutes at nine concurrent Supabase stacks on this
    /// Mac) and `du -sk` on a `node_modules`-heavy tree. Still an explicit bound —
    /// exceeding it degrades the metric to "unknown", it does not wait forever.
    /// nil in tests, where it falls back to `runner` so a fake records the argv.
    private let slowRunner: CommandRunner?
    private var slow: CommandRunner { slowRunner ?? runner }

    /// Ceiling for `slow`. Long enough that a busy-but-alive Docker answers, short
    /// enough that a wedged one can't hold a sweep thread for minutes.
    static let slowCommandTimeout: TimeInterval = 30

    /// Serial queue for interactive driver shell-outs to THIS host (select /
    /// create / kill / rename / cwd / probe). Per-host so a wedged remote can't
    /// head-of-line-block a switch on another host: same-host ops stay ordered
    /// (no racing tmux mutations on one server), different hosts run concurrently,
    /// and a local switch never waits behind a stalled remote's 8s ssh timeout.
    /// The poll/refresh path uses its own global queues, not this one.
    let driverQueue: DispatchQueue

    /// Guards `lastSnapshotKey`, written from whichever poll queue ran the load.
    private let snapshotLock = NSLock()
    /// Shape of the last tree written to `recovery/tree.json` — so an unchanged
    /// tree costs a string compare instead of a file write every 1.5s.
    private var lastSnapshotKey: String?

    /// Guards `tmuxAvailable`, which is read/written from the poll queues.
    private let probeLock = NSLock()
    /// Memoized `tmux -V` result and when it was taken. See `hasTmux()`.
    private var tmuxAvailable: (value: Bool, at: Date)?

    /// Absolute path to the local tmux binary, or nil if not found / remote.
    /// Kept for the local attach command and the self-tests, which shell tmux
    /// directly. Remote services return nil here.
    var tmuxPath: String? { (transport as? LocalTmuxTransport)?.tmuxPath }

    /// Default-init: the local host, auto-discovering tmux, real providers.
    /// The status provider is TTL-cached — see `CachedStatusProvider` for why the
    /// poll must not pay for `sessions.py` every tick. Injected providers (tests)
    /// are deliberately left uncached.
    convenience init() {
        let path = Self.discoverTmux()
        let runner = ProcessCommandRunner()
        self.init(
            host: .local,
            transport: LocalTmuxTransport(tmuxPath: path),
            runner: runner,
            statusProvider: CachedStatusProvider(SessionsPyStatusProvider(runner: runner)),
            agentStates: AgentStateReader().rows,
            transcripts: TranscriptTailReader.shared.read(sessionCwds:codexRollouts:),
            slowRunner: ProcessCommandRunner(timeout: Self.slowCommandTimeout))
    }

    /// Build a service for `host`: the local transport for the local host, the
    /// ssh transport (with ControlMaster reuse) for a remote host. Remote
    /// attention status comes from `sessions.py` *on the remote* if present,
    /// else degrades to tmux-level info.
    convenience init(host: Host) {
        if host.isLocal {
            self.init()
            return
        }
        let alias = host.sshAlias ?? host.name
        let transport = SshTmuxTransport(host: alias)
        Ssh.ensureControlDir()
        self.init(
            host: host,
            transport: transport,
            runner: ProcessCommandRunner(timeout: transport.timeout),
            statusProvider: CachedStatusProvider(RemoteSessionsPyStatusProvider(
                host: alias,
                runner: ProcessCommandRunner(timeout: transport.timeout))),
            // Remote `docker ps` goes through `slow` like the local one: the ssh
            // hop is fast (0.7s for 96 containers on `devbox`), but a wedged
            // remote daemon must hit an explicit ceiling, not the 8s one meant
            // for interactive tmux calls.
            slowRunner: ProcessCommandRunner(timeout: Self.slowCommandTimeout))
    }

    /// Designated init for testing/injection. Pass a `LocalTmuxTransport` with a
    /// nil `tmuxPath` to exercise the no-tmux degrade path, or any transport for
    /// command-sequence assertions against a fake runner.
    init(
        host: Host = .local,
        transport: TmuxTransport,
        runner: CommandRunner,
        statusProvider: AttentionStatusProvider?,
        agentStates: (() -> [AgentStateRow])? = nil,
        transcripts: (([String: String], [String: String]) -> TranscriptTails)? = nil,
        slowRunner: CommandRunner? = nil
    ) {
        self.host = host
        self.transport = transport
        self.runner = runner
        self.slowRunner = slowRunner
        self.statusProvider = statusProvider ?? SessionsPyStatusProvider(runner: runner)
        self.agentStates = agentStates
        self.transcripts = transcripts
        self.driverQueue = DispatchQueue(label: "is.rebar.muxmaestro.drivers.\(host.name)")
    }

    /// Back-compat designated init used by the existing tests: a local transport
    /// with the given tmux path.
    convenience init(
        runner: CommandRunner,
        statusProvider: AttentionStatusProvider?,
        tmuxPath: String?
    ) {
        self.init(
            host: .local,
            transport: LocalTmuxTransport(tmuxPath: tmuxPath),
            runner: runner,
            statusProvider: statusProvider)
    }

    /// Run a tmux argv through the transport, returning stdout or nil.
    @discardableResult
    private func tmux(_ args: [String], stdin: Data? = nil) -> String? {
        guard let (path, full) = transport.command(forTmux: args) else { return nil }
        return runner.run(path, full, stdin: stdin)
    }

    /// Run a destructive tmux command (kill-session/window/pane) through the
    /// transport, capturing stderr so an *already-gone* target reads as SUCCESS —
    /// the whole point of a close is that the thing is no longer there, so a target
    /// that shifted or vanished before the command ran (a stale sidebar row, a
    /// window tmux renumbered) is not a failure. Only a genuine error (bad syntax,
    /// transport down) returns false, and its real message is logged rather than
    /// swallowed behind a generic alert. Blocking; call off the main thread.
    private func tmuxDestructive(_ args: [String]) -> Bool {
        guard let (path, full) = transport.command(forTmux: args) else { return false }
        let (ok, text) = runner.runCapturing(path, full)
        if ok { return true }
        if TmuxCommands.killReachedGoalDespiteError(text) { return true }
        NSLog("MuxMaestro: tmux \(args.first ?? "?") failed on \(host.name): \(text)")
        return false
    }

    /// The session that a bare `tmux attach` (no `-t`) lands on: the most
    /// recently active one. tmux's own `cmd_find_best_session` picks the session
    /// with the greatest `session_activity`, so mirror that. Returns nil when
    /// there's no server or no sessions. Blocking shell-out; used at launch to
    /// seed the terminal's startup attach state.
    func mostRecentSession() -> String? {
        guard let out = tmux(["list-sessions", "-F", "#{session_activity}\t#{session_name}"])
        else { return nil }
        return out.split(separator: "\n").compactMap { line -> (activity: Int, name: String)? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let activity = Int(parts[0]) else { return nil }
            return (activity, String(parts[1]))
        }.max { $0.activity < $1.activity }?.name
    }

    /// The command the libghostty surface runs to attach to `session` on this
    /// host (local `tmux attach` or remote `ssh -t … new-session -A`). When
    /// `useMosh` is set and this is a remote host with a local mosh client, the
    /// roaming mosh form is used instead; it falls back to ssh when mosh isn't
    /// available locally. Local hosts ignore mosh entirely.
    func attachCommand(session: String, useMosh: Bool = false) -> String? {
        if useMosh, let ssh = transport as? SshTmuxTransport,
           let mosh = ssh.moshAttachCommand(session: session) {
            return mosh
        }
        return transport.attachCommand(session: session)
    }

    /// Whether `mosh-server` is on the remote host's PATH (so a mosh attach can
    /// succeed). Runs `command -v mosh-server` over the shared ssh connection.
    /// Always false for the local host (mosh isn't used locally). Returns nil-vs
    /// behavior via `runHostCommand`, which is nil on a non-zero exit (not
    /// installed). Call off the main thread.
    func hasMoshServer() -> Bool {
        guard host.sshAlias != nil else { return false }
        return runHostCommand(local: "", remote: "command", ["-v", "mosh-server"]) != nil
    }

    private static func discoverTmux() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Build the full, sorted session tree from the live tmux server, with
    /// attention statuses joined in.
    ///
    /// Returns `nil` when the `list-sessions` command itself fails (non-zero exit,
    /// launch failure, or — crucially — a timeout under load): the caller must keep
    /// its last good tree instead of blanking, since a transient failure is NOT the
    /// same as "no sessions". Returns `[]` only when the command succeeds with no
    /// sessions. Does real work (a few serial shell-outs); call it off the main thread.
    ///
    /// Costs four commands regardless of how many sessions exist: `list-sessions`,
    /// a server-wide `list-windows -a`, a server-wide `list-panes -a`, and one status
    /// snapshot. It used to issue one `list-windows` per session and one `list-panes`
    /// per window, plus three separate status reads — 19 subprocesses for five
    /// sessions, on every ~1.5s poll, and 19 SSH round-trips for a remote host.
    func loadTree() -> [TmuxSession]? {
        let before = Diag.spawnStats()
        let t0 = Date()
        defer {
            Diag.log("loadTree", "host=\(host.name) "
                + "\(String(format: "%7.1fms", Date().timeIntervalSince(t0) * 1000)) "
                + "\(Diag.spawnStats().delta(since: before))")
        }
        guard let sessOut = tmux(["list-sessions", "-F", TmuxModel.sessionsFormat])
        else {
            // The load that would have blanked the sidebar, had the caller not
            // kept its last good tree. Worth a line every time it happens.
            Diag.log("loadTree", "host=\(host.name) list-sessions FAILED → nil (tree preserved)")
            return nil
        }

        let sessionRows = TmuxModel.dedupeGroups(TmuxModel.parseSessions(sessOut))

        // Two server-wide queries, not one per session and one per window. A failed
        // query yields no windows/panes rather than dropping the session itself —
        // the session row still renders, just without its subtree.
        let windowsBySession = tmux(["list-windows", "-a", "-F", TmuxModel.allWindowsFormat])
            .map(TmuxModel.parseAllWindows) ?? [:]
        let panesByWindow = tmux(["list-panes", "-a", "-F", TmuxModel.allPanesFormat])
            .map(TmuxModel.parseAllPanes) ?? [:]

        var sessions: [TmuxSession] = []
        for row in sessionRows {
            var windows = windowsBySession[row.name] ?? []
            for i in windows.indices {
                windows[i].panes = panesByWindow[
                    TmuxModel.paneKey(session: row.name, window: windows[i].index)] ?? []
            }
            sessions.append(TmuxSession(
                name: row.name, attached: row.attached, windows: windows, activity: row.activity))
        }
        // One status read, parsed three ways — `statuses()`, `activity()` and
        // `paneStatuses()` each used to spawn their own `sessions.py` (~200ms apiece).
        let status = statusProvider.snapshot()
        // A SQLite read, not a subprocess, so it runs every poll instead of
        // riding the status cache: a pane goes red as soon as its agent asks.
        let agentStates = Dictionary(
            (self.agentStates?() ?? []).map { ($0.sessionId, $0) },
            uniquingKeysWith: { first, _ in first })
        let tails = transcripts?(status.sessionCwds, status.codexRollouts) ?? TranscriptTails()
        ObservedCacheTTL.shared.record(AgentState.observedTTL(tails.clocks.values))
        let result = TmuxModel.sorted(
            sessions: sessions, statuses: status.statuses,
            activity: status.activity,
            paneStatuses: status.paneStatuses,
            paneSessionIds: status.paneSessionIds,
            paneStatusSince: status.paneStatusSince,
            codexByPid: status.codexByPid,
            ppids: status.ppids,
            agentStates: agentStates,
            cacheClocks: tails.clocks,
            fallbackTTL: ObservedCacheTTL.shared.value,
            lastPrompts: tails.prompts,
            lastWrites: tails.lastWrites)
        // The app explicitly clears the snapshot when its close actions remove the
        // last session. An empty poll can instead mean tmux died, so it must not
        // erase the last useful tree before manual recovery can use it.
        Diag.log("loadTree", "host=\(host.name) parsedRows=\(sessionRows.count) "
            + "sessions=\(result.count)\(result.isEmpty ? " EMPTY (keeps last snapshot)" : "")")
        // Snapshot capture is cheap and powers the manual recovery button even
        // when automatic recovery hooks are disabled. Hold the startup snapshot
        // through an empty boot, then resume as soon as a live tree appears.
        if !Settings.sessionRecoveryEnabled(), !result.isEmpty {
            SessionRecord.resumeSnapshotWrites()
        }
        persistSnapshot(result)
        return result
    }

    /// Record the local tree to `recovery/tree.json` so a reboot can rebuild it.
    /// Free-riding on the poll the sidebar already runs — no extra tmux calls.
    ///
    /// Local host only (the snapshot restores onto this Mac's tmux server). This
    /// records topology and per-pane agent ids for manual recovery; automatic
    /// relaunch and agent hooks remain separately opt-in. Empty snapshots are
    /// written only by explicit app actions that close the last session.
    private func persistSnapshot(_ sessions: [TmuxSession], allowEmpty: Bool = false) {
        guard host.isLocal, SessionRecord.canWriteSnapshot,
              allowEmpty || !sessions.isEmpty else { return }
        let snapshot = SessionRecord.snapshot(from: sessions, at: Date())
        // Compare on the shape only — `at` changes every poll and would defeat it.
        let key = String(describing: snapshot.sessions)
        snapshotLock.lock()
        let unchanged = lastSnapshotKey == key
        if !unchanged { lastSnapshotKey = key }
        snapshotLock.unlock()
        guard !unchanged else { return }
        SessionRecord.writeSnapshot(snapshot)
    }

    // MARK: Selection drivers

    /// Select a window within a session (does not change which session the
    /// surface is attached to). Unzooms the window first so a previously-zoomed
    /// pane doesn't leave the surface stuck on a single pane.
    @discardableResult
    func selectWindow(session: String, window: Int) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        unzoomIfNeeded(session: session, window: window)
        return tmux(["select-window", "-t", "\(session):\(window)"]) != nil
    }

    /// Select a pane within a window, then zoom it so the single surface shows
    /// exactly that pane. Unzooms first to make zoom idempotent.
    @discardableResult
    func selectPane(session: String, window: Int, pane: String, zoom: Bool) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        _ = tmux(["select-window", "-t", "\(session):\(window)"])
        let ok = tmux(["select-pane", "-t", pane]) != nil
        if zoom, !isZoomed(target: pane) {
            _ = tmux(TmuxCommands.toggleZoom(target: pane))
        }
        return ok
    }

    /// Unzoom the given window if it is currently zoomed.
    func unzoomIfNeeded(session: String, window: Int) {
        guard transport.command(forTmux: []) != nil else { return }
        let target = "\(session):\(window)"
        if isZoomed(target: target) {
            _ = tmux(TmuxCommands.toggleZoom(target: target))
        }
    }

    // MARK: Find in Session (⌘F — copy-mode search)

    /// Start (or retype) a scrollback search in `session`'s active pane: restart
    /// copy-mode from the bottom and search up for the literal `needle`, then
    /// return the match-count label. Restarting from the bottom on every needle
    /// change keeps incremental typing anchored ("nearest match above the
    /// prompt") instead of drifting further up from wherever the previous,
    /// shorter needle landed. An empty needle just ends the search (nil label).
    func searchInPane(session: String, needle: String) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        _ = tmux(TmuxCommands.exitCopyMode(target: session))
        guard !needle.isEmpty else { return nil }
        guard tmux(TmuxCommands.copyMode(target: session)) != nil else { return nil }
        _ = tmux(TmuxCommands.searchBackward(target: session, text: needle))
        return TmuxCommands.searchCountLabel(tmux(TmuxCommands.searchCount(target: session)))
    }

    /// Step the active search (`up` == toward older output) and return the
    /// updated match-count label.
    func searchStep(session: String, up: Bool) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        _ = tmux(TmuxCommands.searchStep(target: session, up: up))
        return TmuxCommands.searchCountLabel(tmux(TmuxCommands.searchCount(target: session)))
    }

    /// End the search and leave copy-mode so the pane resumes live output.
    func endSearch(session: String) {
        guard transport.command(forTmux: []) != nil else { return }
        _ = tmux(TmuxCommands.exitCopyMode(target: session))
    }

    // MARK: Actions (M4)

    /// True when the given target's window is currently zoomed.
    func isZoomed(target: String) -> Bool {
        tmux(TmuxCommands.zoomFlag(target: target))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Toggle zoom on a target (pane id or `session:window`) and return the new
    /// zoom state (true == now zoomed).
    @discardableResult
    func toggleZoom(target: String) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        _ = tmux(TmuxCommands.toggleZoom(target: target))
        return isZoomed(target: target)
    }

    /// Create a detached session in `dir`, optionally launching `claude` in it.
    /// Returns the sanitized session name on success, or nil on failure.
    @discardableResult
    func newSession(name: String, dir: String, launchClaude: Bool) -> String? {
        guard transport.command(forTmux: []) != nil,
              let clean = TmuxCommands.sanitizedSessionName(name) else { return nil }
        // Dedupe up front: tmux hard-fails `new-session` on a name that already
        // exists, and the prompt routinely pre-fills a folder basename that
        // collides. Suffix `-2`, `-3`, … so creation just succeeds.
        let unique = TmuxCommands.uniqueSessionName(clean, existing: existingSessionNames())
        guard tmux(TmuxCommands.newSession(name: unique, dir: dir)) != nil else { return nil }
        if launchClaude {
            _ = tmux(TmuxCommands.sendKeysLine(session: unique, line: "claude"))
        }
        return unique
    }

    /// Recover a lost Claude Code (or, with `agent`, Codex) session: create a
    /// detached tmux session in the transcript's directory and put
    /// `claude --resume <id>` / `codex resume <id>` in its pane —
    /// executed when `autostart`, otherwise just typed so the user fires each one
    /// when they get to it (recovering many at once shouldn't boot them all).
    /// Returns the created session's name, or nil on failure.
    @discardableResult
    func recoverSession(
        name: String, dir: String, claudeSessionId: String, autostart: Bool,
        agent: RecoveryAgent = .claude
    ) -> String? {
        guard transport.command(forTmux: []) != nil,
              let clean = TmuxCommands.sanitizedSessionName(name) else { return nil }
        let unique = TmuxCommands.uniqueSessionName(clean, existing: existingSessionNames())
        guard tmux(TmuxCommands.newSession(name: unique, dir: dir)) != nil else { return nil }
        let resume = agent.resumeCommand(sessionId: claudeSessionId)
        if autostart {
            _ = tmux(TmuxCommands.sendKeysLine(session: unique, line: resume))
        } else {
            _ = tmux(TmuxCommands.sendKeysText(session: unique, text: resume))
        }
        return unique
    }

    /// Rebuild a whole tmux tree from a `SessionRecord` restore plan: one tmux
    /// session per plan session, with saved window names and indexes, pane count,
    /// layouts, active selections, directories, and Claude/Codex resume commands.
    /// Resume commands run immediately when `resumeAgentsImmediately` is enabled;
    /// otherwise they are typed at the prompt for the user to fire later.
    ///
    /// Saved windows are addressed by their restored indexes; snapshots from
    /// older versions without indexes use the current window immediately after
    /// creation. Restore runs on a detached, freshly built session, so nothing
    /// else can move a target window underneath it.
    ///
    /// Returns the names of the sessions created, in plan order. Blocking; call
    /// off the main thread.
    @discardableResult
    func recoverTopology(_ plan: [RestoreSession]) -> [String] {
        recoverTopology(plan, mode: .uniqueNames).created
    }

    /// Rebuild a topology and report each session independently. A failed
    /// session is removed as a unit, while sessions that finished are retained
    /// and can be journaled before moving on to the next one.
    @discardableResult
    func recoverTopology(
        _ plan: [RestoreSession],
        mode: TopologyRestoreMode,
        resumeAgentsImmediately: Bool = false,
        onSessionStarting: ((String, String) -> Bool)? = nil,
        onSession: ((String, String?, Bool) -> Void)? = nil
    ) -> TopologyRestoreReport {
        guard transport.command(forTmux: []) != nil else {
            return TopologyRestoreReport(
                failures: plan.map { TopologyRestoreFailure(
                    session: $0.name, reason: "tmux is unavailable") })
        }

        var report = TopologyRestoreReport()
        var existing = existingSessionNames()
        var liveByName: [String: TmuxSession] = [:]
        if case .resume = mode {
            // No server after a reboot returns nil from list-sessions; recovery
            // creates it through the first new-session call.
            let live = loadTree() ?? []
            liveByName = Dictionary(uniqueKeysWithValues: live.map { ($0.name, $0) })
        }

        for (planIndex, session) in plan.enumerated() {
            guard let clean = TmuxCommands.sanitizedSessionName(session.name),
                  let first = session.windows.first,
                  let firstPane = first.panes.first else {
                let failure = TopologyRestoreFailure(
                    session: session.name, reason: "session has no restorable panes")
                report.failures.append(failure)
                onSession?(session.name, nil, false)
                continue
            }

            let restoreName: String
            let buildName: String
            let inProgressName: String?
            if case let .resume(completed, inProgress, token, uniqueNames) = mode {
                let recordedName = completed[session.name]
                restoreName = TmuxCommands.sanitizedSessionName(
                    recordedName ?? (uniqueNames
                        ? TmuxCommands.uniqueSessionName(clean, existing: existing)
                        : clean)) ?? clean
                if let actual = liveByName[restoreName] {
                    let expected = RestoreSession(name: restoreName, windows: session.windows)
                    if SessionRecord.matches(expected, actual: actual) {
                        if let temporary = inProgress[session.name], liveByName[temporary] != nil,
                           !tmuxDestructive(TmuxCommands.killSession(name: temporary)) {
                            let failure = TopologyRestoreFailure(
                                session: session.name,
                                reason: "could not remove the interrupted recovery session")
                            report.failures.append(failure)
                            onSession?(session.name, temporary, false)
                            continue
                        }
                        report.alreadyPresent.append(restoreName)
                        onSession?(session.name, restoreName, true)
                    } else {
                        let failure = TopologyRestoreFailure(
                            session: session.name,
                            reason: "session named \(restoreName) exists with a different layout")
                        report.failures.append(failure)
                        onSession?(session.name, restoreName, false)
                    }
                    continue
                }

                let pendingName = inProgress[session.name]
                    ?? "mmr-\(String(token.replacingOccurrences(of: "-", with: "").prefix(10)))-\(planIndex)"
                buildName = TmuxCommands.sanitizedSessionName(pendingName) ?? pendingName
                inProgressName = buildName

                if let partial = liveByName[buildName] {
                    guard inProgress[session.name] == buildName else {
                        let failure = TopologyRestoreFailure(
                            session: session.name,
                            reason: "temporary recovery name \(buildName) is already in use")
                        report.failures.append(failure)
                        onSession?(session.name, buildName, false)
                        continue
                    }
                    let expected = RestoreSession(name: buildName, windows: session.windows)
                    if SessionRecord.matches(expected, actual: partial) {
                        guard tmux(TmuxCommands.renameSession(from: buildName, to: restoreName)) != nil else {
                            let failure = TopologyRestoreFailure(
                                session: session.name,
                                reason: "tmux could not finish naming the recovered session")
                            report.failures.append(failure)
                            onSession?(session.name, buildName, false)
                            continue
                        }
                        report.alreadyPresent.append(restoreName)
                        onSession?(session.name, restoreName, true)
                        continue
                    }
                    guard tmuxDestructive(TmuxCommands.killSession(name: buildName)) else {
                        let failure = TopologyRestoreFailure(
                            session: session.name,
                            reason: "could not remove the interrupted recovery session")
                        report.failures.append(failure)
                        onSession?(session.name, buildName, false)
                        continue
                    }
                    liveByName.removeValue(forKey: buildName)
                }

                guard onSessionStarting?(session.name, buildName) ?? true else {
                    let failure = TopologyRestoreFailure(
                        session: session.name, reason: "could not save recovery progress")
                    report.failures.append(failure)
                    onSession?(session.name, buildName, false)
                    continue
                }
            } else {
                restoreName = TmuxCommands.uniqueSessionName(clean, existing: existing)
                buildName = restoreName
                inProgressName = nil
            }

            guard tmux(TmuxCommands.newSession(name: buildName, dir: firstPane.cwd)) != nil
            else {
                let failure = TopologyRestoreFailure(
                    session: session.name, reason: "tmux could not create the session")
                report.failures.append(failure)
                onSession?(session.name, nil, false)
                continue
            }
            existing.insert(restoreName)

            var failureReason: String?
            if let firstWindowIndex = first.index {
                let currentIndexText = tmux([
                    "display-message", "-p", "-t", "=\(buildName):", "#{window_index}",
                ])?.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentIndex = currentIndexText.flatMap { Int($0) }
                if let currentIndex {
                    if currentIndex != firstWindowIndex,
                       tmux(TmuxCommands.moveWindow(
                        source: "=\(buildName):\(currentIndex)",
                        target: "=\(buildName):\(firstWindowIndex)")) == nil {
                        failureReason = "tmux could not restore window index \(firstWindowIndex)"
                    }
                } else {
                    failureReason = "tmux could not read the new session's first window index"
                }
            }

            var pendingResumes: [PendingAgentResume] = []
            // `new-session` already made the first window. Saved windows use
            // their original indexes; old snapshots without indexes still append.
            if failureReason == nil {
                for (position, window) in session.windows.enumerated() {
                    let windowIndex: Int?
                    if position == 0 {
                        windowIndex = window.index
                    } else if let savedIndex = window.index {
                        guard tmux(TmuxCommands.newWindow(
                            session: buildName, cwd: window.panes[0].cwd,
                            atIndex: savedIndex)) != nil else {
                            failureReason = "tmux could not create window \(window.name)"
                            break
                        }
                        windowIndex = savedIndex
                    } else {
                        guard tmux(TmuxCommands.newWindow(
                            session: buildName, cwd: window.panes[0].cwd)) != nil else {
                            failureReason = "tmux could not create window \(window.name)"
                            break
                        }
                        windowIndex = nil
                    }
                    let windowTarget = windowIndex.map { "=\(buildName):\($0)" } ?? "=\(buildName):"
                    if let error = restore(
                        window: window, target: windowTarget,
                        resumeAgentsImmediately: resumeAgentsImmediately,
                        pendingResumes: &pendingResumes) {
                        failureReason = error
                        break
                    }
                }
            }

            if failureReason == nil, let activeWindow = session.windows.first(where: \.active) {
                let target = activeWindow.index.map { "=\(buildName):\($0)" } ?? "=\(buildName):"
                if tmux(TmuxCommands.selectWindow(target: target)) == nil {
                    failureReason = "tmux could not restore the active window"
                }
            }

            // Finish constructing this session's windows and panes before
            // launching any of its recorded agents.
            if failureReason == nil, resumeAgentsImmediately {
                for resume in pendingResumes {
                    guard tmux(TmuxCommands.sendKeysLine(
                        session: resume.pane, line: resume.command)) != nil else {
                        failureReason = "could not resume an agent in session \(session.name)"
                        break
                    }
                }
            }

            if failureReason == nil, inProgressName != nil, buildName != restoreName,
               tmux(TmuxCommands.renameSession(from: buildName, to: restoreName)) == nil {
                failureReason = "tmux could not name the recovered session \(restoreName)"
            }

            if let failureReason {
                let cleanedUp = tmuxDestructive(TmuxCommands.killSession(name: buildName))
                let reason = cleanedUp
                    ? failureReason
                    : "\(failureReason); the incomplete session could not be removed"
                report.failures.append(TopologyRestoreFailure(
                    session: session.name, reason: reason))
                onSession?(session.name, buildName, false)
            } else {
                report.created.append(restoreName)
                onSession?(session.name, restoreName, true)
                liveByName[restoreName] = TmuxSession(
                    name: restoreName, attached: false, windows: [])
            }
        }
        return report
    }

    /// Name the session's current window, stage its first pane, and split out the
    /// rest. `allow-rename off` so the restored name survives the moment the user
    /// presses Enter and the agent sets its own window title.
    private func restore(
        window: RestoreWindow, target: String,
        resumeAgentsImmediately: Bool, pendingResumes: inout [PendingAgentResume]
    ) -> String? {
        let name = window.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            guard tmux(TmuxCommands.renameWindow(target: target, to: name)) != nil else {
                return "tmux could not name window \(name)"
            }
            guard tmux(TmuxCommands.setAllowRename(target: target, on: false)) != nil else {
                return "tmux could not preserve window name \(name)"
            }
        }
        for (index, pane) in window.panes.enumerated() {
            // A split leaves the new pane active, so `target` keeps pointing at
            // the pane being staged.
            if index > 0 {
                guard tmux(TmuxCommands.splitWindow(
                    target: target, vertical: true, cwd: pane.cwd)) != nil else {
                    return "tmux could not create a pane in window \(name)"
                }
            }
            if let resume = pane.resumeCommand {
                if resumeAgentsImmediately {
                    guard let paneID = tmux([
                        "display-message", "-p", "-t", target, "#{pane_id}"])?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !paneID.isEmpty else {
                        return "tmux could not find the agent pane in window \(name)"
                    }
                    pendingResumes.append(PendingAgentResume(pane: paneID, command: resume))
                } else {
                    guard tmux(TmuxCommands.sendKeysText(session: target, text: resume)) != nil else {
                        return "tmux could not stage the agent resume command in window \(name)"
                    }
                }
            }
        }

        if let layout = window.layout, !layout.isEmpty,
           tmux(TmuxCommands.selectLayout(target: target, layout: layout)) == nil {
            return "tmux could not restore pane layout in window \(name)"
        }
        if let activePaneIndex = window.panes.firstIndex(where: \.active) {
            guard tmux(TmuxCommands.selectPane(
                target: "\(target).\(activePaneIndex)")) != nil else {
                return "tmux could not restore active pane in window \(name)"
            }
        }
        return nil
    }

    /// The filesystem path of the tmux socket this service talks to, or nil when
    /// there is no server. Only the recovery self-test uses it — to prove it is
    /// aimed at a scratch server before it starts killing sessions.
    func socketPath() -> String? {
        tmux(["display-message", "-p", "#{socket_path}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Names of every session currently on this host (empty when there's no
    /// server or tmux is unavailable). Used to dedupe a new session's name.
    private func existingSessionNames() -> Set<String> {
        guard let out = tmux(["list-sessions", "-F", "#{session_name}"]) else { return [] }
        return Set(out.split(separator: "\n").map(String.init))
    }

    /// Kill a session.
    @discardableResult
    func killSession(name: String) -> Bool {
        let before = host.isLocal && SessionRecord.canWriteSnapshot
            && Settings.sessionRecoveryEnabled() ? existingSessionNames() : []
        let killed = tmuxDestructive(TmuxCommands.killSession(name: name))
        // Persist the empty-tree tombstone as part of the destructive action.
        // Waiting for the next sidebar poll left a stale non-empty snapshot if
        // the app was quit immediately after closing its last session.
        if killed, before.count == 1, before.contains(name) {
            persistSnapshot([], allowEmpty: true)
        }
        return killed
    }

    /// Whether a session named exactly `name` exists (`=` disables tmux's
    /// prefix matching). Blocking shell-out; call off the main thread.
    func hasSession(_ name: String) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        return tmux(["has-session", "-t", "=\(name)"]) != nil
    }

    /// Run a **non-destructive** tmux argv through this host's transport and hand
    /// back stdout (empty string on a silent success), or nil when tmux is
    /// unavailable or the command failed. `tmux(_:)` itself stays private so
    /// callers go through a typed helper; this is the escape hatch for a command
    /// with exactly one caller: the manager creating its own session detached.
    /// Blocking shell-out; call off the main thread.
    @discardableResult
    func runTmux(_ args: [String]) -> String? {
        tmux(args)
    }

    /// Read the current transcript for an agent session on this host. The id is
    /// treated as an opaque filename component and restricted to UUID characters
    /// before it reaches `find`.
    func handoffTranscript(agent: AgentHandoff.Agent, sessionId: String) -> String? {
        guard !sessionId.isEmpty,
              sessionId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let home = resolveHome() else { return nil }
        let directory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(agent == .claude ? ".claude/projects" : ".codex/sessions",
                                    isDirectory: true).path
        let find = runHostCommand(
            local: "/usr/bin/find", remote: "find",
            [directory, "-type", "f", "-name", "\(sessionId).jsonl", "-print", "-quit"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let find, !find.isEmpty else { return nil }
        return runHostCommand(local: "/usr/bin/tail", remote: "tail", ["-c", "8388608", find])
    }

    /// Reset the agent conversation in `target`, then paste the handoff prompt
    /// after the slash command has had time to create the fresh conversation.
    /// Enter is left to the user so they can add to the prompt first. Work runs on this host's serial driver queue; completion
    /// returns on the main queue.
    func performHandoff(
        target: String, agent: AgentHandoff.Agent, prompt: String,
        completion: @escaping (Bool) -> Void
    ) {
        driverQueue.async { [weak self] in
            guard let self,
                  self.tmux(TmuxCommands.resetForHandoff(
                    target: target, command: agent.resetCommand)) != nil else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.driverQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                let pasted = self.pasteAndSubmit(prompt, into: target, submit: false)
                DispatchQueue.main.async { completion(pasted) }
            }
        }
    }

    /// Open a new window beside `source`, in its directory, start a fresh agent
    /// there, and submit the handoff prompt. The source pane is left as it is.
    /// Completion returns the new window on the main queue (nil on failure).
    func performHandoffInNewWindow(
        session: String, source: String, agent: AgentHandoff.Agent, prompt: String,
        completion: @escaping (TmuxCommands.CreatedPane?) -> Void
    ) {
        driverQueue.async { [weak self] in
            guard let self,
                  let created = TmuxCommands.parseCreatedPane(self.tmux(TmuxCommands.newWindow(
                    session: session, cwd: self.targetCwd(source), printTarget: true))),
                  let shell = self.paneCommand(created.pane),
                  self.tmux(TmuxCommands.startAgent(
                    target: created.pane, command: agent.launchCommand)) != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.submitWhenAgentStarts(
                prompt, into: created.pane, shell: shell,
                deadline: Date().addingTimeInterval(15)) { sent in
                    completion(sent ? created : nil)
                }
        }
    }

    /// Poll until the agent replaces the shell in `pane`, give its input box a
    /// moment to draw, then paste. Runs on the driver queue; completion on main.
    private func submitWhenAgentStarts(
        _ prompt: String, into pane: String, shell: String, deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        let started = AgentHandoff.agentStarted(command: paneCommand(pane) ?? "", shell: shell)
        guard started || Date() >= deadline else {
            driverQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                self.submitWhenAgentStarts(
                    prompt, into: pane, shell: shell, deadline: deadline, completion: completion)
            }
            return
        }
        guard started else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        driverQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            let submitted = self?.pasteAndSubmit(prompt, into: pane) ?? false
            DispatchQueue.main.async { completion(submitted) }
        }
    }

    private func paneCommand(_ pane: String) -> String? {
        tmux(["display-message", "-p", "-t", pane, "#{pane_current_command}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Paste through a private tmux buffer, then press Enter when `submit`.
    private func pasteAndSubmit(_ prompt: String, into target: String, submit: Bool = true) -> Bool {
        let buffer = "sidekick-handoff-\(UUID().uuidString)"
        let commands = TmuxCommands.pasteHandoff(target: target, buffer: buffer)
        return tmux(commands.load, stdin: Data(prompt.utf8)) != nil
            && tmux(commands.paste) != nil
            && (!submit || tmux(TmuxCommands.submitPastedText(target: target)) != nil)
    }

    /// Rename a session. Returns the sanitized new name on success, nil on
    /// failure (missing tmux or empty new name).
    @discardableResult
    func renameSession(from old: String, to new: String) -> String? {
        guard transport.command(forTmux: []) != nil,
              let clean = TmuxCommands.sanitizedSessionName(new) else { return nil }
        guard tmux(TmuxCommands.renameSession(from: old, to: clean)) != nil else { return nil }
        return clean
    }

    // MARK: Window / pane actions (M9)

    /// Kill a window by its `session:window` target. Destructive — callers gate
    /// it behind a confirmation. Routes through the transport so it kills the
    /// window on this service's host (local or remote) automatically.
    @discardableResult
    func killWindow(session: String, window: Int) -> Bool {
        let tree = host.isLocal && SessionRecord.canWriteSnapshot
            && Settings.sessionRecoveryEnabled() ? (loadTree() ?? []) : []
        let removesLastSession = tree.count == 1 && tree[0].name == session
            && tree[0].windows.count == 1 && tree[0].windows[0].index == window
        let target = TmuxCommands.windowTarget(session: session, window: window)
        let killed = tmuxDestructive(TmuxCommands.killWindow(target: target))
        if killed, removesLastSession { persistSnapshot([], allowEmpty: true) }
        return killed
    }

    /// Kill the session's currently-active window (⌘W). tmux resolves a bare
    /// `-t <session>` target to that session's active window — the one the
    /// attached client is viewing. Killing the last window ends the session.
    func killActiveWindow(session: String) -> Bool {
        let tree = host.isLocal && SessionRecord.canWriteSnapshot
            && Settings.sessionRecoveryEnabled() ? (loadTree() ?? []) : []
        let removesLastSession = tree.count == 1 && tree[0].name == session
            && tree[0].windows.count == 1
        // Bare `-t =session` resolves to that session's active window (exact-match on
        // the session name so a prefix can't select the wrong session).
        let killed = tmuxDestructive(TmuxCommands.killWindow(target: "=\(session)"))
        if killed, removesLastSession { persistSnapshot([], allowEmpty: true) }
        return killed
    }

    /// Rename a window. Returns the trimmed new name on success, nil on failure
    /// (missing tmux/transport or an empty new name). Unlike session names, `.`
    /// and `:` are fine in a window name (it's not used as a target separator
    /// once created), so we only trim.
    @discardableResult
    func renameWindow(session: String, window: Int, to new: String) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let target = TmuxCommands.windowTarget(session: session, window: window)
        guard tmux(TmuxCommands.renameWindow(target: target, to: clean)) != nil else { return nil }
        return clean
    }

    /// Set a pane's title by its pane id (e.g. `%12`). Returns the trimmed title on
    /// success, nil on failure (missing tmux/transport or an empty title). Panes
    /// have no name in tmux; the title is the closest equivalent (best-effort — a
    /// program can overwrite it via an escape sequence).
    @discardableResult
    func setPaneTitle(paneId: String, to new: String) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard tmux(TmuxCommands.setPaneTitle(paneId: paneId, to: clean)) != nil else { return nil }
        return clean
    }

    /// Turn `allow-rename` on/off for a window so a program's title escape can't
    /// clobber a name we set (used by the AI auto-namer to make a rename stick).
    @discardableResult
    func setAllowRename(session: String, window: Int, on: Bool) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        let target = TmuxCommands.windowTarget(session: session, window: window)
        return tmux(TmuxCommands.setAllowRename(target: target, on: on)) != nil
    }

    /// Set a window user option such as `@mm_prs`. Blocking — callers dispatch on
    /// `driverQueue`.
    @discardableResult
    func setWindowUserOption(session: String, window: Int, key: String, value: String) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        let target = TmuxCommands.windowTarget(session: session, window: window)
        return tmux(TmuxCommands.setWindowUserOption(target: target, key: key, value: value)) != nil
    }

    /// Set the window name's 🥱 / 💤 tag to match `stage`. Re-reads the name
    /// options, then writes only if they are still what it read (see
    /// `IdleTag.syncCommand`): an agent's naming script may tag the window at any
    /// moment, and writing a stale copy would drop that tag. `seen` is the window's
    /// name, base and tags as the poll read them (see `IdleTag.isSettled`).
    /// Blocking — callers dispatch on `driverQueue`.
    func syncIdleTag(
        session: String, window: Int, stage: IdleStage,
        seen: (name: String, base: String, tags: String)
    ) {
        let target = TmuxCommands.windowTarget(session: session, window: window)
        guard let out = tmux(["display-message", "-p", "-t", target, IdleTag.optionsFormat])
        else { return }
        let f = out.trimmingCharacters(in: .newlines).components(separatedBy: TmuxModel.fieldSep)
        guard f.count == 3,
              IdleTag.isSettled(name: f[0], base: f[1], tags: f[2], seen: seen),
              let update = IdleTag.update(name: f[0], base: f[1], tags: f[2], stage: stage)
        else { return }
        _ = tmux(IdleTag.syncCommand(
            target: target, name: f[0], base: f[1], tags: f[2], update: update))
    }

    /// Create a new window in `session`, optionally in `cwd`. Returns the new
    /// window's index (nil on failure) so the caller can go straight to it —
    /// tmux inserts with `-a` and renumbers, so "the last one" is a bad guess.
    @discardableResult
    func newWindow(session: String, cwd: String?) -> Int? {
        guard transport.command(forTmux: []) != nil else { return nil }
        return TmuxCommands.parseCreatedWindow(
            tmux(TmuxCommands.newWindow(session: session, cwd: cwd, printIndex: true)))
    }

    /// Kill a pane by its `session:window.pane` target. Destructive — callers
    /// gate it behind a confirmation.
    @discardableResult
    func killPane(session: String, window: Int, pane: String) -> Bool {
        let tree = host.isLocal && SessionRecord.canWriteSnapshot
            && Settings.sessionRecoveryEnabled() ? (loadTree() ?? []) : []
        let removesLastSession = tree.count == 1 && tree[0].name == session
            && tree[0].windows.count == 1 && tree[0].windows[0].index == window
            && tree[0].windows[0].panes.count == 1 && tree[0].windows[0].panes[0].id == pane
        let target = TmuxCommands.paneTarget(session: session, window: window, pane: pane)
        let killed = tmuxDestructive(TmuxCommands.killPane(target: target))
        if killed, removesLastSession { persistSnapshot([], allowEmpty: true) }
        return killed
    }

    /// Split a pane horizontally (side by side) or vertically (stacked). Returns
    /// where the new pane landed (nil on failure).
    @discardableResult
    func splitPane(
        session: String, window: Int, pane: String, vertical: Bool
    ) -> TmuxCommands.CreatedPane? {
        guard transport.command(forTmux: []) != nil else { return nil }
        let target = TmuxCommands.paneTarget(session: session, window: window, pane: pane)
        return TmuxCommands.parseCreatedPane(tmux(TmuxCommands.splitWindow(
            target: target, vertical: vertical, cwd: targetCwd(target), printTarget: true)))
    }

    /// Split the active pane of `session` (its active window) — what the attached
    /// surface is showing — left/right (`vertical: false`) or top/bottom
    /// (`vertical: true`). The attached client redraws the new pane on its own.
    @discardableResult
    func splitActivePane(session: String, vertical: Bool) -> TmuxCommands.CreatedPane? {
        guard transport.command(forTmux: []) != nil else { return nil }
        return TmuxCommands.parseCreatedPane(tmux(TmuxCommands.splitWindow(
            target: session, vertical: vertical, cwd: targetCwd(session), printTarget: true)))
    }

    /// Swap two panes by id (drag-to-rearrange "center" drop).
    @discardableResult
    func swapPane(source: String, target: String) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        return tmux(TmuxCommands.swapPane(source: source, target: target)) != nil
    }

    /// Dock `source` beside/above/below `target` (drag-to-rearrange edge drop).
    @discardableResult
    func joinPane(source: String, target: String, horizontal: Bool, before: Bool) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        return tmux(TmuxCommands.joinPane(
            source: source, target: target, horizontal: horizontal, before: before)) != nil
    }

    // MARK: Move / merge (sidebar reorganisation)

    /// Move a window into an existing session on this host, appended at the
    /// destination's next free index. Same host only — tmux moves windows within
    /// one server and has no cross-server verb, so the sidebar never offers a
    /// destination on another host.
    @discardableResult
    func moveWindow(session: String, window: Int, toSession destination: String) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        let source = TmuxCommands.windowTarget(session: session, window: window)
        return tmux(TmuxCommands.moveWindow(
            source: source,
            target: TmuxCommands.sessionSlotTarget(session: destination))) != nil
    }

    /// Move a window into a brand-new session, where it becomes the only window.
    /// tmux cannot make a session out of an existing window, so one is created
    /// first and the move replaces its placeholder window (`-k`) — otherwise the
    /// user is left with a stray shell beside the window they moved. Returns the
    /// created session's real (sanitized, deduped) name, or nil on failure.
    @discardableResult
    func moveWindowToNewSession(session: String, window: Int, name: String) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        let source = TmuxCommands.windowTarget(session: session, window: window)
        guard let created = newMoveDestination(name: name, cwd: targetCwd(source))
        else { return nil }
        let slot = TmuxCommands.windowTarget(session: created, window: 0)
        guard tmux(TmuxCommands.moveWindow(source: source, target: slot, kill: true)) != nil
        else { return nil }
        return created
    }

    /// Move a pane into another session on this host, where it becomes a window of
    /// its own. tmux ends the pane's old window when it was that window's last
    /// pane — the reorganisation the user asked for, not a loss, so there is no
    /// confirmation.
    @discardableResult
    func movePane(
        session: String, window: Int, pane: String, toSession destination: String
    ) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        let source = TmuxCommands.paneTarget(session: session, window: window, pane: pane)
        return tmux(TmuxCommands.breakPane(
            source: source,
            target: TmuxCommands.sessionSlotTarget(session: destination))) != nil
    }

    /// Move a pane into another window of the same session, stacked under that
    /// window's existing panes. Landing in a window that already exists is a join,
    /// not a break: `break-pane` would give the pane a new window rather than put
    /// it in the one the user picked.
    @discardableResult
    func movePane(
        session: String, window: Int, pane: String, toWindow destination: Int
    ) -> Bool {
        guard transport.command(forTmux: []) != nil else { return false }
        let source = TmuxCommands.paneTarget(session: session, window: window, pane: pane)
        let target = TmuxCommands.windowTarget(session: session, window: destination)
        return tmux(TmuxCommands.joinPane(
            source: source, target: target, horizontal: false, before: false)) != nil
    }

    /// Move a pane into a brand-new session. Unlike the window path this cannot
    /// use `-k` to overwrite the placeholder: `break-pane` refuses a destination
    /// index that is already in use. So the pane is appended and the placeholder
    /// killed afterwards — killing it first would take the empty session with it.
    /// Returns the created session's real name, or nil on failure.
    @discardableResult
    func movePaneToNewSession(
        session: String, window: Int, pane: String, name: String
    ) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        let source = TmuxCommands.paneTarget(session: session, window: window, pane: pane)
        guard let created = newMoveDestination(name: name, cwd: targetCwd(source))
        else { return nil }
        guard tmux(TmuxCommands.breakPane(
            source: source,
            target: TmuxCommands.sessionSlotTarget(session: created))) != nil else { return nil }
        _ = tmux(TmuxCommands.killWindow(
            target: TmuxCommands.windowTarget(session: created, window: 0)))
        return created
    }

    /// Merge `source` into `destination` by moving every one of its windows there.
    /// tmux ends a session once its last window leaves, so `source` disappears —
    /// the one move the caller confirms first. The indices come from the caller
    /// (the sidebar already holds the tree) and stay valid throughout: tmux does
    /// not renumber a session's remaining windows when one leaves. Returns false
    /// if any single window failed to move, having still moved the rest.
    @discardableResult
    func mergeSession(_ source: String, windows: [Int], into destination: String) -> Bool {
        guard transport.command(forTmux: []) != nil, !windows.isEmpty else { return false }
        let slot = TmuxCommands.sessionSlotTarget(session: destination)
        var ok = true
        for index in windows {
            let from = TmuxCommands.windowTarget(session: source, window: index)
            if tmux(TmuxCommands.moveWindow(source: from, target: slot)) == nil { ok = false }
        }
        return ok
    }

    /// Create the detached session a "move to new session" lands in. The name is
    /// sanitized and deduped exactly like `newSession`, so a name that already
    /// exists becomes `name-2` instead of hard-failing the whole move; `cwd` is the
    /// moved window/pane's own directory, so the session (and anything opened in it
    /// later) starts where the work is rather than in tmux's default.
    private func newMoveDestination(name: String, cwd: String?) -> String? {
        guard let clean = TmuxCommands.sanitizedSessionName(name) else { return nil }
        let unique = TmuxCommands.uniqueSessionName(clean, existing: existingSessionNames())
        guard tmux(TmuxCommands.newSession(name: unique, dir: cwd)) != nil else { return nil }
        return unique
    }

    /// The working directory of a session's active pane, used to default the
    /// new-session directory picker. nil if unavailable.
    func sessionCwd(_ name: String) -> String? { targetCwd(name) }

    /// The working directory (`#{pane_current_path}`) of any tmux target's active
    /// pane — a session, `session:window`, or a pane id. Used to open a new window
    /// or split beside the current pane rather than in the session's (often `~`)
    /// start directory. nil if unavailable.
    func targetCwd(_ target: String) -> String? {
        tmux(["display-message", "-p", "-t", target, "#{pane_current_path}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Pane capture + file drop (M11)

    /// Capture a pane's full visible output as plain text. `target` is a tmux
    /// target on this service's host (routed through the transport, so it's the
    /// local `tmux capture-pane` or the ssh-wrapped remote one automatically).
    /// Returns the captured text, or nil if the capture failed.
    func capturePane(target: String) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        return tmux(FileTransfer.capturePaneArgv(target: target))
    }

    // MARK: Phone replies

    /// What the phone server may do to a pane on this host. Each call runs one
    /// argv the server built (`MobileReply`); nothing here goes through a shell
    /// on this Mac.
    func phonePane(
        target: String, status: @escaping (MobileThread) -> AttentionStatus
    ) -> MobilePaneIO {
        MobilePaneIO(
            tmux: { [self] args, stdin in tmux(args, stdin: stdin) },
            screen: { [self] in capturePane(target: target) },
            status: status,
            copy: { [self] localPath, path in
                let (cp, args) = FileTransfer.copyArgv(host: host, localPath: localPath, remotePath: path)
                // An upload to a remote host can take longer than a tmux call.
                return slow.run(cp, args) != nil
            },
            exists: { [self] path in
                guard let alias = host.sshAlias else {
                    return FileManager.default.fileExists(atPath: path)
                }
                // `test` prints nothing: the runner's nil is "no such file".
                return runner.run(
                    Ssh.sshPath, Ssh.opts(host: alias) + ["test -e " + Ssh.shellQuote(path)]) != nil
            })
    }

    /// Drop a local file onto a session on this host: resolve the session's cwd,
    /// copy the file there (cp local / scp remote), then PASTE the resulting path
    /// into the session's active pane (no auto-run — the M11 decision). Returns
    /// the remote/destination path on success, nil on any failure.
    ///
    /// `trailingSpace` appends a space to the pasted text (not the returned path)
    /// so a terminal-pane drop reads like the old type-the-path UX (path ready for
    /// the next argument); the sidebar drop leaves it off.
    @discardableResult
    func dropFileToSession(
        session: String, localFile: String, trailingSpace: Bool = false
    ) -> String? {
        guard transport.command(forTmux: []) != nil else { return nil }
        guard let cwd = sessionCwd(session), !cwd.isEmpty else { return nil }
        let fileName = (localFile as NSString).lastPathComponent
        let dest = FileTransfer.dropDestination(cwd: cwd, fileName: fileName)
        // Copy the file into the session's cwd (local cp or remote scp).
        let (cp, args) = FileTransfer.copyArgv(
            host: host, localPath: localFile, remotePath: dest)
        guard runner.run(cp, args) != nil else { return nil }
        // Paste the destination path into the pane WITHOUT pressing Enter.
        let pasted = trailingSpace ? dest + " " : dest
        let cmds = TmuxCommands.pastePath(session: session)
        guard tmux(cmds.load, stdin: Data(pasted.utf8)) != nil else { return nil }
        guard tmux(cmds.paste) != nil else { return nil }
        return dest
    }


    /// Tear down this host's multiplexed SSH connection (and every `-L` forward
    /// channel over it). No-op for the local host. Called on app terminate so a
    /// backgrounded `ssh -fN -L` forward doesn't outlive the app.
    func closeMaster() {
        guard let alias = host.sshAlias else { return }  // local: nothing to close
        _ = runner.run(Ssh.sshPath, Ssh.sshExitArgv(host: alias))
    }

    // MARK: Diff pane (M14)

    /// Compute the working directory's diff for the Diff pane: all uncommitted
    /// changes vs HEAD (`git diff HEAD` — staged + unstaged tracked changes) plus
    /// untracked files synthesized as additions, combined into one patch.
    ///
    /// Every git command threads through `runHostCommand(local:remote:_:)` — the
    /// same seam `listeningPorts` uses — so a remote host's diff goes over ssh
    /// with the ControlMaster opts for free. Does real work (several serial
    /// shell-outs); call it off the main thread. Returns `isRepo: false` when
    /// `cwd` isn't a git work tree so the pane shows a friendly message.
    func gitDiff(cwd: String) -> GitDiffResult {
        // 1. Is cwd inside a git work tree? (non-repo → friendly empty state). This
        // gates everything, so it runs first/alone.
        let inWorkTree = runHostCommand(local: gitPath, remote: "git", GitDiff.isRepoArgv(cwd: cwd))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard inWorkTree else {
            return GitDiffResult(
                patch: "", branch: "", isRepo: false, isEmptyRepo: false, untrackedDropped: 0)
        }

        // 2. Metadata + untracked list are independent — run them concurrently so
        // the round-trips overlap (over ssh this collapses 3 serial trips into ~1).
        let q = DispatchQueue(label: "is.rebar.muxmaestro.gitdiff", attributes: .concurrent)
        let group = DispatchGroup()
        var hasHEAD = false, branch = "", untrackedOut = ""
        q.async(group: group) {
            hasHEAD = self.runHostCommand(
                local: self.gitPath, remote: "git", GitDiff.hasHEADArgv(cwd: cwd)) != nil
        }
        q.async(group: group) {
            branch = self.runHostCommand(
                local: self.gitPath, remote: "git", GitDiff.branchHeaderArgv(cwd: cwd))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        q.async(group: group) {
            untrackedOut = self.runHostCommand(
                local: self.gitPath, remote: "git", GitDiff.untrackedListArgv(cwd: cwd)) ?? ""
        }
        group.wait()

        let (paths, dropped) = GitDiff.parseUntrackedList(untrackedOut)
        if dropped > 0 {
            NSLog("MuxMaestro: diff capped \(dropped) untracked file(s) past "
                + "\(GitDiff.maxUntrackedFiles) in \(cwd)")
        }

        // 3. Tracked diff (needs hasHEAD) + a cat per untracked file — all
        // independent now, so run them concurrently too. The cat-per-file used to
        // be the dominant serial cost (one subprocess / ssh round-trip each).
        var tracked = ""
        q.async(group: group) {
            tracked = self.runHostCommand(
                local: self.gitPath, remote: "git",
                GitDiff.trackedDiffArgv(cwd: cwd, hasHEAD: hasHEAD)) ?? ""
        }
        let lock = NSLock()
        var untrackedByIndex = [String?](repeating: nil, count: paths.count)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let path = paths[i]
            let full = GitDiff.joinPath(cwd: cwd, relative: path)
            guard let raw = self.runHostCommand(local: self.catPath, remote: "cat", [full])
            else { return }
            let (capped, truncated) = GitDiff.capContents(raw)
            if truncated {
                NSLog("MuxMaestro: diff truncated large untracked file \(path) in \(cwd)")
            }
            let patch = GitDiff.untrackedFilePatch(path: path, contents: capped)
            lock.lock(); untrackedByIndex[i] = patch; lock.unlock()
        }
        group.wait()

        let untracked = untrackedByIndex.compactMap { $0 }
        return GitDiffResult(
            patch: GitDiff.combine(tracked: tracked, untracked: untracked),
            branch: branch, isRepo: true, isEmptyRepo: !hasHEAD, untrackedDropped: dropped)
    }

    // MARK: Search palette (⌘⇧F)

    /// Search the working directory `cwd` for `query` (a literal, smart-case
    /// match) via ripgrep, grouped-ready matches with highlight offsets. Routes
    /// through the same `runHostCommand` seam the Diff pane uses, so a remote
    /// host's search runs over ssh with the ControlMaster opts for free. Does real
    /// work (one rg shell-out, possibly a version probe); call it off the main
    /// thread.
    ///
    /// An empty query never spawns rg. ripgrep exits non-zero on **both** "no
    /// matches" and "rg missing", which the runner can't tell apart, so on a nil
    /// result we run a cheap `rg --version` probe to disambiguate: a successful
    /// probe means simply no matches (`rgAvailable: true`, empty), a failed probe
    /// means ripgrep isn't installed/reachable (`rgAvailable: false`) and the
    /// palette shows a friendly note.
    func search(cwd: String, query: String) -> CodeSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CodeSearchResult(matches: [], truncated: false) }

        if let out = runHostCommand(
            local: rgPath, remote: "rg", CodeSearch.searchArgv(cwd: cwd, query: trimmed)) {
            return CodeSearch.parse(out)
        }
        // nil = rg exited non-zero (no matches) OR rg is missing/unreachable.
        let available = runHostCommand(local: rgPath, remote: "rg", ["--version"]) != nil
        return CodeSearchResult(matches: [], truncated: false, rgAvailable: available)
    }

    /// Search every pane's scrollback on this host for `query` — the "All panes"
    /// scope of ⇧⌘F. Two shell-outs total: `list-panes -a`, then ONE chained
    /// invocation that captures every pane (see `PaneSearch.captureArgv`), so a
    /// remote host costs two ssh round trips however many panes it has. Matching
    /// happens here rather than on the host because tmux has no server-wide grep
    /// and piping the capture through a remote `grep` would lose the pane
    /// boundaries. Blocking; call off the main thread.
    func searchPanes(query: String) -> PaneSearchResult {
        let empty = PaneSearchResult(matches: [], truncated: false)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let snapshot = capturePanes() else { return empty }
        return PaneSearch.match(query: trimmed, captures: snapshot.captures, panes: snapshot.panes)
    }

    /// Every pane on this host with its last `PaneSearch.captureLines` lines of
    /// scrollback, keyed by pane id — the corpus both `searchPanes` and the ⌘K
    /// switcher match against. nil when tmux can't be reached or has no panes.
    /// Blocking; call off the main thread.
    func capturePanes() -> (panes: [PaneSearchTarget], captures: [String: [String]])? {
        guard var listed = tmux(PaneSearch.listPanesArgv()) else { return nil }
        // A pane that dies between the listing and the capture aborts the rest of
        // the tmux command list, losing every pane after it — so on failure,
        // re-list and try once more against panes that still exist.
        for attempt in 0...1 {
            let panes = PaneSearch.parsePanes(listed, host: host)
            guard !panes.isEmpty else { return nil }
            if let captured = tmux(PaneSearch.captureArgv(panes: panes.map(\.paneId))) {
                return (panes, PaneSearch.parseCaptures(captured))
            }
            guard attempt == 0, let relisted = tmux(PaneSearch.listPanesArgv()) else { break }
            listed = relisted
        }
        return nil
    }

    // MARK: File-tree panel

    /// List the working directory's tracked + untracked-non-ignored files as a
    /// nested tree for the Tree side panel. Probes for a git work tree first
    /// (reusing `GitDiff.isRepoArgv`) so a non-repo cwd shows the friendly "not a
    /// git repository" state, exactly like the Diff pane. Routes through
    /// `runHostCommand` so a remote host's tree comes over ssh. Call off the main
    /// thread.
    func fileTree(cwd: String) -> FileTreeResult {
        let inWorkTree = runHostCommand(local: gitPath, remote: "git", GitDiff.isRepoArgv(cwd: cwd))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard inWorkTree else {
            return FileTreeResult(root: [], isRepo: false, truncated: false)
        }
        let out = runHostCommand(local: gitPath, remote: "git", FileTree.listArgv(cwd: cwd)) ?? ""
        let (root, truncated) = FileTree.build(fromNulList: out)
        if truncated {
            NSLog("MuxMaestro: file tree capped at \(FileTree.maxFiles) files in \(cwd)")
        }
        return FileTreeResult(root: root, isRepo: true, truncated: truncated)
    }

    /// The repo's tracked + untracked-non-ignored files as a flat list of
    /// relative paths, for the ⌘P quick-open palette. Same `git ls-files` argv as
    /// the file tree (honoring `.gitignore`); routes over ssh for a remote host.
    /// Empty when `cwd` isn't a repo / git fails. Call off the main thread.
    func repoFiles(cwd: String) -> [String] {
        let out = runHostCommand(local: gitPath, remote: "git", FileTree.listArgv(cwd: cwd)) ?? ""
        return out.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
    }

    /// The open PR(s) for whatever branch the session at `cwd` is on. Resolves the
    /// branch + GitHub repo slug via git, then queries `gh pr list --head <branch>`
    /// (scoped by `-R <slug>` so gh needs no cwd). Routes through the same
    /// `runHostCommand` seam as Diff/Tree, so a remote host runs git + gh over ssh.
    /// Returns [] when `cwd` isn't a GitHub repo, gh is missing/unauthed, the head
    /// is detached, or there's no matching open PR. Call off the main thread.
    func openPullRequests(cwd: String) -> [PullRequest] {
        branchPullRequests(cwd: cwd).prs
    }

    /// Same as `openPullRequests`, but also hands back the repo slug it resolved.
    /// The sidebar needs that slug anyway — to look up the PR numbers declared in
    /// a window's NAME — and this way the `git remote get-url` runs once per cwd
    /// instead of twice. Call off the main thread.
    func branchPullRequests(cwd: String) -> (slug: String?, prs: [PullRequest]) {
        guard let slug = repoSlug(cwd: cwd) else { return (nil, []) }
        guard let branch = runHostCommand(
                local: gitPath, remote: "git", GitHubPR.branchArgv(cwd: cwd))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty, branch != "HEAD"
        else { return (slug, []) }
        guard let out = runHostCommand(
            local: ghPath, remote: "gh", GitHubPR.prListArgv(slug: slug, branch: branch))
        else { return (slug, []) }
        return (slug, GitHubPR.parse(json: out))
    }

    /// One pull request by number, in whatever state it is in — the validation
    /// step for a PR number parsed out of a tmux window's name. nil when the
    /// number doesn't exist in that repo (gh exits non-zero) or gh is missing.
    /// The caller **must cache this** (see `PRIdentityCache`): it is one more
    /// subprocess per window and must never land on the 1.5s poll.
    /// Call off the main thread.
    func pullRequest(slug: String, number: Int) -> PullRequest? {
        guard !slug.isEmpty, number > 0,
              let out = runHostCommand(
                local: ghPath, remote: "gh", GitHubPR.prViewArgv(slug: slug, number: number))
        else { return nil }
        return GitHubPR.parseOne(json: out)
    }

    /// The `owner/repo` slug for the GitHub repo at `cwd`, from
    /// `git remote get-url origin`. nil when `cwd` isn't a git repo or its origin
    /// isn't GitHub. Off the main thread.
    func repoSlug(cwd: String) -> String? {
        guard !cwd.isEmpty,
              let remote = runHostCommand(
                local: gitPath, remote: "git", GitHubPR.remoteArgv(cwd: cwd))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return GitHubPR.slug(fromRemoteURL: remote)
    }

    /// The GitHub web URL for the repo at `cwd` (`https://github.com/owner/repo`),
    /// derived from `git remote get-url origin`; routes over ssh for a remote host.
    /// Returns nil when `cwd` isn't a GitHub repo / git fails. Call off the main thread.
    func githubURL(cwd: String) -> String? {
        guard let slug = repoSlug(cwd: cwd) else { return nil }
        return "https://github.com/\(slug)"
    }

    // MARK: Worktree awareness

    /// Classify `cwd` — main checkout, pool worktree, or unmanaged worktree — plus
    /// the repo's shared git dir, which is the key the worktree sweep schedules by.
    /// nil when `cwd` isn't a git repo.
    ///
    /// Two cheap `rev-parse` calls. The caller **must cache this**: a directory does
    /// not stop being a worktree, and this repo already paid once for a subprocess
    /// storm on the 1.5s poll (PR #67). Off the main thread.
    func worktreeInfo(cwd: String) -> (kind: WorktreeKind, commonDir: String)? {
        guard !cwd.isEmpty else { return nil }
        guard let gitDir = runHostCommand(
                local: gitPath, remote: "git", Worktrees.gitDirArgv(cwd: cwd)),
              let commonDir = runHostCommand(
                local: gitPath, remote: "git", Worktrees.commonDirArgv(cwd: cwd))
        else { return nil }
        guard let kind = Worktrees.classify(
            gitDir: gitDir, commonDir: commonDir, path: cwd,
            home: resolveHome() ?? NSHomeDirectory())
        else { return nil }
        return (kind, Worktrees.normalize(commonDir))
    }

    /// Every worktree of the repo containing `cwd` (`git worktree list --porcelain`),
    /// main checkout first. Empty when git fails / `cwd` isn't a repo. Off the main
    /// thread.
    func worktrees(cwd: String) -> [WorktreeEntry] {
        guard !cwd.isEmpty,
              let out = runHostCommand(local: gitPath, remote: "git", Worktrees.listArgv(cwd: cwd))
        else { return [] }
        return Worktrees.parseList(porcelain: out, home: resolveHome() ?? NSHomeDirectory())
    }

    /// Refresh `origin`'s tracking refs for the repo containing `cwd`. Called once
    /// per repo per sweep, before the per-worktree `worktreeWork` calls — `git
    /// cherry` against stale refs is exactly how 27 already-merged commits looked
    /// unpushed on 2026-08-19. Network I/O; off the main thread.
    @discardableResult
    func fetchOrigin(cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        return runHostCommand(local: gitPath, remote: "git", Worktrees.fetchArgv(cwd: cwd)) != nil
    }

    /// Whether the worktree at `cwd` holds work that exists nowhere else: dirty
    /// beyond `supabase/config.toml`, or holding commits absent from the remote
    /// default branch by patch content.
    ///
    /// Returns `.unknown` — never `.none` — when the base branch can't be resolved,
    /// so a missing signal degrades to "not computed", never to a wrong claim of
    /// "safe to delete". Assumes `fetchOrigin` already ran for this repo.
    func worktreeWork(cwd: String) -> WorktreeWork {
        guard let status = worktreeStatus(cwd: cwd) else { return .unknown }
        return worktreeWork(cwd: cwd, status: status)
    }

    /// `git status --porcelain=v1 -z --untracked-files=all` for the worktree at
    /// `cwd`, or nil when git failed. The sweep reads it once and hands it to both
    /// `worktreeWork(cwd:status:)` and `WorktreeChanges.parse`.
    func worktreeStatus(cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        return runHostCommand(local: gitPath, remote: "git", GitCommit.statusArgv(cwd: cwd))
    }

    /// `worktreeWork(cwd:)` with the status already read.
    func worktreeWork(cwd: String, status: String) -> WorktreeWork {
        if Worktrees.isDirty(porcelain: status) { return .unique }
        return worktreeCommitWork(cwd: cwd)
    }

    /// The commit half of `worktreeWork`: `.unique` when HEAD holds commits the
    /// remote default branch has never seen (merge commits included), `.none` when
    /// it holds none, `.unknown` when that can't be told. Ignores the working tree.
    func worktreeCommitWork(cwd: String) -> WorktreeWork {
        guard !cwd.isEmpty, let base = defaultBranch(cwd: cwd) else { return .unknown }
        guard let cherry = runHostCommand(
            local: gitPath, remote: "git", Worktrees.cherryArgv(cwd: cwd, base: base))
        else { return .unknown }
        if Worktrees.hasUniqueCommits(cherryOutput: cherry) { return .unique }

        // `cherry` says nothing about merge commits — it emits a line per non-merge
        // commit and stays silent on a merge. So its silence alone cannot mean
        // "clean": a branch ahead only by `Merge main into feature` produces empty
        // output, and this project integrates with merge and never rebases, so that
        // is the normal shape of a long-lived branch. Cross-check the raw count and
        // treat anything cherry could not account for as work we cannot clear.
        guard let out = runHostCommand(
                local: gitPath, remote: "git",
                Worktrees.aheadCountArgv(cwd: cwd, base: base)),
              let ahead = Worktrees.parseAheadCount(out)
        else { return .unknown }
        return Worktrees.unaccountedCommits(aheadCount: ahead, cherryOutput: cherry) > 0
            ? .unique : WorktreeWork.none
    }

    /// The remote default branch to compare against: `origin/HEAD` when it's set,
    /// else the first of `origin/main` / `origin/master` that actually resolves.
    /// nil when none does — the caller reports `.unknown` rather than guessing.
    private func defaultBranch(cwd: String) -> String? {
        if let out = runHostCommand(
            local: gitPath, remote: "git", Worktrees.defaultBranchArgv(cwd: cwd)),
           let branch = Worktrees.parseDefaultBranch(out) {
            return branch
        }
        return Worktrees.fallbackDefaultBranches.first { ref in
            runHostCommand(
                local: gitPath, remote: "git",
                Worktrees.verifyRefArgv(cwd: cwd, ref: ref)) != nil
        }
    }

    // MARK: Worktree metrics

    /// Everything Docker is running on this host, or `.unavailable`.
    ///
    /// **Never call this from the poll.** At nine concurrent Supabase stacks on
    /// this Mac a single `docker ps` took over five minutes; the sweep calls it once
    /// per pass, and `slow`'s timeout turns a wedged daemon into `.unavailable`. A
    /// missing binary, a dead daemon and a timeout are the same answer on purpose:
    /// "unknown", never "0 containers".
    ///
    /// Remote hosts are in: `ssh devbox docker ps` answers for 96 containers in
    /// 0.7s, which makes the remote the CHEAP side of this call and the Mac the
    /// hazard. Two callers now want the answer — the worktree sweep and the
    /// Running popover — so it is cached per host for `dockerSnapshotTTL` and the
    /// lock is held across the call: a second caller waits for the first's
    /// answer rather than starting a second five-minute `docker ps`.
    func dockerSnapshot(now: Date = Date()) -> DockerSnapshot {
        dockerLock.lock()
        defer { dockerLock.unlock() }
        if let cached = cachedDocker, now.timeIntervalSince(cached.at) < Self.dockerSnapshotTTL {
            return cached.snapshot
        }
        guard let out = runHostSlow(local: dockerPath, remote: "docker", Docker.psArgv()) else {
            // A dead daemon is cached too — otherwise every caller pays the full
            // timeout again, which is how a wedged Docker Desktop becomes a
            // permanent stall instead of one.
            cachedDocker = (.unavailable, now)
            return .unavailable
        }
        let snapshot = DockerSnapshot.containers(Docker.parsePS(out))
        cachedDocker = (snapshot, now)
        return snapshot
    }

    /// Guards `cachedDocker`, and serializes `docker ps` on this host.
    private let dockerLock = NSLock()
    private var cachedDocker: (snapshot: DockerSnapshot, at: Date)?

    /// How long a `docker ps` answer is reused. Just under the Running popover's
    /// 30s base cadence, so the rail gets a fresh answer each sweep while a
    /// second caller in the same moment shares it.
    static let dockerSnapshotTTL: TimeInterval = 25

    /// Every listening TCP port on this host with the pid holding it, or nil when
    /// the probe failed — "unknown", never "nothing is listening" (lsof also exits
    /// non-zero when nothing matches, and a host with no listener at all does not
    /// really happen).
    ///
    /// ONE subprocess per host regardless of pane count, and never on the 1.5s
    /// poll. A remote lsof run as a normal user sees only that user's own
    /// processes — which is exactly the set that can belong to one of their panes;
    /// root-owned containers on that host come from `dockerSnapshot` instead.
    /// The last `lines` of scrollback for `ids`, in ONE tmux invocation via the
    /// `PaneSearch` marker trick — so a remote host costs one ssh hop no matter
    /// how many panes hold a port. Empty when the capture failed.
    ///
    /// Used by the Running popover to read the URL a dev server printed, which beats
    /// any guess about its scheme.
    func capturePanes(_ ids: [String], lines: Int) -> [String: [String]] {
        guard !ids.isEmpty, let out = tmux(PaneSearch.captureArgv(panes: ids, lines: lines))
        else { return [:] }
        return PaneSearch.parseCaptures(out)
    }

    /// Whether `port` on THIS Mac speaks HTTPS — one HEAD with a 300ms ceiling,
    /// the (b) step of the scheme rule when a pane's scrollback never printed its
    /// URL. Local only: a remote port is reached by host name and is not worth an
    /// ssh round trip to guess a scheme.
    ///
    /// Any failure is a "no": a plain-HTTP server answers an HTTPS handshake with
    /// garbage or a reset, which is exactly the signal wanted. Blocks for up to
    /// the timeout — call off the main thread.
    func probeHTTPS(port: Int) -> Bool {
        guard host.isLocal, let url = URL(string: "https://127.0.0.1:\(port)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: Self.httpsProbeTimeout)
        request.httpMethod = "HEAD"
        let gate = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = response != nil
            gate.signal()
        }
        task.resume()
        if gate.wait(timeout: .now() + Self.httpsProbeTimeout + 0.2) == .timedOut { task.cancel() }
        return ok
    }

    static let httpsProbeTimeout: TimeInterval = 0.3

    /// `docker stop <name>…` on this host. Returns whether Docker reported
    /// success, and its output on failure so the caller can show it.
    ///
    /// `stop`, never `kill`: containers get their SIGTERM and their grace period,
    /// so a database writes its pages out. Nothing here ever force-kills.
    func stopContainers(_ names: [String]) -> (ok: Bool, text: String) {
        guard !names.isEmpty else { return (false, "Nothing to stop.") }
        return runHostWrite(local: dockerPath, remote: "docker", ["stop"] + names)
    }

    /// SIGINT one process on this host — the signal a dev server started in a
    /// terminal already knows how to handle, because it is what ⌃C sends.
    ///
    /// Never SIGKILL: a killed `vite` leaves its child `esbuild` orphaned and
    /// still holding the port, which is the opposite of what the row promised.
    @discardableResult
    func interrupt(pid: Int) -> Bool {
        guard pid > 1 else { return false }
        return runHostWrite(local: killPath, remote: "kill", ["-INT", "\(pid)"]).ok
    }

    private var killPath: String {
        FileManager.default.isExecutableFile(atPath: "/bin/kill") ? "/bin/kill" : "kill"
    }

    /// pid → ppid for every process on this host, so a listening pid can be
    /// walked back to the pane that started it. One subprocess per host, off the
    /// poll; empty when `ps` failed, which simply attributes no ports.
    func processTable() -> [Int: Int] {
        guard let out = runHostCommand(
            local: CodexSessions.psPath, remote: "ps", ["-Ao", "pid=,ppid="]) else { return [:] }
        return CodexSessions.parseProcessTable(out)
    }

    func listeningPorts() -> [ListeningPort]? {
        guard let out = runHostCommand(
            local: CodexSessions.lsofPath, remote: "lsof", Running.lsofArgv())
        else { return nil }
        return Running.parseListeners(out)
    }

    /// The `project_id` from `<root>/supabase/config.toml`, or nil when the tree has
    /// no Supabase config.
    func supabaseProjectID(root: String) -> String? {
        guard let toml = runHostCommand(
            local: catPath, remote: "cat", [Docker.configTomlPath(root: root)]) else { return nil }
        return Docker.supabaseProjectID(configToml: toml)
    }

    /// `treehouse status --json` for the pool behind `repo`, which must be the
    /// repo's **main checkout**. Empty when treehouse isn't installed or the repo
    /// has no pool.
    func treehouseStatus(repo: String) -> [TreehouseWorktree] {
        guard host.isLocal, let treehouse = treehousePath,
              let out = slow.run(envPath, Treehouse.statusArgv(treehouse: treehouse, repo: repo))
        else { return [] }
        return Treehouse.parseStatus(out)
    }

    /// When the worktree at `path` was last touched: the newest of its HEAD commit
    /// date and the mtimes of the worktree root and its gitdir's `index` / `HEAD`.
    ///
    /// The mtimes are read with `FileManager`, not `stat(1)` — this repo has already
    /// paid for one subprocess storm (PR #67). Never a directory walk. A remote
    /// host returns just the commit date.
    func worktreeLastUsed(path: String) -> Date? {
        let commit = runHostCommand(local: gitPath, remote: "git",
                                    WorktreeMetrics.headCommitDateArgv(cwd: path))
            .flatMap(WorktreeMetrics.parseEpoch)
        guard host.isLocal else { return commit }
        var dates: [Date?] = [commit, Self.modifiedAt(path)]
        if let gitDir = runHostCommand(local: gitPath, remote: "git",
                                       Worktrees.gitDirArgv(cwd: path)) {
            let dir = Worktrees.normalize(gitDir)
            dates.append(Self.modifiedAt(dir + "/index"))
            dates.append(Self.modifiedAt(dir + "/HEAD"))
        }
        return WorktreeMetrics.newest(dates)
    }

    private static func modifiedAt(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The file extensions this repo authors, from `git ls-files`. Empty when git
    /// fails, which classifies every untracked file as `unknown` — never scratch.
    func authoredExtensions(repo: String) -> Set<String> {
        guard let out = runHostCommand(
            local: gitPath, remote: "git", UntrackedClassifier.lsFilesArgv(cwd: repo))
        else { return [] }
        return UntrackedClassifier.authoredExtensions(lsFiles: out)
    }

    /// `du -sk <path>` in kilobytes, or nil. **On demand only** — one per expanded
    /// or selected row, never a sweep over every tree. Off the main thread.
    func diskUsageKB(path: String) -> Int? {
        guard let out = slow.run(duPath, WorktreeMetrics.duArgv(path: path)) else { return nil }
        return WorktreeMetrics.parseDuKB(out)
    }

    /// Best-effort local paths for the metric tools. An absent tool degrades the
    /// metric to "unknown" instead of a wrong claim.
    private var dockerPath: String {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "docker"
    }
    private var treehousePath: String? {
        [NSHomeDirectory() + "/go/bin/treehouse", "/opt/homebrew/bin/treehouse",
         "/usr/local/bin/treehouse"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
    private var duPath: String {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/du") ? "/usr/bin/du" : "du"
    }
    /// `env -C <dir> <cmd>` gives a command with no `-C` of its own (treehouse) a
    /// working directory without a shell.
    private var envPath: String { "/usr/bin/env" }

    /// Read a file's contents on this host (local `cat` or remote `cat` over ssh)
    /// for the Tree panel's preview, capped to a sane size (reusing
    /// `GitDiff.capContents`) so a huge file can't wedge the web view. Returns nil
    /// if the read failed. Call off the main thread.
    func readFile(path: String) -> String? {
        guard let raw = runHostCommand(local: catPath, remote: "cat", [path]) else { return nil }
        return GitDiff.capContents(raw).contents
    }

    // MARK: Commit panel (stage → commit → push → PR)

    /// The session's uncommitted changed files (`git status --porcelain`), for the
    /// commit panel. Empty when `cwd` isn't a repo / git fails. Off the main thread.
    func changedFiles(cwd: String) -> [ChangedFile] {
        guard !cwd.isEmpty,
              let out = runHostCommand(local: gitPath, remote: "git", GitCommit.statusArgv(cwd: cwd))
        else { return [] }
        return GitCommit.parseStatus(out)
    }

    /// The current branch name at `cwd`, or nil (detached / not a repo).
    func currentBranch(cwd: String) -> String? {
        guard let b = runHostCommand(local: gitPath, remote: "git", GitHubPR.branchArgv(cwd: cwd))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty, b != "HEAD" else { return nil }
        return b
    }

    @discardableResult
    func stage(cwd: String, path: String) -> Bool {
        runHostWrite(local: gitPath, remote: "git", GitCommit.addArgv(cwd: cwd, path: path)).ok
    }
    @discardableResult
    func unstage(cwd: String, path: String) -> Bool {
        runHostWrite(local: gitPath, remote: "git", GitCommit.unstageArgv(cwd: cwd, path: path)).ok
    }

    /// Commit the staged index with `subject` (+ optional `body`). Returns success
    /// and the git output (the error text on failure). Off the main thread.
    func commit(cwd: String, subject: String, body: String) -> (ok: Bool, text: String) {
        runHostWrite(local: gitPath, remote: "git",
                     GitCommit.commitArgv(cwd: cwd, subject: subject, body: body))
    }

    /// Push the current branch, setting the upstream (`-u origin <branch>`) when it
    /// has none yet. Returns success + git output (rejection text on failure).
    func push(cwd: String) -> (ok: Bool, text: String) {
        guard let branch = currentBranch(cwd: cwd) else {
            return (false, "Couldn’t resolve the current branch.")
        }
        let hasUpstream = runHostCommand(local: gitPath, remote: "git",
                                         GitCommit.upstreamArgv(cwd: cwd)) != nil
        return runHostWrite(local: gitPath, remote: "git",
                            GitCommit.pushArgv(cwd: cwd, branch: branch, setUpstream: !hasUpstream))
    }

    /// Open a GitHub PR for the branch at `cwd` (the branch must be pushed first).
    /// On success gh prints the new PR's URL, which is returned as `text`.
    func createPullRequest(cwd: String, title: String, body: String) -> (ok: Bool, text: String) {
        guard let branch = currentBranch(cwd: cwd),
              let remote = runHostCommand(local: gitPath, remote: "git", GitHubPR.remoteArgv(cwd: cwd))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let slug = GitHubPR.slug(fromRemoteURL: remote)
        else { return (false, "Couldn’t resolve the GitHub repo for this session.") }
        return runHostWrite(local: ghPath, remote: "gh",
                            GitHubPR.prCreateArgv(slug: slug, branch: branch, title: title, body: body))
    }

    /// Write-op sibling of `runHostCommand`: same local/ssh routing but captures
    /// stdout+stderr + success (via `runCapturing`) so callers can show errors.
    private func runHostWrite(local: String, remote: String, _ args: [String]) -> (ok: Bool, text: String) {
        if let alias = host.sshAlias {
            let remoteCmd = ([remote] + args).map(Ssh.shellQuote)
            return runner.runCapturing(Ssh.sshPath, Ssh.opts(host: alias) + remoteCmd)
        }
        return runner.runCapturing(local, args)
    }

    /// Run a non-tmux command (`ps`, `lsof`) on this service's host: directly with
    /// the resolved `local` absolute path, or `ssh <opts> <host> <remote> <args…>`
    /// using the bare `remote` name (resolved on the remote PATH — the remote may
    /// install it anywhere). The remote tokens are single-quoted (like the tmux
    /// transport) so the remote login shell receives them verbatim. Returns
    /// stdout or nil.
    private func runHostCommand(local: String, remote: String, _ args: [String]) -> String? {
        if let alias = host.sshAlias {
            let remoteCmd = ([remote] + args).map(Ssh.shellQuote)
            return runner.run(Ssh.sshPath, Ssh.opts(host: alias) + remoteCmd)
        }
        return runner.run(local, args)
    }

    /// `runHostCommand`'s slow sibling — same local/ssh routing, run under
    /// `slow`'s 30s ceiling instead of the 4s/8s interactive one. For `docker ps`,
    /// which legitimately outlives that ceiling on this Mac.
    private func runHostSlow(local: String, remote: String, _ args: [String]) -> String? {
        if let alias = host.sshAlias {
            let remoteCmd = ([remote] + args).map(Ssh.shellQuote)
            return slow.run(Ssh.sshPath, Ssh.opts(host: alias) + remoteCmd)
        }
        return slow.run(local, args)
    }

    /// This host's `$HOME`: `NSHomeDirectory()` locally, or the remote login dir
    /// for a remote — a bare `ssh <host> pwd` lands in `$HOME` and prints it, so no
    /// shell-variable expansion is needed (which the single-quoted transport
    /// wouldn't do anyway). Cached after the first success; nil if the remote probe
    /// fails. Blocks on ssh for a remote — call off the main thread. Used by the
    /// "Beam here / to another server" flows to map a remote project path to its
    /// same-relative path on this Mac.
    private let homeLock = NSLock()
    private var cachedHome: String?
    func resolveHome() -> String? {
        if host.isLocal { return NSHomeDirectory() }
        homeLock.lock()
        if let cachedHome { homeLock.unlock(); return cachedHome }
        homeLock.unlock()
        guard let out = runHostCommand(local: "/bin/pwd", remote: "pwd", []) else { return nil }
        let home = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return nil }
        homeLock.lock(); cachedHome = home; homeLock.unlock()
        return home
    }

    /// Best-effort local git path — `/usr/bin/git` (the macOS developer-tools
    /// shim) first, then Homebrew. Remote uses the bare `git` on the remote PATH.
    private var gitPath: String {
        ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "git"
    }
    /// Best-effort local `cat` path (used to read untracked-file contents for the
    /// synthesized diff). Remote uses the bare `cat` on the remote PATH.
    private var catPath: String {
        FileManager.default.isExecutableFile(atPath: "/bin/cat") ? "/bin/cat" : "cat"
    }
    /// Best-effort local `gh` (GitHub CLI) path — Homebrew first, then other
    /// prefixes. Remote uses the bare `gh` on the remote PATH.
    private var ghPath: String {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "gh"
    }
    /// Best-effort local ripgrep path — Homebrew first (where it lives on this
    /// Mac), then other common prefixes. Remote uses the bare `rg` on the remote
    /// PATH (resolved on the remote, which may install it anywhere).
    private var rgPath: String {
        ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "rg"
    }

    /// Best-effort reachability probe for a remote host: connect over ssh and
    /// run a trivial `true`. Tests connectivity (not whether tmux is installed),
    /// so a reachable host without tmux still shows as reachable (its tree just
    /// comes up empty). Returns reachable for the local host without a probe.
    /// Runs off the main thread (bounded by the transport timeout + ssh
    /// ConnectTimeout).
    /// Whether tmux is available on this host, by running `tmux -V`. Local uses
    /// the discovered binary; remote shells `tmux -V` over the shared ssh
    /// connection. Call off the main thread.
    ///
    /// Cached, because the answer is near-static but the question was being asked
    /// once per host per poll — a whole ssh round-trip every 1.5s to re-learn that
    /// tmux is still installed. A "yes" holds for 5 minutes; a "no" is re-checked
    /// after 15s so installing tmux is picked up promptly rather than after five
    /// minutes of a misleading "tmux missing" row.
    func hasTmux() -> Bool {
        let now = Date()
        probeLock.lock()
        if let cached = tmuxAvailable,
           now.timeIntervalSince(cached.at) < (cached.value ? 300 : 15) {
            probeLock.unlock()
            return cached.value
        }
        probeLock.unlock()

        let available = tmux(["-V"]) != nil
        probeLock.lock()
        tmuxAvailable = (available, now)
        probeLock.unlock()
        return available
    }

    func probeReachability() -> HostReachability {
        guard let alias = host.sshAlias else { return .reachable }
        // `echo ok` (not `true`) so the probe succeeds on a Windows remote too —
        // cmd.exe / PowerShell have no `true`, which made a perfectly reachable
        // Windows host (e.g. one running a tmux-alike) read as "unreachable".
        // `echo` is a builtin on sh, cmd.exe, and PowerShell alike. No tmux
        // involved, so it shares the ControlMaster connection with the tree loads.
        let args = Ssh.opts(host: alias) + ["echo", "ok"]
        return runner.run(Ssh.sshPath, args) != nil ? .reachable : .unreachable
    }

    /// This host's CPU use, memory, disk and uptime for its stat card, or nil when
    /// the host did not answer. One `sh -c` of `HostStats.script` — locally, or
    /// over the same ControlMaster connection as the probe above, so a poll opens
    /// no new ssh connection. The script samples CPU for about a second, so it runs
    /// under the slow ceiling. Off the main thread.
    func hostStats() -> HostStats? {
        runHostSlow(local: "/bin/sh", remote: "sh", ["-c", HostStats.script])
            .flatMap(HostStats.parse)
    }
}
