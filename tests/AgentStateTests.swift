import XCTest

// AgentState.swift, ManagerStore.swift and TmuxModel.swift are compiled directly
// into this test target. `mux event` runs the way the hooks run it: the bundled
// script, the hook JSON on stdin, against a temp DB.

/// Runs commands for real with `env`, and runs `afterFirstRead` once, right after
/// the first `display-message` returns — the gap a concurrent writer can hit.
private final class RacingTmuxRunner: CommandRunner {
    let env: [String: String]
    var afterFirstRead: (() -> Void)?

    init(env: [String: String]) { self.env = env }

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        if args.first == "display-message", let hook = afterFirstRead {
            afterFirstRead = nil
            hook()
        }
        return String(decoding: data, as: UTF8.self)
    }

    func runCapturing(_ path: String, _ args: [String]) -> (ok: Bool, text: String) {
        let out = run(path, args, stdin: nil)
        return (out != nil, out ?? "")
    }
}

final class AgentStateTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String { dir.appendingPathComponent("manager.db").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: mux event

    func testAClaudeTurnWalksTheStates() throws {
        try event(["hook_event_name": "SessionStart", "source": "startup"])
        XCTAssertEqual(try row()?.state, .idle)
        try event(["hook_event_name": "UserPromptSubmit", "prompt": "push it"])
        XCTAssertEqual(try row()?.state, .busy)
        try event(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                   "tool_input": ["command": "git push"]])
        XCTAssertEqual(try row()?.state, .waiting)
        XCTAssertEqual(try row()?.reason, "Bash: git push")
        try event(["hook_event_name": "PostToolUse", "tool_name": "Bash",
                   "tool_input": ["command": "git push"], "tool_response": ["stdout": "ok"]])
        XCTAssertEqual(try row()?.state, .busy)
        try event(["hook_event_name": "Stop", "last_assistant_message": "Pushed."])
        XCTAssertEqual(try row()?.state, .done)
        XCTAssertEqual(try row()?.reason, "Pushed.")
        XCTAssertEqual(try row()?.pane, "%7")
        try event(["hook_event_name": "SessionEnd", "reason": "prompt_input_exit"])
        XCTAssertNil(try row(), "an ended session is not live")
        XCTAssertEqual(try sql("SELECT state FROM agent_state WHERE session_id = 's1';"), "ended")
        XCTAssertEqual(
            try sql("SELECT group_concat(event, ',') FROM "
                + "(SELECT event FROM agent_events WHERE session_id = 's1' ORDER BY id);"),
            "SessionStart,UserPromptSubmit,PermissionRequest,PostToolUse,Stop,SessionEnd")
    }

    func testSinceMovesOnlyWhenTheStateChanges() throws {
        try event(["hook_event_name": "PermissionRequest", "tool_name": "Bash"])
        _ = try sql("UPDATE agent_state SET since = 100;")
        try event(["hook_event_name": "Notification", "notification_type": "permission_prompt",
                   "message": "Claude needs your permission to use Bash"])
        XCTAssertEqual(try row()?.state, .waiting)
        XCTAssertEqual(try row()?.since, 100)
        try event(["hook_event_name": "PostToolUse", "tool_name": "Bash"])
        XCTAssertEqual(try row()?.state, .busy)
        XCTAssertGreaterThan(try row()?.since ?? 0, 100)
    }

    func testCompactionDoesNotEndTheTurn() throws {
        try event(["hook_event_name": "UserPromptSubmit", "prompt": "go"])
        try event(["hook_event_name": "SessionStart", "source": "compact"])
        XCTAssertEqual(try row()?.state, .busy)
    }

    func testQuestionsAndPlansWaitOnTheHuman() throws {
        try event(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"], session: "ask")
        try event(["hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode"], session: "plan")
        try event(["hook_event_name": "PreToolUse", "tool_name": "Read",
                   "tool_input": ["file_path": "/a"]], session: "read")
        XCTAssertEqual(try row("ask")?.state, .waiting)
        XCTAssertEqual(try row("plan")?.state, .waiting)
        XCTAssertEqual(try row("read")?.state, .busy)
        XCTAssertEqual(try row("read")?.reason, "Read: /a")
    }

    func testIdleReminderChangesNothingAndAFailedTurnWaits() throws {
        try event(["hook_event_name": "Stop"])
        try event(["hook_event_name": "Notification", "notification_type": "idle_prompt",
                   "message": "Claude is waiting for your input"])
        XCTAssertEqual(try row()?.state, .done, "an idle reminder is not a new state")
        XCTAssertEqual(try sql("SELECT count(*) FROM agent_events;"), "2")
        try event(["hook_event_name": "StopFailure", "error": "rate_limit"])
        XCTAssertEqual(try row()?.state, .waiting)
        XCTAssertEqual(try row()?.reason, "rate_limit")
    }

    func testCodexWritesTheSameTables() throws {
        try event(["hook_event_name": "PreToolUse", "tool_name": "shell", "turn_id": "t1",
                   "tool_input": ["command": ["ls"]]],
                  agent: "codex", session: "c1", pane: "%12")
        let codex = try row("c1")
        XCTAssertEqual(codex?.agent, "codex")
        XCTAssertEqual(codex?.state, .busy)
        XCTAssertEqual(codex?.pane, "%12")
        XCTAssertEqual(codex?.cwd, "/repo")
    }

    func testQuotesNewlinesAndOddPanesAreStoredSafely() throws {
        try event(["hook_event_name": "UserPromptSubmit", "cwd": "/tmp/it's here",
                   "prompt": "fix 'this'\nand \"that\""],
                  pane: "%1'; DROP TABLE agent_state; --")
        let stored = try row()
        XCTAssertEqual(stored?.cwd, "/tmp/it's here")
        XCTAssertEqual(stored?.reason, "fix 'this' and \"that\"")
        XCTAssertEqual(stored?.pane, "", "a value that isn't a pane id is dropped")
    }

    func testEventNeverFailsAndNeverPrints() throws {
        let stop = #"{"session_id":"x","hook_event_name":"Stop"}"#
        let cases: [(args: [String], stdin: String, db: String?)] = [
            (["event", "claude"], "not json", nil),
            (["event", "claude"], "", nil),
            (["event", "claude"], #"{"hook_event_name":"Stop"}"#, nil),
            (["event", "gemini"], stop, nil),
            (["event"], stop, nil),
            (["event", "claude"], stop, "/nonexistent/dir/manager.db"),
        ]
        for c in cases {
            let result = runMux(c.args, stdin: Data(c.stdin.utf8), pane: "%1", db: c.db)
            XCTAssertEqual(result.status, 0, "\(c)")
            XCTAssertEqual(result.output, "", "\(c)")
        }
        XCTAssertNil(try row("x"))
    }

    // MARK: work log

    // work_log is the durable record of what an agent worked on, written by the
    // same hook run. tmux is reachable from the test process, so `%7` may well
    // resolve to a real pane here: nothing below asserts on session, window or
    // prs, which are the only columns that would come from it.

    func testEventsKeepAWorkLogRow() throws {
        try event(["hook_event_name": "SessionStart", "source": "startup"])
        XCTAssertEqual(try workLog("session_id, last_state, cwd"), "s1|idle|/repo")
        XCTAssertEqual(try sql("SELECT first_seen = last_seen FROM work_log;"), "1")
        try event(["hook_event_name": "Stop", "last_assistant_message": "Pushed."])
        XCTAssertEqual(try workLog("last_state"), "done")
        XCTAssertEqual(try sql("SELECT last_seen >= first_seen FROM work_log;"), "1")
        try event(["hook_event_name": "SessionEnd", "reason": "prompt_input_exit"])
        XCTAssertEqual(try workLog("last_state"), "ended", "the work outlives the session")
        XCTAssertEqual(try sql("SELECT count(*) FROM work_log;"), "1")
    }

    func testSpawnedRowIsClaimedByItsPane() throws {
        // One event first, so the schema exists; its pane is not the one below.
        try event(["hook_event_name": "SessionStart"], session: "other", pane: "%1")
        _ = try sql("""
            INSERT INTO work_log(session_id, agent, repo, branch, prs, host, session, window,
                                 pane, cwd, last_state, first_seen, last_seen)
            VALUES('', 'claude', 'r', 'b', '', 'localhost', '', NULL, '%7', '/wt', 'spawned', 10, 10);
            """)
        try event(["hook_event_name": "SessionStart", "source": "startup"])
        // The spawned row is now this session's row: `mux spin` knew the repo and
        // branch, and the event's cwd (/repo) has no .git to say otherwise.
        XCTAssertEqual(try workLog("repo, branch, last_state, first_seen"), "r|b|idle|10")
        XCTAssertEqual(try sql("SELECT count(*) FROM work_log;"), "2")
        // A second agent in the same pane is new work, not the same row again.
        try event(["hook_event_name": "SessionStart", "source": "startup"], session: "s2")
        XCTAssertEqual(try sql("SELECT count(*) FROM work_log;"), "3")
        XCTAssertEqual(try workLog("repo, branch, last_state", session: "s2"), "||idle")
    }

    func testToolEventsDoNotTouchTmuxContext() throws {
        // The skipped tmux call cannot be seen from here; what must still happen
        // on the storm path can: the row keeps moving.
        try event(["hook_event_name": "PreToolUse", "tool_name": "Bash",
                   "tool_input": ["command": "ls"]])
        XCTAssertEqual(try workLog("last_state, cwd"), "busy|/repo")
        _ = try sql("UPDATE work_log SET last_seen = 100;")
        try event(["hook_event_name": "PostToolUse", "tool_name": "Bash",
                   "tool_input": ["command": "ls"]])
        XCTAssertEqual(try workLog("last_state"), "busy")
        XCTAssertEqual(try sql("SELECT last_seen > 100 FROM work_log;"), "1")
    }

    func testGitContextFromAWorktree() throws {
        let files = FileManager.default
        let mainGit = dir.appendingPathComponent("main/.git")
        let wtGit = mainGit.appendingPathComponent("worktrees/wt")
        try files.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try write("ref: refs/heads/main\n", mainGit.appendingPathComponent("HEAD"))
        try write("ref: refs/heads/feat/x\n", wtGit.appendingPathComponent("HEAD"))
        let worktree = dir.appendingPathComponent("wt")
        try files.createDirectory(at: worktree.appendingPathComponent("sub"),
                                  withIntermediateDirectories: true)
        try write("gitdir: \(wtGit.path)\n", worktree.appendingPathComponent(".git"))

        try event(["hook_event_name": "SessionStart",
                   "cwd": worktree.appendingPathComponent("sub").path])
        XCTAssertEqual(try workLog("repo, branch"), "main|feat/x",
                       "a worktree reports the main checkout and its own branch")

        let plain = dir.appendingPathComponent("plain")
        try files.createDirectory(at: plain.appendingPathComponent(".git"),
                                  withIntermediateDirectories: true)
        try write("ref: refs/heads/trunk\n", plain.appendingPathComponent(".git/HEAD"))
        try event(["hook_event_name": "SessionStart", "cwd": plain.path], session: "s2")
        XCTAssertEqual(try workLog("repo, branch", session: "s2"), "plain|trunk")
    }

    private func write(_ text: String, _ url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func workLog(_ columns: String, session: String = "s1") throws -> String {
        try sql("SELECT \(columns) FROM work_log WHERE session_id = '\(session)';")
    }

    // MARK: freshness

    private func stateRow(
        _ state: AgentStateRow.State, updatedAt: Int, session: String = "s1", since: Int = 0
    ) -> AgentStateRow {
        AgentStateRow(
            sessionId: session, agent: "claude", state: state, reason: "", pane: "%1",
            cwd: "/repo", since: since, updatedAt: updatedAt)
    }

    func testEndedIsNeverFresh() {
        XCTAssertFalse(AgentState.isFresh(stateRow(.ended, updatedAt: 1000), scanStatus: nil, now: 1000))
    }

    func testWithoutAScanOnlyBusyExpires() {
        let busy = stateRow(.busy, updatedAt: 1000)
        XCTAssertTrue(AgentState.isFresh(busy, scanStatus: nil, now: 1000 + AgentState.busySeconds))
        XCTAssertFalse(AgentState.isFresh(busy, scanStatus: nil, now: 1001 + AgentState.busySeconds))
        XCTAssertTrue(AgentState.isFresh(stateRow(.waiting, updatedAt: 0), scanStatus: nil, now: 100_000))
        XCTAssertTrue(AgentState.isFresh(stateRow(.done, updatedAt: 0), scanStatus: .unknown, now: 100_000))
    }

    func testTheScanWinsOnceItOutlivesItsLag() {
        let busy = stateRow(.busy, updatedAt: 1000)
        XCTAssertTrue(AgentState.isFresh(busy, scanStatus: .idle, now: 1000 + AgentState.scanLagSeconds))
        XCTAssertFalse(AgentState.isFresh(busy, scanStatus: .idle, now: 1001 + AgentState.scanLagSeconds))
        // Agreement never expires, and done agrees with idle.
        XCTAssertTrue(AgentState.isFresh(stateRow(.waiting, updatedAt: 0), scanStatus: .waiting, now: 100_000))
        XCTAssertTrue(AgentState.isFresh(stateRow(.done, updatedAt: 0), scanStatus: .idle, now: 100_000))
        XCTAssertFalse(AgentState.isFresh(stateRow(.done, updatedAt: 0), scanStatus: .busy, now: 100_000))
    }

    // MARK: joined onto the tree

    func testACodexPaneTakesItsHookState() {
        let sessions = [TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "codex", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "codex", title: "", active: true, pid: 100),
                TmuxPane(id: "%2", index: 1, command: "zsh", title: "", active: false, pid: 200),
            ]),
        ])]
        let sorted = TmuxModel.sorted(
            sessions: sessions, statuses: [:], codexByPid: [101: "c1"], ppids: [101: 100],
            agentStates: ["c1": stateRow(.waiting, updatedAt: 990, session: "c1", since: 990)],
            now: 1000)
        let panes = sorted[0].windows[0].panes
        XCTAssertEqual(panes[0].attention, .waiting)
        XCTAssertEqual(panes[0].agentState, AgentPaneState(sessionId: "c1", state: .waiting, since: 990))
        XCTAssertNil(panes[1].agentState)
        XCTAssertEqual(sorted[0].attention, .waiting, "the session rolls up from its panes")
    }

    func testAClaudePaneFallsBackToTheScanWhenTheHookIsStale() {
        let sorted = TmuxModel.sorted(
            sessions: [claudeSession()], statuses: ["work": .idle], paneStatuses: ["%1": .idle],
            paneSessionIds: ["%1": "s1"],
            agentStates: ["s1": stateRow(.busy, updatedAt: 900)], now: 1000)
        XCTAssertEqual(sorted[0].windows[0].panes[0].attention, .idle)
        XCTAssertNil(sorted[0].windows[0].panes[0].agentState)
        XCTAssertEqual(sorted[0].attention, .idle)
    }

    func testRowsForSessionsInNoPaneAreIgnored() {
        let sorted = TmuxModel.sorted(
            sessions: [claudeSession()], statuses: ["work": .busy], paneStatuses: ["%1": .busy],
            paneSessionIds: ["%1": "s1"],
            agentStates: ["other": stateRow(.waiting, updatedAt: 1000, session: "other")], now: 1000)
        XCTAssertEqual(sorted[0].windows[0].panes[0].attention, .busy)
        XCTAssertNil(sorted[0].windows[0].panes[0].agentState)
    }

    // MARK: dozing

    func testAPaneIdleForAnHourDozes() {
        let sorted = TmuxModel.sorted(
            sessions: [claudeSession()], statuses: ["work": .idle], paneStatuses: ["%1": .idle],
            paneStatusSince: ["%1": 1000 - AgentState.dozeSeconds], now: 1000)
        XCTAssertEqual(sorted[0].windows[0].panes[0].idleStage, .dozing)
        XCTAssertEqual(sorted[0].windows[0].idleStage, .dozing)
    }

    func testAPaneIdleForUnderAnHourIsAwake() {
        let sorted = TmuxModel.sorted(
            sessions: [claudeSession()], statuses: ["work": .idle], paneStatuses: ["%1": .idle],
            paneStatusSince: ["%1": 1001 - AgentState.dozeSeconds], now: 1000)
        XCTAssertEqual(sorted[0].windows[0].panes[0].idleStage, .awake)
    }

    func testOnlyIdlePanesDoze() {
        for status in [AttentionStatus.waiting, .busy] {
            let sorted = TmuxModel.sorted(
                sessions: [claudeSession()], statuses: [:], paneStatuses: ["%1": status],
                paneStatusSince: ["%1": 0], now: 100_000)
            XCTAssertEqual(sorted[0].windows[0].panes[0].idleStage, .awake, "\(status)")
        }
    }

    func testAnIdlePaneWithNoStatusTimeIsAwake() {
        let sorted = TmuxModel.sorted(
            sessions: [claudeSession()], statuses: [:], paneStatuses: ["%1": .idle], now: 100_000)
        XCTAssertEqual(sorted[0].windows[0].panes[0].idleStage, .awake)
    }

    func testTheHookSinceWinsOverTheScanTime() {
        let sorted = TmuxModel.sorted(
            sessions: [claudeSession()], statuses: [:], paneStatuses: ["%1": .idle],
            paneSessionIds: ["%1": "s1"], paneStatusSince: ["%1": 0],
            agentStates: ["s1": stateRow(.done, updatedAt: 100_000, session: "s1", since: 99_000)],
            now: 100_000)
        XCTAssertEqual(sorted[0].windows[0].panes[0].idleStage, .awake, "done 1000s ago is not an hour")
    }

    func testAWindowDozesWhenEveryAgentPaneDozes() {
        let session = TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
                TmuxPane(id: "%2", index: 1, command: "claude", title: "", active: false),
                TmuxPane(id: "%3", index: 2, command: "zsh", title: "", active: false),
            ]),
            TmuxWindow(index: 2, name: "shell", active: false, panes: [
                TmuxPane(id: "%4", index: 0, command: "zsh", title: "", active: true),
            ]),
        ])
        let old = ["%1": 0, "%2": 0]
        let oneAwake = TmuxModel.sorted(
            sessions: [session], statuses: [:], paneStatuses: ["%1": .idle, "%2": .busy],
            paneStatusSince: old, now: 100_000)
        XCTAssertEqual(oneAwake[0].windows[0].idleStage, .awake)

        let allAsleep = TmuxModel.sorted(
            sessions: [session], statuses: [:], paneStatuses: ["%1": .idle, "%2": .idle],
            paneStatusSince: old, now: 100_000)
        XCTAssertEqual(allAsleep[0].windows[0].idleStage, .dozing, "a plain shell pane does not keep it awake")
        XCTAssertEqual(allAsleep[0].windows[1].idleStage, .awake, "a window with no agent never dozes")
    }

    // MARK: 🥱 cache clock — transcript tail

    /// One assistant transcript line, shaped like Claude Code writes it.
    private func assistantLine(
        at timestamp: String, oneHour: Int = 0, fiveMin: Int = 0,
        model: String = "claude-opus-5", text: String = "ok"
    ) -> String {
        """
        {"parentUuid":"p","isSidechain":false,"message":{"model":"\(model)","role":"assistant",\
        "content":[{"type":"text","text":"\(text)"}],"usage":{"input_tokens":2,\
        "cache_creation_input_tokens":\(oneHour + fiveMin),"cache_read_input_tokens":120000,\
        "cache_creation":{"ephemeral_1h_input_tokens":\(oneHour),"ephemeral_5m_input_tokens":\(fiveMin)}}},\
        "type":"assistant","uuid":"u","timestamp":"\(timestamp)","sessionId":"s1"}
        """
    }

    private func tail(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    private let t0 = "2026-09-16T12:00:00.000Z"
    private let t0Epoch = 1_789_560_000

    func testTheClockIsTheLastReplyAndItsTTL() {
        let clock = CacheClock.parse(tail: tail([
            assistantLine(at: "2026-09-16T11:00:00.000Z", fiveMin: 900),
            #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-09-16T11:59:00.000Z"}"#,
            assistantLine(at: t0, oneHour: 400),
            #"{"type":"system","subtype":"turn_duration","timestamp":"2026-09-16T12:00:05.000Z"}"#,
        ]))
        XCTAssertEqual(clock, CacheClock(lastReplyAt: t0Epoch, ttlSeconds: 3600))
    }

    func testAFiveMinuteWriteGivesAFiveMinuteTTL() {
        let clock = CacheClock.parse(tail: tail([assistantLine(at: t0, fiveMin: 900)]))
        XCTAssertEqual(clock?.ttlSeconds, 300)
    }

    func testAReadOnlyTurnTakesTheTTLOfTheLastWrite() {
        let clock = CacheClock.parse(tail: tail([
            assistantLine(at: "2026-09-16T11:00:00.000Z", fiveMin: 900),
            assistantLine(at: t0),
        ]))
        XCTAssertEqual(clock, CacheClock(lastReplyAt: t0Epoch, ttlSeconds: 300))
    }

    func testNoWriteInTheTailLeavesTheTTLUnknown() {
        let clock = CacheClock.parse(tail: tail([assistantLine(at: t0)]))
        XCTAssertEqual(clock, CacheClock(lastReplyAt: t0Epoch, ttlSeconds: nil))
    }

    func testASyntheticReplyDoesNotMoveTheClock() {
        // Claude Code writes `<synthetic>` entries (interrupts, API errors) that
        // never reach the API, so they do not refresh the cache.
        let clock = CacheClock.parse(tail: tail([
            assistantLine(at: t0, oneHour: 400),
            assistantLine(at: "2026-09-16T12:30:00.000Z", model: "<synthetic>"),
        ]))
        XCTAssertEqual(clock?.lastReplyAt, t0Epoch)
    }

    func testAPartialFirstLineAndJunkAreSkipped() {
        let clock = CacheClock.parse(tail: Data(
            ("ssistant\",\"timestamp\":\"2026-09-16T13:00:00.000Z\"}\nnot json\n"
                + assistantLine(at: t0, oneHour: 1) + "\n").utf8))
        XCTAssertEqual(clock, CacheClock(lastReplyAt: t0Epoch, ttlSeconds: 3600))
        XCTAssertNil(CacheClock.parse(tail: Data("{\"type\":\"user\"}\n".utf8)))
    }

    func testTimestampsWithoutFractionalSecondsParse() {
        XCTAssertEqual(
            CacheClock.parse(tail: tail([assistantLine(at: "2026-09-16T12:00:00Z")]))?.lastReplyAt,
            t0Epoch)
    }

    // MARK: 🥱 / 💤 stage

    private func stage(
        _ attention: AttentionStatus = .idle, idle: Int, ttl: Int? = 3600, since: Int? = nil
    ) -> IdleStage {
        AgentState.idleStage(
            attention: attention, cache: CacheClock(lastReplyAt: 100_000 - idle, ttlSeconds: ttl),
            statusSince: since, now: 100_000)
    }

    func testAnHourCacheYawnsForItsLastTenMinutesThenDozes() {
        XCTAssertEqual(stage(idle: 50 * 60 - 1), .awake)
        XCTAssertEqual(stage(idle: 50 * 60), .yawning)
        XCTAssertEqual(stage(idle: 60 * 60 - 1), .yawning)
        XCTAssertEqual(stage(idle: 60 * 60), .dozing)
    }

    func testAnUnknownTTLCountsAsAnHour() {
        XCTAssertEqual(stage(idle: 55 * 60, ttl: nil), .yawning)
        XCTAssertEqual(stage(idle: 65 * 60, ttl: nil), .dozing)
    }

    func testAFiveMinuteCacheNeverYawns() {
        XCTAssertEqual(stage(idle: 4 * 60, ttl: 300), .awake)
        XCTAssertEqual(stage(idle: 299, ttl: 300), .awake)
        XCTAssertEqual(stage(idle: 300, ttl: 300), .dozing)
    }

    func testOnlyIdleAgentsYawnOrDoze() {
        for attention in [AttentionStatus.waiting, .busy, .unknown] {
            XCTAssertEqual(stage(attention, idle: 55 * 60), .awake, "\(attention)")
            XCTAssertEqual(stage(attention, idle: 99 * 60), .awake, "\(attention)")
        }
    }

    func testTheTranscriptClockWinsOverTheStatusTime() {
        // Status changed 2h ago, but the last reply was 10 min ago: awake.
        XCTAssertEqual(stage(idle: 600, since: 100_000 - 7200), .awake)
    }

    func testWithoutATranscriptTheStatusTimeStillDozesButNeverYawns() {
        func fallback(_ idle: Int) -> IdleStage {
            AgentState.idleStage(attention: .idle, cache: nil, statusSince: 100_000 - idle, now: 100_000)
        }
        XCTAssertEqual(fallback(55 * 60), .awake)
        XCTAssertEqual(fallback(60 * 60), .dozing)
        XCTAssertEqual(
            AgentState.idleStage(attention: .idle, cache: nil, statusSince: nil, now: 100_000), .awake)
    }

    func testAWindowRollsUpItsAgentPanes() {
        XCTAssertEqual(AgentState.rollup([]), .awake)
        XCTAssertEqual(AgentState.rollup([.dozing, .dozing]), .dozing)
        XCTAssertEqual(AgentState.rollup([.yawning, .dozing]), .yawning)
        XCTAssertEqual(AgentState.rollup([.yawning]), .yawning)
        XCTAssertEqual(AgentState.rollup([.yawning, .awake]), .awake)
        XCTAssertEqual(AgentState.rollup([.dozing, .awake]), .awake)
    }

    func testAnUnknownTTLTakesTheFallbackTTL() {
        func unknown(_ idle: Int) -> IdleStage {
            AgentState.idleStage(
                attention: .idle, cache: CacheClock(lastReplyAt: 100_000 - idle, ttlSeconds: nil),
                statusSince: nil, now: 100_000, fallbackTTL: 300)
        }
        XCTAssertEqual(unknown(299), .awake)
        XCTAssertEqual(unknown(300), .dozing)
    }

    func testWithoutATranscriptTheStatusTimeDozesAtTheFallbackTTL() {
        func fallback(_ idle: Int) -> IdleStage {
            AgentState.idleStage(
                attention: .idle, cache: nil, statusSince: 100_000 - idle, now: 100_000,
                fallbackTTL: 300)
        }
        XCTAssertEqual(fallback(299), .awake)
        XCTAssertEqual(fallback(300), .dozing)
    }

    func testTheObservedTTLIsTheNewestKnownOne() {
        XCTAssertNil(AgentState.observedTTL([]))
        XCTAssertNil(AgentState.observedTTL([CacheClock(lastReplyAt: 50, ttlSeconds: nil)]))
        XCTAssertEqual(
            AgentState.observedTTL([
                CacheClock(lastReplyAt: 10, ttlSeconds: 3600),
                CacheClock(lastReplyAt: 30, ttlSeconds: 300),
                CacheClock(lastReplyAt: 50, ttlSeconds: nil),
            ]), 300)
    }

    func testSortedFallsBackToTheTTLItsOtherClaudeSessionsUse() {
        let session = TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
                TmuxPane(id: "%2", index: 1, command: "claude", title: "", active: false),
                TmuxPane(id: "%3", index: 2, command: "claude", title: "", active: false),
                TmuxPane(id: "%4", index: 3, command: "codex", title: "", active: false, pid: 10),
            ]),
        ])
        let sixMinutesAgo = 100_000 - 6 * 60
        let sorted = TmuxModel.sorted(
            sessions: [session], statuses: [:],
            paneStatuses: ["%1": .idle, "%2": .idle, "%3": .idle, "%4": .idle],
            paneSessionIds: ["%1": "s1", "%2": "s2"],
            paneStatusSince: ["%3": sixMinutesAgo, "%4": sixMinutesAgo],
            codexByPid: [11: "c1"], ppids: [11: 10],
            cacheClocks: [
                "s1": CacheClock(lastReplyAt: 100_000 - 60, ttlSeconds: 300),
                "s2": CacheClock(lastReplyAt: sixMinutesAgo, ttlSeconds: nil),
            ],
            now: 100_000)
        XCTAssertEqual(
            sorted[0].windows[0].panes.map(\.idleStage), [.awake, .dozing, .dozing, .awake],
            "a 5-minute user's unknown-TTL and transcript-less panes doze at 5 minutes; Codex keeps the hour")
    }

    func testSortedTakesAFallbackTTLObservedElsewhere() {
        let session = TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
            ]),
        ])
        let sorted = TmuxModel.sorted(
            sessions: [session], statuses: [:], paneStatuses: ["%1": .idle],
            paneStatusSince: ["%1": 100_000 - 6 * 60], fallbackTTL: 300, now: 100_000)
        XCTAssertEqual(sorted[0].windows[0].panes[0].idleStage, .dozing)
    }

    func testSortedUsesTheClaudeSessionsCacheClock() {
        let session = TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
                TmuxPane(id: "%2", index: 1, command: "claude", title: "", active: false),
                TmuxPane(id: "%3", index: 2, command: "zsh", title: "", active: false),
            ]),
        ])
        let sorted = TmuxModel.sorted(
            sessions: [session], statuses: [:], paneStatuses: ["%1": .idle, "%2": .idle],
            paneSessionIds: ["%1": "s1", "%2": "s2"], paneStatusSince: ["%1": 99_990, "%2": 99_990],
            cacheClocks: [
                "s1": CacheClock(lastReplyAt: 100_000 - 55 * 60, ttlSeconds: 3600),
                "s2": CacheClock(lastReplyAt: 100_000 - 65 * 60, ttlSeconds: nil),
            ],
            now: 100_000)
        let w = sorted[0].windows[0]
        XCTAssertEqual(w.panes.map(\.idleStage), [.yawning, .dozing, .awake])
        XCTAssertEqual(w.idleStage, .yawning, "every agent pane is 🥱 or 💤, one is 🥱")
    }

    // MARK: 🥱 transcript reader

    func testTheReaderReadsOnlyTheTailAndOnlyWhenTheFileChanges() throws {
        let projects = dir.appendingPathComponent("projects")
        let cwd = "/Users/me/code/my_app.v2"
        let folder = projects.appendingPathComponent("-Users-me-code-my-app-v2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        // A big old head the tail never reaches: a 5m write that must not count.
        let head = assistantLine(at: "2026-09-16T10:00:00.000Z", fiveMin: 9,
                                 text: String(repeating: "x", count: 200_000))
        try (head + "\n" + assistantLine(at: t0, oneHour: 5) + "\n").write(
            to: file, atomically: true, encoding: .utf8)

        let reader = TranscriptTailReader(projectsDir: projects, tailBytes: 4096)
        XCTAssertEqual(reader.read(sessionCwds: ["s1": cwd]).clocks,
                       ["s1": CacheClock(lastReplyAt: t0Epoch, ttlSeconds: 3600)])
        XCTAssertEqual(reader.readCount, 1)
        _ = reader.read(sessionCwds: ["s1": cwd]).clocks
        XCTAssertEqual(reader.readCount, 1, "an unchanged file is not read again")

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((assistantLine(at: "2026-09-16T12:10:00.000Z") + "\n").utf8))
        try handle.close()
        XCTAssertEqual(reader.read(sessionCwds: ["s1": cwd]).clocks["s1"]?.lastReplyAt, t0Epoch + 600)
        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(reader.read(sessionCwds: [:]).clocks, [:], "gone sessions are dropped")
    }

    func testTheReaderFindsATranscriptOutsideItsCwdFolder() throws {
        let projects = dir.appendingPathComponent("projects")
        let folder = projects.appendingPathComponent("-somewhere-else")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (assistantLine(at: t0, oneHour: 5) + "\n").write(
            to: folder.appendingPathComponent("s9.jsonl"), atomically: true, encoding: .utf8)
        let reader = TranscriptTailReader(projectsDir: projects)
        XCTAssertEqual(reader.read(sessionCwds: ["s9": "/moved"]).clocks["s9"]?.ttlSeconds, 3600)
        XCTAssertEqual(reader.read(sessionCwds: ["nope": "/x"]).clocks, [:])
    }

    func testParseSessionCwds() {
        let json = Data(#"[{"sessionId":"a","cwd":"/r/a","pane":"%1"},{"sessionId":"","cwd":"/x"},{"sessionId":"b"}]"#.utf8)
        XCTAssertEqual(TmuxModel.parseSessionCwds(fromSessionsJSON: json), ["a": "/r/a", "b": ""])
    }

    // MARK: 🥱 / 💤 tag

    func testYawnSwapsForDozeAndNeverShowsBoth() {
        let yawn = IdleTag.update(name: "pw 👀590", base: "pw", tags: "👀590", stage: .yawning)
        XCTAssertEqual(yawn?.name, "pw 👀590 🥱")
        let doze = IdleTag.update(name: "pw 👀590 🥱", base: "pw", tags: "👀590 🥱", stage: .dozing)
        XCTAssertEqual(doze?.tags, "👀590 💤")
        XCTAssertEqual(doze?.name, "pw 👀590 💤")
        let wake = IdleTag.update(name: "pw 🥱 👀590 💤", base: "pw", tags: "🥱 👀590 💤", stage: .awake)
        XCTAssertEqual(wake?.name, "pw 👀590")
        let fixBoth = IdleTag.update(name: "pw 🥱 💤", base: "pw", tags: "🥱 💤", stage: .yawning)
        XCTAssertEqual(fixBoth?.tags, "🥱")
        XCTAssertNil(IdleTag.update(name: "pw ✅ 🥱", base: "pw", tags: "✅ 🥱", stage: .yawning))
    }

    func testAYawningRowLeadsWithTheMarkerAndDropsBothTags() {
        var p = TmuxPane(id: "%7", index: 0, command: "2.1.273", title: "", active: false)
        p.attention = .idle
        p.idleStage = .yawning
        XCTAssertEqual(IdleTag.paneLabel(p), "🥱 %7 2.1.273")
        let w = TmuxWindow(index: 2, name: "acme 💤 👀9 🥱", active: false, panes: [p])
        XCTAssertEqual(IdleTag.windowLabel(w), "🥱 2: acme 👀9")
    }

    // MARK: 💤 tag

    func testTaggingAnUnnamedWindowAdoptsItsName() {
        let u = IdleTag.update(name: "2.1.268", base: "", tags: "", stage: .dozing)
        XCTAssertEqual(u?.base, "2.1.268")
        XCTAssertEqual(u?.tags, "💤")
        XCTAssertEqual(u?.name, "2.1.268 💤")
    }

    func testTaggingGoesAfterTheAgentsTags() {
        let u = IdleTag.update(name: "pw 👀590 ✅", base: "pw", tags: "👀590 ✅", stage: .dozing)
        XCTAssertEqual(u?.base, "pw")
        XCTAssertEqual(u?.tags, "👀590 ✅ 💤")
        XCTAssertEqual(u?.name, "pw 👀590 ✅ 💤")
    }

    func testUntaggingKeepsTheAgentsTags() {
        let u = IdleTag.update(name: "pw 💤 ✅", base: "pw", tags: "💤 ✅", stage: .awake)
        XCTAssertEqual(u?.base, "pw")
        XCTAssertEqual(u?.tags, "✅")
        XCTAssertEqual(u?.name, "pw ✅")
    }

    func testAWindowAlreadyRightIsLeftAlone() {
        XCTAssertNil(IdleTag.update(name: "pw ✅ 💤", base: "pw", tags: "✅ 💤", stage: .dozing))
        XCTAssertNil(IdleTag.update(name: "pw ✅", base: "pw", tags: "✅", stage: .awake))
        XCTAssertNil(IdleTag.update(name: "zsh", base: "", tags: "", stage: .awake))
    }

    // MARK: 💤 on window and pane rows

    private func dozingPane(_ id: String = "%1", active: Bool = false) -> TmuxPane {
        var p = TmuxPane(id: id, index: 0, command: "2.1.261", title: "", active: active)
        p.attention = .idle
        p.idleStage = .dozing
        return p
    }

    func testADozingWindowRowLeadsWithTheMarkerAndDropsTheTagFromItsName() {
        let w = TmuxWindow(index: 0, name: "acme-app 💤", active: true, panes: [dozingPane()])
        XCTAssertEqual(IdleTag.windowLabel(w), "💤 0: acme-app ●")
    }

    func testAnAwakeWindowRowHidesAStaleTagAndKeepsTheAgentsTags() {
        let w = TmuxWindow(index: 3, name: "hdr-dev 💤 👀116", active: false, panes: [
            TmuxPane(id: "%2", index: 0, command: "zsh", title: "", active: true),
        ])
        XCTAssertEqual(IdleTag.windowLabel(w), "3: hdr-dev 👀116")
    }

    func testOnlyTheTagWordIsStripped() {
        let w = TmuxWindow(index: 1, name: "nap💤time", active: false, panes: [])
        XCTAssertEqual(IdleTag.windowLabel(w), "1: nap💤time")
    }

    func testADozingPaneRowLeadsWithTheMarker() {
        XCTAssertEqual(IdleTag.paneLabel(dozingPane("%273", active: true)), "💤 %273 2.1.261 ◀")
        let shell = TmuxPane(id: "%452", index: 1, command: "zsh", title: "", active: false)
        XCTAssertEqual(IdleTag.paneLabel(shell), "%452 zsh")
    }

    func testARenameOutsideTmuxNameIsNeverReverted() {
        // Renamed to "new" while tagged: the stale base must not come back.
        XCTAssertNil(IdleTag.update(name: "new", base: "old", tags: "💤", stage: .awake))
        let u = IdleTag.update(name: "new", base: "old", tags: "✅", stage: .dozing)
        XCTAssertEqual(u?.base, "new")
        XCTAssertEqual(u?.tags, "💤")
        XCTAssertEqual(u?.name, "new 💤")
    }

    func testOnlyAMismatchThePollAlsoSawCountsAsARename() {
        let before = (name: "pw 👀590", base: "pw", tags: "👀590")
        XCTAssertTrue(IdleTag.isSettled(name: "pw 👀590", base: "pw", tags: "👀590", seen: before))
        XCTAssertTrue(IdleTag.isSettled(name: "zsh", base: "", tags: "", seen: before))
        XCTAssertFalse(IdleTag.isSettled(name: "pw 👀590", base: "pw", tags: "👀590 ✅", seen: before),
                       "the naming script between its options and its rename")
        XCTAssertTrue(IdleTag.isSettled(name: "new", base: "pw", tags: "👀590",
                                        seen: ("new", "pw", "👀590")))
    }

    /// Real tmux on a private server. An agent's tag command lands
    /// between the app's read and its write; the write must not drop that tag.
    func testSyncIdleTagKeepsATagWrittenBetweenReadAndWrite() throws {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("tmux is not installed") }
        // A short socket dir: tmux socket paths are capped near 104 bytes.
        let socketDir = "/tmp/mmzzz-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        env["TMUX_TMPDIR"] = socketDir
        // Without a UTF-8 locale tmux prints tabs and emoji as `_`.
        env["LANG"] = "en_US.UTF-8"
        let runner = RacingTmuxRunner(env: env)
        defer {
            _ = runner.run(tmux, ["kill-server"], stdin: nil)
            try? FileManager.default.removeItem(atPath: socketDir)
        }
        // A base with every character the format and command quoting must survive.
        let base = "fix, #W {it's} ; \"x\""
        let escaped = base.replacingOccurrences(of: "#", with: "##")
        XCTAssertNotNil(runner.run(tmux, ["-f", "/dev/null", "new-session", "-d", "-s", "zzz", "sleep 60"], stdin: nil))
        XCTAssertNotNil(runner.run(tmux, ["set-window-option", "-t", "=zzz:0", "@tn_base", base], stdin: nil))
        XCTAssertNotNil(runner.run(tmux, ["rename-window", "-t", "=zzz:0", escaped], stdin: nil))
        func read() -> String? {
            runner.run(tmux, ["display-message", "-p", "-t", "=zzz:0", IdleTag.optionsFormat], stdin: nil)?
                .trimmingCharacters(in: .newlines)
        }
        let service = TmuxService(runner: runner, statusProvider: nil, tmuxPath: tmux)
        /// One poll: the sidebar's read, then the driver-queue sync.
        func poll(_ stage: IdleStage) {
            let f = (read() ?? "").components(separatedBy: "\t")
            service.syncIdleTag(session: "zzz", window: 0, stage: stage, seen: (f[0], f[1], f[2]))
        }

        // What a tag command (👀590) writes, run right after the app's read.
        let seen = (base, base, "")
        runner.afterFirstRead = {
            _ = runner.run(tmux, ["set-window-option", "-t", "=zzz:0", "@tn_tags", "👀590"], stdin: nil)
            _ = runner.run(tmux, ["rename-window", "-t", "=zzz:0", "\(escaped) 👀590"], stdin: nil)
        }
        service.syncIdleTag(session: "zzz", window: 0, stage: .dozing, seen: seen)
        XCTAssertEqual(read(), "\(base) 👀590\t\(base)\t👀590", "the agent's tag survives")

        poll(.yawning)
        XCTAssertEqual(read(), "\(base) 👀590 🥱\t\(base)\t👀590 🥱", "the next poll adds 🥱")
        poll(.dozing)
        XCTAssertEqual(read(), "\(base) 👀590 💤\t\(base)\t👀590 💤", "💤 replaces 🥱")
        poll(.dozing)
        XCTAssertEqual(read(), "\(base) 👀590 💤\t\(base)\t👀590 💤", "a steady poll changes nothing")

        poll(.awake)
        XCTAssertEqual(read(), "\(base) 👀590\t\(base)\t👀590", "waking removes only 💤")

        // A tag command (✅) caught between its option writes and its rename.
        let settled = (name: "\(base) 👀590", base: base, tags: "👀590")
        XCTAssertNotNil(runner.run(tmux, ["set-window-option", "-t", "=zzz:0", "@tn_tags", "👀590 ✅"], stdin: nil))
        service.syncIdleTag(session: "zzz", window: 0, stage: .dozing, seen: settled)
        XCTAssertEqual(read(), "\(base) 👀590\t\(base)\t👀590 ✅", "a half-written name is left alone")
        XCTAssertNotNil(runner.run(tmux, ["rename-window", "-t", "=zzz:0", "\(escaped) 👀590 ✅"], stdin: nil))
        poll(.dozing)
        XCTAssertEqual(read(), "\(base) 👀590 ✅ 💤\t\(base)\t👀590 ✅ 💤")

        // A rename from outside that the poll saw too is taken as the new base.
        XCTAssertNotNil(runner.run(tmux, ["rename-window", "-t", "=zzz:0", "renamed"], stdin: nil))
        poll(.dozing)
        XCTAssertEqual(read(), "renamed 💤\trenamed\t💤")
    }

    private func claudeSession() -> TmuxSession {
        TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
            ]),
        ])
    }

    // MARK: toasts

    private func session(_ states: [AgentPaneState?]) -> TmuxSession {
        TmuxSession(name: "work", attached: true, windows: [
            TmuxWindow(index: 3, name: "agent-hooks", active: true, panes: states.enumerated().map {
                TmuxPane(id: "%\($0.offset)", index: $0.offset, command: "claude", title: "",
                         active: $0.offset == 0, agentState: $0.element)
            }),
        ])
    }

    func testEachEntryIntoAStateToastsOnce() {
        var tracker = AgentToastTracker()
        let done = AgentPaneState(sessionId: "s1", state: .done, since: 1000)
        XCTAssertEqual(tracker.toasts(in: [session([done])], now: 1001).map(\.state), [.done])
        XCTAssertEqual(tracker.toasts(in: [session([done])], now: 1002), [])
        // A second turn that finished between two refreshes is a new entry.
        let again = AgentPaneState(sessionId: "s1", state: .done, since: 1010)
        XCTAssertEqual(tracker.toasts(in: [session([again])], now: 1011).count, 1)
    }

    func testOnlyRecentWaitingAndDoneToast() {
        var tracker = AgentToastTracker()
        let old = AgentPaneState(
            sessionId: "old", state: .done, since: 1000 - AgentState.toastRecentSeconds - 1)
        let busy = AgentPaneState(sessionId: "busy", state: .busy, since: 1000)
        let idle = AgentPaneState(sessionId: "idle", state: .idle, since: 1000)
        XCTAssertEqual(tracker.toasts(in: [session([old, busy, idle, nil])], now: 1000), [])
        // Seen once while old, it stays quiet.
        XCTAssertEqual(tracker.toasts(in: [session([old])], now: 1000), [])
    }

    func testWaitingToastsBeforeDone() {
        var tracker = AgentToastTracker()
        let toasts = tracker.toasts(in: [session([
            AgentPaneState(sessionId: "d", state: .done, since: 1005),
            AgentPaneState(sessionId: "w", state: .waiting, since: 1000),
        ])], now: 1006)
        XCTAssertEqual(toasts.map(\.sessionId), ["w", "d"])
        XCTAssertEqual(toasts.map(\.visible), [false, true])
        XCTAssertEqual(toasts.first?.windowIndex, 3)
    }

    func testToastTextCarriesTheThreadLink() {
        let toast = AgentToast(
            sessionId: "s1", state: .waiting, since: 0, session: "mux-maestro",
            windowIndex: 7, windowName: "agent-hooks", visible: false)
        XCTAssertEqual(AgentState.threadLink(toast), "mux-maestro:7")
        XCTAssertEqual(AgentState.toastText(toast), "Needs you · agent-hooks\nmux-maestro:7")
    }

    // MARK: store

    func testStoreSkipsEndedAndUnknownStatesAndClears() throws {
        try event(["hook_event_name": "Stop"], session: "live")
        try event(["hook_event_name": "SessionEnd", "reason": "other"], session: "gone")
        _ = try sql("INSERT INTO agent_state(session_id, agent, state, since, updated_at) "
            + "VALUES('future', 'claude', 'thinking', 0, 0);")
        let store = try ManagerStore(dbPath: dbPath)
        XCTAssertEqual(try store.agentStates().map(\.sessionId), ["live"])
        try store.clearAgentStates()
        XCTAssertEqual(try store.agentStates(), [])
    }

    // MARK: helpers

    /// Run `mux event <agent>` with `fields` over a default session id and cwd,
    /// and assert it behaved as a hook must: exit 0, nothing printed.
    private func event(
        _ fields: [String: Any], agent: String = "claude", session: String = "s1",
        pane: String? = "%7"
    ) throws {
        var payload: [String: Any] = ["session_id": session, "cwd": "/repo"]
        payload.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let result = runMux(["event", agent], stdin: data, pane: pane)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "")
    }

    private func row(_ session: String = "s1") throws -> AgentStateRow? {
        try ManagerStore(dbPath: dbPath).agentStates().first { $0.sessionId == session }
    }

    private var muxPath: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("../app/MuxMaestro/Resources/manager/mux")
            .standardizedFileURL
    }

    private func runMux(
        _ args: [String], stdin: Data, pane: String?, db: String? = nil
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [muxPath.path] + args
        var env = ProcessInfo.processInfo.environment
        env["MUX_MANAGER_DB"] = db ?? dbPath
        env["TMUX_PANE"] = pane
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return (-1, "spawn failed: \(error)")
        }
        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func sql(_ query: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Line 2: the user's last prompt

extension AgentStateTests {
    /// Claude Code transcript lines, shaped like the real ones.
    private func claudeUser(_ content: String, at timestamp: String = "2026-09-16T12:00:00.000Z",
                            extra: String = "") -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":\#(content)},"uuid":"u","timestamp":"\#(timestamp)"\#(extra)}"#
    }

    private func json(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), as: UTF8.self)
    }

    private var claudeToolResult: String {
        claudeUser(#"[{"tool_use_id":"toolu_1","type":"tool_result","content":"file.txt"}]"#,
                   at: "2026-09-16T12:05:00.000Z", extra: #","toolUseResult":{"stdout":"file.txt"}"#)
    }

    private var claudeAssistant: String {
        #"{"type":"assistant","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"done"}]},"timestamp":"2026-09-16T12:06:00.000Z"}"#
    }

    func testTheLastPromptIsTheLatestHumanEntry() {
        let prompt = LastPrompt.parse(claudeTail: tail([
            claudeUser(json("old prompt"), at: "2026-09-16T11:00:00.000Z"),
            claudeUser(json("fix the sidebar"), at: "2026-09-16T12:00:00.000Z"),
            claudeAssistant,
            claudeToolResult,
            claudeAssistant,
        ]))
        XCTAssertEqual(prompt, LastPrompt(text: "fix the sidebar", at: t0Epoch))
    }

    func testMetaCommandAndInterruptEntriesAreNotPrompts() {
        let prompt = LastPrompt.parse(claudeTail: tail([
            claudeUser(json("the real one")),
            claudeUser(json("Base directory for this skill: /x"), extra: #","isMeta":true"#),
            claudeUser(json("<command-name>/clear</command-name>\n<command-message>clear</command-message>")),
            claudeUser(json("<local-command-stdout>Set model</local-command-stdout>")),
            claudeUser(json("<task-notification>\n<task-id>b1</task-id>")),
            claudeUser(json("  <system-reminder>hi</system-reminder>")),
            claudeUser(#"[{"type":"text","text":"[Request interrupted by user]"}]"#),
            claudeUser(json("This session is being continued from a previous conversation"),
                       extra: #","isCompactSummary":true"#),
        ]))
        XCTAssertEqual(prompt?.text, "the real one")
    }

    /// A `!` shell command and a message typed while the agent was busy are the
    /// user's input too. Queued task notifications and peer messages are not.
    func testAShellCommandAndAQueuedMessageArePrompts() {
        func queued(_ prompt: String, mode: String, origin: String?, at: String) -> String {
            let o = origin.map { #","origin":{"kind":"\#($0)"}"# } ?? ""
            return #"{"parentUuid":"p","type":"attachment","attachment":{"type":"queued_command","prompt":\#(json(prompt)),"commandMode":"\#(mode)"\#(o)},"userType":"external","timestamp":"\#(at)"}"#
        }
        let shell = LastPrompt.parse(claudeTail: tail([
            claudeUser(json("older"), at: "2026-09-16T11:00:00.000Z"),
            claudeUser(json("<bash-input> cd ~/x && make test</bash-input>")),
            claudeUser(json("<bash-stdout>ok</bash-stdout><bash-stderr></bash-stderr>"),
                       at: "2026-09-16T12:00:01.000Z"),
            claudeAssistant,
        ]))
        XCTAssertEqual(shell, LastPrompt(text: "! cd ~/x && make test", at: t0Epoch))

        let queuedPrompt = LastPrompt.parse(claudeTail: tail([
            claudeUser(json("older"), at: "2026-09-16T11:00:00.000Z"),
            queued("like an icon\nor format", mode: "prompt", origin: "human", at: t0),
            claudeToolResult,
            queued("<task-notification>", mode: "task-notification", origin: nil, at: "2026-09-16T12:10:00.000Z"),
            queued("<cross-session-message>", mode: "prompt", origin: "peer", at: "2026-09-16T12:11:00.000Z"),
        ]))
        XCTAssertEqual(queuedPrompt, LastPrompt(text: "like an icon", at: t0Epoch))
    }

    func testAMultiLinePromptShowsItsFirstNonEmptyLine() {
        let prompt = LastPrompt.parse(claudeTail: tail([
            claudeUser(json("\n\n   two line rows please  \nsecond line\nthird")),
        ]))
        XCTAssertEqual(prompt?.text, "two line rows please")
    }

    func testArrayContentUsesTheFirstTextBlock() {
        let prompt = LastPrompt.parse(claudeTail: tail([
            claudeUser(#"[{"type":"image","source":{"type":"base64","data":"AAAA"}},{"type":"text","text":"what is this [Image #1]"},{"type":"text","text":"later"}]"#),
        ]))
        XCTAssertEqual(prompt?.text, "what is this [Image #1]")
    }

    func testNoPromptInTheTail() {
        XCTAssertNil(LastPrompt.parse(claudeTail: tail([claudeAssistant, claudeToolResult])))
        XCTAssertNil(LastPrompt.parse(claudeTail: tail([claudeUser(json("   \n  "))])))
        // A cut first line and junk are skipped, not fatal.
        XCTAssertEqual(
            LastPrompt.parse(claudeTail: Data(("\"user\",\"content\":\"cut\"}\nnot json\n"
                + claudeUser(json("whole")) + "\n").utf8))?.text,
            "whole")
    }

    func testALongPromptIsCappedForTheRow() {
        let prompt = LastPrompt.parse(claudeTail: tail([claudeUser(json(String(repeating: "a", count: 5000)))]))
        XCTAssertEqual(prompt?.text.count, LastPrompt.maxLength)
    }

    // Codex rollouts. Checked against real files (codex-cli 0.147–0.154): a TUI
    // main thread records the human prompt only as a `response_item` user message;
    // `event_msg` / `user_message` appears in guardian subagent rollouts, so both
    // shapes count.

    private func codexUser(_ text: String, at timestamp: String = "2026-09-16T12:00:00.000Z") -> String {
        #"{"timestamp":"\#(timestamp)","ordinal":5,"type":"response_item","payload":{"type":"message","id":"msg_1","role":"user","content":[{"type":"input_text","text":\#(json(text))}]}}"#
    }

    func testCodexTakesTheLastUserMessageAndSkipsContextBlocks() {
        let prompt = LastPrompt.parse(codexTail: tail([
            codexUser("<environment_context>\n  <cwd>/x</cwd>", at: "2026-09-16T11:00:00.000Z"),
            codexUser("for the GitHub pull requests\nmore"),
            #"{"timestamp":"2026-09-16T12:00:01.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
            #"{"timestamp":"2026-09-16T12:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}"#,
            #"{"timestamp":"2026-09-16T12:00:03.000Z","type":"event_msg","payload":{"type":"token_count"}}"#,
            codexUser("<environment_context>\n  <cwd>/y</cwd>", at: "2026-09-16T12:00:04.000Z"),
        ]))
        XCTAssertEqual(prompt, LastPrompt(text: "for the GitHub pull requests", at: t0Epoch))
    }

    func testCodexUserMessageEventsCount() {
        let prompt = LastPrompt.parse(codexTail: tail([
            codexUser("older", at: "2026-09-16T11:00:00.000Z"),
            #"{"timestamp":"2026-09-16T12:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"newer\nline two","images":[]}}"#,
        ]))
        XCTAssertEqual(prompt, LastPrompt(text: "newer", at: t0Epoch))
    }

    // MARK: Line 2 — transcript reader

    private func writeLines(_ lines: [String], to file: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func append(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    /// `n` tool-result lines of about `bytes` each: a tool loop with no prompt.
    private func toolLoop(_ n: Int, bytes: Int = 1000) -> [String] {
        (0..<n).map { _ in
            claudeUser(#"[{"tool_use_id":"t","type":"tool_result","content":"\#(String(repeating: "x", count: bytes))"}]"#)
        }
    }

    func testTheReaderGrowsPastAToolLoopToFindThePrompt() throws {
        let projects = dir.appendingPathComponent("projects")
        let folder = projects.appendingPathComponent("-w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        // 40 KB of tool results after the prompt; the first tail is 4 KB.
        try writeLines([claudeUser(json("start the loop"))] + toolLoop(40) + [
            assistantLine(at: t0, oneHour: 5),
        ], to: file)

        let reader = TranscriptTailReader(projectsDir: projects, tailBytes: 4096, promptCapBytes: 128_000)
        let tails = reader.read(sessionCwds: ["s1": "/w"])
        XCTAssertEqual(tails.prompts["s1"]?.text, "start the loop")
        XCTAssertEqual(tails.clocks["s1"]?.ttlSeconds, 3600, "the cache clock still reads")
        XCTAssertEqual(reader.readCount, 1)
        _ = reader.read(sessionCwds: ["s1": "/w"])
        XCTAssertEqual(reader.readCount, 1, "an unchanged file is not read again")
    }

    func testThePromptSearchStopsAtItsCap() throws {
        let folder = dir.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeLines([claudeUser(json("too far back"))] + toolLoop(60),
                       to: folder.appendingPathComponent("s1.jsonl"))
        let reader = TranscriptTailReader(
            projectsDir: dir.appendingPathComponent("projects"), tailBytes: 4096, promptCapBytes: 16_000)
        XCTAssertNil(reader.read(sessionCwds: ["s1": "/w"]).prompts["s1"])
    }

    func testAnAppendOnlySearchesTheNewBytes() throws {
        let folder = dir.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        try writeLines([claudeUser(json("first"))], to: file)
        let reader = TranscriptTailReader(
            projectsDir: dir.appendingPathComponent("projects"), tailBytes: 4096, promptCapBytes: 16_000)
        XCTAssertEqual(reader.read(sessionCwds: ["s1": "/w"]).prompts["s1"]?.text, "first")

        // A tool loop pushes the prompt past the cap: the known prompt stands.
        try append(toolLoop(60), to: file)
        XCTAssertEqual(reader.read(sessionCwds: ["s1": "/w"]).prompts["s1"]?.text, "first")
        XCTAssertEqual(reader.readCount, 2)

        try append([claudeUser(json("second"), at: "2026-09-16T12:30:00.000Z")] + toolLoop(3), to: file)
        let next = reader.read(sessionCwds: ["s1": "/w"]).prompts["s1"]
        XCTAssertEqual(next, LastPrompt(text: "second", at: t0Epoch + 1800))

        // A rewritten (shorter) file starts over.
        try writeLines(toolLoop(2), to: file)
        XCTAssertNil(reader.read(sessionCwds: ["s1": "/w"]).prompts["s1"])
    }

    func testAPromptWrittenAcrossTwoPollsIsNotMissed() throws {
        let folder = dir.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        let line = claudeUser(json("half written"))
        let cut = line.index(line.startIndex, offsetBy: 40)
        try (claudeUser(json("before")) + "\n" + line[..<cut]).write(to: file, atomically: true, encoding: .utf8)
        let reader = TranscriptTailReader(projectsDir: dir.appendingPathComponent("projects"), tailBytes: 4096)
        XCTAssertEqual(reader.read(sessionCwds: ["s1": "/w"]).prompts["s1"]?.text, "before")
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((line[cut...] + "\n").utf8))
        try handle.close()
        XCTAssertEqual(reader.read(sessionCwds: ["s1": "/w"]).prompts["s1"]?.text, "half written")
    }

    func testTheReaderReadsCodexRollouts() throws {
        let file = dir.appendingPathComponent("rollout-2026-09-16T12-00-00-c1.jsonl")
        try writeLines([codexUser("<environment_context>"), codexUser("ship it")], to: file)
        let reader = TranscriptTailReader(projectsDir: dir.appendingPathComponent("none"))
        let tails = reader.read(sessionCwds: [:], codexRollouts: ["c1": file.path])
        XCTAssertEqual(tails.prompts, ["c1": LastPrompt(text: "ship it", at: t0Epoch)])
        XCTAssertEqual(tails.clocks, [:], "Codex has no cache clock")
    }

    /// The last write is the newest timestamped entry, not the file's mtime.
    /// Claude Code appends untimestamped bookkeeping (`last-prompt`, `cost-state`,
    /// `ai-title`) to idle transcripts, which bumps the mtime of threads nobody
    /// has touched for hours.
    func testTheReaderReportsWhenEachTranscriptWasLastWritten() throws {
        let folder = dir.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        try writeLines([
            claudeUser(json("hi")),
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]},"timestamp":"2026-09-16T12:01:30.000Z"}"#,
            #"{"type":"last-prompt","lastPrompt":"hi","sessionId":"s1"}"#,
            #"{"type":"cost-state","sessionId":"s1"}"#,
        ], to: file)
        let touched = Date(timeIntervalSince1970: TimeInterval(t0Epoch + 7200))
        try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: file.path)
        let reader = TranscriptTailReader(projectsDir: dir.appendingPathComponent("projects"))
        XCTAssertEqual(reader.read(sessionCwds: ["s1": "/w"]).lastWrites, ["s1": t0Epoch + 90])

        // More bookkeeping later changes nothing.
        try append([#"{"type":"ai-title","aiTitle":"x"}"#], to: file)
        XCTAssertEqual(reader.read(sessionCwds: ["s1": "/w"]).lastWrites, ["s1": t0Epoch + 90])
    }

    // MARK: Line 2 — panes and windows

    func testSortedGivesEachAgentPaneItsPromptAndTheWindowTheNewest() {
        let session = TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
                TmuxPane(id: "%2", index: 1, command: "codex", title: "", active: false, pid: 10),
                TmuxPane(id: "%3", index: 2, command: "zsh", title: "", active: false),
            ]),
        ])
        let sorted = TmuxModel.sorted(
            sessions: [session], statuses: [:], paneStatuses: ["%1": .idle],
            paneSessionIds: ["%1": "s1"],
            codexByPid: [11: "c1"], ppids: [11: 10],
            lastPrompts: [
                "s1": LastPrompt(text: "older", at: 100),
                "c1": LastPrompt(text: "newer", at: 200),
            ])
        let w = sorted[0].windows[0]
        XCTAssertEqual(w.panes.map { $0.lastPrompt?.text }, ["older", "newer", nil])
        XCTAssertEqual(w.lastPrompt?.text, "newer")
    }

    func testSortedGivesEachAgentPaneItsLastWriteAndTheWindowTheNewest() {
        let session = TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
                TmuxPane(id: "%2", index: 1, command: "codex", title: "", active: false, pid: 10),
                TmuxPane(id: "%3", index: 2, command: "zsh", title: "", active: false),
            ]),
        ])
        let sorted = TmuxModel.sorted(
            sessions: [session], statuses: [:], paneStatuses: ["%1": .idle],
            paneSessionIds: ["%1": "s1"],
            codexByPid: [11: "c1"], ppids: [11: 10],
            lastWrites: ["s1": 500, "c1": 300])
        let w = sorted[0].windows[0]
        XCTAssertEqual(w.panes.map(\.lastActivityAt), [500, 300, nil])
        XCTAssertEqual(w.lastActivityAt, 500)
    }

    func testByRecentPutsTheNewestPromptFirstAndPromptlessWindowsLastInIndexOrder() {
        func window(_ index: Int, prompt: Int?, activity: Int? = nil) -> TmuxWindow {
            var p = TmuxPane(id: "%\(index)", index: 0, command: "claude", title: "", active: false)
            p.lastPrompt = prompt.map { LastPrompt(text: "p", at: $0) }
            p.lastActivityAt = activity
            return TmuxWindow(index: index, name: "w\(index)", active: false, panes: [p])
        }
        let windows = [window(0, prompt: 100), window(1, prompt: nil), window(2, prompt: 300),
                       window(3, prompt: nil), window(4, prompt: 100)]
        XCTAssertEqual(TmuxWindow.byRecent(windows).map(\.index), [2, 0, 4, 1, 3])
    }

    /// Agent writes must not reorder rows: only the user's prompt counts.
    func testByRecentIgnoresAgentActivity() {
        func window(_ index: Int, prompt: Int, activity: Int) -> TmuxWindow {
            var p = TmuxPane(id: "%\(index)", index: 0, command: "claude", title: "", active: false)
            p.lastPrompt = LastPrompt(text: "p", at: prompt)
            p.lastActivityAt = activity
            return TmuxWindow(index: index, name: "w\(index)", active: false, panes: [p])
        }
        let windows = [window(0, prompt: 200, activity: 210), window(1, prompt: 100, activity: 999)]
        XCTAssertEqual(TmuxWindow.byRecent(windows).map(\.index), [0, 1])
    }

    func testAWindowWithNoAgentPromptHasNone() {
        let w = TmuxWindow(index: 0, name: "zsh", active: true, panes: [
            TmuxPane(id: "%1", index: 0, command: "zsh", title: "", active: true),
        ])
        XCTAssertNil(w.lastPrompt)
    }
}
