import XCTest

// TmuxService.swift + TmuxCommands.swift (Foundation-only, no AppKit) are
// compiled directly into this test target, so the shell-driving layer can be
// asserted against a fake CommandRunner without spawning real processes.

/// Records every command it's asked to run and replies from a scripted table so
/// tests can assert the exact argv sequence the service emits.
private final class FakeRunner: CommandRunner {
    /// Each recorded invocation: (path, args, whether stdin was provided).
    private(set) var calls: [(path: String, args: [String], hadStdin: Bool)] = []
    /// The stdin bytes of each call, in order (nil when none was piped).
    private(set) var stdins: [Data?] = []
    /// Canned stdout keyed by the args' joined string; nil entries simulate a
    /// failed command (non-zero exit / launch failure / timeout).
    var responses: [String: String?] = [:]
    /// Default reply for any args not in `responses`.
    var defaultResponse: String? = ""

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        calls.append((path, args, stdin != nil))
        stdins.append(stdin)
        let key = args.joined(separator: " ")
        if let scripted = responses[key] { return scripted }
        return defaultResponse
    }

    /// The args of each call, in order, for sequence assertions.
    var argSequences: [[String]] { calls.map(\.args) }
}

final class TmuxServiceTests: XCTestCase {
    private let tmux = "/usr/bin/tmux"

    private func makeService(_ runner: FakeRunner) -> TmuxService {
        // Inject a fixed tmux path so the service doesn't depend on the host.
        TmuxService(runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: tmux)
    }

    // MARK: selectWindow — must unzoom first, then select-window

    func testSelectWindowUnzoomsThenSelects() {
        let runner = FakeRunner()
        // Window is currently zoomed → unzoom must fire before select-window.
        runner.responses["display-message -p -t web:1 #{window_zoomed_flag}"] = "1"
        let service = makeService(runner)

        XCTAssertTrue(service.selectWindow(session: "web", window: 1))

        XCTAssertEqual(runner.argSequences, [
            ["display-message", "-p", "-t", "web:1", "#{window_zoomed_flag}"],
            ["resize-pane", "-Z", "-t", "web:1"],
            ["select-window", "-t", "web:1"],
        ])
    }

    func testSelectWindowDoesNotUnzoomWhenNotZoomed() {
        let runner = FakeRunner()
        runner.responses["display-message -p -t web:2 #{window_zoomed_flag}"] = "0"
        let service = makeService(runner)

        XCTAssertTrue(service.selectWindow(session: "web", window: 2))

        // No resize-pane (unzoom) call when the window isn't zoomed.
        XCTAssertFalse(runner.argSequences.contains(["resize-pane", "-Z", "-t", "web:2"]))
        XCTAssertEqual(runner.argSequences.last, ["select-window", "-t", "web:2"])
    }

    // MARK: selectPane — select window, select pane, then zoom if not zoomed

    func testSelectPaneSelectsThenZoomsWhenRequested() {
        let runner = FakeRunner()
        // Pane is not currently zoomed → a zoom toggle should follow.
        runner.responses["display-message -p -t %12 #{window_zoomed_flag}"] = "0"
        let service = makeService(runner)

        XCTAssertTrue(service.selectPane(session: "web", window: 1, pane: "%12", zoom: true))

        XCTAssertEqual(runner.argSequences, [
            ["select-window", "-t", "web:1"],
            ["select-pane", "-t", "%12"],
            ["display-message", "-p", "-t", "%12", "#{window_zoomed_flag}"],
            ["resize-pane", "-Z", "-t", "%12"],
        ])
    }

    func testSelectPaneDoesNotDoubleZoomWhenAlreadyZoomed() {
        let runner = FakeRunner()
        runner.responses["display-message -p -t %9 #{window_zoomed_flag}"] = "1"
        let service = makeService(runner)

        XCTAssertTrue(service.selectPane(session: "web", window: 0, pane: "%9", zoom: true))

        // Already zoomed → no extra resize-pane toggle.
        XCTAssertFalse(runner.argSequences.contains(["resize-pane", "-Z", "-t", "%9"]))
    }

    func testSelectPaneSkipsZoomWhenZoomFalse() {
        let runner = FakeRunner()
        let service = makeService(runner)

        XCTAssertTrue(service.selectPane(session: "web", window: 1, pane: "%5", zoom: false))

        XCTAssertEqual(runner.argSequences, [
            ["select-window", "-t", "web:1"],
            ["select-pane", "-t", "%5"],
        ])
    }

    // MARK: Find in Session (⌘F — copy-mode search)

    func testSearchInPaneRestartsCopyModeThenSearchesAndCounts() {
        let runner = FakeRunner()
        runner.responses["display-message -p -t web #{search_count}\t#{search_count_partial}"]
            = "14\t0\n"
        let service = makeService(runner)

        XCTAssertEqual(service.searchInPane(session: "web", needle: "error"), "14 matches")

        // Cancel first (restart from the bottom), then copy-mode, then the
        // literal-text search, then the count read.
        XCTAssertEqual(runner.argSequences, [
            ["send-keys", "-t", "web", "-X", "cancel"],
            ["copy-mode", "-t", "web"],
            ["send-keys", "-t", "web", "-X", "search-backward-text", "error"],
            ["display-message", "-p", "-t", "web", "#{search_count}\t#{search_count_partial}"],
        ])
    }

    func testSearchInPaneEmptyNeedleJustEndsTheSearch() {
        let runner = FakeRunner()
        let service = makeService(runner)

        XCTAssertNil(service.searchInPane(session: "web", needle: ""))

        XCTAssertEqual(runner.argSequences, [
            ["send-keys", "-t", "web", "-X", "cancel"],
        ])
    }

    func testSearchStepEmitsAgainOrReverseByDirection() {
        let runner = FakeRunner()
        let service = makeService(runner)

        _ = service.searchStep(session: "web", up: true)
        _ = service.searchStep(session: "web", up: false)

        XCTAssertEqual(runner.argSequences[0],
                       ["send-keys", "-t", "web", "-X", "search-again"])
        XCTAssertEqual(runner.argSequences[2],
                       ["send-keys", "-t", "web", "-X", "search-reverse"])
    }

    func testEndSearchCancelsCopyMode() {
        let runner = FakeRunner()
        let service = makeService(runner)

        service.endSearch(session: "web")

        XCTAssertEqual(runner.argSequences, [["send-keys", "-t", "web", "-X", "cancel"]])
    }

    // MARK: unzoomIfNeeded

    func testUnzoomIfNeededTogglesOnlyWhenZoomed() {
        let zoomed = FakeRunner()
        zoomed.responses["display-message -p -t web:1 #{window_zoomed_flag}"] = "1"
        makeService(zoomed).unzoomIfNeeded(session: "web", window: 1)
        XCTAssertTrue(zoomed.argSequences.contains(["resize-pane", "-Z", "-t", "web:1"]))

        let notZoomed = FakeRunner()
        notZoomed.responses["display-message -p -t web:1 #{window_zoomed_flag}"] = "0"
        makeService(notZoomed).unzoomIfNeeded(session: "web", window: 1)
        XCTAssertFalse(notZoomed.argSequences.contains(["resize-pane", "-Z", "-t", "web:1"]))
    }

    // MARK: toggleZoom returns the read-back state

    func testToggleZoomReturnsNewState() {
        let runner = FakeRunner()
        // After toggling, the flag reads back as zoomed.
        runner.responses["display-message -p -t web #{window_zoomed_flag}"] = "1"
        XCTAssertTrue(makeService(runner).toggleZoom(target: "web"))
        XCTAssertEqual(runner.argSequences.first, ["resize-pane", "-Z", "-t", "web"])
    }

    // MARK: zoom toggle targets the selected pane, not the session (M6 fix a)

    func testToggleZoomTargetsSelectedPaneId() {
        // selectPane(zoom:) zoomed pane %12; the toolbar toggle must resolve the
        // SAME target (via TmuxCommands.zoomTarget) so resize-pane -Z hits %12,
        // not the session's active window — otherwise the button desyncs from
        // the visible surface.
        let runner = FakeRunner()
        runner.responses["display-message -p -t %12 #{window_zoomed_flag}"] = "0"
        let service = makeService(runner)
        let target = TmuxCommands.zoomTarget(for: .pane(id: "%12"))
        _ = service.toggleZoom(target: target)
        XCTAssertEqual(runner.argSequences.first, ["resize-pane", "-Z", "-t", "%12"])
    }

    // MARK: name sanitation flows through new/rename

    func testNewSessionSanitizesName() {
        let runner = FakeRunner()
        let name = makeService(runner).newSession(name: "a.b:c", dir: "/tmp", launchClaude: false)
        XCTAssertEqual(name, "a_b_c")
        // newSession first lists existing names (to dedupe), then creates.
        XCTAssertTrue(
            runner.argSequences.contains(["new-session", "-d", "-s", "a_b_c", "-c", "/tmp"]))
    }

    func testNewSessionDedupesAgainstExistingNames() {
        let runner = FakeRunner()
        // The live server already has a session named "api" (and "api-2").
        runner.responses["list-sessions -F #{session_name}"] = "api\napi-2\nweb"
        let name = makeService(runner).newSession(name: "api", dir: "/tmp", launchClaude: false)
        XCTAssertEqual(name, "api-3")
        XCTAssertTrue(
            runner.argSequences.contains(["new-session", "-d", "-s", "api-3", "-c", "/tmp"]))
    }

    func testNewSessionLaunchesClaudeWhenRequested() {
        let runner = FakeRunner()
        _ = makeService(runner).newSession(name: "api", dir: "/tmp", launchClaude: true)
        XCTAssertEqual(runner.argSequences.last, ["send-keys", "-t", "api", "claude", "Enter"])
    }

    func testRenameSessionSanitizes() {
        let runner = FakeRunner()
        XCTAssertEqual(makeService(runner).renameSession(from: "old", to: "new:name"), "new_name")
    }

    // MARK: no tmux → every driver degrades to false/nil, no calls made

    func testNoTmuxPathDegradesGracefully() {
        let runner = FakeRunner()
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: nil)
        XCTAssertFalse(service.selectWindow(session: "web", window: 1))
        XCTAssertFalse(service.selectPane(session: "web", window: 1, pane: "%1", zoom: true))
        XCTAssertNil(service.newSession(name: "x", dir: "/tmp", launchClaude: false))
        XCTAssertFalse(service.killSession(name: "x"))
        XCTAssertNil(service.loadTree())
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: loadTree builds the joined, sorted tree from canned tmux output

    func testLoadTreeBuildsSortedTree() {
        let runner = FakeRunner()
        let US = TmuxModel.fieldSep
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] =
            "idle-one\(US)0\nneeds-one\(US)1\n"
        // Server-wide: one list-windows and one list-panes for every session.
        runner.responses["list-windows -a -F \(TmuxModel.allWindowsFormat)"] =
            "idle-one\(US)0\(US)main\(US)1\nneeds-one\(US)0\(US)main\(US)1\n"
        runner.responses["list-panes -a -F \(TmuxModel.allPanesFormat)"] =
            "idle-one\(US)0\(US)%1\(US)0\(US)zsh\(US)t\(US)1\n"
            + "needs-one\(US)0\(US)%2\(US)0\(US)zsh\(US)t\(US)1\n"

        let statuses = StaticStatusProvider(["needs-one": .waiting, "idle-one": .idle])
        let service = TmuxService(runner: runner, statusProvider: statuses, tmuxPath: tmux)

        guard let tree = service.loadTree() else { return XCTFail("expected a tree") }
        XCTAssertEqual(tree.map(\.name), ["idle-one", "needs-one"])  // stable alphabetical
        XCTAssertEqual(tree.first { $0.name == "needs-one" }?.attention, .waiting)
        XCTAssertEqual(
            tree.first { $0.name == "needs-one" }?.windows.first?.panes.first?.id, "%2")
    }

    // MARK: loadTree distinguishes a transient failure from a genuine empty
    //
    // Regression: the sidebar blanked while sessions were live because a failed
    // `list-sessions` (e.g. timed out under load) was collapsed to [] — same as
    // "no sessions" — and the poll overwrote the cached tree. loadTree must return
    // nil on failure so the caller keeps its last good tree.

    func testLoadTreeReturnsNilWhenListSessionsFails() {
        let runner = FakeRunner()
        // nil == command failure (non-zero exit / launch failure / timeout).
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = .some(nil)
        let service = makeService(runner)
        XCTAssertNil(service.loadTree(),
            "a failed list-sessions must return nil so the caller keeps the last good tree")
    }

    func testLoadTreeReturnsEmptyWhenServerHasNoSessions() {
        let runner = FakeRunner()
        // Empty stdout on a clean run == server up, genuinely zero sessions.
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = ""
        let service = makeService(runner)
        XCTAssertEqual(service.loadTree(), [],
            "a clean run with no sessions must return [] (not nil) so the tree clears")
    }

    // MARK: SessionsPyStatusProvider graceful degrade (item c/d)

    func testStatusProviderReturnsNilWhenToolMissing() {
        // Point at a path that cannot exist so the degrade is deterministic and
        // independent of the host's ~/tools-proto checkout.
        let provider = SessionsPyStatusProvider(
            runner: FakeRunner(),
            scriptPath: "/nonexistent/sidekick/sessions.py",
            codexScan: nil)  // no ps/lsof shell-out from a unit test
        // statuses() must still be safe (empty) so the tree renders as unknown.
        XCTAssertTrue(provider.statuses().isEmpty)
        // And the nil-returning variant distinguishes unavailable from empty.
        XCTAssertNil(provider.statusesOrNil())
    }

    // MARK: RemoteSessionsPyStatusProvider — pushes the bundled sessions.py

    private let remoteScript = "~/.muxmaestro/tools/sessions.py"

    func testRemotePushCommandWritesThroughATempFile() {
        XCTAssertEqual(
            RemoteSessionsPyStatusProvider.pushCommand(scriptPath: remoteScript),
            "mkdir -p ~/.muxmaestro/tools && cat > ~/.muxmaestro/tools/sessions.py.tmp "
                + "&& mv -f ~/.muxmaestro/tools/sessions.py.tmp ~/.muxmaestro/tools/sessions.py")
    }

    func testRemoteStatusPushesTheBundledScriptThenOnlyRunsIt() {
        let runner = FakeRunner()
        runner.defaultResponse = "[]"
        let script = Data("print('[]')".utf8)
        let provider = RemoteSessionsPyStatusProvider(
            host: "box", runner: runner, scriptPath: remoteScript, script: script)

        XCTAssertNotNil(provider.statusesOrNil())
        XCTAssertNotNil(provider.statusesOrNil())

        XCTAssertEqual(runner.calls.map(\.path), [Ssh.sshPath, Ssh.sshPath])
        let pushThenList = RemoteSessionsPyStatusProvider.pushCommand(scriptPath: remoteScript)
            + " && python3 \(remoteScript) list"
        XCTAssertEqual(runner.calls[0].args.suffix(3), ["sh", "-c", Ssh.shellQuote(pushThenList)])
        XCTAssertEqual(runner.stdins[0], script)
        XCTAssertEqual(
            runner.calls[1].args.last,
            Ssh.shellQuote("test -f \(remoteScript) && python3 \(remoteScript) list"))
        XCTAssertNil(runner.stdins[1])
    }

    func testRemoteStatusPushesAgainAfterAFailedRead() {
        let runner = FakeRunner()
        runner.defaultResponse = nil  // host offline
        let provider = RemoteSessionsPyStatusProvider(
            host: "box", runner: runner, scriptPath: remoteScript, script: Data("x".utf8))

        XCTAssertNil(provider.statusesOrNil())
        runner.defaultResponse = "[]"
        XCTAssertNotNil(provider.statusesOrNil())
        XCTAssertNotNil(provider.statusesOrNil())

        XCTAssertEqual(runner.stdins.map { $0 != nil }, [true, true, false])
    }

    func testRemoteStatusWithoutABundledScriptOnlyRunsWhatIsThere() {
        let runner = FakeRunner()
        runner.defaultResponse = "[]"
        let provider = RemoteSessionsPyStatusProvider(
            host: "box", runner: runner, scriptPath: remoteScript, script: nil)

        XCTAssertNotNil(provider.statusesOrNil())

        XCTAssertEqual(runner.stdins.map { $0 != nil }, [false])
        XCTAssertEqual(
            runner.calls[0].args.last,
            Ssh.shellQuote("test -f \(remoteScript) && python3 \(remoteScript) list"))
    }

    // MARK: ProcessCommandRunner timeout — hung child is bounded + reaped

    func testProcessCommandRunnerTimesOutAndReapsChild() {
        // Run a child that sleeps far longer than the timeout. run() must return
        // nil within a bounded wall-time (timeout + the SIGTERM/SIGKILL grace,
        // not the full sleep), and the child must be gone afterwards.
        //
        // Collision-proof: a bare `sleep 10` collides with any other `sleep 10`
        // on a busy box (e.g. a poll loop), so `pgrep -f "sleep 10"` can match an
        // unrelated process and fail the test spuriously. We give the child a
        // UNIQUE sentinel duration nothing else would run, and assert on THAT
        // exact command line — so the reap check is about the child we spawned,
        // not "any sleep on the host". The duration is huge (so it really would
        // outlive the timeout) plus a random fractional tag for uniqueness.
        let sentinel = "987654.\(Int.random(in: 100000...999999))"  // e.g. 987654.314159
        let runner = ProcessCommandRunner(timeout: 1.0)
        let start = Date()
        let result = runner.run("/bin/sleep", [sentinel])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "a timed-out command must return nil")
        // 1s timeout + up to ~1s of SIGTERM/SIGKILL grace + reader join; well
        // under the sentinel sleep. Generous ceiling to stay non-flaky on CI.
        XCTAssertLessThan(elapsed, 5.0, "must not block for the child's full runtime")

        // The child must be reaped — no `sleep <sentinel>` left running. Match the
        // UNIQUE sentinel so only THIS test's child can match (never an unrelated
        // `sleep 10`). Give the escalation a beat to land first.
        Thread.sleep(forTimeInterval: 0.3)
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "sleep \(sentinel)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        // pgrep exits 1 (no match) when our specific child was reaped. The
        // sentinel guarantees no false match from any other process on the host.
        XCTAssertNotEqual(pgrep.terminationStatus, 0,
            "the hung child should have been killed and reaped: \(String(data: out, encoding: .utf8) ?? "")")
    }

    // MARK: drainToEnd — bounded, leak-proof, crash-proof pipe reader
    //
    // Regression for the SIGABRT crash: `readDataToEndOfFile()` blocks until every
    // write end of a pipe is closed and throws an uncatchable
    // NSFileHandleOperationException on an OS-level read failure. A spawned
    // node/`gh`/`claude` forks a grandchild that inherits stdout, so the pipe
    // stayed open after we killed the child; reader threads (and their fds) piled
    // up until the process blew past the GCD 64-thread limit and a FileHandle read
    // finally threw → abort(). `drainToEnd` reads at the POSIX level, bounded by a
    // deadline, and never throws.

    func testDrainToEndStopsAtDeadlineWhenPipeHeldOpen() throws {
        // The crash mechanism: the write end is never closed (as when a grandchild
        // keeps it open). readDataToEndOfFile() would block here forever; drainToEnd
        // must return the buffered bytes at its deadline instead of wedging.
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("partial".utf8))

        let start = Date()
        let (data, complete) = drainToEnd(pipe.fileHandleForReading, deadline: .now() + 0.6)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(complete, "a deadline-cut read is not a complete read")
        XCTAssertEqual(String(data: data, encoding: .utf8), "partial",
            "must return whatever was buffered before the deadline")
        XCTAssertGreaterThan(elapsed, 0.4, "should have waited roughly to its deadline")
        XCTAssertLessThan(elapsed, 3.0, "must NOT block on the still-open write end")
        try? pipe.fileHandleForWriting.close()
    }

    func testDrainToEndReturnsAllDataThenEOF() throws {
        // Normal path: once the write end closes, drainToEnd sees EOF and returns
        // the full payload well before its (generous) deadline.
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello world".utf8))
        try pipe.fileHandleForWriting.close()

        let start = Date()
        let (data, complete) = drainToEnd(pipe.fileHandleForReading, deadline: .now() + 5.0)
        XCTAssertTrue(complete, "EOF means the whole payload was read")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
            "EOF should end the read promptly, not wait out the deadline")
    }

    func testDrainToEndReturnsEmptyOnBadFdWithoutCrashing() {
        // A read on a dead fd (EBADF) is exactly what fd exhaustion produced. It
        // must return empty, never throw the uncatchable NSFileHandleOperation
        // Exception that aborted the app. A handle wrapping fd -1 stands in for a
        // bad descriptor without pre-closing (reading .fileDescriptor on an
        // already-closed handle itself throws).
        let handle = FileHandle(fileDescriptor: -1, closeOnDealloc: false)
        let (data, complete) = drainToEnd(handle, deadline: .now() + 0.4)
        XCTAssertTrue(data.isEmpty, "a bad fd yields no data and no crash")
        XCTAssertFalse(complete, "a bad fd never reaches EOF, so the read is incomplete")
    }

    // MARK: run() must not leak fds when a grandchild keeps stdout open

    func testRunDoesNotLeakFdsWhenGrandchildHoldsStdout() {
        // Root-cause reproduction. The child (`sh`) exits immediately after
        // printing, but backgrounds a `sleep` that INHERITS the stdout pipe and
        // outlives it — so the pipe's write end stays open. Under the old
        // readDataToEndOfFile() reader, each call leaked a blocked reader thread
        // holding the read fd; N calls leaked ~N fds → eventual exhaustion + abort.
        // With drainToEnd the reader self-bounds at the deadline and the fd is
        // released, so the open-fd count stays flat across many calls.
        let sentinel = "987654.\(Int.random(in: 100000...999999))"
        let runner = ProcessCommandRunner(timeout: 1.0)
        let script = "/bin/sleep \(sentinel) & printf hi"

        func openFdCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
        }

        // Warm up (first spawn opens some long-lived fds) then baseline.
        _ = runner.run("/bin/sh", ["-c", script])
        Thread.sleep(forTimeInterval: 1.5)
        let before = openFdCount()

        for _ in 0..<20 { _ = runner.run("/bin/sh", ["-c", script]) }
        // Let every reader pass its 1s deadline and release its fd.
        Thread.sleep(forTimeInterval: 2.0)
        let after = openFdCount()

        // Reap the backgrounded grandchildren so the test leaves nothing behind.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "sleep \(sentinel)"]
        try? pkill.run(); pkill.waitUntilExit()

        // Old code leaked ~20 read fds here; the fix keeps growth near zero.
        XCTAssertLessThan(after - before, 12,
            "run() must not leak an fd per call when a grandchild holds stdout open "
            + "(before=\(before) after=\(after))")
    }

    // MARK: loadTree's cost must not scale with the number of sessions
    //
    // It used to issue one `list-windows` per session and one `list-panes` per
    // window: ~19 subprocesses per 1.5s poll locally, ~19 SSH round-trips remotely.
    // Both are now server-wide single queries. Pinned here because the regression is
    // invisible — a correct tree, quietly costing O(sessions) processes.

    func testLoadTreeIssuesAFixedNumberOfTmuxCallsRegardlessOfSessionCount() {
        func tmuxCallCount(sessions: Int) -> Int {
            let runner = FakeRunner()
            let US = TmuxModel.fieldSep
            let names = (0..<sessions).map { "s\($0)" }
            runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] =
                names.map { "\($0)\(US)0\n" }.joined()
            runner.responses["list-windows -a -F \(TmuxModel.allWindowsFormat)"] =
                names.flatMap { n in (0..<3).map { "\(n)\(US)\($0)\(US)w\(US)1\n" } }.joined()
            runner.responses["list-panes -a -F \(TmuxModel.allPanesFormat)"] =
                names.flatMap { n in
                    (0..<3).map { "\(n)\(US)\($0)\(US)%\($0)\(US)0\(US)zsh\(US)t\(US)1\n" }
                }.joined()
            let service = TmuxService(
                runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: tmux)
            XCTAssertEqual(service.loadTree()?.count, sessions)
            return runner.calls.count
        }

        XCTAssertEqual(tmuxCallCount(sessions: 1), 3,
            "list-sessions + list-windows -a + list-panes -a")
        XCTAssertEqual(tmuxCallCount(sessions: 12), 3,
            "twelve sessions must cost the same three shell-outs as one")
    }

    func testLoadTreeAttachesWindowsAndPanesToTheRightSession() {
        // The batched queries key windows by session and panes by session+window; a
        // mis-keyed lookup would hand a session someone else's panes.
        let runner = FakeRunner()
        let US = TmuxModel.fieldSep
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = "api\(US)0\nweb\(US)1\n"
        runner.responses["list-windows -a -F \(TmuxModel.allWindowsFormat)"] =
            "api\(US)0\(US)edit\(US)1\nweb\(US)0\(US)serve\(US)1\nweb\(US)1\(US)logs\(US)0\n"
        runner.responses["list-panes -a -F \(TmuxModel.allPanesFormat)"] =
            "api\(US)0\(US)%10\(US)0\(US)zsh\(US)t\(US)1\n"
            + "web\(US)0\(US)%20\(US)0\(US)node\(US)t\(US)1\n"
            + "web\(US)1\(US)%21\(US)0\(US)tail\(US)t\(US)1\n"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: tmux)

        guard let tree = service.loadTree() else { return XCTFail("expected a tree") }
        let api = tree.first { $0.name == "api" }
        let web = tree.first { $0.name == "web" }
        XCTAssertEqual(api?.windows.map(\.index), [0])
        XCTAssertEqual(api?.windows.first?.panes.map(\.id), ["%10"])
        XCTAssertEqual(web?.windows.map(\.index), [0, 1])
        XCTAssertEqual(web?.windows.first?.panes.map(\.id), ["%20"])
        XCTAssertEqual(web?.windows.last?.panes.map(\.id), ["%21"])
    }

    func testLoadTreeKeepsSessionsWhenTheWindowQueryFails() {
        // A failed server-wide window query costs the subtree, never the sessions.
        let runner = FakeRunner()
        let US = TmuxModel.fieldSep
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = "api\(US)0\n"
        runner.responses["list-windows -a -F \(TmuxModel.allWindowsFormat)"] = String?.none
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: tmux)

        let tree = service.loadTree()
        XCTAssertEqual(tree?.map(\.name), ["api"])
        XCTAssertEqual(tree?.first?.windows.count, 0)
    }

    // MARK: An aborted drain must be a failure, not "the command printed nothing"
    //
    // Root cause of the vanishing-sessions bug. `run()` only checked
    // `terminationStatus == 0`, so a child that exited cleanly while the reader gave
    // up at its deadline returned `""` — indistinguishable from a command that
    // legitimately printed nothing. `tmux list-sessions` coming back `""` parses to
    // zero sessions, and unlike the documented `nil` path that *preserves* the last
    // good tree, an empty list OVERWRITES it. The sidebar blanked.

    func testRunReturnsNilWhenStdoutCouldNotBeFullyDrained() {
        // The child exits 0 immediately, but a backgrounded grandchild inherits and
        // holds the stdout pipe, so the reader never sees EOF and bails at its
        // deadline with zero bytes. Exit status says "success"; the output is a lie.
        let sentinel = "876543.\(Int.random(in: 100000...999999))"
        let runner = ProcessCommandRunner(timeout: 0.3)
        let out = runner.run("/bin/sh", ["-c", "/bin/sleep \(sentinel) & exit 0"])

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "sleep \(sentinel)"]
        try? pkill.run(); pkill.waitUntilExit()

        XCTAssertNil(out, "a drain that never reached EOF must be reported as failure "
            + "(nil), not as successful empty output — an empty tmux list-sessions "
            + "blanks the sidebar, while nil preserves the last good tree")
    }

    func testRunReturnsEmptyStringWhenCommandLegitimatelyPrintsNothing() {
        // The other side of the same coin: a real, complete, zero-byte read is still
        // a success. The fix must not turn every empty output into a failure.
        let runner = ProcessCommandRunner(timeout: 4.0)
        XCTAssertEqual(runner.run("/usr/bin/true", []), "",
            "a command that runs, prints nothing, and exits 0 still succeeds")
    }

    func testDrainToEndReportsWhetherItReachedEOF() throws {
        // The seam where the information was being destroyed: the reader knew it had
        // given up, and threw that fact away by returning bare `Data`.
        let held = Pipe()
        try held.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
        let cut = drainToEnd(held.fileHandleForReading, deadline: .now() + 0.4)
        XCTAssertEqual(String(data: cut.data, encoding: .utf8), "partial")
        XCTAssertFalse(cut.complete, "a deadline-cut read must report itself incomplete")
        try? held.fileHandleForWriting.close()

        let closed = Pipe()
        try closed.fileHandleForWriting.write(contentsOf: Data("all of it".utf8))
        try closed.fileHandleForWriting.close()
        let full = drainToEnd(closed.fileHandleForReading, deadline: .now() + 5.0)
        XCTAssertEqual(String(data: full.data, encoding: .utf8), "all of it")
        XCTAssertTrue(full.complete, "reaching EOF must report itself complete")
    }

    // MARK: ProcessCommandRunner injects a usable PATH into children

    func testProcessCommandRunnerGivesChildrenAUsablePath() {
        // Regression: a Finder/Xcode-launched GUI app inherits a minimal PATH, so
        // a child that shells out by bare name (sessions.py → `tmux list-panes`)
        // can't find it, every session's tmuxSession comes back null, and the
        // sidebar shows all-grey `.unknown` dots. The runner must hand children a
        // PATH that includes the standard bin dirs. Assert the child actually SEES
        // /opt/homebrew/bin (where tmux lives) at the front of its PATH.
        let runner = ProcessCommandRunner(timeout: 4.0)
        let childPath = runner.run("/bin/sh", ["-c", "printf %s \"$PATH\""])
        XCTAssertNotNil(childPath, "the child must run and report its PATH")
        let entries = (childPath ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, "/opt/homebrew/bin",
            "standard bin dirs must be prepended so by-name tools (tmux) resolve; got: \(childPath ?? "nil")")
        XCTAssertTrue(entries.contains("/usr/bin"),
            "the child PATH must still include the system bin dirs; got: \(childPath ?? "nil")")
    }

    // MARK: M8 — remote service routes every tmux call through ssh

    private func makeRemoteService(_ runner: FakeRunner, host: String = "buildbox") -> TmuxService {
        TmuxService(
            host: Host(name: host, sshAlias: host),
            transport: SshTmuxTransport(host: host),
            runner: runner,
            statusProvider: StaticStatusProvider())
    }

    func testRemoteSelectWindowSshPrefixesTheTmuxCall() {
        let runner = FakeRunner()
        // The zoom-flag probe runs over ssh too; reply "0" so no unzoom fires.
        let service = makeRemoteService(runner)
        XCTAssertTrue(service.selectWindow(session: "api", window: 1))
        // The final call must be the ssh-wrapped, quoted select-window.
        let last = runner.calls.last!
        XCTAssertEqual(last.path, "/usr/bin/ssh")
        XCTAssertEqual(Array(last.args.suffix(4)),
            ["'tmux'", "'select-window'", "'-t'", "'api:1'"])
        XCTAssertTrue(last.args.contains("ControlMaster=auto"))
        XCTAssertTrue(last.args.contains("buildbox"))
    }

    func testRemoteNewSessionSshPrefixed() {
        let runner = FakeRunner()
        let name = makeRemoteService(runner).newSession(name: "api", dir: "~", launchClaude: false)
        XCTAssertEqual(name, "api")
        // Skip the dedupe `list-sessions` call; assert on the create call.
        let call = runner.calls.first { $0.args.contains("'new-session'") }!
        XCTAssertEqual(call.path, "/usr/bin/ssh")
        // PR#9 carry-over fix: the default dir `~` must reach the remote shell
        // UNquoted so it tilde-expands to the remote $HOME — not the literal
        // `'~'` that made tmux create the session under a directory named `~`.
        XCTAssertEqual(Array(call.args.suffix(7)),
            ["'tmux'", "'new-session'", "'-d'", "'-s'", "'api'", "'-c'", "~"])
    }

    func testRemoteNewSessionAbsoluteDirIsStillFullyQuoted() {
        // A normal absolute dir (no tilde) stays single-quoted verbatim — the
        // tilde fix must not weaken quoting for any other path.
        let runner = FakeRunner()
        _ = makeRemoteService(runner).newSession(
            name: "api", dir: "/Users/me/My Code", launchClaude: false)
        let call = runner.calls.first { $0.args.contains("'new-session'") }!
        XCTAssertEqual(Array(call.args.suffix(2)),
            ["'-c'", "'/Users/me/My Code'"])
    }

    func testRemoteProbeReachabilityConnectsOverSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = ""  // ssh `echo ok` succeeds
        let service = makeRemoteService(runner)
        XCTAssertEqual(service.probeReachability(), .reachable)
        // Probe is `ssh <opts> echo ok` — cross-platform, no tmux involved.
        XCTAssertEqual(Array(runner.calls.last!.args.suffix(2)), ["echo", "ok"])
        XCTAssertFalse(runner.calls.last!.args.contains { $0.contains("tmux") })
    }

    func testRemoteProbeReachabilityUnreachableWhenSshFails() {
        let runner = FakeRunner()
        runner.defaultResponse = String?.none  // ssh fails / times out
        XCTAssertEqual(makeRemoteService(runner).probeReachability(), .unreachable)
    }

    func testRemoteHostStatsRunsTheScriptOverTheSharedSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = "@cores\n8\n@loadavg\n2.10 1.0 1.0 1/2 3\n"
            + "@cpu\ncpu  0 0 0 100 0 0 0 0\ncpu  50 0 0 150 0 0 0 0\n"
        let stats = makeRemoteService(runner).hostStats()
        XCTAssertEqual(stats?.cpuLabel, "CPU 50%")
        XCTAssertEqual(stats?.cpuTooltip, "load 2.1 · 8 cores")
        let call = runner.calls.last!
        XCTAssertEqual(call.path, "/usr/bin/ssh")
        XCTAssertTrue(call.args.contains("ControlMaster=auto"))
        XCTAssertEqual(Array(call.args.suffix(3)),
            ["'sh'", "'-c'", Ssh.shellQuote(HostStats.script)])
    }

    func testHostStatsNilWhenTheHostDoesNotAnswer() {
        let runner = FakeRunner()
        runner.defaultResponse = String?.none
        XCTAssertNil(makeRemoteService(runner).hostStats())
    }

    func testLocalHostStatsRunsLocallyWithoutSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = "@cores\n10\n"
        XCTAssertEqual(makeService(runner).hostStats()?.cores, 10)
        XCTAssertEqual(runner.calls.last?.path, "/bin/sh")
        XCTAssertEqual(runner.calls.last?.args, ["-c", HostStats.script])
    }

    // MARK: mosh-server detection (Phase 2)

    func testRemoteHasMoshServerProbesOverSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = "/usr/bin/mosh-server"  // `command -v` succeeds
        let service = makeRemoteService(runner)
        XCTAssertTrue(service.hasMoshServer())
        let last = runner.calls.last!
        XCTAssertEqual(last.path, "/usr/bin/ssh")
        XCTAssertEqual(Array(last.args.suffix(3)), ["'command'", "'-v'", "'mosh-server'"])
        XCTAssertTrue(last.args.contains("buildbox"))
    }

    func testRemoteHasMoshServerFalseWhenMissing() {
        let runner = FakeRunner()
        runner.defaultResponse = String?.none  // `command -v` exits non-zero
        XCTAssertFalse(makeRemoteService(runner).hasMoshServer())
    }

    func testLocalHasMoshServerIsFalseWithoutShelling() {
        let runner = FakeRunner()
        XCTAssertFalse(makeService(runner).hasMoshServer())
        XCTAssertTrue(runner.calls.isEmpty)  // never shells out locally for mosh
    }

    // MARK: attachCommand(useMosh:) routing (Phase 2)

    private func remoteMoshService(_ moshPath: String?) -> TmuxService {
        TmuxService(
            host: Host(name: "buildbox", sshAlias: "buildbox"),
            transport: SshTmuxTransport(host: "buildbox", moshPath: moshPath),
            runner: FakeRunner(),
            statusProvider: StaticStatusProvider())
    }

    func testAPhoneActionOnARemoteHostGoesThroughSshWithEachArgumentQuoted() {
        let runner = FakeRunner()
        let service = TmuxService(
            host: Host(name: "devbox", sshAlias: "devbox"),
            transport: SshTmuxTransport(host: "devbox", moshPath: nil),
            runner: runner, statusProvider: StaticStatusProvider())
        let ran = service.phoneTmux(["rename-window", "-t", "%3", "deploy fix"])
        XCTAssertEqual(ran?.ok, true)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].path, Ssh.sshPath)
        let args = runner.calls[0].args
        XCTAssertTrue(args.contains("devbox"))
        // ssh joins the remote command and the remote shell reads it again:
        // each tmux argument is one quoted word, so a space stays in the name.
        let remote = args.joined(separator: " ")
        for word in ["rename-window", "-t", "%3", "deploy fix"] {
            XCTAssertTrue(remote.contains(Ssh.shellQuote(word)), word)
        }
        XCTAssertTrue(remote.hasSuffix(Ssh.shellQuote("deploy fix")))

        // tmux refused the call and the host still answers: a failure of
        // tmux, not of the way there.
        let probe = (Ssh.opts(host: "devbox") + ["true"]).joined(separator: " ")
        runner.defaultResponse = nil
        runner.responses[probe] = ""
        XCTAssertEqual(service.phoneTmux(["kill-window", "-t", "%3"])?.ok, false)
        XCTAssertEqual(runner.calls.last?.args.last, "true")

        // ssh does not get there: there is no tmux to call.
        runner.responses[probe] = .some(nil)
        XCTAssertNil(service.phoneTmux(["kill-window", "-t", "%3"]))
    }

    func testTheTreeCarriesEachSessionsIdAndGroupsKeepTheirOwn() {
        // `a` and `a-view` are one group; the tree keeps `a`, with a's id.
        let out = "a\t1\ta\t100\t$0\na-view\t0\ta\t90\t$1\nother\t0\t\t80\t$2\nold\t0\t\t70\n"
        XCTAssertEqual(TmuxModel.parseSessionIds(out), ["a": "$0", "a-view": "$1", "other": "$2"])
        XCTAssertTrue(TmuxModel.sessionsFormat.hasSuffix("\t#{session_id}"))
        let runner = FakeRunner()
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = out
        let tree = makeService(runner).loadTree() ?? []
        XCTAssertEqual(tree.map(\.name).sorted(), ["a", "old", "other"])
        XCTAssertEqual(tree.first { $0.name == "a" }?.id, "$0")
        XCTAssertEqual(tree.first { $0.name == "other" }?.id, "$2")
        XCTAssertEqual(tree.first { $0.name == "old" }?.id, "")
    }

    func testRemoteAttachUsesMoshWhenRequestedAndAvailable() {
        let cmd = remoteMoshService("/opt/homebrew/bin/mosh")
            .attachCommand(session: "api", useMosh: true)!
        XCTAssertTrue(cmd.hasPrefix("/opt/homebrew/bin/mosh "))
    }

    func testRemoteAttachFallsBackToSshWhenMoshUnavailableLocally() {
        let cmd = remoteMoshService(nil).attachCommand(session: "api", useMosh: true)!
        XCTAssertTrue(cmd.hasPrefix("/usr/bin/ssh -t "))
    }

    func testRemoteAttachUsesSshWhenMoshNotRequested() {
        let cmd = remoteMoshService("/opt/homebrew/bin/mosh")
            .attachCommand(session: "api", useMosh: false)!
        XCTAssertTrue(cmd.hasPrefix("/usr/bin/ssh -t "))
    }

    func testLocalAttachIgnoresMosh() {
        let cmd = makeService(FakeRunner()).attachCommand(session: "web", useMosh: true)
        XCTAssertEqual(cmd, "/usr/bin/tmux attach -t 'web'")
    }

    func testLocalProbeReachabilityIsAlwaysReachableWithoutShelling() {
        let runner = FakeRunner()
        let service = TmuxService(runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: tmux)
        XCTAssertEqual(service.probeReachability(), .reachable)
        XCTAssertTrue(runner.calls.isEmpty)  // no probe shell-out for local
    }

    // MARK: M9 — window / pane actions (local argv + remote ssh routing)

    func testKillWindowLocalArgv() {
        let runner = FakeRunner()
        XCTAssertTrue(makeService(runner).killWindow(session: "web", window: 1))
        XCTAssertEqual(runner.argSequences, [["kill-window", "-t", "=web:1"]])
    }

    func testRenameWindowLocalArgvAndTrims() {
        let runner = FakeRunner()
        let name = makeService(runner).renameWindow(session: "web", window: 2, to: "  editor  ")
        XCTAssertEqual(name, "editor")
        XCTAssertEqual(runner.argSequences, [["rename-window", "-t", "=web:2", "--", "editor"]])
    }

    func testRenameWindowRejectsEmptyName() {
        let runner = FakeRunner()
        XCTAssertNil(makeService(runner).renameWindow(session: "web", window: 0, to: "   "))
        XCTAssertTrue(runner.calls.isEmpty)  // never shells out on an empty name
    }

    func testNewWindowLocalArgvAndReportsTheNewIndex() {
        let runner = FakeRunner()
        runner.responses["new-window -a -t web: -P -F #{window_index}"] = "3"
        XCTAssertEqual(makeService(runner).newWindow(session: "web", cwd: nil), 3)
        XCTAssertEqual(runner.argSequences,
                       [["new-window", "-a", "-t", "web:", "-P", "-F", "#{window_index}"]])
    }

    func testNewWindowReturnsNilWhenTmuxFails() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertNil(makeService(runner).newWindow(session: "web", cwd: nil))
    }

    func testKillPaneLocalArgv() {
        let runner = FakeRunner()
        XCTAssertTrue(makeService(runner).killPane(session: "web", window: 1, pane: "%12"))
        XCTAssertEqual(runner.argSequences, [["kill-pane", "-t", "=web:1.%12"]])
    }

    func testSplitPaneLocalArgvHorizontalAndVertical() {
        // The split first resolves the pane's cwd (so the new pane opens beside it,
        // not in the session's ~ start dir), then splits with `-c <cwd>`.
        let h = FakeRunner()
        h.responses["display-message -p -t =web:1.%12 #{pane_current_path}"] = "/repo"
        h.responses["split-window -h -t =web:1.%12 -P -F #{window_index}\t#{pane_id} -c /repo"] =
            "1\t%40"
        XCTAssertEqual(
            makeService(h).splitPane(session: "web", window: 1, pane: "%12", vertical: false),
            TmuxCommands.CreatedPane(window: 1, pane: "%40"))
        XCTAssertEqual(h.argSequences, [
            ["display-message", "-p", "-t", "=web:1.%12", "#{pane_current_path}"],
            ["split-window", "-h", "-t", "=web:1.%12",
             "-P", "-F", "#{window_index}\t#{pane_id}", "-c", "/repo"],
        ])

        let v = FakeRunner()
        v.responses["display-message -p -t =web:1.%12 #{pane_current_path}"] = "/repo"
        v.responses["split-window -v -t =web:1.%12 -P -F #{window_index}\t#{pane_id} -c /repo"] =
            "1\t%41"
        XCTAssertEqual(
            makeService(v).splitPane(session: "web", window: 1, pane: "%12", vertical: true)?.pane,
            "%41")
        XCTAssertEqual(v.argSequences, [
            ["display-message", "-p", "-t", "=web:1.%12", "#{pane_current_path}"],
            ["split-window", "-v", "-t", "=web:1.%12",
             "-P", "-F", "#{window_index}\t#{pane_id}", "-c", "/repo"],
        ])
    }

    func testRemoteKillWindowRoutesThroughSsh() {
        // A remote window kill must go over ssh (so it kills on the remote host),
        // quoted token-by-token like every other remote tmux call.
        let runner = FakeRunner()
        XCTAssertTrue(makeRemoteService(runner).killWindow(session: "api", window: 1))
        let call = runner.calls.last!
        XCTAssertEqual(call.path, "/usr/bin/ssh")
        XCTAssertEqual(Array(call.args.suffix(4)),
            ["'tmux'", "'kill-window'", "'-t'", "'=api:1'"])
        XCTAssertTrue(call.args.contains("ControlMaster=auto"))
        XCTAssertTrue(call.args.contains("buildbox"))
    }

    func testRemoteSplitPaneRoutesThroughSsh() {
        // Empty replies throughout: the cwd probe comes back blank (so no `-c`),
        // which keeps this focused on the argv the remote actually receives.
        let runner = FakeRunner()
        makeRemoteService(runner).splitPane(session: "api", window: 2, pane: "%5", vertical: true)
        let call = runner.calls.last!
        XCTAssertEqual(call.path, "/usr/bin/ssh")
        XCTAssertEqual(Array(call.args.suffix(8)),
            ["'tmux'", "'split-window'", "'-v'", "'-t'", "'=api:2.%5'",
             "'-P'", "'-F'", "'#{window_index}\t#{pane_id}'"])
    }

    // MARK: Move / merge — the exact sequences the sidebar reorganisation emits

    func testMoveWindowToSessionAppendsAtTheDestinationsNextIndex() {
        let runner = FakeRunner()
        XCTAssertTrue(
            makeService(runner).moveWindow(session: "web", window: 1, toSession: "api"))
        // `=api:` (trailing colon, no index) is what makes tmux append; both ends are
        // exact-matched so a prefix name can't be picked up as the source or target.
        XCTAssertEqual(runner.argSequences, [["move-window", "-s", "=web:1", "-t", "=api:"]])
    }

    func testMoveWindowToNewSessionCreatesThenReplacesThePlaceholder() {
        let runner = FakeRunner()
        runner.responses["display-message -p -t =web:3 #{pane_current_path}"] = "/repo"
        runner.responses["list-sessions -F #{session_name}"] = "web\napi"

        XCTAssertEqual(
            makeService(runner).moveWindowToNewSession(
                session: "web", window: 3, name: "scratch"),
            "scratch")

        XCTAssertEqual(runner.argSequences, [
            // The new session starts where the moved window's work is, not in ~.
            ["display-message", "-p", "-t", "=web:3", "#{pane_current_path}"],
            ["list-sessions", "-F", "#{session_name}"],
            ["new-session", "-d", "-s", "scratch", "-c", "/repo"],
            // `-k` overwrites the placeholder window, so the moved window is the
            // new session's only window and lands at index 0.
            ["move-window", "-s", "=web:3", "-t", "=scratch:0", "-k"],
        ])
    }

    func testMoveWindowToNewSessionDedupesACollidingName() {
        // A name already in use would hard-fail `new-session` and abandon the move
        // mid-way; dedupe up front instead, and target the deduped name.
        let runner = FakeRunner()
        runner.responses["list-sessions -F #{session_name}"] = "web\napi"

        XCTAssertEqual(
            makeService(runner).moveWindowToNewSession(session: "web", window: 3, name: "api"),
            "api-2")

        XCTAssertEqual(runner.argSequences.suffix(2), [
            ["new-session", "-d", "-s", "api-2"],
            ["move-window", "-s", "=web:3", "-t", "=api-2:0", "-k"],
        ])
    }

    func testMoveWindowToNewSessionRejectsAnEmptyName() {
        let runner = FakeRunner()
        XCTAssertNil(
            makeService(runner).moveWindowToNewSession(session: "web", window: 3, name: "   "))
        // The cwd probe is allowed, but nothing is created or moved.
        XCTAssertFalse(runner.argSequences.contains { $0.first == "new-session" })
        XCTAssertFalse(runner.argSequences.contains { $0.first == "move-window" })
    }

    func testMovePaneToSessionBreaksItIntoItsOwnWindowThere() {
        let runner = FakeRunner()
        XCTAssertTrue(makeService(runner).movePane(
            session: "web", window: 1, pane: "%12", toSession: "api"))
        XCTAssertEqual(runner.argSequences, [
            ["break-pane", "-s", "=web:1.%12", "-t", "=api:"],
        ])
    }

    func testMovePaneToWindowJoinsRatherThanBreaks() {
        // Landing in an existing window is a join — break-pane would give the pane a
        // window of its own instead of putting it in the one the user picked.
        let runner = FakeRunner()
        XCTAssertTrue(makeService(runner).movePane(
            session: "web", window: 1, pane: "%12", toWindow: 4))
        XCTAssertEqual(runner.argSequences, [
            ["join-pane", "-s", "=web:1.%12", "-t", "=web:4", "-v"],
        ])
    }

    func testMovePaneToNewSessionAppendsThenKillsThePlaceholder() {
        let runner = FakeRunner()
        runner.responses["display-message -p -t =web:1.%12 #{pane_current_path}"] = "/repo"
        runner.responses["list-sessions -F #{session_name}"] = "web"

        XCTAssertEqual(
            makeService(runner).movePaneToNewSession(
                session: "web", window: 1, pane: "%12", name: "scratch"),
            "scratch")

        XCTAssertEqual(runner.argSequences, [
            ["display-message", "-p", "-t", "=web:1.%12", "#{pane_current_path}"],
            ["list-sessions", "-F", "#{session_name}"],
            ["new-session", "-d", "-s", "scratch", "-c", "/repo"],
            // break-pane refuses an index already in use, so it cannot overwrite the
            // placeholder the way move-window's `-k` does: append, then kill window 0.
            ["break-pane", "-s", "=web:1.%12", "-t", "=scratch:"],
            ["kill-window", "-t", "=scratch:0"],
        ])
    }

    func testMergeSessionMovesEveryWindowToTheDestination() {
        let runner = FakeRunner()
        XCTAssertTrue(
            makeService(runner).mergeSession("old", windows: [0, 2, 5], into: "keep"))
        XCTAssertEqual(runner.argSequences, [
            ["move-window", "-s", "=old:0", "-t", "=keep:"],
            ["move-window", "-s", "=old:2", "-t", "=keep:"],
            ["move-window", "-s", "=old:5", "-t", "=keep:"],
        ])
    }

    func testMergeSessionWithNoWindowsShellsOutNothing() {
        let runner = FakeRunner()
        XCTAssertFalse(makeService(runner).mergeSession("old", windows: [], into: "keep"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testMergeSessionReportsFailureButStillMovesTheRest() {
        let runner = FakeRunner()
        runner.responses["move-window -s =old:2 -t =keep:"] = String?.none
        XCTAssertFalse(
            makeService(runner).mergeSession("old", windows: [0, 2, 5], into: "keep"))
        // A window that refuses to move must not abandon the ones after it.
        XCTAssertEqual(runner.argSequences.count, 3)
    }

    func testRemoteMoveWindowRoutesThroughSsh() {
        let runner = FakeRunner()
        XCTAssertTrue(
            makeRemoteService(runner).moveWindow(session: "api", window: 1, toSession: "web"))
        let call = runner.calls.last!
        XCTAssertEqual(call.path, "/usr/bin/ssh")
        XCTAssertEqual(Array(call.args.suffix(6)),
            ["'tmux'", "'move-window'", "'-s'", "'=api:1'", "'-t'", "'=web:'"])
    }

    func testNoTmuxPathDegradesEveryMove() {
        let runner = FakeRunner()
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: nil)
        XCTAssertFalse(service.moveWindow(session: "web", window: 1, toSession: "api"))
        XCTAssertNil(service.moveWindowToNewSession(session: "web", window: 1, name: "x"))
        XCTAssertFalse(service.movePane(
            session: "web", window: 1, pane: "%1", toSession: "api"))
        XCTAssertFalse(service.movePane(session: "web", window: 1, pane: "%1", toWindow: 2))
        XCTAssertNil(service.movePaneToNewSession(
            session: "web", window: 1, pane: "%1", name: "x"))
        XCTAssertFalse(service.mergeSession("old", windows: [0], into: "keep"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: M8 — remote attention degrade path (sessions.py absent on remote)

    func testRemoteStatusProviderDegradesWhenScriptMissing() {
        // The remote `test -f … && python3 … list` exits non-zero (script
        // absent), so run() returns nil → explicit degrade (nil, not a crash).
        let runner = FakeRunner()
        runner.defaultResponse = String?.none
        let provider = RemoteSessionsPyStatusProvider(host: "buildbox", runner: runner)
        XCTAssertNil(provider.statusesOrNil())
        XCTAssertTrue(provider.statuses().isEmpty)  // safe fallback → all unknown
        // It went over ssh with the reuse opts.
        XCTAssertEqual(runner.calls.first!.path, "/usr/bin/ssh")
        XCTAssertTrue(runner.calls.first!.args.contains("ControlMaster=auto"))
    }

    func testRemoteStatusProviderParsesWhenScriptPresent() {
        let runner = FakeRunner()
        runner.defaultResponse = """
        [{"tmuxSession":"api","status":"waiting"}]
        """
        let provider = RemoteSessionsPyStatusProvider(host: "buildbox", runner: runner)
        XCTAssertEqual(provider.statusesOrNil()?["api"], .waiting)
    }

    // MARK: applyRefresh skips reload when the tree is unchanged (item 6)

    func testUnchangedTreeSkipsReload() {
        // applyRefresh() only reloads the outline when SidebarDiff.treesEqual is
        // false. Building the tree twice from identical canned tmux output must
        // yield trees the diff considers equal, so a poll tick with no real
        // change is a no-op (no reloadData / flicker). This is the predicate the
        // re-entrancy-guarded refresh relies on. We wrap loadTree() output in a
        // node that mirrors SidebarNode's identity/display (SidebarNode itself
        // lives in the AppKit-only app file, not this host-less test bundle).
        let runner = FakeRunner()
        let US = TmuxModel.fieldSep
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = "web\(US)1\n"
        runner.responses["list-windows -a -F \(TmuxModel.allWindowsFormat)"] =
            "web\(US)0\(US)main\(US)1\n"
        runner.responses["list-panes -a -F \(TmuxModel.allPanesFormat)"] =
            "web\(US)0\(US)%1\(US)0\(US)zsh\(US)t\(US)1\n"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatusProvider(["web": .idle]), tmuxPath: tmux)

        let first = TreeNode.build(service.loadTree() ?? [])
        let second = TreeNode.build(service.loadTree() ?? [])
        XCTAssertTrue(SidebarDiff.treesEqual(first, second),
            "identical tmux state must diff equal so the refresh skips reloadData")

        // A real change (attention flips) must diff unequal so it DOES reload.
        let changed = TmuxService(
            runner: runner, statusProvider: StaticStatusProvider(["web": .waiting]), tmuxPath: tmux)
        XCTAssertFalse(SidebarDiff.treesEqual(first, TreeNode.build(changed.loadTree() ?? [])),
            "a changed attention dot must diff unequal so the outline reloads")
    }
}

/// Diffable mirror of SidebarNode's identity/display, built from a TmuxSession
/// tree, so the diff predicate can be exercised in the host-less test target.
private struct TreeNode: DiffableTreeNode {
    let diffIdentity: String
    let diffDisplay: String
    let diffChildren: [TreeNode]

    static func build(_ sessions: [TmuxSession]) -> [TreeNode] {
        sessions.map { s in
            TreeNode(
                diffIdentity: "S:\(s.name)",
                diffDisplay: "\(s.attention.dot) \(s.name) \(s.attention.label)",
                diffChildren: s.windows.map { w in
                    TreeNode(
                        diffIdentity: "W:\(s.name):\(w.index)",
                        diffDisplay: "\(w.index): \(w.name)\(w.active ? " ●" : "")",
                        diffChildren: w.panes.map { p in
                            TreeNode(
                                diffIdentity: "P:\(p.id)",
                                diffDisplay: "\(p.id) \(p.command)\(p.active ? " ◀" : "")",
                                diffChildren: [])
                        })
                })
        }
    }
}

/// Counts reads and reports a settable status, so the cache's effect on the
/// underlying (expensive, ~180ms) `sessions.py` run is directly assertable.
private final class CountingStatusProvider: AttentionStatusProvider {
    private let lock = NSLock()
    private var _reads = 0
    private var _status: AttentionStatus = .busy
    /// Fulfilled on each read, so a test can await the background refresh instead
    /// of sleeping.
    var onRead: (() -> Void)?

    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }

    func setStatus(_ s: AttentionStatus) { lock.lock(); _status = s; lock.unlock() }

    func statuses() -> [String: AttentionStatus] {
        lock.lock()
        _reads += 1
        let s = _status
        lock.unlock()
        onRead?()
        return ["web": s]
    }

    func snapshot() -> StatusSnapshot { StatusSnapshot(statuses: statuses()) }
}

/// The attention snapshot must stop riding the tree poll's cadence: it cost a
/// ~180ms `sessions.py` spawn per host per 1.5s tick, roughly 7x the tmux tree it
/// decorates. See `CachedStatusProvider`.
final class CachedStatusProviderTests: XCTestCase {
    /// A clock the test advances by hand, so TTL behavior is asserted without sleeping.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    func testFirstReadIsSynchronousSoTheFirstPaintHasRealDots() {
        let base = CountingStatusProvider()
        let clock = Clock()
        let cache = CachedStatusProvider(base, ttl: 5, now: { clock.now })

        XCTAssertEqual(cache.snapshot().statuses["web"], .busy)
        XCTAssertEqual(base.reads, 1, "cold start must block once, not paint empty")
    }

    func testReadsWithinTheTTLNeverTouchTheUnderlyingTool() {
        let base = CountingStatusProvider()
        let clock = Clock()
        let cache = CachedStatusProvider(base, ttl: 5, now: { clock.now })
        _ = cache.snapshot()

        // Three more 1.5s poll ticks inside the 5s TTL.
        for _ in 0..<3 {
            clock.advance(1.5)
            XCTAssertEqual(cache.snapshot().statuses["web"], .busy)
        }
        XCTAssertEqual(base.reads, 1, "poll ticks inside the TTL must be free")
    }

    func testStaleReadServesCachedValueThenRefreshesInBackground() {
        let base = CountingStatusProvider()
        let clock = Clock()
        let cache = CachedStatusProvider(base, ttl: 5, now: { clock.now })
        _ = cache.snapshot()

        base.setStatus(.waiting)
        // Park the background refresh inside the base provider, standing in for the
        // ~180ms `sessions.py` spawn, so "the stale read didn't block on it" is a
        // deterministic assertion rather than a race the test usually wins.
        let inFlight = expectation(description: "refresh reached the base provider")
        let release = DispatchSemaphore(value: 0)
        base.onRead = {
            inFlight.fulfill()
            release.wait()
        }
        clock.advance(5)

        // Returns the OLD value immediately while the refresh is still parked.
        XCTAssertEqual(cache.snapshot().statuses["web"], .busy)
        wait(for: [inFlight], timeout: 5)
        XCTAssertEqual(cache.snapshot().statuses["web"], .busy, "still serving cache mid-refresh")
        release.signal()

        // Once it lands, the refreshed value is served from then on.
        let landed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in cache.snapshot().statuses["web"] == .waiting },
            object: nil)
        wait(for: [landed], timeout: 5)
        XCTAssertEqual(base.reads, 2, "exactly one refresh, not one per read")
    }

    func testSingleViewReadsAreServedFromTheSameCache() {
        let base = CountingStatusProvider()
        let clock = Clock()
        let cache = CachedStatusProvider(base, ttl: 5, now: { clock.now })

        _ = cache.statuses()
        _ = cache.activity()
        _ = cache.paneStatuses()
        _ = cache.snapshot()
        XCTAssertEqual(base.reads, 1, "individual views must not sneak past the TTL")
    }
}

/// Regression test for the "MuxMaestro stalls and has to be force-quit" hang.
///
/// Spawning is the app's hot path (every 1.5s poll forks tmux/git/gh/ssh), and the
/// old waiter — `DispatchQueue.global().async { proc.waitUntilExit() }` — strands a
/// pool thread whenever Foundation drops the runloop wakeup under concurrent
/// spawns. 64 stranded threads hit GCD's dispatch-thread soft limit and the app
/// freezes. This asserts every waiter completes; run against `waitUntilExit` it
/// fails with ~1% of the spawns stranded.
final class ProcessExitSignalTests: XCTestCase {
    func testEveryWaiterCompletesUnderConcurrentSpawns() {
        // 600 at 40-way is enough to make the ~1% drop rate show up reliably
        // (a 400-spawn run stranded only 1), and costs ~0.5s when correct.
        let spawns = 600
        let concurrency = 40
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: concurrency)
        let lock = NSLock()
        var stranded = 0

        for _ in 0..<spawns {
            slots.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { slots.signal(); group.leave() }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = ["-c", "exit 0"]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                let exited = exitSignal(for: proc)
                do { try proc.run() } catch { return }
                // 5s is ~1000x what `exit 0` needs; only a dropped wakeup misses it.
                if exited.wait(timeout: .now() + 5) == .timedOut {
                    kill(proc.processIdentifier, SIGKILL)
                    lock.lock(); stranded += 1; lock.unlock()
                }
            }
        }
        group.wait()
        XCTAssertEqual(stranded, 0, "\(stranded)/\(spawns) exit waiters never woke")
    }
}

/// A static, deterministic status provider for service tests (no shelling).
private struct StaticStatusProvider: AttentionStatusProvider {
    let map: [String: AttentionStatus]
    init(_ map: [String: AttentionStatus] = [:]) { self.map = map }
    func statuses() -> [String: AttentionStatus] { map }
}

// MARK: - searchPanes (⇧⌘F "All panes")

/// A runner whose reply is computed per call, so a test can change what tmux
/// "returns" between two identical invocations (the re-list case below).
private final class ScriptedRunner: CommandRunner {
    var handler: ([String]) -> String? = { _ in "" }
    private(set) var calls: [[String]] = []

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        calls.append(args)
        return handler(args)
    }
}

extension TmuxServiceTests {
    private func scriptedService(_ runner: ScriptedRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: "/usr/bin/tmux")
    }

    func testSearchPanesIsTwoRoundTripsForAnyNumberOfPanes() {
        let runner = ScriptedRunner()
        runner.handler = { args in
            if args == PaneSearch.listPanesArgv() {
                return "%1\tapp\t0\tdev\tzsh\n%2\tapp\t1\tlogs\ttail"
            }
            if args == PaneSearch.captureArgv(panes: ["%1", "%2"]) {
                return """
                \(PaneSearch.marker)%1
                connection refused
                \(PaneSearch.marker)%2
                all good
                """
            }
            return nil
        }

        let result = scriptedService(runner).searchPanes(query: "refused")

        XCTAssertEqual(runner.calls.count, 2,
                       "one list + one chained capture, whatever the pane count")
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.pane.paneId, "%1")
        XCTAssertEqual(result.matches.first?.lineText, "connection refused")
    }

    func testSearchPanesRelistsAndRetriesWhenAPaneDiesMidCapture() {
        // %2 dies between the listing and the capture. tmux aborts the rest of the
        // command list and exits non-zero, so the whole capture comes back nil —
        // without the retry, one dead pane would empty the entire result set.
        let runner = ScriptedRunner()
        var lists = 0
        runner.handler = { args in
            if args == PaneSearch.listPanesArgv() {
                lists += 1
                return lists == 1
                    ? "%1\tapp\t0\tdev\tzsh\n%2\tapp\t1\tlogs\ttail"
                    : "%1\tapp\t0\tdev\tzsh"
            }
            if args == PaneSearch.captureArgv(panes: ["%1", "%2"]) { return nil }
            if args == PaneSearch.captureArgv(panes: ["%1"]) {
                return "\(PaneSearch.marker)%1\nstill here"
            }
            return nil
        }

        let result = scriptedService(runner).searchPanes(query: "still")

        XCTAssertEqual(lists, 2, "the failed capture must trigger exactly one re-list")
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.lineText, "still here")
    }

    func testSearchPanesGivesUpAfterOneRetry() {
        let runner = ScriptedRunner()
        runner.handler = { args in
            args == PaneSearch.listPanesArgv() ? "%1\tapp\t0\tdev\tzsh" : nil
        }

        let result = scriptedService(runner).searchPanes(query: "anything")

        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(runner.calls.count, 4, "list, capture, re-list, capture — then stop")
    }

    func testSearchPanesReturnsNothingForAnEmptyQuery() {
        let runner = ScriptedRunner()
        XCTAssertTrue(scriptedService(runner).searchPanes(query: "   ").matches.isEmpty)
        XCTAssertTrue(runner.calls.isEmpty, "an empty query must not touch tmux")
    }
}
