import XCTest

// GatewayKey.swift, JevClient.swift and SessionTriage.swift compile directly into
// this test target, like the other logic tests. The request and response
// fixtures are the ones sent to and returned by the live gateway on 2026-09-22.
final class SessionTriageTests: XCTestCase {

    // MARK: Fixtures

    /// The request body sent live, keys sorted. jev answered it with `liveResponse`.
    private let liveRequest = #"""
    {"questions":{"goalMet":{"instructions":"The goal the user stated at the start of this thread is achieved.","type":"boolean"},"important":{"instructions":"This thread affects production, money, customer data, or another person who waits on the user.","type":"boolean"},"safeToClose":{"instructions":"The user can close this thread now and lose nothing.","type":"boolean"},"threadState":{"criteria":{"abandoned":"The user moved on and left the thread unfinished.","blocked":"The agent hit an error or obstacle it cannot get past on its own.","done":"The stated goal is finished and nothing is left to do.","needs_user_action":"The user must do something outside the chat, such as run a command, approve a merge, or log in.","needs_user_reply":"The agent asked the user a question or for a decision and waits for the answer.","waiting_on_third_party":"The work waits on someone or something other than the user, such as CI, a reviewer, or a deploy.","working":"The agent is still doing the task and will go on without the user."},"instructions":"Which one best describes where this coding-agent thread stands now?","type":"choice"},"unshippedWork":{"instructions":"The thread mentions work that is not yet committed, pushed, or merged.","type":"boolean"},"urgent":{"instructions":"The user should look at this thread within the next hour.","type":"boolean"},"userActionOutstanding":{"instructions":"The user still has to do something before this work is complete.","type":"boolean"},"waitingOnThirdParty":{"instructions":"The work waits on a person or system other than the user, such as CI, a reviewer, or a deploy.","type":"boolean"}},"state":{"agentStatus":"idle","goal":"Add a dark mode toggle to the settings page and open a PR.","idleMinutes":14,"recentTurns":[{"role":"user","text":"Add a dark mode toggle to the settings page and open a PR."},{"role":"assistant","text":"[tool: Bash]\n[tool: Edit]\nThe toggle is in place and the tests pass. I committed it on feat/dark-mode and pushed. PR #412 is open; CI is running. Want me to merge once CI is green?"}]}}
    """#

    /// The live response, verbatim. It holds no key.
    private let liveResponse = #"""
    {"answers":{"threadState":{"type":"choice","choice":"needs_user_reply","probabilities":{"abandoned":0,"waiting_on_third_party":0.22,"needs_user_reply":0.77,"needs_user_action":0,"blocked":0,"done":0.01,"working":0}},"goalMet":{"type":"boolean","probability":0.82},"userActionOutstanding":{"type":"boolean","probability":0.64},"waitingOnThirdParty":{"type":"boolean","probability":0.9},"unshippedWork":{"type":"boolean","probability":0.09},"safeToClose":{"type":"boolean","probability":0.43},"urgent":{"type":"boolean","probability":0.61},"important":{"type":"boolean","probability":0.33}},"rounding":{"probabilityDecimals":2,"scoreDecimals":2},"usage":{"inputTokens":794,"outputTokens":212},"warnings":[],"providerMetadata":{"typesafe":{"confidence":{"threadState":0.73}},"gateway":{"routing":{"originalModelId":"typesafe-ai/jev","resolvedProvider":"typesafe-ai","fallbacksAvailable":[],"planningReasoning":"System credentials planned for: typesafe-ai. Total execution order: typesafe-ai(system)","canonicalSlug":"typesafe-ai/jev","finalProvider":"typesafe-ai","modelAttemptCount":1,"modelAttempts":[{"canonicalSlug":"typesafe-ai/jev","success":true,"providerAttemptCount":1,"providerAttempts":[{"provider":"typesafe-ai","credentialType":"system","success":true,"startTime":1790137945260,"endTime":1790137945400,"statusCode":200}]}],"totalProviderAttemptCount":1},"cost":"0","marketCost":"0.000033348","surchargeCost":"0","gatewayCost":"0","generationId":"gen_01M368JJVZG0C4QZ3P05HAVFDY"}}}
    """#

    /// What the gateway returned for a bad key.
    private let unauthorized = #"""
    {"error":{"message":"Authentication failed. Check that your Vercel credential is valid and has access to AI Gateway.","type":"authentication_error"}}
    """#

    /// A Claude Code transcript in its real record shapes: harness records, a
    /// slash-command echo, a meta note, tool calls and results, and an ai-title.
    private let transcript: [String] = [
        #"{"type":"permission-mode","permissionMode":"auto","sessionId":"s1"}"#,
        #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: local command output."}}"#,
        #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the login redirect bug"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed and committed. Push?"}]}}"#,
        #"{"type":"ai-title","aiTitle":"Login redirect fix","sessionId":"s1"}"#,
        #"{"type":"user","message":{"role":"user","content":"yes push"}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Pushed."}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tex"#,
    ]

    // MARK: State

    func testStateCarriesGoalTitleAndTurns() {
        let state = SessionTriage.state(
            head: transcript, tail: transcript, agentStatus: "idle", idleMinutes: 3)
        XCTAssertEqual(state.goal, "Fix the login redirect bug\n\nSummary: Login redirect fix")
        XCTAssertEqual(state.recentTurns, [
            TriageTurn(role: "user", text: "Fix the login redirect bug"),
            TriageTurn(role: "assistant",
                       text: "Looking.\n[tool: Bash]\n[tool: Edit]\nFixed and committed. Push?"),
            TriageTurn(role: "user", text: "yes push"),
            TriageTurn(role: "assistant", text: "Pushed."),
        ])
        XCTAssertEqual(state.agentStatus, "idle")
        XCTAssertEqual(state.idleMinutes, 3)
    }

    func testStateKeepsTheLastEightTurns() {
        var lines: [String] = []
        for i in 1...6 {
            lines.append(#"{"type":"user","message":{"role":"user","content":"prompt \#(i)"}}"#)
            lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply \#(i)"}]}}"#)
        }
        let state = SessionTriage.state(head: lines, tail: lines, agentStatus: "idle", idleMinutes: 0)
        XCTAssertEqual(state.recentTurns.count, 8)
        XCTAssertEqual(state.recentTurns.first, TriageTurn(role: "user", text: "prompt 3"))
        XCTAssertEqual(state.recentTurns.last, TriageTurn(role: "assistant", text: "reply 6"))
        XCTAssertEqual(state.goal, "prompt 1")
    }

    func testLongTurnsAreCut() {
        let long = String(repeating: "a", count: 2_000) + "END"
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"START\#(long)"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"START\#(long)"}]}}"#,
        ]
        let turns = SessionTriage.state(head: [], tail: lines, agentStatus: "idle", idleMinutes: 0)
            .recentTurns
        XCTAssertEqual(turns.map(\.text.count), [1_500, 1_500])
        // A prompt keeps its start; a reply keeps its end, where the question is.
        XCTAssertTrue(turns[0].text.hasPrefix("START"))
        XCTAssertTrue(turns[1].text.hasSuffix("END"))
    }

    func testFirstPromptTurnsASlashCommandIntoItsGoal() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-message>bug-fix</command-message>\n<command-name>/bug-fix</command-name>\n<command-args>the sidebar freezes</command-args>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"a later prompt"}}"#,
        ]
        XCTAssertEqual(ManagerTranscript.firstPrompt(lines: lines), "/bug-fix the sidebar freezes")
        // A command with no arguments names no goal: the next prompt is the goal.
        XCTAssertEqual(ManagerTranscript.firstPrompt(lines: Array(lines[0...0]) + [lines[2]]), "a later prompt")
    }

    func testTitleComesFromTheHeadWhenTheTailHasNone() {
        let head = [
            #"{"type":"user","message":{"role":"user","content":"Fix the login redirect bug"}}"#,
            #"{"type":"ai-title","aiTitle":"Login redirect fix","sessionId":"s1"}"#,
        ]
        let tail = [#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Pushed."}]}}"#]
        let state = SessionTriage.state(head: head, tail: tail, agentStatus: "idle", idleMinutes: 0)
        XCTAssertEqual(state.goal, "Fix the login redirect bug\n\nSummary: Login redirect fix")
    }

    // MARK: Request

    func testRequestMatchesTheLiveGoldenBody() throws {
        let state = TriageState(
            goal: "Add a dark mode toggle to the settings page and open a PR.",
            recentTurns: [
                TriageTurn(role: "user", text: "Add a dark mode toggle to the settings page and open a PR."),
                TriageTurn(role: "assistant", text: "[tool: Bash]\n[tool: Edit]\nThe toggle is in place and the tests pass. I committed it on feat/dark-mode and pushed. PR #412 is open; CI is running. Want me to merge once CI is green?"),
            ],
            agentStatus: "idle", idleMinutes: 14)
        let request = try JevClient(key: "test-key")
            .request(state: state, questions: SessionTriage.questions)
        XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v4/ai/evaluation-model")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ai-gateway-protocol-version"), "0.0.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ai-evaluation-model-specification-version"), "4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ai-model-id"), "typesafe-ai/jev")
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self), liveRequest)
    }

    // MARK: Response

    func testDecodesTheLiveResponse() throws {
        let response = try JevClient.decode(data: Data(liveResponse.utf8), status: 200).get()
        XCTAssertEqual(response.answers.count, 8)
        guard case .choice(let choice, let probabilities)? = response.answers["threadState"] else {
            return XCTFail("threadState is not a choice")
        }
        XCTAssertEqual(choice, "needs_user_reply")
        XCTAssertEqual(probabilities["needs_user_reply"], 0.77)
        XCTAssertEqual(response.answers["goalMet"], .boolean(0.82))
        XCTAssertEqual(response.usage, JevResponse.Usage(inputTokens: 794, outputTokens: 212))
        XCTAssertEqual(response.providerMetadata?.gateway?.marketCost, "0.000033348")
        let verdict = SessionTriage.verdict(response)
        XCTAssertEqual(verdict.chip, .yourMove)
        XCTAssertEqual(verdict.tooltip, "Goal met 82% · Your action 64% · Third party 90% · Unshipped 9%")
    }

    func testUnauthorizedCarriesTheGatewayMessage() {
        let result = JevClient.decode(data: Data(unauthorized.utf8), status: 401)
        XCTAssertEqual(result, .failure(.unauthorized(
            "Authentication failed. Check that your Vercel credential is valid and has access to AI Gateway.")))
    }

    func testServerErrorAndGarbageFail() {
        XCTAssertEqual(JevClient.decode(data: Data(), status: 500), .failure(.http(500, "")))
        XCTAssertEqual(JevClient.decode(data: Data("{}".utf8), status: 200), .failure(.badResponse))
    }

    // MARK: Chip rules

    private func answers(
        _ state: [String: Double], chosen: String? = nil, _ booleans: [String: Double] = [:]
    ) -> [String: JevAnswer] {
        let pick = chosen ?? state.max { $0.value < $1.value }?.key ?? "working"
        var out: [String: JevAnswer] = ["threadState": .choice(pick, probabilities: state)]
        for (k, v) in booleans { out[k] = .boolean(v) }
        return out
    }

    func testUrgentNeedsAUserFacingState() {
        XCTAssertEqual(SessionTriage.chip(answers(["blocked": 0.6, "working": 0.4], ["urgent": 0.85])), .urgent)
        XCTAssertEqual(SessionTriage.chip(answers(["needs_user_reply": 0.5, "done": 0.4], ["urgent": 0.8])), .urgent)
        // Urgent but the agent is still working: no chip.
        XCTAssertNil(SessionTriage.chip(answers(["working": 0.9], ["urgent": 0.95])))
        // Not urgent enough falls through to the next rule.
        XCTAssertEqual(SessionTriage.chip(answers(["needs_user_reply": 0.9], ["urgent": 0.79])), .yourMove)
    }

    func testYourMoveCountsReplyAndActionTogether() {
        XCTAssertEqual(SessionTriage.chip(answers(["needs_user_reply": 0.4, "needs_user_action": 0.3, "done": 0.3])), .yourMove)
        XCTAssertNil(SessionTriage.chip(answers(["needs_user_reply": 0.4, "needs_user_action": 0.2, "working": 0.4])))
    }

    func testWaitingAndBlocked() {
        XCTAssertEqual(SessionTriage.chip(answers(["waiting_on_third_party": 0.7, "done": 0.3])), .waiting)
        XCTAssertEqual(SessionTriage.chip(answers(["blocked": 0.7, "working": 0.3])), .blocked)
    }

    func testCloseNeedsFinishedSafeAndShipped() {
        let safe = ["safeToClose": 0.9, "unshippedWork": 0.1]
        XCTAssertEqual(SessionTriage.chip(answers(["done": 0.8, "working": 0.2], safe)), .close)
        XCTAssertEqual(SessionTriage.chip(answers(["done": 0.4, "abandoned": 0.4], safe)), .close)
        // Not safe enough: done, not close.
        XCTAssertEqual(SessionTriage.chip(answers(["done": 0.8], ["safeToClose": 0.79, "unshippedWork": 0.1])), .done)
        // Abandoned but not safe: nothing clears the bar.
        XCTAssertNil(SessionTriage.chip(answers(["abandoned": 0.9], ["safeToClose": 0.5, "unshippedWork": 0.1])))
    }

    func testUnshippedWorkBlocksClose() {
        XCTAssertEqual(SessionTriage.chip(answers(["done": 0.9], ["safeToClose": 0.95, "unshippedWork": 0.3])), .done)
        // Missing is not "none": a response without unshippedWork never says Close?.
        XCTAssertEqual(SessionTriage.chip(answers(["done": 0.9], ["safeToClose": 0.95])), .done)
    }

    func testFailsClosedOnMissingAnswers() {
        XCTAssertNil(SessionTriage.chip([:]))
        XCTAssertNil(SessionTriage.chip(["urgent": .boolean(1), "safeToClose": .boolean(1)]))
        // A boolean where a choice belongs counts for nothing.
        XCTAssertNil(SessionTriage.chip(["threadState": .boolean(1)]))
        XCTAssertEqual(SessionTriage.tooltip([:]), "Goal met ? · Your action ? · Third party ? · Unshipped ?")
    }

    func testRollupPicksTheMostUrgent() {
        let done = TriageVerdict(chip: .done, tooltip: "a")
        let move = TriageVerdict(chip: .yourMove, tooltip: "b")
        let none = TriageVerdict(chip: nil, tooltip: "c")
        XCTAssertEqual(TriageVerdict.rollup([done, none, move]), move)
        XCTAssertNil(TriageVerdict.rollup([none]))
        var pane = TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true)
        pane.triage = move
        let session = TmuxSession(name: "s", attached: false, windows: [
            TmuxWindow(index: 0, name: "w", active: true, panes: [pane]),
        ])
        XCTAssertEqual(session.triage, move)
    }

    func testDoneAndCloseWaitUntilEveryAgentPaneIsIdle() {
        func pane(_ i: Int, _ attention: AttentionStatus, _ chip: TriageChip?) -> TmuxPane {
            var p = TmuxPane(id: "%\(i)", index: i, command: "claude", title: "", active: i == 0)
            p.attention = attention
            p.triage = chip.map { TriageVerdict(chip: $0, tooltip: "") }
            return p
        }
        func session(_ panes: [TmuxPane]) -> TmuxSession {
            TmuxSession(name: "s", attached: false, windows: [
                TmuxWindow(index: 0, name: "w", active: true, panes: panes),
            ])
        }
        // Another pane runs, or waits with no verdict: not done, not closable.
        XCTAssertNil(session([pane(0, .idle, .close), pane(1, .busy, nil)]).triage)
        XCTAssertNil(session([pane(0, .idle, .done), pane(1, .waiting, nil)]).triage)
        // A chip that asks for the user still shows.
        XCTAssertEqual(session([pane(0, .idle, .yourMove), pane(1, .busy, nil)]).triage?.chip, .yourMove)
        XCTAssertEqual(session([pane(0, .idle, .close), pane(1, .busy, nil), pane(2, .idle, .waiting)])
            .triage?.chip, .waiting)
        // Every agent pane idle (a plain shell does not count): Close? shows.
        XCTAssertEqual(session([pane(0, .idle, .close), pane(1, .unknown, nil)]).triage?.chip, .close)
    }

    // MARK: Key store

    func testInMemoryStoreRoundTrips() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.read())
        XCTAssertTrue(store.write("k"))
        XCTAssertEqual(store.read(), "k")
        XCTAssertTrue(store.delete())
        XCTAssertNil(store.read())
    }

    func testKeyIsSavedOnlyAfterTheTestCallSucceeds() {
        let empty = InMemorySecretStore()
        let fake = FakeTransport()
        var failure: JevError?? = .none
        GatewayKey.verifyAndSave("bad", store: empty, transport: fake) { failure = .some($0) }
        XCTAssertEqual(fake.pending.count, 1)
        fake.answer(body: unauthorized, status: 401)
        XCTAssertEqual(failure, .some(.unauthorized(
            "Authentication failed. Check that your Vercel credential is valid and has access to AI Gateway.")))
        XCTAssertNil(empty.read())

        GatewayKey.verifyAndSave("good", store: empty, transport: fake) { failure = .some($0) }
        fake.answer(body: liveResponse)
        XCTAssertEqual(failure, .some(nil))
        XCTAssertEqual(empty.read(), "good")
    }

    func testSavingTheKeyPostsDidChangeAndAFailureDoesNot() {
        let store = InMemorySecretStore()
        let fake = FakeTransport()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: GatewayKey.didChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        GatewayKey.verifyAndSave("bad", store: store, transport: fake) { _ in }
        fake.answer(body: unauthorized, status: 401)
        XCTAssertEqual(posts, 0)
        GatewayKey.verifyAndSave("good", store: store, transport: fake) { _ in }
        fake.answer(body: liveResponse)
        XCTAssertEqual(posts, 1)
    }

    // MARK: Local only

    func testOnlyTheLocalHostTriages() {
        XCTAssertNotNil(TmuxService(host: .local).triage)
        XCTAssertNil(TmuxService(host: Host(name: "devbox", sshAlias: "devbox")).triage)
    }

    // MARK: Scheduler

    /// Records requests; the test answers them.
    private final class FakeTransport: HTTPTransport {
        var pending: [(URLRequest, (Result<(Data, Int), Error>) -> Void)] = []
        func send(_ request: URLRequest, completion: @escaping (Result<(Data, Int), Error>) -> Void) {
            pending.append((request, completion))
        }
        func answer(_ i: Int = 0, body: String, status: Int = 200) {
            let (_, done) = pending.remove(at: i)
            done(.success((Data(body.utf8), status)))
        }
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var files: [String: TranscriptFile] = [:]
    private let store = InMemorySecretStore("key")
    private let transport = FakeTransport()

    private func service() -> SessionTriageService {
        SessionTriageService(
            store: store, transport: transport,
            now: { [unowned self] in self.clock },
            read: { [unowned self] _ in .init(head: self.transcript, tail: self.transcript) },
            run: { $0() })
    }

    private func tree(_ panes: [(String, AttentionStatus)]) -> [TmuxSession] {
        let tmuxPanes = panes.enumerated().map { i, p -> TmuxPane in
            var pane = TmuxPane(id: "%\(i)", index: i, command: "claude", title: "", active: i == 0)
            pane.claudeSessionId = p.0
            pane.attention = p.1
            return pane
        }
        return [TmuxSession(name: "s", attached: false, windows: [
            TmuxWindow(index: 0, name: "w", active: true, panes: tmuxPanes),
        ])]
    }

    private func verdicts(_ sessions: [TmuxSession]) -> [TriageChip?] {
        sessions.flatMap { $0.windows.flatMap { $0.panes.map { $0.triage?.chip } } }
    }

    /// A transcript last written `age` seconds before the clock.
    private func written(_ sid: String, size: UInt64 = 100, age: TimeInterval = 60) {
        files[sid] = TranscriptFile(
            path: "/t/\(sid).jsonl", size: size, mtime: clock.addingTimeInterval(-age))
    }

    func testClassifiesAnIdleQuietThreadAndShowsItNextPoll() {
        let s = service()
        written("a")
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [nil])
        XCTAssertEqual(transport.pending.count, 1)
        let body = transport.pending[0].0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(body.contains(#""goal":"Fix the login redirect bug"#))
        XCTAssertTrue(body.contains(#""idleMinutes":1"#))
        transport.answer(body: liveResponse)
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [.yourMove])
        // Unchanged transcript: no second call.
        XCTAssertTrue(transport.pending.isEmpty)
    }

    func testNoKeyNoCall() {
        store.delete()
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        XCTAssertTrue(transport.pending.isEmpty)
    }

    func testAMissingKeyIsLookedForAgainAfterAMinute() {
        store.delete()
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        store.write("key")
        clock = clock.addingTimeInterval(59)
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        XCTAssertTrue(transport.pending.isEmpty)
        clock = clock.addingTimeInterval(1)
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        XCTAssertEqual(transport.pending.count, 1)
    }

    func testRemovingTheKeyHidesVerdicts() {
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        transport.answer(body: liveResponse)
        store.delete()
        s.keyChanged()
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [nil])
    }

    func testRunningAgentIsNotClassifiedAndHidesItsChip() {
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        transport.answer(body: liveResponse)
        written("a", size: 200)
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .busy)]), transcripts: files)), [nil])
        XCTAssertTrue(transport.pending.isEmpty)
    }

    func testWaitsForTwentyQuietSeconds() {
        let s = service()
        written("a", age: 19)
        _ = s.apply(to: tree([("a", .waiting)]), transcripts: files)
        XCTAssertTrue(transport.pending.isEmpty)
        clock = clock.addingTimeInterval(1)
        _ = s.apply(to: tree([("a", .waiting)]), transcripts: files)
        XCTAssertEqual(transport.pending.count, 1)
        let body = transport.pending[0].0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(body.contains(#""agentStatus":"waiting_for_user""#))
    }

    func testChangedTranscriptIsClassifiedAgain() {
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        transport.answer(body: liveResponse)
        written("a", size: 150)
        // The old verdict was for another transcript: no chip while the new one
        // is fetched.
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [nil])
        XCTAssertEqual(transport.pending.count, 1)
        transport.answer(body: liveResponse)
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [.yourMove])
    }

    func testAVerdictThatLandsAfterThePaneRanIsNotShown() {
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        XCTAssertEqual(transport.pending.count, 1)
        // The agent starts again and writes; then the old call answers.
        written("a", size: 300, age: 0)
        _ = s.apply(to: tree([("a", .busy)]), transcripts: files)
        transport.answer(body: liveResponse)
        // Idle again, not yet quiet: the verdict read a shorter transcript.
        clock = clock.addingTimeInterval(5)
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [nil])
        XCTAssertTrue(transport.pending.isEmpty)
    }

    func testForgetsSessionsThatAreGone() {
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        transport.answer(body: liveResponse)
        files = [:]
        _ = s.apply(to: [], transcripts: files)
        // Back with the same transcript: the verdict was dropped, so it is fetched anew.
        written("a")
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [nil])
        XCTAssertEqual(transport.pending.count, 1)
    }

    func testTheTailReaderHandsOverClaudeTranscriptFiles() throws {
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        let folder = projects.appendingPathComponent("-r-a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        let rollout = projects.appendingPathComponent("rollout.jsonl")
        try "{}\n".write(to: rollout, atomically: true, encoding: .utf8)
        let tails = TranscriptTailReader(projectsDir: projects)
            .read(sessionCwds: ["s1": "/r/a"], codexRollouts: ["c1": rollout.path])
        XCTAssertEqual(Array(tails.files.keys), ["s1"], "Codex rollouts are not Claude transcripts")
        XCTAssertEqual(tails.files["s1"]?.path, file.path)
        XCTAssertEqual(tails.files["s1"]?.size, 3)
    }

    func testAtMostTwoInFlight() {
        let s = service()
        for sid in ["a", "b", "c"] { written(sid) }
        let panes: [(String, AttentionStatus)] = [("a", .idle), ("b", .idle), ("c", .idle)]
        _ = s.apply(to: tree(panes), transcripts: files)
        XCTAssertEqual(transport.pending.count, 2)
        _ = s.apply(to: tree(panes), transcripts: files)
        XCTAssertEqual(transport.pending.count, 2)
        transport.answer(body: liveResponse)
        _ = s.apply(to: tree(panes), transcripts: files)
        XCTAssertEqual(transport.pending.count, 2)
    }

    func testFailureBacksOffFiveMinutes() {
        let s = service()
        written("a")
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        transport.answer(body: liveResponse)
        written("a", size: 150)
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        transport.answer(body: "", status: 500)
        XCTAssertEqual(verdicts(s.apply(to: tree([("a", .idle)]), transcripts: files)), [nil])
        XCTAssertTrue(transport.pending.isEmpty)
        clock = clock.addingTimeInterval(299)
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        XCTAssertTrue(transport.pending.isEmpty)
        clock = clock.addingTimeInterval(1)
        _ = s.apply(to: tree([("a", .idle)]), transcripts: files)
        XCTAssertEqual(transport.pending.count, 1)
    }

    func testPaneWithoutClaudeSessionIsSkipped() {
        let s = service()
        var sessions = tree([("a", .idle)])
        sessions[0].windows[0].panes[0].claudeSessionId = nil
        written("a")
        _ = s.apply(to: sessions, transcripts: files)
        XCTAssertTrue(transport.pending.isEmpty)
    }
}
