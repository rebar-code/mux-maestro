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
        XCTAssertEqual(typed(runner), [], "nothing may be typed into a waiting pane")
        // The pane was read, to see whether the stored status still holds.
        XCTAssertEqual(runner.recorded().first, ["capture-pane", "-p", "-t", "%5"])
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
            // A pane in copy mode takes the Enter as a copy-mode key, so the
            // prompt would sit unsent in the input box.
            ["copy-mode", "-q", "-t", "%5"],
            ["load-buffer", "-b", "sidekick", "-"],
            ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "%5"],
            ["send-keys", "-t", "%5", "Enter"],
        ])
        XCTAssertEqual(runner.stdinText(), "what is up", "the prompt goes in over stdin, not argv")
        XCTAssertEqual(runner.paths(), Array(repeating: "/usr/bin/tmux", count: 4))
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
            runner.recorded().contains(["send-keys", "-t", "%5", "Enter"]),
            "Enter must not reach a pane that is now on a prompt")
        // The pasted text is taken out again, so a later Enter cannot send it.
        XCTAssertEqual(Array(typed(runner).suffix(2)), [
            ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "%5"],
            ["send-keys", "-t", "%5", "C-u"],
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
            XCTAssertEqual(typed(runner), [], "nothing may be typed: \(reason)")
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
        XCTAssertFalse(runner.recorded().contains(["send-keys", "-t", "%5", "Enter"]))
        // Two lines were pasted: both are deleted.
        XCTAssertEqual(runner.recorded().last, ["send-keys", "-t", "%5", "C-u", "C-u"])
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
        XCTAssertEqual(runner.recorded().last, ["send-keys", "-t", "%5", "Enter"])
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

    // MARK: a stale "waiting"

    /// The manager pane, idle at its input box: what it shows after a question
    /// was cancelled with Esc. No hook fires then, so the stored status still
    /// says waiting.
    private static let idleScreen = """
    ⏺ I will wait for your answer.

    ⏺ User declined to answer questions

    ────────────────────────────────────────────────────────
    ❯\u{A0}
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """
    private static let idleCursorRow = 5

    /// The same pane while the question is still up.
    private static let promptScreen = """
    ⏺ I need one thing from you.

    ────────────────────────────────────────────────────────
     ☐ Deploy

    Which environment should this go to?

    ❯ 1. Staging
      2. Production
      3. Type something.

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """
    private static let promptCursorRow = 7

    /// A runner whose pane shows `screen`, with the cursor on `row`.
    private func runner(showing screen: String, cursorRow row: Int) -> FakeRunner {
        let runner = FakeRunner()
        runner.output = { args in
            if args.first == "capture-pane" { return screen + "\n" }
            if args.last == "#{cursor_y}" { return "\(row)\n" }
            return ""
        }
        return runner
    }

    private func typed(_ runner: FakeRunner) -> [[String]] {
        runner.recorded().filter { ["load-buffer", "paste-buffer", "send-keys"].contains($0.first ?? "") }
    }

    /// The reported bug: the stored status says waiting for an hour, the pane
    /// is idle at its input box, and the phone is refused every time.
    func testAStoredWaitingIsNotTrustedOverAnIdleInputBoxOnScreen() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let transcript = try seedTranscript(
            in: dir.appendingPathComponent("projects"), sessionId: "wanted", lines: [userPrompt])
        let runner = runner(showing: Self.idleScreen, cursorRow: Self.idleCursorRow)
        let status = StatusBox(.waiting)
        runner.onRun = { args in
            if args.last == "Enter" { status.value = .busy }
        }
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in status.value }, queue: DispatchQueue(label: "test.pane"))
        XCTAssertEqual(driver.paneStatus(), .idle, "the phone must be told the pane is idle")

        let done = expectation(description: "done")
        driver.send("what needs me?", requireIdle: true, onDelta: { _ in }) { outcome in
            XCTAssertEqual(outcome, .done(reply: "Second part."))
            done.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.append(self.textTwo, to: transcript) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { status.value = .idle }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(typed(runner), [
            ["load-buffer", "-b", "sidekick", "-"],
            ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "%5"],
            ["send-keys", "-t", "%5", "Enter"],
        ])
    }

    func testAStoredWaitingStandsWhileAPromptIsOnScreen() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = runner(showing: Self.promptScreen, cursorRow: Self.promptCursorRow)
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in .waiting }, queue: DispatchQueue(label: "test.pane"))
        XCTAssertEqual(driver.paneStatus(), .waiting)

        for requireIdle in [true, false] {
            let done = expectation(description: "refused")
            driver.send("what needs me?", requireIdle: requireIdle, onDelta: { _ in XCTFail("no reply") }) {
                XCTAssertEqual($0, .refused("Maestro is waiting on a prompt"))
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(typed(runner), [], "nothing may be typed into a pane that shows a prompt")
    }

    /// No status at all (no hook row, no status in the file) with an idle
    /// input box on screen is idle too; with anything else on screen it is not.
    func testAnUnknownStatusIsSettledByTheScreen() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let idle = ManagerPaneDriver(
            config: config(claudeDir: dir),
            runner: runner(showing: Self.idleScreen, cursorRow: Self.idleCursorRow),
            statusOverride: { _ in nil }, queue: DispatchQueue(label: "test.pane"))
        // The seeded file says idle; take that away so nothing is known.
        try Data(#"{"sessionId":"wanted","tmux":"mux-manager:@1.%5"}"#.utf8)
            .write(to: dir.appendingPathComponent("sessions/4242.json"))
        XCTAssertEqual(idle.paneStatus(), .idle)

        let shell = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner(showing: "$ ls\nREADME.md\n$ ", cursorRow: 2),
            statusOverride: { _ in nil }, queue: DispatchQueue(label: "test.pane"))
        XCTAssertNil(shell.paneStatus())
        // A pane that cannot be read settles nothing.
        let dead = FakeRunner()
        dead.unreadable = true
        let unread = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: dead,
            statusOverride: { _ in .waiting }, queue: DispatchQueue(label: "test.pane"))
        XCTAssertEqual(unread.paneStatus(), .waiting)
    }

    /// Busy and idle are not second-guessed, and the pane is not read for them.
    func testTheScreenIsReadOnlyForAWaitingOrUnknownStatus() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        for status in [ManagerTurnStatus.busy, .idle] {
            let runner = runner(showing: Self.idleScreen, cursorRow: Self.idleCursorRow)
            let driver = ManagerPaneDriver(
                config: config(claudeDir: dir), runner: runner,
                statusOverride: { _ in status }, queue: DispatchQueue(label: "test.pane"))
            XCTAssertEqual(driver.paneStatus(), status)
            XCTAssertEqual(runner.recorded(), [])
        }
    }

    func testAnInputBoxIsIdleOnlyAsTheLastThingOnScreenWithTheCursorInIt() {
        XCTAssertTrue(ManagerScreen.showsIdleInputBox(Self.idleScreen, cursorRow: Self.idleCursorRow))
        // The older, boxed input.
        let boxed = "⏺ Done.\n\n╭──────────────╮\n│ >            │\n╰──────────────╯\n  ? for shortcuts\n"
        XCTAssertTrue(ManagerScreen.showsIdleInputBox(boxed, cursorRow: 3))
        // A named session: its name is in the box's top rule (v2.1.294).
        let named = "⏺ Done.\n\n──────────── fix-login-form ─\n❯\u{A0}\n──────────\n  ? for shortcuts"
        XCTAssertTrue(ManagerScreen.showsIdleInputBox(named, cursorRow: 3))
        XCTAssertFalse(ManagerScreen.showsIdleInputBox(named, cursorRow: 5))
        // Text typed into the box, over several lines, is still an idle box.
        let typing = "──────────\n❯ first line\n  second line\n──────────\n  ? for shortcuts"
        XCTAssertTrue(ManagerScreen.showsIdleInputBox(typing, cursorRow: 2))

        // The cursor is elsewhere (unknown, or parked by something in front).
        XCTAssertFalse(ManagerScreen.showsIdleInputBox(Self.idleScreen, cursorRow: nil))
        XCTAssertFalse(ManagerScreen.showsIdleInputBox(Self.idleScreen, cursorRow: 1))
        XCTAssertFalse(ManagerScreen.showsIdleInputBox(Self.idleScreen, cursorRow: 7))
        // A question, a permission prompt, a shell, an empty pane.
        XCTAssertFalse(ManagerScreen.showsIdleInputBox(Self.promptScreen, cursorRow: Self.promptCursorRow))
        let permission = """
        ╭──────────────────────────────╮
        │ Bash command                 │
        │   make test                  │
        │ Do you want to proceed?      │
        │ ❯ 1. Yes                     │
        │   2. No                      │
        ╰──────────────────────────────╯
        """
        for row in 0..<7 {
            XCTAssertFalse(ManagerScreen.showsIdleInputBox(permission, cursorRow: row), "row \(row)")
        }
        XCTAssertFalse(ManagerScreen.showsIdleInputBox("$ ls\nREADME.md\n$ ", cursorRow: 2))
        XCTAssertFalse(ManagerScreen.showsIdleInputBox("", cursorRow: 0))
        // Choices under the box: a menu is in front of it.
        let menu = "──────────\n❯\n──────────\n❯ 1. Sonnet\n  2. Opus\n"
        XCTAssertFalse(ManagerScreen.showsIdleInputBox(menu, cursorRow: 1))
        // An old input box far up the screen, with other output under it.
        let old = "──────────\n❯\n──────────\n" + (0..<8).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertFalse(ManagerScreen.showsIdleInputBox(old, cursorRow: 1))
        XCTAssertTrue(ManagerScreen.isChoice("❯ 1. Yes"))
        XCTAssertTrue(ManagerScreen.isChoice("12. Twelve"))
        XCTAssertFalse(ManagerScreen.isChoice("1.5 seconds"))
        XCTAssertFalse(ManagerScreen.isChoice("❯"))
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

    // MARK: The Maestro's own pane

    /// The reported bug: the session had a second window, a plain shell, and
    /// it was the active one. Every command named the session, tmux took that
    /// to mean its active pane, and the chat was run by the shell as commands.
    func testEveryCommandNamesTheMaestroPaneNotTheSession() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = runner(showing: Self.idleScreen, cursorRow: Self.idleCursorRow)
        runner.panes = "%5 1 0 0 /Users/me/manager\n%9 0 0 1 /Users/me/code/acme-app\n"
        let status = StatusBox(.waiting)
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in status.value }, queue: DispatchQueue(label: "test.pane"))

        // The screen and the cursor row are read to settle a stored "waiting".
        XCTAssertEqual(driver.paneStatus(), .idle)
        XCTAssertEqual(runner.recorded(), [
            ["capture-pane", "-p", "-t", "%5"],
            ["display-message", "-p", "-t", "%5", "#{cursor_y}"],
        ])

        status.value = .idle
        let sent = expectation(description: "sent")
        runner.onRun = { if $0 == ["send-keys", "-t", "%5", "Enter"] { sent.fulfill() } }
        driver.send("Still there?", onDelta: { _ in }) { _ in }
        wait(for: [sent], timeout: 5)
        driver.cancel()
        XCTAssertTrue(runner.recorded().contains(
            ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "%5"]))
        XCTAssertEqual(
            runner.recorded().filter { $0.contains("mux-manager") }, [],
            "a session name is the session's active pane, whichever that is")
    }

    /// No agent pane, or the Maestro's pane is at a shell: the turn fails and
    /// no key goes anywhere.
    func testNothingIsTypedWhenTheMaestroPaneIsMissingOrIsAShell() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let onlyAShell = "%9 0 0 1 /Users/me/code/acme-app\n"
        let maestroAtAShell = "%5 1 0 1 /Users/me/manager\n%9 0 0 0 /Users/me/code/acme-app\n"
        for panes in [onlyAShell, maestroAtAShell, ""] {
            let runner = FakeRunner()
            runner.panes = panes
            let driver = ManagerPaneDriver(
                config: config(claudeDir: dir), runner: runner,
                statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
            let done = expectation(description: "unreachable")
            driver.send("hello", onDelta: { _ in XCTFail("no reply expected") }) { outcome in
                XCTAssertEqual(outcome, .unreachable("The Maestro session is not running"))
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(runner.recorded(), [], "nothing may be done to any pane")
            XCTAssertNil(driver.paneStatus())
            XCTAssertNil(driver.currentSessionId())
        }
    }

    /// Two agents in the session: the transcript read is the one of the pane
    /// that gets the text, not the one that wrote last.
    func testTheTranscriptIsTheOneOfTheMaestroPane() throws {
        let dir = try makeClaudeDir()
        try write(["sessionId": "maestro", "tmux": "mux-manager:@1.%5", "status": "idle", "updatedAt": 1_000],
                  to: dir.appendingPathComponent("sessions/1.json"))
        try write(["sessionId": "other", "tmux": "mux-manager:@2.%8", "status": "busy", "updatedAt": 2_000],
                  to: dir.appendingPathComponent("sessions/2.json"))
        try write(["sessionId": "longer-id", "tmux": "mux-manager:@3.%55", "updatedAt": 3_000],
                  to: dir.appendingPathComponent("sessions/3.json"))
        let runner = FakeRunner()
        runner.panes = "%5 1 0 0 /Users/me/manager\n%8 0 0 0 /Users/me/manager\n"
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner, queue: DispatchQueue(label: "test.pane"))
        XCTAssertEqual(driver.currentSessionId(), "maestro")
        XCTAssertEqual(driver.fileStatus(), .idle)
    }

    // MARK: The Maestro's own pane, against a real tmux

    /// The bug end to end: window 0 holds the Maestro, a second window with a
    /// shell is the active one, and a turn is sent.
    func testATurnIsTypedIntoTheMaestroPaneWhenAShellWindowIsActive() throws {
        guard let tmux = PrivateTmux() else { throw XCTSkip("no tmux on this machine") }
        addTeardownBlock { tmux.tmux(["kill-server"]) }
        tmux.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "mux-manager", "-x", "100", "-y", "30", "cat"]
                  + ManagerPane.createMarkArgv(session: "mux-manager"))
        let maestro = tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"])
        tmux.tmux(["new-window", "-t", "mux-manager", "/bin/sh"])
        let shell = tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"])
        XCTAssertTrue(maestro.hasPrefix("%") && shell.hasPrefix("%") && maestro != shell)

        let dir = try makeClaudeDir()
        try write(["sessionId": "wanted", "tmux": "mux-manager:@0.\(maestro)", "status": "idle"],
                  to: dir.appendingPathComponent("sessions/4242.json"))
        let driver = ManagerPaneDriver(
            config: .init(tmuxPath: tmux.path, claudeDir: dir, pollInterval: 0.02), runner: tmux,
            statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        driver.send("hello maestro", onDelta: { _ in }) { _ in }
        // `cat` shows the paste once and gives it back once after the Enter.
        XCTAssertTrue(eventually { tmux.screen(maestro).components(separatedBy: "hello maestro").count == 3 })
        driver.cancel()
        XCTAssertFalse(tmux.screen(shell).contains("hello"), "the chat must not reach the shell")
        XCTAssertFalse(tmux.screen(shell).contains("not found"))

        // The rail terminal attaches to the Maestro's window, not the shell's.
        XCTAssertEqual(tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"]), shell)
        tmux.tmux(ManagerPane.showArgv(pane: maestro))
        XCTAssertEqual(tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"]), maestro)
    }

    /// A session from before panes were marked: the first pane in the manager
    /// home is the Maestro's, and it is marked so it stays that.
    func testASessionWithoutTheMarkPinsTheFirstPaneInTheManagerHome() throws {
        guard let tmux = PrivateTmux() else { throw XCTSkip("no tmux on this machine") }
        addTeardownBlock { tmux.tmux(["kill-server"]) }
        let home = try makeClaudeDir()
        let size = ["-x", "100", "-y", "30"]
        tmux.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "mux-manager", "-c", home.path] + size + ["cat"])
        let maestro = tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"])
        // A second agent in the same home, then a shell elsewhere, left active.
        tmux.tmux(["new-window", "-t", "mux-manager", "-c", home.path, "cat"])
        tmux.tmux(["new-window", "-t", "mux-manager", "-c", "/", "/bin/sh"])
        let shell = tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"])

        let dir = try makeClaudeDir()
        let driver = ManagerPaneDriver(
            config: .init(tmuxPath: tmux.path, homePath: home.path, claudeDir: dir, pollInterval: 0.02),
            runner: tmux, statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        driver.send("hello maestro", onDelta: { _ in }) { _ in }
        XCTAssertTrue(eventually { tmux.screen(maestro).components(separatedBy: "hello maestro").count == 3 })
        driver.cancel()
        XCTAssertFalse(tmux.screen(shell).contains("hello"))
        let marks = tmux.tmux(["list-panes", "-s", "-t", "mux-manager", "-F", "#{pane_id}=#{@mux_maestro}"])
        XCTAssertEqual(marks.split(separator: "\n").filter { $0.hasSuffix("=1") }, ["\(maestro)=1"])
    }

    func testTheLaunchCommandRunsTheChosenAgentWithItsModel() {
        XCTAssertEqual(MaestroAgent.claude.command(model: ""), "claude")
        XCTAssertEqual(MaestroAgent.codex.command(model: "  "), "codex")
        XCTAssertEqual(MaestroAgent.claude.command(model: " opus "), "claude --model 'opus'")
        // A model is free text from a settings field: it never reaches the shell bare.
        XCTAssertEqual(MaestroAgent.codex.command(model: "x; rm -rf ~"), "codex --model 'x; rm -rf ~'")
        XCTAssertEqual(
            ManagerPane.launchShell(homePath: "/Users/me/manager", agent: .claude, model: ""),
            #"exec "$SHELL" -lc 'PATH='\''/Users/me/manager/bin'\'':"$PATH" exec claude'"#)
        XCTAssertTrue(
            ManagerPane.launchShell(homePath: "/Users/me/manager", agent: .codex, model: "gpt-5.5")
                .contains("exec codex --model"))
    }

    /// A session from before the mark is found by its start command, whichever
    /// agent the app launched in it.
    func testAPaneLaunchedWithEitherAgentCountsAsLaunched() throws {
        guard let tmux = PrivateTmux(environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"]) else {
            throw XCTSkip("no tmux on this machine")
        }
        addTeardownBlock { tmux.tmux(["kill-server"]) }
        let run: ([String]) -> String? = { tmux.run(tmux.path, $0, stdin: nil) }
        tmux.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "mux-manager", "-c", "/", "cat"])
        // `exec <agent>` only has to be in the start command; `cat` keeps the pane alive.
        for agent in MaestroAgent.allCases {
            tmux.tmux(["new-window", "-t", "mux-manager", "-c", "/", "cat; : exec \(agent.rawValue) --model m"])
        }
        let rows = ManagerPane.parse(run(ManagerPane.listArgv(session: "mux-manager")) ?? "")
        XCTAssertEqual(rows.map(\.launched), [false, true, true])
    }

    func testThePinnedPaneIsTheMarkedOneElseTheFirstTheAppLaunched() {
        let rows = ManagerPane.parse(
            "%12 0 0 1 /Users/me/code/acme-app\n"
                + "%9 0 0 0 /Users/me/manager\n"
                + "%3 0 1 0 /Users/me/elsewhere\n"
                + "%4 1 0 0 /Users/me/manager\n"
                + "not a pane\n"
                + "%5_1_claude_/Users/me/manager_\n")
        XCTAssertEqual(rows.map(\.id), ["%12", "%9", "%3", "%4"])
        // The mark wins over everything.
        XCTAssertEqual(ManagerPane.pinned(rows, homePath: "/Users/me/manager")?.id, "%4")
        // No mark: the lowest id among the app's launch and the panes in the home.
        let unmarked = Array(rows.dropLast())
        XCTAssertEqual(ManagerPane.pinned(unmarked, homePath: "/Users/me/manager")?.id, "%3")
        XCTAssertEqual(ManagerPane.pinned(Array(unmarked.prefix(2)), homePath: "/Users/me/manager")?.id, "%9")
        // A shell elsewhere is never it.
        XCTAssertNil(ManagerPane.pinned(Array(unmarked.prefix(1)), homePath: "/Users/me/manager"))
        XCTAssertNil(ManagerPane.pinned(Array(unmarked.prefix(2)), homePath: nil))

        // A pane found by the rule is marked; one at a shell is neither marked
        // nor returned.
        var ran: [[String]] = []
        let found = ManagerPane.resolve(session: "mux-manager", homePath: "/Users/me/manager") {
            ran.append($0)
            return $0.first == "list-panes" ? "%9 0 0 0 /Users/me/manager\n" : ""
        }
        XCTAssertEqual(found, "%9")
        XCTAssertEqual(ran.first?.prefix(4), ["list-panes", "-s", "-t", "=mux-manager"])
        XCTAssertEqual(ran.last, ["set-option", "-p", "-t", "%9", "@mux_maestro", "1"])
        ran = []
        XCTAssertEqual(ManagerPane.lookup(session: "mux-manager", homePath: "/Users/me/manager") {
            ran.append($0)
            return "%9 0 0 1 /Users/me/manager\n"
        }, ManagerPane.Lookup.none)
        XCTAssertEqual(ran.count, 1)
        // The app's own launch at its login shell is on its way to the agent.
        XCTAssertEqual(
            ManagerPane.lookup(session: "mux-manager", homePath: nil) { _ in "%9 1 1 1 /Users/me/manager\n" },
            .starting)
    }

    /// The path is the one free-text field. It is last, so the spaces that
    /// part the fields, and anything else, may be in it.
    func testAPathWithSpacesAndBarsIsReadWhole() {
        let home = "/Users/me/Library/Application Support/Mux|Maestro 1 0/manager"
        let rows = ManagerPane.parse("%7 0 0 0 \(home)\n%8 0 0 1 /Users/me/a b\n%9 0 0 0 \n")
        XCTAssertEqual(rows.map(\.path), [home, "/Users/me/a b", ""])
        XCTAssertEqual(ManagerPane.pinned(rows, homePath: home)?.id, "%7")
    }

    /// An app opened from Finder has no LANG or LC_ variable. tmux then prints
    /// control characters as "_", so a format parted by tabs comes back as one
    /// field and every turn was refused.
    func testThePaneIsFoundWithNoLocaleInTheEnvironment() throws {
        guard let tmux = PrivateTmux(environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"]) else {
            throw XCTSkip("no tmux on this machine")
        }
        addTeardownBlock { tmux.tmux(["kill-server"]) }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager home|\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let size = ["-x", "100", "-y", "30"]
        // Marked, as the app makes it.
        tmux.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "mux-manager", "-c", home.path] + size + ["cat"]
                  + ManagerPane.createMarkArgv(session: "mux-manager"))
        let maestro = tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"])
        tmux.tmux(["new-window", "-t", "mux-manager", "-c", "/", "/bin/sh"])
        let run: ([String]) -> String? = { tmux.run(tmux.path, $0, stdin: nil) }
        XCTAssertEqual(ManagerPane.resolve(session: "mux-manager", homePath: nil, run: run), maestro)
        let rows = ManagerPane.parse(run(ManagerPane.listArgv(session: "mux-manager")) ?? "")
        XCTAssertEqual(rows.map(\.shell), [false, true])
        XCTAssertEqual(rows.map(\.marked), [true, false])

        // Not marked, found by its directory: a path with a space and a bar.
        tmux.tmux(["set-option", "-p", "-u", "-t", maestro, "@mux_maestro"])
        XCTAssertNil(ManagerPane.resolve(session: "mux-manager", homePath: "/Users/me/manager", run: run))
        XCTAssertEqual(ManagerPane.resolve(session: "mux-manager", homePath: home.path, run: run), maestro)

        let dir = try makeClaudeDir()
        let driver = ManagerPaneDriver(
            config: .init(tmuxPath: tmux.path, homePath: home.path, claudeDir: dir, pollInterval: 0.02),
            runner: tmux, statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        driver.send("hello maestro", onDelta: { _ in }) { _ in }
        XCTAssertTrue(eventually { tmux.screen(maestro).components(separatedBy: "hello maestro").count == 3 })
        driver.cancel()
    }

    /// The app made the session a moment ago and the pane is still in its
    /// login shell. The turn waits for the agent; it is not refused, and it
    /// is not typed into the shell.
    func testATurnWaitsForAPaneThatIsStillStarting() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = FakeRunner()
        runner.panes = "%5 1 1 1 /Users/me/manager\n"
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        let sent = expectation(description: "sent")
        runner.onRun = { if $0 == ["send-keys", "-t", "%5", "Enter"] { sent.fulfill() } }
        driver.send("hello", onDelta: { _ in }) { _ in }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(runner.recorded(), [], "nothing is typed into the login shell")
        XCTAssertGreaterThan(runner.lookups(), 1)
        runner.panes = "%5 1 1 0 /Users/me/manager\n"
        wait(for: [sent], timeout: 5)
        driver.cancel()

        // A launch that never gets to the agent: the wait ends.
        let stuck = FakeRunner()
        stuck.panes = "%5 1 1 1 /Users/me/manager\n"
        var brief = config(claudeDir: dir)
        brief.startTimeout = 0.3
        let late = ManagerPaneDriver(
            config: brief, runner: stuck,
            statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        let done = expectation(description: "unreachable")
        late.send("hello", onDelta: { _ in }) { outcome in
            XCTAssertEqual(outcome, .unreachable("The Maestro session is not running"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(stuck.recorded(), [])
    }

    /// A session with shells only: the turn fails and no shell gets the text.
    func testNoShellGetsTheTurnWhenTheSessionHasNoMaestroPane() throws {
        guard let tmux = PrivateTmux() else { throw XCTSkip("no tmux on this machine") }
        addTeardownBlock { tmux.tmux(["kill-server"]) }
        tmux.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "mux-manager", "-x", "100", "-y", "30",
                   "-c", "/", "/bin/sh"])
        let shell = tmux.tmux(["display-message", "-p", "-t", "mux-manager", "#{pane_id}"])
        let dir = try makeClaudeDir()
        let driver = ManagerPaneDriver(
            config: .init(tmuxPath: tmux.path, claudeDir: dir, pollInterval: 0.02), runner: tmux,
            statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        let done = expectation(description: "unreachable")
        driver.send("hello maestro", onDelta: { _ in }) { outcome in
            XCTAssertEqual(outcome, .unreachable("The Maestro session is not running"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(tmux.screen(shell).contains("hello"))
    }

    private func eventually(_ timeout: TimeInterval = 5, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return check()
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

    /// The pane's hook row said "waiting" for a prompt that has since gone;
    /// no later hook wrote the row, and Claude's own status file says idle.
    /// The manager then refused every turn, so nothing could ever write the
    /// row again.
    func testAStaleHookRowDoesNotOutliveClaudesOwnStatus() {
        let row = { (state: AgentStateRow.State, at: Int) in
            AgentStateRow(
                sessionId: "wanted", agent: "claude", state: state, reason: "Claude needs your permission",
                pane: "%5", cwd: "/Users/me", since: at, updatedAt: at)
        }
        let now = 1_000_000
        // Written hours ago, and the file disagrees: the file is believed.
        XCTAssertNil(ManagerPaneDriver.status(for: row(.waiting, now - 5000), fileStatus: .idle, now: now))
        XCTAssertNil(ManagerPaneDriver.status(for: row(.busy, now - 5000), fileStatus: .idle, now: now))
        // The row still wins while the file may lag behind it, and when they agree.
        XCTAssertEqual(
            ManagerPaneDriver.status(for: row(.waiting, now - 5), fileStatus: .idle, now: now), .waiting)
        XCTAssertEqual(
            ManagerPaneDriver.status(for: row(.waiting, now - 5000), fileStatus: .waiting, now: now), .waiting)
        XCTAssertEqual(
            ManagerPaneDriver.status(for: row(.done, now - 5000), fileStatus: .idle, now: now), .idle)
        // No file to compare with: the row is all there is.
        XCTAssertEqual(
            ManagerPaneDriver.status(for: row(.waiting, now - 5000), fileStatus: nil, now: now), .waiting)
        XCTAssertNil(ManagerPaneDriver.status(for: row(.ended, now), fileStatus: .idle, now: now))
    }

    func testAPrivateTmuxServerEndsWhenTheProcessThatMadeItIsGone() throws {
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["60"]
        try owner.run()
        guard let tmux = PrivateTmux(owner: owner.processIdentifier) else {
            owner.terminate()
            throw XCTSkip("no tmux on this machine")
        }
        addTeardownBlock { tmux.tmux(["kill-server"]) }
        tmux.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "mux-manager", "-x", "100", "-y", "30", "cat"])
        XCTAssertFalse(tmux.tmux(["list-sessions"]).isEmpty)
        // No teardown runs: the owner is gone at once.
        owner.terminate()
        owner.waitUntilExit()
        XCTAssertTrue(eventually { tmux.tmux(["list-sessions"]).isEmpty })
    }

    func testFileStatusReadsClaudesOwnStatusForTheManagerPane() throws {
        let dir = try makeClaudeDir()
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: FakeRunner(),
            statusOverride: { _ in .waiting }, queue: DispatchQueue(label: "test.pane"))
        XCTAssertNil(driver.fileStatus())
        try seedSession(in: dir, sessionId: "wanted")
        // Not the hook row's answer: the file's.
        XCTAssertEqual(driver.fileStatus(), .idle)
    }

    // MARK: Reset

    /// A reply with the usage Claude Code records: 1,000 + 2,000 + 40,000.
    private let sizedReply = #"""
    {"type":"assistant","message":{"role":"assistant","model":"claude-x","content":[{"type":"text","text":"Sized."}],"stop_reason":"end_turn","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":40000,"output_tokens":9}}}
    """#
    /// The harness's own note, written with no API call: its usage is zero.
    private let syntheticReply = #"""
    {"type":"assistant","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Note."}],"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """#

    func testContextTokensIsTheLastRealReplysUsage() {
        XCTAssertEqual(
            ManagerTranscript.contextTokens(lines: [userPrompt, textTwo, sizedReply, syntheticReply, halfLine]),
            43_000)
        // A reply with no usage field (an older build) reads as empty.
        XCTAssertEqual(ManagerTranscript.contextTokens(lines: [userPrompt, textTwo]), 0)
        XCTAssertNil(ManagerTranscript.contextTokens(lines: [userPrompt, halfLine]))
        XCTAssertNil(ManagerTranscript.contextTokens(lines: []))
    }

    func testResetPolicyNeedsAnIdlePaneWithATranscript() {
        let policy = ManagerResetPolicy(idleSeconds: 1800, contextTokens: 80_000)
        let now = 1_000_000
        let reason = { (status: ManagerTurnStatus?, idleSince: Int?, tokens: Int?) in
            ManagerResetPolicy.reason(
                policy: policy, status: status, idleSince: idleSince, contextTokens: tokens, now: now)
        }
        XCTAssertNil(reason(.idle, now - 1799, 1000))
        XCTAssertEqual(reason(.idle, now - 1800, 1000), "idle 1800s")
        XCTAssertEqual(reason(.idle, now - 1, 80_000), "context 80000 tokens")
        XCTAssertNil(reason(.idle, nil, 79_999), "no idle row and under size")
        // Anything but idle is left alone, however old or large.
        XCTAssertNil(reason(.busy, now - 9000, 500_000))
        XCTAssertNil(reason(.waiting, now - 9000, 500_000))
        XCTAssertNil(reason(nil, now - 9000, 500_000))
        // No transcript: a session that is fresh after a reset. Never again.
        XCTAssertNil(reason(.idle, now - 9000, nil))
        // A threshold of 0 turns its rule off.
        let off = ManagerResetPolicy(idleSeconds: 0, contextTokens: 0)
        XCTAssertNil(ManagerResetPolicy.reason(
            policy: off, status: .idle, idleSince: now - 9000, contextTokens: 500_000, now: now))
        let sizeOnly = ManagerResetPolicy(idleSeconds: 0, contextTokens: 80_000)
        XCTAssertNil(ManagerResetPolicy.reason(
            policy: sizeOnly, status: .idle, idleSince: now - 9000, contextTokens: 1000, now: now))
        XCTAssertEqual(ManagerResetPolicy.reason(
            policy: sizeOnly, status: .idle, idleSince: nil, contextTokens: 80_000, now: now),
            "context 80000 tokens")
    }

    func testContextTokensReadsTheManagerPanesTranscript() throws {
        let dir = try makeClaudeDir()
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: FakeRunner(), queue: DispatchQueue(label: "test.pane"))
        XCTAssertNil(driver.contextTokens(), "no session yet")
        try seedSession(in: dir, sessionId: "wanted")
        XCTAssertNil(driver.contextTokens(), "no transcript yet")
        try seedTranscript(
            in: dir.appendingPathComponent("projects"), sessionId: "wanted", lines: [userPrompt, sizedReply])
        XCTAssertEqual(driver.contextTokens(), 43_000)
    }

    func testResetClearsAnIdlePane() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = FakeRunner()
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        let done = expectation(description: "reset")
        driver.reset(command: "/clear") {
            XCTAssertTrue($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(runner.recorded(), [
            ["copy-mode", "-q", "-t", "%5"],
            ["send-keys", "-t", "%5", "/clear", "Enter"],
        ])
    }

    func testResetLeavesAPaneThatIsNotIdleByEverySource() throws {
        // The hook row, as the screen settles it, and the status file must
        // both say idle. Each of these has one that does not. (No hook row
        // is no opinion: the file answers, as for a turn.)
        let cases: [(row: ManagerTurnStatus?, file: String)] = [
            (.busy, "idle"), (.waiting, "idle"), (nil, "thinking"), (.idle, "busy"), (.idle, "waiting"),
        ]
        for (row, file) in cases {
            let dir = try makeClaudeDir()
            try write(["sessionId": "wanted", "tmux": "mux-manager:@1.%5", "status": file],
                      to: dir.appendingPathComponent("sessions/4242.json"))
            let runner = FakeRunner()
            let driver = ManagerPaneDriver(
                config: config(claudeDir: dir), runner: runner,
                statusOverride: { _ in row }, queue: DispatchQueue(label: "test.pane"))
            let done = expectation(description: "refused")
            driver.reset(command: "/clear") {
                XCTAssertFalse($0, "row \(String(describing: row)), file \(file)")
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(typed(runner), [], "row \(String(describing: row)), file \(file)")
        }
    }

    func testResetDoesNotInterruptATurn() throws {
        let dir = try makeClaudeDir()
        try seedSession(in: dir, sessionId: "wanted")
        let runner = FakeRunner()
        let driver = ManagerPaneDriver(
            config: config(claudeDir: dir), runner: runner,
            statusOverride: { _ in .idle }, queue: DispatchQueue(label: "test.pane"))
        driver.send("survey", onDelta: { _ in }) { _ in }
        let done = expectation(description: "refused")
        driver.reset(command: "/clear") {
            XCTAssertFalse($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        driver.cancel()
        XCTAssertFalse(runner.recorded().contains(["send-keys", "-t", "%5", "/clear", "Enter"]))
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
    /// What a command prints, for a test that gives the pane a screen.
    var output: (([String]) -> String?)?

    private let lock = NSLock()
    private var calls: [(path: String, args: [String], stdin: Data?)] = []

    /// What `list-panes` prints for the session: one marked agent pane unless a
    /// test says otherwise. The lookups are counted apart from `recorded()`,
    /// which holds what was done to a pane.
    var panes = "%5 1 0 0 /Users/me/manager\n"
    /// The pane cannot be captured, though tmux answers.
    var unreadable = false
    private var lookupCount = 0

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        let failing = self.failing
        if args.first == "list-panes" {
            lookupCount += 1
            lock.unlock()
            return failing ? nil : panes
        }
        calls.append((path, args, stdin))
        lock.unlock()
        onRun?(args)
        if unreadable, args.first == "capture-pane" { return nil }
        return failing ? nil : (output?(args) ?? "")
    }

    func lookups() -> Int {
        lock.lock(); defer { lock.unlock() }
        return lookupCount
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

/// Runs real tmux on a server of the test's own (`tmux -L <name>`), never the
/// default one.
private final class PrivateTmux: CommandRunner {
    let path: String
    let name = "mm-maestro-\(UUID().uuidString.prefix(8))"
    /// The whole environment of each tmux call, when a test gives one.
    private let fixedEnvironment: [String: String]?
    /// The process the server must not outlive.
    private let owner: Int32
    private var guarded = false

    init?(environment: [String: String]? = nil, owner: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let path = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        self.path = path
        self.fixedEnvironment = environment
        self.owner = owner
    }

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-L", name] + args
        // No $TMUX: it names the live server.
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        process.environment = fixedEnvironment ?? environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        if let input, let stdin {
            input.fileHandleForWriting.write(stdin)
            input.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // The server exists from its first session on, whoever starts it.
        if args.contains("new-session"), !guarded {
            guarded = true
            _ = run(self.path, TmuxOrphanGuard.argv(tmux: self.path, socket: name, owner: owner), stdin: nil)
        }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    func tmux(_ args: [String]) -> String {
        (run(path, args, stdin: nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func screen(_ pane: String) -> String { tmux(["capture-pane", "-p", "-t", pane]) }
}
