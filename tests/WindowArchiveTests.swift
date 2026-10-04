import XCTest

// WindowArchive.swift is Foundation-only and compiled into this test target with
// TmuxService.swift, so Archive Window and its undo are asserted against a fake
// CommandRunner, then once against real tmux on a private socket.

/// Records every command and replies from a scripted table. A key's replies are
/// used in order and the last one repeats, so two `display-message` calls with
/// the same argv can return two pane ids.
private final class ScriptedRunner: CommandRunner {
    private(set) var calls: [(path: String, args: [String])] = []
    var responses: [String: [String?]] = [:]
    var defaultResponse: String? = ""

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        calls.append((path, args))
        let key = args.joined(separator: " ")
        guard var queue = responses[key], let next = queue.first else { return defaultResponse }
        if queue.count > 1 {
            queue.removeFirst()
            responses[key] = queue
        }
        return next
    }

    var argSequences: [[String]] { calls.map(\.args) }
}

private final class StatusStub: AttentionStatusProvider {
    var status = StatusSnapshot()
    func statuses() -> [String: AttentionStatus] { status.statuses }
    func snapshot() -> StatusSnapshot { status }
}

/// Runs real tmux against one private socket, never the default server.
private final class PrivateTmuxRunner: CommandRunner {
    let socket: String
    init(socket: String) { self.socket = socket }

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-S", socket] + args
        // No $TMUX (it names the live server), and a PATH with no agent CLI on it.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": "/tmp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

final class WindowArchiveTests: XCTestCase {
    private let tmux = "/usr/bin/tmux"
    private let claudeId = "11111111-2222-4333-8444-555555555555"
    private let codexId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let layout = "b8f4,160x48,0,0[160x24,0,0,5,160x23,0,25,6]"

    private let listSessions = ["list-sessions", "-F", TmuxModel.sessionsFormat]
    private let listWindows = ["list-windows", "-a", "-F", TmuxModel.allWindowsFormat]
    private let listPanes = ["list-panes", "-a", "-F", TmuxModel.allPanesFormat]

    override func setUp() {
        super.setUp()
        // `loadTree` records the tree for reboot recovery; a fixture must not
        // replace the real snapshot.
        SessionRecord.suspendSnapshotWrites()
    }

    override func tearDown() {
        SessionRecord.resumeSnapshotWrites()
        super.tearDown()
    }

    private func key(_ argv: [String]) -> String { argv.joined(separator: " ") }

    /// `acme-app` with a shell window 1 and, at index 2, window `api`: a Claude
    /// Code pane and an active Codex pane. `lone` adds a one-window session.
    private func scriptTree(_ runner: ScriptedRunner, _ status: StatusStub, codexIdKnown: Bool = true) {
        runner.responses[key(listSessions)] = ["acme-app\t1\t\t100\nlone\t0\t\t90"]
        runner.responses[key(listWindows)] = [[
            "acme-app\t1\tshell\t0\t\t\t\t\t",
            "acme-app\t2\tapi\t1\t\t\t\t\t\(layout)",
            "lone\t0\tnotes\t1\t\t\t\t\t",
        ].joined(separator: "\n")]
        runner.responses[key(listPanes)] = [[
            "acme-app\t1\t%4\t0\tzsh\tdevbox\t1\t/Users/me\t0\t0\t160\t48\t600",
            "acme-app\t2\t%5\t0\tclaude\tdevbox\t0\t/Users/me/acme-app\t0\t0\t160\t24\t700",
            "acme-app\t2\t%6\t1\tcodex\tdevbox\t1\t/Users/me/acme-app/web\t0\t25\t160\t23\t800",
            "lone\t0\t%7\t0\tzsh\tdevbox\t1\t/Users/me/notes\t0\t0\t160\t48\t900",
        ].joined(separator: "\n")]
        status.status.paneSessionIds = ["%5": claudeId]
        if codexIdKnown {
            status.status.codexByPid = [801: codexId]
            status.status.ppids = [801: 800]
        }
    }

    private func localService(_ runner: ScriptedRunner, _ status: StatusStub = StatusStub()) -> TmuxService {
        TmuxService(runner: runner, statusProvider: status, tmuxPath: tmux)
    }

    private func remoteService(_ runner: ScriptedRunner, _ status: StatusStub = StatusStub()) -> TmuxService {
        TmuxService(
            host: Host(name: "devbox", sshAlias: "devbox"),
            transport: SshTmuxTransport(host: "devbox"),
            runner: runner, statusProvider: status)
    }

    private func archived(
        host: Host = .local, removedSession: Bool = false,
        panes: [ArchivedPane]? = nil
    ) -> ArchivedWindow {
        ArchivedWindow(
            host: host, session: "acme-app", removedSession: removedSession, index: 2,
            name: "api", layout: panes == nil ? layout : "",
            panes: panes ?? [
                ArchivedPane(
                    id: "%5", cwd: "/Users/me/acme-app", command: "claude", active: false,
                    agent: .claude, agentSessionId: claudeId),
                ArchivedPane(
                    id: "%6", cwd: "/Users/me/acme-app/web", command: "codex", active: true,
                    agent: .codex, agentSessionId: codexId),
            ])
    }

    // MARK: Capture

    func testArchiveReadsTheWindowThenKillsItLocalArgv() {
        let runner = ScriptedRunner()
        let status = StatusStub()
        scriptTree(runner, status)

        let result = localService(runner, status)
            .archiveWindow(session: "acme-app", window: 2, records: [:])

        XCTAssertEqual(runner.argSequences, [
            listSessions, listWindows, listPanes,
            ["kill-window", "-t", "=acme-app:2"],
        ])
        XCTAssertEqual(runner.calls.map(\.path), [tmux, tmux, tmux, tmux])
        XCTAssertTrue(result.killed)
        XCTAssertEqual(result.archived, archived())
    }

    func testArchiveOverSshRunsEveryCommandOnTheRemoteHost() {
        let runner = ScriptedRunner()
        let status = StatusStub()
        scriptTree(runner, status, codexIdKnown: false)
        // ssh receives each tmux token single-quoted, so script by that form.
        for argv in [listSessions, listWindows, listPanes] {
            let quoted = (["tmux"] + argv).map(Ssh.shellQuote)
            let reply = runner.responses[key(argv)]
            runner.responses[key(Ssh.opts(host: "devbox") + quoted)] = reply
        }

        let result = remoteService(runner, status)
            .archiveWindow(session: "acme-app", window: 2, records: [:])

        let expected = [listSessions, listWindows, listPanes, ["kill-window", "-t", "=acme-app:2"]]
        XCTAssertEqual(runner.calls.map(\.path), Array(repeating: Ssh.sshPath, count: 4))
        XCTAssertEqual(
            runner.argSequences,
            expected.map { Ssh.opts(host: "devbox") + (["tmux"] + $0).map(Ssh.shellQuote) })
        XCTAssertTrue(result.killed)
        XCTAssertEqual(result.archived?.host, Host(name: "devbox", sshAlias: "devbox"))
        XCTAssertEqual(result.archived?.panes.map(\.cwd),
                       ["/Users/me/acme-app", "/Users/me/acme-app/web"])
        // Codex ids come from a local process scan, so a remote codex pane has none.
        XCTAssertEqual(result.archived?.panes.map(\.agentSessionId), [claudeId, nil])
        XCTAssertEqual(result.archived?.panes.map(\.agent), [.claude, .codex])
    }

    func testArchivingTheOnlyWindowRecordsThatTheSessionWent() {
        let runner = ScriptedRunner()
        let status = StatusStub()
        scriptTree(runner, status)
        let result = localService(runner, status)
            .archiveWindow(session: "lone", window: nil, records: [:])
        XCTAssertEqual(runner.argSequences.last, ["kill-window", "-t", "=lone:0"],
                       "the window that was read is the one killed")
        XCTAssertEqual(result.archived?.removedSession, true)
        XCTAssertEqual(result.archived?.panes.map(\.agent), [nil])
    }

    func testNothingIsKeptWhenTheKillFails() {
        let runner = ScriptedRunner()
        let status = StatusStub()
        scriptTree(runner, status)
        runner.responses["kill-window -t =acme-app:2"] = [nil]
        let result = localService(runner, status)
            .archiveWindow(session: "acme-app", window: 2, records: [:])
        XCTAssertFalse(result.killed)
        XCTAssertNil(result.archived)
    }

    func testRedoRefusesAWindowThatIsNoLongerTheOneUndoMade() {
        let runner = ScriptedRunner()
        let status = StatusStub()
        scriptTree(runner, status)
        let result = localService(runner, status)
            .archiveWindow(session: "acme-app", window: 2, records: [:], onlyIfNamed: "web")
        XCTAssertFalse(result.killed)
        XCTAssertNil(result.archived)
        XCTAssertFalse(runner.argSequences.contains { $0.first == "kill-window" })
    }

    func testHookRecordSuppliesAnIdThePollMissedButNotForAShellPane() {
        let runner = ScriptedRunner()
        let status = StatusStub()
        scriptTree(runner, status, codexIdKnown: false)
        let records = [
            "%6": AgentRecord(pane: "%6", agent: .codex, sessionId: codexId, cwd: "/Users/me/acme-app/web"),
            "%4": AgentRecord(pane: "%4", agent: .claude, sessionId: claudeId, cwd: "/Users/me"),
        ]
        let service = localService(runner, status)
        XCTAssertEqual(
            service.archiveWindow(session: "acme-app", window: 2, records: records)
                .archived?.panes.map(\.agentSessionId),
            [claudeId, codexId])
        // %4 is back at a zsh prompt: its old record must not resume anything.
        let shell = service.archiveWindow(session: "acme-app", window: 1, records: records).archived
        XCTAssertEqual(shell?.panes.map(\.agent), [nil])
        XCTAssertEqual(shell?.panes.map(\.agentSessionId), [nil])
    }

    // MARK: Restore

    func testUndoRebuildsTheWindowAndResumesBothAgentsLocalArgv() {
        let runner = ScriptedRunner()
        runner.responses["list-sessions -F #{session_name}"] = ["acme-app\nlone"]
        runner.responses["list-windows -t =acme-app -F #{window_index}"] = ["0\n1"]
        runner.responses["new-window -d -t =acme-app:2 -P -F #{window_index} -c /Users/me/acme-app"] = ["2"]
        runner.responses["display-message -p -t =acme-app:2 #{pane_id}"] = ["%20\n", "%21\n"]

        let result = localService(runner).restoreArchivedWindow(archived()) { _ in true }

        XCTAssertEqual(result, .success(RestoredWindow(index: 2, agentsWithoutSession: 0)))
        XCTAssertEqual(runner.argSequences, [
            ["list-sessions", "-F", "#{session_name}"],
            ["list-windows", "-t", "=acme-app", "-F", "#{window_index}"],
            ["new-window", "-d", "-t", "=acme-app:2", "-P", "-F", "#{window_index}",
             "-c", "/Users/me/acme-app"],
            ["display-message", "-p", "-t", "=acme-app:2", "#{window_id}"],
            ["rename-window", "-t", "=acme-app:2", "--", "api"],
            ["set-window-option", "-t", "=acme-app:2", "allow-rename", "off"],
            ["display-message", "-p", "-t", "=acme-app:2", "#{pane_id}"],
            ["split-window", "-v", "-t", "=acme-app:2", "-c", "/Users/me/acme-app/web"],
            ["display-message", "-p", "-t", "=acme-app:2", "#{pane_id}"],
            ["select-layout", "-t", "=acme-app:2", layout],
            ["select-pane", "-t", "=acme-app:2.1"],
            ["send-keys", "-t", "%20", "claude --resume \(claudeId)", "Enter"],
            ["send-keys", "-t", "%21", "codex resume \(codexId)", "Enter"],
        ])
    }

    func testUndoCreatesTheSessionAgainWhenArchivingEndedIt() {
        let runner = ScriptedRunner()
        runner.responses["list-sessions -F #{session_name}"] = ["lone"]
        runner.responses["display-message -p -t =acme-app: #{window_index}"] = ["0\n"]
        runner.responses["display-message -p -t =acme-app:2 #{pane_id}"] = ["%20", "%21"]

        let result = localService(runner)
            .restoreArchivedWindow(archived(removedSession: true)) { _ in true }

        XCTAssertEqual(result, .success(RestoredWindow(index: 2, agentsWithoutSession: 0)))
        XCTAssertEqual(Array(runner.argSequences.prefix(5)), [
            ["list-sessions", "-F", "#{session_name}"],
            ["new-session", "-d", "-s", "acme-app", "-c", "/Users/me/acme-app"],
            ["display-message", "-p", "-t", "=acme-app:", "#{window_index}"],
            ["move-window", "-s", "=acme-app:0", "-t", "=acme-app:2"],
            ["display-message", "-p", "-t", "=acme-app:2", "#{window_id}"],
        ])
        XCTAssertEqual(runner.argSequences.last,
                       ["send-keys", "-t", "%21", "codex resume \(codexId)", "Enter"])
    }

    func testUndoTakesTheNextIndexWhenTheOldOneIsTaken() {
        let runner = ScriptedRunner()
        runner.responses["list-sessions -F #{session_name}"] = ["acme-app"]
        runner.responses["list-windows -t =acme-app -F #{window_index}"] = ["1\n2"]
        runner.responses["new-window -a -t acme-app: -P -F #{window_index} -c /Users/me/acme-app"] = ["3"]

        let shell = [ArchivedPane(
            id: "%5", cwd: "/Users/me/acme-app", command: "zsh", active: true,
            agent: nil, agentSessionId: nil)]
        let result = localService(runner).restoreArchivedWindow(archived(panes: shell)) { _ in true }

        XCTAssertEqual(result, .success(RestoredWindow(index: 3, agentsWithoutSession: 0)))
        // A shell pane: its directory, its name, and nothing typed into it.
        XCTAssertEqual(Array(runner.argSequences.dropFirst(2)), [
            ["new-window", "-a", "-t", "acme-app:", "-P", "-F", "#{window_index}",
             "-c", "/Users/me/acme-app"],
            ["display-message", "-p", "-t", "=acme-app:3", "#{window_id}"],
            ["rename-window", "-t", "=acme-app:3", "--", "api"],
            ["set-window-option", "-t", "=acme-app:3", "allow-rename", "off"],
            ["select-pane", "-t", "=acme-app:3.0"],
        ])
    }

    func testUndoOverSshChecksTheDirectoryAndBuildsOnTheRemoteHost() {
        let runner = ScriptedRunner()
        let remote = Host(name: "devbox", sshAlias: "devbox")
        func ssh(_ argv: [String]) -> [String] { Ssh.opts(host: "devbox") + argv.map(Ssh.shellQuote) }
        runner.responses[key(ssh(["tmux", "list-sessions", "-F", "#{session_name}"]))] = ["acme-app"]
        runner.responses[key(ssh(["tmux", "new-window", "-d", "-t", "=acme-app:2", "-P", "-F",
                                  "#{window_index}", "-c", "/home/me/acme-app"]))] = ["2"]
        runner.responses[key(ssh(["tmux", "display-message", "-p", "-t", "=acme-app:2", "#{pane_id}"]))]
            = ["%20"]
        let pane = ArchivedPane(
            id: "%5", cwd: "/home/me/acme-app", command: "claude", active: true,
            agent: .claude, agentSessionId: claudeId)

        let result = remoteService(runner)
            .restoreArchivedWindow(archived(host: remote, panes: [pane]))

        XCTAssertEqual(result, .success(RestoredWindow(index: 2, agentsWithoutSession: 0)))
        XCTAssertEqual(Set(runner.calls.map(\.path)), [Ssh.sshPath])
        XCTAssertEqual(runner.argSequences, [
            ssh(["test", "-d", "/home/me/acme-app"]),
            ssh(["tmux", "list-sessions", "-F", "#{session_name}"]),
            ssh(["tmux", "list-windows", "-t", "=acme-app", "-F", "#{window_index}"]),
            ssh(["tmux", "new-window", "-d", "-t", "=acme-app:2", "-P", "-F", "#{window_index}",
                 "-c", "/home/me/acme-app"]),
            ssh(["tmux", "display-message", "-p", "-t", "=acme-app:2", "#{window_id}"]),
            ssh(["tmux", "rename-window", "-t", "=acme-app:2", "--", "api"]),
            ssh(["tmux", "set-window-option", "-t", "=acme-app:2", "allow-rename", "off"]),
            ssh(["tmux", "display-message", "-p", "-t", "=acme-app:2", "#{pane_id}"]),
            ssh(["tmux", "select-pane", "-t", "=acme-app:2.0"]),
            ssh(["tmux", "send-keys", "-t", "%20", "claude --resume \(claudeId)", "Enter"]),
        ])
    }

    func testUndoWithoutAnAgentIdRestoresAShellAndSaysSo() {
        let runner = ScriptedRunner()
        runner.responses["list-sessions -F #{session_name}"] = ["acme-app"]
        runner.responses["new-window -d -t =acme-app:2 -P -F #{window_index} -c /Users/me/acme-app"] = ["2"]
        let pane = ArchivedPane(
            id: "%5", cwd: "/Users/me/acme-app", command: "claude", active: true,
            agent: .claude, agentSessionId: nil)

        let result = localService(runner).restoreArchivedWindow(archived(panes: [pane])) { _ in true }

        XCTAssertEqual(result, .success(RestoredWindow(index: 2, agentsWithoutSession: 1)))
        XCTAssertFalse(runner.argSequences.contains { $0.first == "send-keys" },
                       "no session is guessed, so nothing is typed")
        XCTAssertEqual(
            WindowArchive.restoredNote(RestoredWindow(index: 2, agentsWithoutSession: 1)),
            "Agent session not found")
        XCTAssertEqual(
            WindowArchive.restoredNote(RestoredWindow(index: 2, agentsWithoutSession: 0)), "")
    }

    func testUndoFailsBeforeTouchingTmuxWhenADirectoryIsGone() {
        let runner = ScriptedRunner()
        let window = archived()
        let result = localService(runner).restoreArchivedWindow(window) {
            $0 != "/Users/me/acme-app/web"
        }
        XCTAssertEqual(result, .failure(.directoryMissing("/Users/me/acme-app/web")))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(
            WindowArchive.failureMessage(window, .directoryMissing("/Users/me/acme-app/web")),
            "Couldn’t restore “api”. /Users/me/acme-app/web no longer exists.")
    }

    func testAFailedRebuildRemovesTheHalfMadeWindow() {
        let runner = ScriptedRunner()
        runner.responses["list-sessions -F #{session_name}"] = ["acme-app"]
        runner.responses["new-window -d -t =acme-app:2 -P -F #{window_index} -c /Users/me/acme-app"] = ["2"]
        runner.responses["split-window -v -t =acme-app:2 -c /Users/me/acme-app/web"] = [nil]
        runner.responses["display-message -p -t =acme-app:2 #{pane_id}"] = ["%20"]
        runner.responses["display-message -p -t =acme-app:2 #{window_id}"] = ["@9\n"]

        let result = localService(runner).restoreArchivedWindow(archived()) { _ in true }

        guard case .failure(let failure) = result, failure.isRetryable
        else { return XCTFail("expected a retryable tmux failure") }
        // By window id: the index can belong to another window by now.
        XCTAssertEqual(runner.argSequences.last, ["kill-window", "-t", "@9"])
        XCTAssertFalse(runner.argSequences.contains { $0.first == "send-keys" })
    }

    // MARK: Copy + history

    func testCopy() {
        XCTAssertEqual(WindowArchive.archivedTitle(archived()), "Archived api")
        XCTAssertEqual(WindowArchive.restoredTitle(archived()), "Restored api")
        let unnamed = ArchivedWindow(
            host: .local, session: "acme-app", removedSession: false, index: 4, name: " ",
            layout: "", panes: [])
        XCTAssertEqual(WindowArchive.archivedTitle(unnamed), "Archived window 4")
        XCTAssertEqual(WindowArchive.actionName, "Archive Window")
    }

    private func entryWindow(_ index: Int, cwd: String = "/Users/me/acme-app") -> ArchivedWindow {
        ArchivedWindow(
            host: .local, session: "acme-app", removedSession: false, index: index,
            name: "w\(index)", layout: "",
            panes: [ArchivedPane(
                id: "%\(index)", cwd: cwd, command: "zsh", active: true,
                agent: nil, agentSessionId: nil)])
    }

    func testHistoryKeepsTheLastTenAndReportsWhatItDrops() {
        let history = WindowArchiveHistory()
        var left: [Int] = []
        history.onLeave = { entry, _ in left.append(entry.archived.index) }
        for index in 0..<12 { history.push(entryWindow(index)) }
        XCTAssertEqual(history.limit, 10)
        XCTAssertEqual(history.entries.map(\.archived.index), Array(2..<12))
        XCTAssertEqual(left, [0, 1])
    }

    func testEvictedEntryLosesItsUndoAction() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let history = WindowArchiveHistory(limit: 1)
        history.onLeave = { entry, _ in undo.removeAllActions(withTarget: entry) }
        var undone: [String] = []
        for index in [1, 2] {
            let entry = history.push(entryWindow(index))
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: entry) { undone.append($0.archived.name) }
            undo.endUndoGrouping()
        }
        undo.undo()
        XCTAssertEqual(undone, ["w2"])
        XCTAssertFalse(undo.canUndo, "the evicted archive is no longer on the stack")
    }

    // The worktree cleanup waits until undo is no longer on offer.

    func testWorktreeCleanupIsDueOnlyWhenTheArchiveLeavesTheHistory() {
        let history = WindowArchiveHistory(limit: 2)
        var due: [String] = []
        history.onLeave = { _, worktree in if let worktree { due.append(worktree) } }
        history.push(entryWindow(1, cwd: "/Users/me/wt-a/src"), worktree: "/Users/me/wt-a")
        history.push(entryWindow(2))
        XCTAssertEqual(due, [], "undo is still offered, so the worktree stays")
        history.push(entryWindow(3))
        XCTAssertEqual(due, ["/Users/me/wt-a"])
    }

    func testARestoredWindowKeepsItsWorktree() {
        let history = WindowArchiveHistory()
        var due: [String] = []
        history.onLeave = { _, worktree in if let worktree { due.append(worktree) } }
        let entry = history.push(entryWindow(1, cwd: "/Users/me/wt-a"), worktree: "/Users/me/wt-a")
        entry.isArchived = false
        // A new archive clears the redo stack, so the restored entry can go.
        history.push(entryWindow(2))
        XCTAssertEqual(history.entries.map(\.archived.index), [2])
        XCTAssertEqual(due, [], "the window is back in its worktree")
    }

    func testCleanupWaitsForAnotherArchivedWindowInTheSameWorktree() {
        let history = WindowArchiveHistory(limit: 2)
        var due: [String] = []
        history.onLeave = { _, worktree in if let worktree { due.append(worktree) } }
        history.push(entryWindow(1, cwd: "/Users/me/wt-a"))
        history.push(entryWindow(2, cwd: "/Users/me/wt-a/web"), worktree: "/Users/me/wt-a")
        let second = history.entries[1]
        history.remove(second)
        XCTAssertEqual(due, [], "window 1 can still be restored into the worktree")
        XCTAssertEqual(history.entries.first?.worktree, "/Users/me/wt-a")
        XCTAssertEqual(history.drain(), ["/Users/me/wt-a"], "quitting ends every offer")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testOnlyAFailureThatCanChangeIsRetryable() {
        XCTAssertTrue(WindowRestoreFailure.tmux("tmux could not create the window.").isRetryable)
        XCTAssertFalse(WindowRestoreFailure.directoryMissing("/Users/me/acme-app").isRetryable)
        XCTAssertFalse(WindowRestoreFailure.sessionGone("acme-app").isRetryable)
    }

    // MARK: Agent ids

    func testAHookRecordNeedsTheSameDirectoryAndAnAgentCommand() {
        func capture(command: String, recordCwd: String) -> ArchivedPane? {
            var pane = TmuxPane(id: "%5", index: 0, command: command, title: "", active: true)
            pane.path = "/Users/me/acme-app"
            let tree = [TmuxSession(name: "acme-app", attached: false, windows: [
                TmuxWindow(index: 2, name: "api", active: true, panes: [pane]),
            ])]
            let record = AgentRecord(pane: "%5", agent: .claude, sessionId: claudeId, cwd: recordCwd)
            return WindowArchive.capture(
                tree: tree, host: .local, session: "acme-app", window: 2, records: ["%5": record])?
                .panes.first
        }
        XCTAssertEqual(capture(command: "claude", recordCwd: "/Users/me/acme-app")?.agentSessionId, claudeId)
        // Claude Code names its process after its version.
        XCTAssertEqual(capture(command: "2.1.34", recordCwd: "/Users/me/acme-app")?.agentSessionId, claudeId)
        XCTAssertEqual(capture(command: "node", recordCwd: "/Users/me/acme-app")?.agentSessionId, claudeId)
        // An editor in a pane whose id an old record happens to carry.
        let vim = capture(command: "vim", recordCwd: "/Users/me/acme-app")
        XCTAssertNil(vim?.agent)
        XCTAssertNil(vim?.agentSessionId)
        // Pane ids restart with the tmux server: same id, another directory.
        let moved = capture(command: "claude", recordCwd: "/Users/me/other")
        XCTAssertEqual(moved?.agent, .claude)
        XCTAssertNil(moved?.agentSessionId, "reported as not found, never resumed")
    }

    func testAnIdThatIsNotASessionIdIsTreatedAsMissing() {
        var pane = TmuxPane(id: "%5", index: 0, command: "claude", title: "", active: true)
        pane.path = "/Users/me/acme-app"
        pane.claudeSessionId = "x; touch /tmp/owned"
        let tree = [TmuxSession(name: "acme-app", attached: false, windows: [
            TmuxWindow(index: 2, name: "api", active: true, panes: [pane]),
        ])]
        let captured = WindowArchive.capture(
            tree: tree, host: .local, session: "acme-app", window: 2)?.panes.first
        XCTAssertEqual(captured?.agent, .claude)
        XCTAssertNil(captured?.agentSessionId)
        XCTAssertEqual(captured?.lostAgentSession, true)
    }

    func testResumeCommandQuotesAnIdTheShellWouldSplit() {
        XCTAssertEqual(
            RecoveryAgent.claude.resumeCommand(sessionId: claudeId), "claude --resume \(claudeId)")
        XCTAssertEqual(
            RecoveryAgent.codex.resumeCommand(sessionId: codexId), "codex resume \(codexId)")
        XCTAssertEqual(
            RecoveryAgent.claude.resumeCommand(sessionId: "x; touch /tmp/owned"),
            "claude --resume 'x; touch /tmp/owned'")
        XCTAssertEqual(
            RecoveryAgent.codex.resumeCommand(sessionId: "it's"), #"codex resume 'it'\''s'"#)
    }

    // MARK: Session gone, hostile names

    func testUndoDoesNotRecreateASessionThatWasKilledSeparately() {
        let runner = ScriptedRunner()
        runner.responses["list-sessions -F #{session_name}"] = ["lone"]
        let result = localService(runner).restoreArchivedWindow(archived()) { _ in true }
        XCTAssertEqual(result, .failure(.sessionGone("acme-app")))
        XCTAssertEqual(runner.argSequences, [["list-sessions", "-F", "#{session_name}"]])
        XCTAssertEqual(
            WindowArchive.failureMessage(archived(), .sessionGone("acme-app")),
            "Couldn’t restore “api”. The session “acme-app” no longer exists.")
    }

    func testTmuxLiteralEscapesFormatsAndATrailingSemicolon() {
        XCTAssertEqual(TmuxCommands.literal("api"), "api")
        XCTAssertEqual(TmuxCommands.literal("a#{session_name}#(id)"), "a##{session_name}##(id)")
        XCTAssertEqual(TmuxCommands.literal("build;"), #"build\;"#)
        XCTAssertEqual(TmuxCommands.literal("a;b"), "a;b")
        XCTAssertEqual(
            TmuxCommands.renameWindow(target: "=web:1", to: "-n"),
            ["rename-window", "-t", "=web:1", "--", "-n"])
    }

    func testUndoPassesNamesAndDirectoriesToTmuxAsLiterals() {
        let runner = ScriptedRunner()
        runner.responses["list-sessions -F #{session_name}"] = ["acme-app"]
        runner.responses["list-windows -t =acme-app -F #{window_index}"] = ["0"]
        runner.defaultResponse = "2"
        let pane = ArchivedPane(
            id: "%5", cwd: "/Users/me/a#{pane_id};", command: "zsh", active: true,
            agent: nil, agentSessionId: nil)
        let window = ArchivedWindow(
            host: .local, session: "acme-app", removedSession: false, index: 2,
            name: "#(id);", layout: "", panes: [pane])
        _ = localService(runner).restoreArchivedWindow(window) { _ in true }
        XCTAssertTrue(runner.argSequences.contains(
            ["new-window", "-d", "-t", "=acme-app:2", "-P", "-F", "#{window_index}",
             "-c", #"/Users/me/a##{pane_id}\;"#]))
        XCTAssertTrue(runner.argSequences.contains(
            ["rename-window", "-t", "=acme-app:2", "--", #"##(id)\;"#]))
    }

    // MARK: Real tmux, private socket

    func testArchiveThenUndoOnAPrivateTmuxServer() throws {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("tmux is not installed") }
        // Short paths: a tmux socket path is capped near 104 bytes.
        let root = "/tmp/mmaw-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        for dir in ["acme-app", "acme-app/web", "notes"] {
            try fm.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
        }
        // tmux reports `pane_current_path` with symlinks resolved (/tmp → /private/tmp).
        let real = try XCTUnwrap(realpath(root, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let runner = PrivateTmuxRunner(socket: "\(root)/s")
        defer {
            _ = runner.run(tmux, ["kill-server"], stdin: nil)
            try? fm.removeItem(atPath: root)
        }
        func run(_ args: [String]) -> String? {
            runner.run(tmux, args, stdin: nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A holder session keeps the server up when the fixture's last window goes,
        // and /bin/sh keeps the panes free of the developer's shell config.
        XCTAssertNotNil(run(["-f", "/dev/null", "new-session", "-d", "-s", "holder", "sleep 600"]))
        XCTAssertNotNil(run(["set-option", "-g", "default-shell", "/bin/sh"]))
        XCTAssertNotNil(run(["new-session", "-d", "-s", "acme-app", "-c", "\(real)/notes"]))
        XCTAssertNotNil(run(["new-window", "-d", "-t", "=acme-app:3", "-c", "\(real)/acme-app"]))
        XCTAssertNotNil(run(["rename-window", "-t", "=acme-app:3", "--", "api"]))
        XCTAssertNotNil(run(["split-window", "-v", "-t", "=acme-app:3", "-c", "\(real)/acme-app/web"]))
        let agentPane = try XCTUnwrap(
            run(["list-panes", "-t", "=acme-app:3", "-F", "#{pane_id}"])?
                .split(separator: "\n").first.map(String.init))

        func windows(_ session: String) -> String? {
            run(["list-windows", "-t", "=\(session)", "-F", "#{window_index} #{window_name} #{window_panes}"])
        }
        func paths(_ target: String) -> [String] {
            (run(["list-panes", "-t", target, "-F", "#{pane_current_path}"]) ?? "")
                .split(separator: "\n").map(String.init)
        }
        /// A new pane reports its directory once its shell has started.
        func waitFor(_ what: String, _ check: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !check(), Date() < deadline { usleep(50_000) }
            XCTAssertTrue(check(), what)
        }
        let expectedPaths = ["\(real)/acme-app", "\(real)/acme-app/web"]
        waitFor("fixture panes are up") { paths("=acme-app:3") == expectedPaths }

        let status = StatusStub()
        status.status.paneSessionIds = [agentPane: claudeId]
        let service = TmuxService(runner: runner, statusProvider: status, tmuxPath: tmux)

        // Archive window 3, then undo.
        let first = service.archiveWindow(session: "acme-app", window: 3, records: [:])
        XCTAssertTrue(first.killed)
        let archivedWindow = try XCTUnwrap(first.archived)
        XCTAssertEqual(archivedWindow.name, "api")
        XCTAssertEqual(archivedWindow.panes.map(\.cwd), expectedPaths)
        XCTAssertFalse(archivedWindow.removedSession)
        XCTAssertEqual(windows("acme-app")?.contains("api"), false)

        XCTAssertEqual(
            service.restoreArchivedWindow(archivedWindow),
            .success(RestoredWindow(index: 3, agentsWithoutSession: 0)))
        XCTAssertEqual(windows("acme-app")?.split(separator: "\n").last, "3 api 2")
        waitFor("restored panes are in their directories") { paths("=acme-app:3") == expectedPaths }
        // The resume command ran in the pane that held the agent. No agent CLI is
        // on this server's PATH, so the shell only echoes it.
        let restoredPane = try XCTUnwrap(
            run(["list-panes", "-t", "=acme-app:3", "-F", "#{pane_id}"])?
                .split(separator: "\n").first.map(String.init))
        waitFor("the resume command was run") {
            // -J joins the line the 80-column pane wrapped.
            run(["capture-pane", "-p", "-J", "-t", restoredPane])?
                .contains("claude --resume \(self.claudeId)") == true
        }

        // Redo is a second archive of the restored window.
        let second = service.archiveWindow(session: "acme-app", window: 3, records: [:])
        XCTAssertTrue(second.killed)
        XCTAssertEqual(second.archived?.panes.map(\.cwd), expectedPaths)

        // Archive the session's only window: the session goes, and undo makes it again.
        let last = service.archiveWindow(session: "acme-app", window: nil, records: [:])
        let lone = try XCTUnwrap(last.archived)
        XCTAssertTrue(lone.removedSession)
        XCTAssertNil(windows("acme-app"), "the session ended with its last window")
        XCTAssertEqual(
            service.restoreArchivedWindow(lone),
            .success(RestoredWindow(index: lone.index, agentsWithoutSession: 0)))
        waitFor("the session is back in its directory") {
            paths("=acme-app:\(lone.index)") == ["\(real)/notes"]
        }

        // Names and directories tmux would expand or split, restored as written.
        let hostileDir = "\(real)/a#{session_name};"
        try fm.createDirectory(atPath: hostileDir, withIntermediateDirectories: true)
        let hostileName = "-n #(echo x) #{pane_id};"
        XCTAssertNotNil(run(["new-window", "-d", "-t", "=acme-app:7", "-c", "\(real)/a##{session_name}" + #"\;"#]))
        XCTAssertNotNil(run(["rename-window", "-t", "=acme-app:7", "--", #"-n ##(echo x) ##{pane_id}\;"#]))
        waitFor("hostile fixture is up") { paths("=acme-app:7") == [hostileDir] }
        let hostile = try XCTUnwrap(
            service.archiveWindow(session: "acme-app", window: 7, records: [:]).archived)
        XCTAssertEqual(hostile.name, hostileName)
        XCTAssertEqual(
            service.restoreArchivedWindow(hostile),
            .success(RestoredWindow(index: 7, agentsWithoutSession: 0)))
        XCTAssertEqual(run(["display-message", "-p", "-t", "=acme-app:7", "#{window_name}"]), hostileName)
        waitFor("the hostile directory is restored, not the home directory") {
            paths("=acme-app:7") == [hostileDir]
        }
        XCTAssertTrue(service.archiveWindow(session: "acme-app", window: 7, records: [:]).killed)

        // A session id that is shell text never reaches a shell.
        let marker = "\(real)/owned"
        let evilPane = try XCTUnwrap(
            run(["list-panes", "-t", "=acme-app:\(lone.index)", "-F", "#{pane_id}"]))
        status.status.paneSessionIds = [evilPane: "x; touch \(marker)"]
        let evil = try XCTUnwrap(
            service.archiveWindow(session: "acme-app", window: lone.index, records: [:]).archived)
        XCTAssertEqual(evil.panes.map(\.agentSessionId), [nil])
        XCTAssertEqual(
            service.restoreArchivedWindow(evil),
            .success(RestoredWindow(index: lone.index, agentsWithoutSession: 1)),
            "restored as a shell, and reported as an agent session not found")
        usleep(500_000)
        XCTAssertFalse(fm.fileExists(atPath: marker))

        // A directory removed after the archive: undo fails and names it.
        let gone = service.archiveWindow(session: "acme-app", window: nil, records: [:])
        try fm.removeItem(atPath: "\(real)/notes")
        XCTAssertEqual(
            service.restoreArchivedWindow(try XCTUnwrap(gone.archived)),
            .failure(.directoryMissing("\(real)/notes")))
        XCTAssertNil(windows("acme-app"))
    }
}
