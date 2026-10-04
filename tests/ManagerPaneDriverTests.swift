import XCTest

// ManagerPaneDriver.swift compiles directly into this test target (no app host /
// @testable import), same as the other logic tests. The transcript fixtures are
// real Claude Code JSONL shapes; the watcher is driven by a synthetic clock and
// the driver by a fake CommandRunner over a temp ~/.claude.
final class ManagerPaneDriverTests: XCTestCase {

    // MARK: Fixtures

    /// A plainly typed prompt: content is a bare string.
    private let userPrompt = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    /// Thinking never reaches the reply.
    private let thinking = #"""
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}],"stop_reason":null}}
    """#
    /// The first segment of a reply, before a tool call.
    private let textOne = #"""
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First part."}],"stop_reason":"tool_use"}}
    """#
    private let toolUse = #"""
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Read","input":{"file":"x"}}],"stop_reason":"tool_use"}}
    """#
    private let toolResult = #"""
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"ok"}]}}
    """#
    /// The final segment: a terminal stop_reason.
    private let textTwo = #"""
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Second part."}],"stop_reason":"end_turn"}}
    """#
    /// A harness note the human never typed.
    private let metaUser = #"""
    {"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: this is a note."}}
    """#
    /// Mid-append: the last line of a live transcript is routinely half written.
    private let halfLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tex"#
    /// An older build that omits stop_reason entirely.
    private let legacyText = #"""
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Legacy."}]}}
    """#

    private var wholeTurn: [String] {
        [userPrompt, thinking, textOne, toolUse, toolResult, textTwo, halfLine]
    }

    // MARK: assistantText

    func testAssistantTextSkipsThinkingToolUseAndHalfLines() {
        let text = ManagerTranscript.assistantText(lines: wholeTurn, after: 0)
        XCTAssertEqual(text, "First part.\nSecond part.")
    }

    func testAssistantTextHonoursStartLine() {
        // Start after the first reply segment: only the tail is new.
        let text = ManagerTranscript.assistantText(lines: wholeTurn, after: 3)
        XCTAssertEqual(text, "Second part.")
        XCTAssertEqual(ManagerTranscript.assistantText(lines: wholeTurn, after: 99), "")
    }

    // MARK: tool call in flight

    func testToolCallInFlightUntilItsResultLands() {
        XCTAssertTrue(ManagerTranscript.toolCallInFlight(lines: [userPrompt, toolUse], after: 0))
        XCTAssertFalse(ManagerTranscript.toolCallInFlight(
            lines: [userPrompt, toolUse, toolResult], after: 0))
        XCTAssertFalse(ManagerTranscript.toolCallInFlight(lines: [userPrompt], after: 0))
    }

    // MARK: stop_reason

    func testTurnEndedFollowsTheLastStopReason() {
        XCTAssertFalse(ManagerTranscript.turnEnded(lines: [userPrompt, textOne, toolUse], after: 0))
        XCTAssertTrue(ManagerTranscript.turnEnded(lines: wholeTurn, after: 0))
    }

    func testHasStopDataFalseWithoutTheField() {
        XCTAssertFalse(ManagerTranscript.hasStopData(lines: [userPrompt, legacyText], after: 0))
        XCTAssertTrue(ManagerTranscript.hasStopData(lines: [userPrompt, textTwo], after: 0))
        // A null stop_reason is still stop DATA; it just isn't terminal.
        XCTAssertTrue(ManagerTranscript.hasStopData(lines: [thinking], after: 0))
        XCTAssertFalse(ManagerTranscript.turnEnded(lines: [thinking], after: 0))
    }

    // MARK: lastReplyText

    func testLastReplyTextWalksBackToTheNewestTurnThatSpoke() {
        let oldAnswer = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Old answer."}],"stop_reason":"end_turn"}}
        """#
        let secondPrompt = #"{"type":"user","message":{"role":"user","content":"second question"}}"#
        let slashEcho = #"""
        {"type":"user","message":{"role":"user","content":"<command-message>voice</command-message>"}}
        """#
        let lines = [
            userPrompt, oldAnswer,
            secondPrompt, toolUse, toolResult, textTwo, metaUser,
            slashEcho,  // the newest turn said nothing; the walk keeps going back
        ]
        XCTAssertEqual(ManagerTranscript.lastReplyText(lines: lines), "Second part.")
    }

    func testLastReplyTextEmptyTranscript() {
        XCTAssertEqual(ManagerTranscript.lastReplyText(lines: []), "")
        XCTAssertEqual(ManagerTranscript.lastReplyText(lines: [halfLine]), "")
    }

    // MARK: status mapping

    func testAgentStateFoldsOntoTurnStatus() {
        XCTAssertEqual(ManagerPaneDriver.status(for: .waiting), .waiting)
        XCTAssertEqual(ManagerPaneDriver.status(for: .busy), .busy)
        XCTAssertEqual(ManagerPaneDriver.status(for: .idle), .idle)
        XCTAssertEqual(ManagerPaneDriver.status(for: .done), .idle)
        XCTAssertNil(ManagerPaneDriver.status(for: .ended))
    }

    // MARK: Watcher — (a) a plain stop

    func testWatcherStopEmitsDeltasInOrderThenDone() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []

        XCTAssertNil(feed(&watcher, &deltas, at: 0, .busy, []))
        XCTAssertNil(feed(&watcher, &deltas, at: 0.4, .busy, [userPrompt, textOne]))
        XCTAssertNil(feed(&watcher, &deltas, at: 0.8, .busy, [userPrompt, textOne, textTwo]))
        // Idle, but not quiet long enough yet.
        XCTAssertNil(feed(&watcher, &deltas, at: 0.9, .idle, [userPrompt, textOne, textTwo]))
        let outcome = feed(&watcher, &deltas, at: 1.5, .idle, [userPrompt, textOne, textTwo])

        XCTAssertEqual(outcome, .done(reply: "First part.\nSecond part."))
        XCTAssertEqual(deltas, ["First part.", "\nSecond part."])
        XCTAssertEqual(deltas.joined(), "First part.\nSecond part.", "no text emitted twice")
    }

    // MARK: Watcher — (b) a tool call in flight

    func testWatcherDoesNotFinishWhileAToolCallIsInFlight() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []
        let inFlight = [userPrompt, textOne, toolUse]

        XCTAssertNil(feed(&watcher, &deltas, at: 0, .busy, []))
        XCTAssertNil(feed(&watcher, &deltas, at: 0.5, .busy, inFlight))
        // A long quiet gap with the pane already idle must NOT end the turn.
        XCTAssertNil(feed(&watcher, &deltas, at: 5, .idle, inFlight))

        let finished = inFlight + [toolResult, textTwo]
        XCTAssertNil(feed(&watcher, &deltas, at: 5.2, .idle, finished))
        let outcome = feed(&watcher, &deltas, at: 6, .idle, finished)
        XCTAssertEqual(outcome, .done(reply: "First part.\nSecond part."))
    }

    // MARK: Watcher — (c) permission, then resume

    func testWatcherPermissionThenResumeEmitsOnlyPostApprovalText() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []
        let before = [userPrompt, textOne]

        XCTAssertNil(feed(&watcher, &deltas, at: 0, .busy, before))
        XCTAssertEqual(feed(&watcher, &deltas, at: 0.4, .waiting, before),
                       .permission(reply: "First part."))
        XCTAssertEqual(deltas, ["First part."])

        deltas = []
        watcher.resume(fromLine: before.count, at: 0.4)
        // Still on the prompt: silence, no outcome.
        XCTAssertNil(feed(&watcher, &deltas, at: 0.6, .waiting, before))
        // Approved at the keyboard: status leaves waiting.
        XCTAssertNil(feed(&watcher, &deltas, at: 1.0, .busy, before))
        let after = before + [textTwo]
        XCTAssertNil(feed(&watcher, &deltas, at: 1.4, .busy, after))
        XCTAssertEqual(feed(&watcher, &deltas, at: 2.2, .idle, after), .done(reply: "Second part."))
        XCTAssertEqual(deltas, ["Second part."], "the pre-approval text is never re-emitted")
    }

    func testWatcherNeverApprovedReportsPermissionAgain() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []
        let before = [userPrompt, textOne]
        XCTAssertEqual(feed(&watcher, &deltas, at: 0, .waiting, before),
                       .permission(reply: "First part."))
        watcher.resume(fromLine: before.count, at: 0)
        XCTAssertNil(feed(&watcher, &deltas, at: 100, .waiting, before))
        XCTAssertEqual(watcher.phase, .awaitingApproval)
        // Past approvalWait the watcher gives up; the driver reads the phase to
        // tell this "pending" from a second prompt in a resumed turn.
        XCTAssertEqual(feed(&watcher, &deltas, at: ManagerTurnWatcher.approvalWait + 1,
                            .waiting, before), .permission(reply: ""))
        XCTAssertEqual(watcher.phase, .awaitingApproval)
    }

    // MARK: Watcher — (d) the transcript appears mid-turn

    func testWatcherPicksUpATranscriptThatAppearsMidTurn() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []
        XCTAssertNil(feed(&watcher, &deltas, at: 0, nil, []))
        XCTAssertNil(feed(&watcher, &deltas, at: 0.2, nil, []))
        // A fresh session writes its whole transcript at once; every line is new.
        let lines = [userPrompt, textTwo]
        XCTAssertNil(feed(&watcher, &deltas, at: 2, nil, lines))
        XCTAssertEqual(feed(&watcher, &deltas, at: 6.5, nil, lines), .done(reply: "Second part."))
        XCTAssertEqual(deltas, ["Second part."])
    }

    // MARK: Watcher — (e) no status source at all

    func testWatcherStatuslessFallsBackToTranscriptQuiet() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []
        let lines = [userPrompt, textTwo]
        XCTAssertNil(feed(&watcher, &deltas, at: 0.2, nil, lines))
        // Quiet, but not yet the status-less fallback window.
        XCTAssertNil(feed(&watcher, &deltas, at: 3.5, nil, lines))
        XCTAssertEqual(feed(&watcher, &deltas, at: 4.3, nil, lines), .done(reply: "Second part."))
    }

    // MARK: Watcher — (f) nothing ever stirs

    func testWatcherGraceEndsATurnThatNeverStarted() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []
        XCTAssertNil(feed(&watcher, &deltas, at: 1, nil, []))
        XCTAssertNil(feed(&watcher, &deltas, at: 5.9, nil, []))
        // Never a silent empty `.done`: the rail would show nothing at all.
        XCTAssertEqual(feed(&watcher, &deltas, at: 6, nil, []),
                       .unreachable(ManagerTurnWatcher.neverStarted))
        XCTAssertEqual(deltas, [])
    }

    // MARK: Watcher — (g) the hard ceiling

    func testWatcherHardTimeout() {
        var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
        var deltas: [String] = []
        let stuck = [userPrompt, textOne, toolUse]
        XCTAssertNil(feed(&watcher, &deltas, at: 0, .busy, []))
        XCTAssertNil(feed(&watcher, &deltas, at: 1, .busy, stuck))
        XCTAssertNil(feed(&watcher, &deltas, at: 80, .busy, stuck))
        XCTAssertEqual(feed(&watcher, &deltas, at: 90.5, .busy, stuck),
                       .timeout(reply: "First part."))
    }

    // MARK: Session lookup

    func testSessionIdPicksTheRightFileAndIgnoresUnreadableOnes() throws {
        let dir = try makeClaudeDir()
        let sessions = dir.appendingPathComponent("sessions")
        try "not json at all".write(
            to: sessions.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try write(["sessionId": "other", "tmux": "other-session:@1.%2"],
                  to: sessions.appendingPathComponent("2.json"))
        try write(["sessionId": "wanted", "tmux": "mux-manager:@1.%5", "status": "idle"],
                  to: sessions.appendingPathComponent("3.json"))
        // A session name that merely starts with ours must not match.
        try write(["sessionId": "nope", "tmux": "mux-manager-2:@1.%9"],
                  to: sessions.appendingPathComponent("4.json"))

        XCTAssertEqual(
            ManagerTranscript.sessionId(forTmuxSession: "mux-manager", sessionsDir: sessions),
            "wanted")
        XCTAssertNil(
            ManagerTranscript.sessionId(forTmuxSession: "absent", sessionsDir: sessions))
    }

    func testSessionIdPrefersTheMostRecentlyUpdatedMatch() throws {
        let dir = try makeClaudeDir()
        let sessions = dir.appendingPathComponent("sessions")
        // A restarted manager: the old pane's file lingers with an older stamp.
        try write(["sessionId": "old", "tmux": "mux-manager:@1.%5", "updatedAt": 1_000],
                  to: sessions.appendingPathComponent("1.json"))
        try write(["sessionId": "new", "tmux": "mux-manager:@1.%8", "updatedAt": 2_000],
                  to: sessions.appendingPathComponent("2.json"))
        try write(["sessionId": "unstamped", "tmux": "mux-manager:@1.%9"],
                  to: sessions.appendingPathComponent("3.json"))
        XCTAssertEqual(
            ManagerTranscript.sessionId(forTmuxSession: "mux-manager", sessionsDir: sessions),
            "new")
    }

    func testStatusReadsTheSessionFile() throws {
        let dir = try makeClaudeDir()
        let file = dir.appendingPathComponent("sessions/9.json")
        try write(["sessionId": "s", "tmux": "mux-manager:@1.%5",
                   "status": "waiting", "waitingFor": "permission"], to: file)
        let (status, waitingFor) = ManagerTranscript.status(sessionFile: file)
        XCTAssertEqual(status, .waiting)
        XCTAssertEqual(waitingFor, "permission")

        let missing = dir.appendingPathComponent("sessions/absent.json")
        XCTAssertNil(ManagerTranscript.status(sessionFile: missing).0)
    }

    func testFindJSONLGlobsProjectDirs() throws {
        let dir = try makeClaudeDir()
        let projects = dir.appendingPathComponent("projects")
        let url = try seedTranscript(in: projects, sessionId: "wanted", lines: [userPrompt])
        XCTAssertEqual(
            ManagerTranscript.findJSONL(sessionId: "wanted", projectsDir: projects), url)
        XCTAssertNil(ManagerTranscript.findJSONL(sessionId: "absent", projectsDir: projects))
        XCTAssertEqual(ManagerTranscript.lineCount(of: url), 1, "a final newline is not a line")
    }

    // MARK: Driver

    func testSendRefusesWhileTheManagerIsWaiting() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = FakeRunner()
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in .waiting }, queue: DispatchQueue(label: "test.pane"))

        let done = expectation(description: "refused")
        driver.send("hello", onDelta: { _ in XCTFail("no reply expected") }) { outcome in
            XCTAssertEqual(outcome, .refused("Maestro is waiting on a prompt"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(runner.recorded(), [], "nothing may be typed into a waiting pane")
    }

    func testSendPastesThenReadsTheReplyBack() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let transcript = try seedTranscript(
            in: dir.appendingPathComponent("projects"), sessionId: "wanted", lines: [userPrompt])
        let runner = FakeRunner()
        let status = StatusBox(.busy)
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in status.value }, queue: DispatchQueue(label: "test.pane"))

        var deltas: [String] = []
        let done = expectation(description: "done")
        driver.send("what is up", onDelta: { deltas.append($0) }) { outcome in
            XCTAssertEqual(outcome, .done(reply: "Second part."))
            done.fulfill()
        }
        // The pane answers after the Enter has gone in (0.3s), then goes idle. The
        // two are separated so the poll loop has seen the new line before the
        // status settles, which is the order a real pane produces.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.append(self.textTwo, to: transcript)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            status.value = .idle
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(deltas, ["Second part."])
        XCTAssertEqual(runner.recorded(), [
            ["display-message", "-pt", "mux-manager", "#{pane_id}"],
            // A pane in copy mode takes the Enter as a copy-mode key, so the
            // prompt would sit unsent in the input box.
            ["copy-mode", "-q", "-t", "mux-manager"],
            ["load-buffer", "-b", "sidekick", "-"],
            ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "mux-manager"],
            ["send-keys", "-t", "mux-manager", "Enter"],
        ])
        XCTAssertEqual(runner.stdinText(), "what is up", "the prompt goes in over stdin, not argv")
        XCTAssertEqual(runner.paths(), Array(repeating: "/usr/bin/tmux", count: 5))
    }

    /// A permission prompt that comes up between the paste and the Enter would
    /// take the Enter as its answer.
    func testSendDoesNotPressEnterWhenAPromptAppearsAfterThePaste() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = FakeRunner()
        let status = StatusBox(.busy)
        // The pane reaches a prompt as soon as the text is pasted.
        runner.onRun = { args in
            if args.first == "paste-buffer" { status.value = .waiting }
        }
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in status.value }, queue: DispatchQueue(label: "test.pane"))

        let done = expectation(description: "refused")
        driver.send("approve it", onDelta: { _ in XCTFail("no reply expected") }) { outcome in
            XCTAssertEqual(outcome, .refused("Maestro is waiting on a prompt"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(
            runner.recorded().contains(["send-keys", "-t", "mux-manager", "Enter"]),
            "Enter must not reach a pane that is now on a prompt")
        // The pasted text is taken out again, so a later Enter cannot send it.
        XCTAssertEqual(Array(runner.recorded().suffix(2)), [
            ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "mux-manager"],
            ["send-keys", "-t", "mux-manager", "C-u"],
        ])

        // The driver is free again: the refused turn is not left running.
        status.value = .waiting
        let again = expectation(description: "refused again")
        driver.send("hello", onDelta: { _ in }) { outcome in
            XCTAssertEqual(outcome, .refused("Maestro is waiting on a prompt"))
            again.fulfill()
        }
        wait(for: [again], timeout: 5)
    }

    func testOnlyAnIdlePaneTakesATurnThatRequiresIdle() {
        XCTAssertNil(ManagerPaneDriver.refusal(status: .idle, requireIdle: true))
        XCTAssertEqual(
            ManagerPaneDriver.refusal(status: .busy, requireIdle: true), "Maestro is busy")
        XCTAssertEqual(
            ManagerPaneDriver.refusal(status: nil, requireIdle: true), "Maestro is not ready")
        XCTAssertEqual(
            ManagerPaneDriver.refusal(status: .waiting, requireIdle: true),
            "Maestro is waiting on a prompt")
        // The rail's own turns are as before: only a prompt refuses.
        XCTAssertNil(ManagerPaneDriver.refusal(status: .busy, requireIdle: false))
        XCTAssertNil(ManagerPaneDriver.refusal(status: nil, requireIdle: false))
        XCTAssertEqual(
            ManagerPaneDriver.refusal(status: .waiting, requireIdle: false),
            "Maestro is waiting on a prompt")
    }

    func testAPhoneTurnTypesNothingIntoABusyOrUnknownPane() throws {
        for (status, reason) in [(ManagerTurnStatus.busy as ManagerTurnStatus?, "Maestro is busy"),
                                 (nil, "Maestro is not ready")] {
            let dir = try makeClaudeDir()
            // No session file: with no hook row either, the state is not known.
            if status != nil { try seedSession(in: dir, sessionId: "wanted") }
            let runner = FakeRunner()
            let driver = ManagerPaneDriver(
                config: config(claudeDir: dir), runner: runner,
                statusOverride: { _ in status }, queue: DispatchQueue(label: "test.pane"))
            let done = expectation(description: "refused")
            driver.send("hello", requireIdle: true, onDelta: { _ in XCTFail("no reply expected") }) {
                XCTAssertEqual($0, .refused(reason))
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(runner.recorded(), [], "nothing may be typed: \(reason)")
        }
    }

    /// The pane was idle at the paste and is busy by the Enter (a turn typed on
    /// the Mac started in between). It may reach a prompt next.
    func testAPhoneTurnIsTakenBackWhenThePaneStopsBeingIdleBeforeTheEnter() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = FakeRunner()
        let status = StatusBox(.idle)
        runner.onRun = { args in
            if args.first == "paste-buffer" { status.value = .busy }
        }
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in status.value }, queue: DispatchQueue(label: "test.pane"))

        let done = expectation(description: "refused")
        driver.send("first line\nsecond line", requireIdle: true, onDelta: { _ in }) {
            XCTAssertEqual($0, .refused("Maestro is busy"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(runner.recorded().contains(["send-keys", "-t", "mux-manager", "Enter"]))
        // Two lines were pasted: both are deleted.
        XCTAssertEqual(runner.recorded().last, ["send-keys", "-t", "mux-manager", "C-u", "C-u"])
    }

    func testAPhoneTurnRunsFromAnIdlePane() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let transcript = try seedTranscript(
            in: dir.appendingPathComponent("projects"), sessionId: "wanted", lines: [userPrompt])
        let runner = FakeRunner()
        let status = StatusBox(.idle)
        // The Enter starts the turn.
        runner.onRun = { args in
            if args.last == "Enter" { status.value = .busy }
        }
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in status.value }, queue: DispatchQueue(label: "test.pane"))
        let done = expectation(description: "done")
        driver.send("what is up", requireIdle: true, onDelta: { _ in }) { outcome in
            XCTAssertEqual(outcome, .done(reply: "Second part."))
            done.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.append(self.textTwo, to: transcript) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { status.value = .idle }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(runner.recorded().last, ["send-keys", "-t", "mux-manager", "Enter"])
        XCTAssertFalse(runner.recorded().contains { $0.contains("C-u") })
    }

    func testPaneStatusReadsTheHookRowThenTheSessionFile() throws {
        let dir = try makeClaudeDir()
        let none = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: FakeRunner(), queue: DispatchQueue(label: "test.pane"))
        XCTAssertNil(none.paneStatus(), "no session yet: not known, and so not idle")

        try seedSession(in: dir, sessionId: "wanted")
        XCTAssertEqual(none.paneStatus(), .idle)
        let hooked = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: FakeRunner(),
            statusOverride: { $0 == "wanted" ? .waiting : nil }, queue: DispatchQueue(label: "test.pane"))
        XCTAssertEqual(hooked.paneStatus(), .waiting)
    }

    func testSendRefusesASecondTurnWhileOneIsRunning() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        _ = try seedTranscript(
            in: dir.appendingPathComponent("projects"), sessionId: "wanted", lines: [userPrompt])
        let runner = FakeRunner()
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in .busy }, queue: DispatchQueue(label: "test.pane"))

        let first = expectation(description: "first settles")
        first.isInverted = true
        driver.send("one", onDelta: { _ in }) { _ in first.fulfill() }

        let refused = expectation(description: "second refused")
        driver.send("two", onDelta: { _ in XCTFail("no reply expected") }) { outcome in
            XCTAssertEqual(outcome, .refused("A turn is running"))
            refused.fulfill()
        }
        wait(for: [refused], timeout: 5)
        wait(for: [first], timeout: 0.1)
        driver.cancel()
    }

    func testSendReportsAnUnreachablePane() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = FakeRunner()
        runner.failing = true
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))

        let done = expectation(description: "unreachable")
        driver.send("hello", onDelta: { _ in }) { outcome in
            XCTAssertEqual(outcome, .unreachable("The Maestro session is not running"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testSendRefusesAnEmptyPrompt() throws {
        let dir = try makeClaudeDir()
        let runner = FakeRunner()
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner, queue: DispatchQueue(label: "test.pane"))
        let done = expectation(description: "refused")
        driver.send("   \n ", onDelta: { _ in }) { outcome in
            XCTAssertEqual(outcome, .refused("Nothing to send"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(runner.recorded(), [])
    }

    func testCurrentSessionIdAndLastReply() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        _ = try seedTranscript(
            in: dir.appendingPathComponent("projects"), sessionId: "wanted",
            lines: [userPrompt, textOne, textTwo])
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: FakeRunner(),
            queue: DispatchQueue(label: "test.pane"))
        XCTAssertEqual(driver.currentSessionId(), "wanted")
        XCTAssertEqual(driver.lastReply(), "First part.\nSecond part.")
    }

    // MARK: Helpers

    /// One poll, collecting the delta so a test can assert the whole stream.
    private func feed(
        _ watcher: inout ManagerTurnWatcher,
        _ deltas: inout [String],
        at now: TimeInterval,
        _ status: ManagerTurnStatus?,
        _ lines: [String]
    ) -> ManagerTurnOutcome? {
        let (delta, outcome) = watcher.step(now: now, status: status, lines: lines)
        if !delta.isEmpty { deltas.append(delta) }
        return outcome
    }

    private func config(claudeDir: URL) -> ManagerPaneDriver.Config {
        ManagerPaneDriver.Config(
            tmuxPath: "/usr/bin/tmux", tmuxSession: "mux-manager",
            claudeDir: claudeDir, pollInterval: 0.02)
    }

    private func makeClaudeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString)", isDirectory: true)
        for sub in ["sessions", "projects"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func seedSession(in claudeDir: URL, sessionId: String) throws {
        try write(["sessionId": sessionId, "tmux": "mux-manager:@1.%5", "status": "idle"],
                  to: claudeDir.appendingPathComponent("sessions/4242.json"))
    }

    @discardableResult
    private func seedTranscript(in projectsDir: URL, sessionId: String, lines: [String]) throws -> URL {
        let project = projectsDir.appendingPathComponent("-Users-me-code-p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = project.appendingPathComponent("\(sessionId).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Append atomically: the driver is reading this file from another queue, and
    /// a half-written read would test the fixture rather than the code.
    private func append(_ line: String, to url: URL) {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }
}

/// A mutable status the test sets from the main queue while the driver reads it
/// from its own.
private final class StatusBox {
    private let lock = NSLock()
    private var stored: ManagerTurnStatus?

    init(_ value: ManagerTurnStatus?) { stored = value }

    var value: ManagerTurnStatus? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Records every argv the driver runs. `failing` makes every command fail, which
/// is what a dead tmux session looks like.
private final class FakeRunner: CommandRunner {
    var failing = false
    /// Called with each argv as it runs, for a test that changes the pane's
    /// state at one step.
    var onRun: (([String]) -> Void)?

    private let lock = NSLock()
    private var calls: [(path: String, args: [String], stdin: Data?)] = []

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        calls.append((path, args, stdin))
        let failing = self.failing
        lock.unlock()
        onRun?(args)
        return failing ? nil : ""
    }

    func recorded() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.args)
    }

    func paths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.path)
    }

    /// The text pasted in over stdin, across every call that carried any.
    func stdinText() -> String {
        lock.lock(); defer { lock.unlock() }
        return calls.compactMap(\.stdin).map { String(decoding: $0, as: UTF8.self) }.joined()
    }
}
