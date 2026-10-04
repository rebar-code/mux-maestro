import XCTest

// ManagerStore.swift compiles directly into this test target (no app host /
// @testable import), same as the other logic tests. The `mux` CLI is exercised
// as a real subprocess against a temp-dir DB.
final class ManagerStoreTests: XCTestCase {
    private var dbPath = ""

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-\(UUID().uuidString).db").path
    }

    override func tearDownWithError() throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = dbPath + suffix
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }
    }

    private func makeStore() throws -> ManagerStore {
        try ManagerStore(dbPath: dbPath)
    }

    // MARK: Schema + empty reads

    func testEmptyReads() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.reviewItems(), [])
        XCTAssertEqual(try store.reviewItems(includeDismissed: true), [])
        XCTAssertEqual(try store.unseenNotifications(), [])
    }

    // MARK: upsert insert + conflict update

    func testUpsertInsertThenConflictUpdate() throws {
        let store = try makeStore()
        try store.upsertReview(key: "k", session: "devbox", severity: .warn, text: "first")
        let inserted = try XCTUnwrap(try store.reviewItems().first)
        XCTAssertEqual(inserted.text, "first")
        XCTAssertEqual(inserted.severity, .warn)
        let createdAt = try firstCreatedAt()

        // Ensure the clock advances so updated_at can move.
        Thread.sleep(forTimeInterval: 1.1)
        try store.upsertReview(key: "k", session: "devbox", severity: .blocked, text: "second")

        let items = try store.reviewItems()
        XCTAssertEqual(items.count, 1)
        let updated = items[0]
        XCTAssertEqual(updated.text, "second")
        XCTAssertEqual(updated.severity, .blocked)
        XCTAssertGreaterThan(updated.updatedAt, inserted.updatedAt)
        XCTAssertEqual(try firstCreatedAt(), createdAt, "created_at preserved across upsert")
    }

    func testUpsertPreservesDismissed() throws {
        let store = try makeStore()
        try store.upsertReview(key: "k", text: "first")
        try store.dismiss(key: "k")
        XCTAssertEqual(try store.reviewItems(), [])

        try store.upsertReview(key: "k", text: "updated")
        // dismissed intentionally preserved on conflict.
        XCTAssertEqual(try store.reviewItems(), [])
        let all = try store.reviewItems(includeDismissed: true)
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all[0].dismissed)
        XCTAssertEqual(all[0].text, "updated")
    }

    // MARK: dismiss

    func testDismissHidesFromDefaultButVisibleWhenIncluded() throws {
        let store = try makeStore()
        try store.upsertReview(key: "k", text: "t")
        try store.dismiss(key: "k")
        XCTAssertTrue(try store.reviewItems().isEmpty)
        let included = try store.reviewItems(includeDismissed: true)
        XCTAssertEqual(included.count, 1)
        XCTAssertTrue(included[0].dismissed)
    }

    // MARK: ordering

    func testSeverityOrdering() throws {
        let store = try makeStore()
        try store.upsertReview(key: "i", severity: .info, text: "info")
        try store.upsertReview(key: "b", severity: .blocked, text: "blocked")
        try store.upsertReview(key: "w", severity: .warn, text: "warn")
        let keys = try store.reviewItems().map(\.key)
        XCTAssertEqual(keys, ["b", "w", "i"])
    }

    func testUnknownSeverityMapsToInfo() throws {
        XCTAssertEqual(ManagerReviewItem.Severity(rawValue: "bogus"), .info)
        XCTAssertEqual(ManagerReviewItem.Severity(rawValue: "blocked"), .blocked)
    }

    // MARK: notifications

    func testNotificationsSeenLifecycle() throws {
        let store = try makeStore()
        try store.addNotification(session: "a", text: "one")
        try store.addNotification(session: "b", text: "two")
        let unseen = try store.unseenNotifications()
        XCTAssertEqual(unseen.map(\.text), ["one", "two"])
        XCTAssertEqual(unseen.map(\.session), ["a", "b"])

        try store.markSeen(upTo: unseen[0].id)
        XCTAssertEqual(try store.unseenNotifications().map(\.text), ["two"])

        try store.markSeen(upTo: unseen[1].id)
        XCTAssertEqual(try store.unseenNotifications(), [])
    }

    func testWindowRoundTrips() throws {
        let store = try makeStore()
        try store.upsertReview(key: "w", window: 3, text: "t")
        try store.upsertReview(key: "n", window: nil, text: "t")
        let byKey = Dictionary(uniqueKeysWithValues: try store.reviewItems().map { ($0.key, $0) })
        XCTAssertEqual(byKey["w"]?.window, 3)
        XCTAssertNil(byKey["n"]?.window ?? nil)
    }

    // MARK: session snapshot

    func testAttentionMapsOntoSurveyStates() {
        XCTAssertEqual(ManagerSessionRow.State(.waiting), .waiting)
        XCTAssertEqual(ManagerSessionRow.State(.busy), .active)
        XCTAssertEqual(ManagerSessionRow.State(.idle), .inactive)
        // No Claude session mapped to the tmux session is not "working".
        XCTAssertEqual(ManagerSessionRow.State(.unknown), .inactive)
    }

    func testSessionStateUnknownRawValueMapsToInactive() {
        XCTAssertEqual(ManagerSessionRow.State(rawValue: "bogus"), .inactive)
        XCTAssertEqual(ManagerSessionRow.State(rawValue: "waiting"), .waiting)
        XCTAssertEqual(ManagerSessionRow.State(rawValue: "active"), .active)
    }

    func testSessionStateSortRankPutsWaitingFirst() {
        let ranked = [ManagerSessionRow.State.inactive, .active, .waiting]
            .sorted { $0.sortRank < $1.sortRank }
        XCTAssertEqual(ranked, [.waiting, .active, .inactive])
    }

    func testReplaceSessionsRoundTripsAndOrders() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.sessions(), [])
        try store.replaceSessions([
            sessionRow("quiet", state: .inactive),
            sessionRow("stuck", state: .waiting, attached: true),
            sessionRow("busy", state: .active, host: "devbox"),
        ])
        let rows = try store.sessions()
        XCTAssertEqual(rows.map(\.name), ["stuck", "busy", "quiet"], "waiting → active → inactive")
        let stuck = rows[0]
        XCTAssertEqual(stuck.host, "localhost")
        XCTAssertTrue(stuck.attached)
        XCTAssertEqual(stuck.windows, 2)
        XCTAssertEqual(stuck.panes, 3)
        XCTAssertEqual(stuck.cwd, "/tmp/stuck")
    }

    func testReplaceSessionsIsASnapshotNotAMerge() throws {
        let store = try makeStore()
        try store.replaceSessions([sessionRow("gone"), sessionRow("stays")])
        try store.replaceSessions([sessionRow("stays")])
        XCTAssertEqual(try store.sessions().map(\.name), ["stays"])
        try store.replaceSessions([])
        XCTAssertEqual(try store.sessions(), [])
    }

    /// The same session name on two hosts is two rows (the PK is host+name).
    func testSameSessionNameOnTwoHosts() throws {
        let store = try makeStore()
        try store.replaceSessions([
            sessionRow("dev", host: "localhost"), sessionRow("dev", host: "devbox"),
        ])
        XCTAssertEqual(try store.sessions().map(\.host), ["devbox", "localhost"])
    }

    // MARK: mux sessions CLI

    func testMuxSessionsListShape() throws {
        let store = try makeStore()
        try store.replaceSessions([
            sessionRow("quiet", state: .inactive),
            sessionRow("stuck", state: .waiting, attached: true),
        ])
        let lines = try self.store(mux: ["sessions"]).split(separator: "\n").map(String.init)
        // status|name|host|attached|windows|panes|cwd
        XCTAssertEqual(lines, [
            "waiting|stuck|localhost|attached|2|3|/tmp/stuck",
            "inactive|quiet|localhost|detached|2|3|/tmp/quiet",
        ])
    }

    func testMuxSessionsJSONIsFreshAndParsable() throws {
        let store = try makeStore()
        try store.replaceSessions([sessionRow("busy", state: .active)])
        let object = try sessionsJSON()
        XCTAssertEqual(object["stale"] as? Bool, false)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["name"] as? String, "busy")
        XCTAssertEqual(sessions[0]["status"] as? String, "active")
        XCTAssertEqual(sessions[0]["attached"] as? Bool, false)
        XCTAssertEqual(sessions[0]["panes"] as? Int, 3)
    }

    /// No snapshot at all reads as stale — the app isn't running.
    func testMuxSessionsEmptyIsStale() throws {
        let object = try sessionsJSON()
        XCTAssertEqual(object["stale"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(object["sessions"] as? [[String: Any]]).isEmpty)
    }

    func testMuxSessionsUnexpectedArgumentExitsTwo() {
        XCTAssertEqual(runMux(["sessions", "--nope"]).status, 2)
    }

    /// `mux sessions --json` prints the object on stdout and any staleness
    /// warning on stderr; `runMux` merges both streams, so parse the first line.
    private func sessionsJSON() throws -> [String: Any] {
        let output = try store(mux: ["sessions", "--json"])
        let line = String(try XCTUnwrap(output.split(separator: "\n").first))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func sessionRow(
        _ name: String,
        state: ManagerSessionRow.State = .inactive,
        host: String = "localhost",
        attached: Bool = false,
        windowIndexes: [Int]? = [1, 2]
    ) -> ManagerSessionRow {
        ManagerSessionRow(name: name, host: host, attached: attached, state: state,
                          windows: 2, panes: 3, cwd: "/tmp/\(name)",
                          windowIndexes: windowIndexes)
    }

    func testReplaceSessionsRoundTripsTheWindowIndexes() throws {
        let store = try makeStore()
        try store.replaceSessions([
            sessionRow("acme-app", windowIndexes: [1, 2, 7]),
            sessionRow("billing", windowIndexes: []),
            sessionRow("reports", windowIndexes: nil),
        ])
        XCTAssertEqual(try store.sessions().map(\.windowIndexes), [[1, 2, 7], [], nil])
        XCTAssertEqual(
            try sqlite("SELECT '[' || COALESCE(window_indexes, 'none') || ']' FROM sessions ORDER BY name;"),
            ["[1,2,7]", "[]", "[none]"])
    }

    // MARK: work_log

    func testSchemaCreatesWorkLog() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.workLog(), [], "the table exists on a fresh DB")
        let names = try sqlite("""
        SELECT name FROM sqlite_master WHERE name IN
          ('work_log', 'work_log_session', 'work_log_last_seen') ORDER BY name;
        """)
        XCTAssertEqual(names, ["work_log", "work_log_last_seen", "work_log_session"])
    }

    /// The unique index only covers claimed rows, so several `spawned` rows can
    /// sit in the log waiting for their agent's first event.
    func testWorkLogUniqueIndexSkipsUnclaimedRows() throws {
        let store = try makeStore()
        try store.insertWorkLog(pane: "%1")
        try store.insertWorkLog(pane: "%2")
        XCTAssertEqual(try store.workLog().count, 2)
    }

    func testWorkLogOrdersByLastSeenAndParsesPRs() throws {
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        try store.insertWorkLog(sessionId: "old", repo: "acme-app", prs: "12 34",
                                firstSeen: now - 500, lastSeen: now - 500)
        try store.insertWorkLog(sessionId: "new", repo: "mux-maestro", prs: "",
                                firstSeen: now - 10, lastSeen: now)
        try store.insertWorkLog(sessionId: "odd", repo: "widget-shop", prs: "7 draft 9",
                                firstSeen: now - 100, lastSeen: now - 100)

        let rows = try store.workLog()
        XCTAssertEqual(rows.map(\.sessionId), ["new", "odd", "old"])
        XCTAssertEqual(rows[0].prs, [])
        XCTAssertEqual(rows[1].prs, [7, 9], "a non-number token is dropped, not the row")
        XCTAssertEqual(rows[2].prs, [12, 34])
        XCTAssertEqual(try store.workLog(limit: 1).map(\.sessionId), ["new"])
    }

    func testWorkLogRoundTripsEveryColumn() throws {
        let store = try makeStore()
        try store.insertWorkLog(
            sessionId: "s1", agent: "claude", repo: "mux-maestro", branch: "feat/x",
            prs: "113", host: "devbox", session: "dev", window: 6, pane: "%42",
            cwd: "/tmp/wt", lastState: "busy", firstSeen: 1_000, lastSeen: 2_000)
        let row = try XCTUnwrap(try store.workLog().first)
        XCTAssertGreaterThan(row.id, 0)
        XCTAssertEqual(row.agent, "claude")
        XCTAssertEqual(row.repo, "mux-maestro")
        XCTAssertEqual(row.branch, "feat/x")
        XCTAssertEqual(row.prs, [113])
        XCTAssertEqual(row.host, "devbox")
        XCTAssertEqual(row.session, "dev")
        XCTAssertEqual(row.window, 6)
        XCTAssertEqual(row.pane, "%42")
        XCTAssertEqual(row.cwd, "/tmp/wt")
        XCTAssertEqual(row.lastState, "busy")
        XCTAssertEqual(row.firstSeen, 1_000)
        XCTAssertEqual(row.lastSeen, 2_000)

        try store.insertWorkLog(sessionId: "s2", window: nil, lastSeen: 3_000)
        XCTAssertNil(try store.workLog().first?.window ?? nil)
    }

    // MARK: updates feed

    func testUpdatesUnionsStopEventsAndNotificationsNewestFirst() throws {
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        try store.insertWorkLog(sessionId: "s1", host: "devbox", session: "dev", window: 3,
                                lastState: "done")
        // Dated around the notification, which the store stamps with "now".
        try store.insertAgentEvent(sessionId: "s1", event: "Stop",
                                   summary: "Shipped the fix", ts: now + 100)
        try store.addNotification(session: "toast", text: "hello")
        try store.insertAgentEvent(sessionId: "s1", event: "Stop", summary: "", ts: now - 100)
        // Noise: the storm events never reach the feed.
        try store.insertAgentEvent(sessionId: "s1", event: "PreToolUse", summary: "x", ts: now + 200)

        let rows = try store.updates(since: 0)
        XCTAssertEqual(rows.map(\.kind), [.done, .notification, .done])
        XCTAssertEqual(rows[0].text, "Shipped the fix")
        XCTAssertEqual(rows[0].sessionId, "s1")
        XCTAssertEqual(rows[0].host, "devbox", "host/session/window joined from work_log")
        XCTAssertEqual(rows[0].session, "dev")
        XCTAssertEqual(rows[0].window, 3)
        XCTAssertEqual(rows[1].text, "hello")
        XCTAssertEqual(rows[1].sessionId, "", "a notification belongs to no session")
        XCTAssertEqual(rows[1].session, "toast")
        XCTAssertEqual(rows[2].window, 3, "every event for the session joins the same row")
        XCTAssertEqual(rows[2].text, "Done", "a summary-less Stop still reads as something")
    }

    func testUpdatesForAnUnknownSessionStillShow() throws {
        let store = try makeStore()
        try store.insertAgentEvent(sessionId: "stranger", event: "Stop", summary: "hi", ts: 500)
        let row = try XCTUnwrap(try store.updates(since: 0).first)
        XCTAssertEqual(row.host, "localhost")
        XCTAssertEqual(row.session, "")
        XCTAssertNil(row.window)
        XCTAssertEqual(row.at, 500)
    }

    func testUpdatesHonourSinceAndLimit() throws {
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        try store.insertAgentEvent(sessionId: "s1", event: "Stop", summary: "old", ts: now - 100)
        try store.insertAgentEvent(sessionId: "s1", event: "Stop", summary: "new", ts: now + 100)
        try store.addNotification(text: "toast")

        XCTAssertEqual(try store.updates(since: now + 50).map(\.text), ["new"])
        XCTAssertEqual(try store.updates(since: now - 50).map(\.text), ["new", "toast"])
        XCTAssertEqual(try store.updates(since: 0, limit: 1).map(\.text), ["new"])
    }

    func testWaitingAgentsIsEmptyWithoutHookState() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.waitingAgents(), [])
    }

    // MARK: mux CLI integration

    func testMuxCLIRoundTrip() throws {
        try store(mux: ["review", "add", "--key", "sess-perms", "--session", "devbox",
                        "--severity", "blocked", "--window", "2", "--text", "it's a 'test'"])
        let store = try makeStore()
        let item = try XCTUnwrap(try store.reviewItems().first)
        XCTAssertEqual(item.key, "sess-perms")
        XCTAssertEqual(item.session, "devbox")
        XCTAssertEqual(item.severity, .blocked)
        XCTAssertEqual(item.window, 2)
        XCTAssertEqual(item.text, "it's a 'test'", "single quotes + spaces round-trip exactly")

        try self.store(mux: ["notify", "--session", "devbox", "hello", "world"])
        let note = try XCTUnwrap(try store.unseenNotifications().first)
        XCTAssertEqual(note.text, "hello world")
        XCTAssertEqual(note.session, "devbox")
    }

    func testMuxReviewDoneDeletes() throws {
        try store(mux: ["review", "add", "--key", "gone", "--text", "bye"])
        let store = try makeStore()
        XCTAssertEqual(try store.reviewItems().count, 1)
        try self.store(mux: ["review", "done", "--key", "gone"])
        XCTAssertEqual(try store.reviewItems(includeDismissed: true), [])
    }

    func testMuxReviewListShape() throws {
        try store(mux: ["review", "add", "--key", "k1", "--session", "s1",
                        "--severity", "warn", "--text", "hello there"])
        let output = try store(mux: ["review", "list"])
        let line = String(try XCTUnwrap(output.split(separator: "\n").first))
        // key|severity|host|session|dismissed|text
        XCTAssertEqual(line, "k1|warn|localhost|s1|0|hello there")
    }

    func testMuxInvalidSeverityExitsTwo() throws {
        let result = runMux(["review", "add", "--key", "k", "--text", "t", "--severity", "nope"])
        XCTAssertEqual(result.status, 2)
    }

    // MARK: mux point

    private let pointRows =
        "SELECT key, host, session, COALESCE(window, 'none'), severity, text, dismissed FROM review ORDER BY key;"

    private func seedPointSessions() throws {
        try makeStore().replaceSessions([
            sessionRow("acme-app", state: .waiting, windowIndexes: [1, 2, 7]),
            sessionRow("billing", state: .waiting, host: "devbox", windowIndexes: [0, 3]),
        ])
    }

    func testMuxPointRecordsABlockedReviewRow() throws {
        try seedPointSessions()
        try store(mux: ["point", "acme-app", "--reason", "  needs your approval "])
        try store(mux: ["point", "billing:3", "--host", "devbox", "--reason", "asks 'which' database"])
        XCTAssertEqual(try sqlite(pointRows), [
            "point:devbox:billing:3|devbox|billing|3|blocked|asks 'which' database|0",
            "point:localhost:acme-app|localhost|acme-app|none|blocked|needs your approval|0",
        ])
        let item = try XCTUnwrap(try makeStore().reviewItems().first { $0.session == "billing" })
        XCTAssertTrue(item.isPointer)
        XCTAssertEqual(item.window, 3)
    }

    // MARK: mux point --action (cards)

    private let cardRows =
        "SELECT key, v, pane, body, actions, answer, COALESCE(answered_at, 'none') FROM review_card ORDER BY key;"
    private let yes = "Yes=yes, run it"
    private let no = "No=no, stop.\nExplain why first; it's O'Brien's table."

    func testMuxPointWithActionsWritesACardTheStoreReads() throws {
        try seedPointSessions()
        try store(mux: [
            "point", "acme-app:2", "--reason", "asks whether to run the migration",
            "--pane", "%14", "--body", "It adds two columns.", "--action", yes, "--action", no,
        ])
        let item = try XCTUnwrap(try makeStore().reviewItems().first)
        XCTAssertTrue(item.isPointer)
        XCTAssertEqual(item.card, ManagerCard(
            pane: "%14", body: "It adds two columns.",
            actions: [
                ManagerCard.Action(label: "Yes", text: "yes, run it"),
                // Both lines and the quotes, exactly as given.
                ManagerCard.Action(label: "No", text: "no, stop.\nExplain why first; it's O'Brien's table."),
            ]))
        XCTAssertEqual(MobileCard(item)?.source, MobileCard.Source(
            host: "localhost", session: "acme-app", window: 2, pane: "%14"))
        // A pointer with no action has no card.
        try store(mux: ["point", "acme-app", "--reason", "needs your approval"])
        let plain = try XCTUnwrap(try makeStore().reviewItems().first { $0.window == nil })
        XCTAssertNil(plain.card)
    }

    func testTheSameQuestionKeepsItsAnswerAndANewOneDoesNot() throws {
        try seedPointSessions()
        let point = ["point", "acme-app", "--reason", "asks whether to run the migration"]
        try store(mux: point + ["--action", yes, "--action", no])
        let store = try makeStore()
        try store.recordAnswer(key: "point:localhost:acme-app", label: "Yes", at: 1_759_500_100)
        XCTAssertEqual(
            try store.reviewItems().first?.card?.answer,
            ManagerCard.Answer(label: "Yes", at: 1_759_500_100))

        // Raised again as it was: still answered. The body is not the question.
        try self.store(mux: point + ["--body", "More words.", "--action", yes, "--action", no])
        XCTAssertEqual(try store.reviewItems().first?.card?.answer?.label, "Yes")
        // Another reason, other actions or another pane: a new question.
        for change in [
            ["point", "acme-app", "--reason", "asks which database", "--action", yes, "--action", no],
            point + ["--action", yes],
            point + ["--action", yes, "--pane", "%12"],
        ] {
            try store.recordAnswer(key: "point:localhost:acme-app", label: "Yes", at: 1_759_500_100)
            try self.store(mux: change)
            let card = try XCTUnwrap(try store.reviewItems().first?.card)
            XCTAssertNil(card.answer, "\(change)")
        }
    }

    func testACardGoesWhenItsPointerGoes() throws {
        try seedPointSessions()
        let action = ["--action", yes]
        try store(mux: ["point", "acme-app", "--reason", "one"] + action)
        try store(mux: ["point", "acme-app:1", "--reason", "two"] + action)
        try store(mux: ["point", "acme-app:2", "--reason", "three"] + action)
        try store(mux: ["point", "acme-app:7", "--reason", "four"] + action)
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review_card;"), ["4"])
        // Cleared by the Maestro, through either verb.
        try store(mux: ["point", "acme-app", "--done"])
        try store(mux: ["review", "done", "--key", "point:localhost:acme-app:1"])
        // Pointed again with no action: a plain pointer.
        try store(mux: ["point", "acme-app:2", "--reason", "three"])
        XCTAssertEqual(try sqlite("SELECT key FROM review_card;"), ["point:localhost:acme-app:7"])
        // Dismissed by the human and pruned: the card goes with the row.
        let store = try makeStore()
        try store.dismiss(key: "point:localhost:acme-app:7")
        try store.pruneDismissed(olderThanDays: -1)
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review_card;"), ["0"])
    }

    func testMuxPointRefusesACardItCannotStandBehind() throws {
        try seedPointSessions()
        let point = ["point", "acme-app", "--reason", "asks a question"]
        for (args, message) in [
            (["--action", "Yes"], "--action wants LABEL=TEXT"),
            (["--action", "=yes"], "--action has no label"),
            (["--action", "Yes="], "has no text"),
            (["--action", "Yes=go\u{1B}[A"], "control character"),
            (["--action", "Y\nes=go"], "one line"),
            (["--action", "Y\u{200B}es=go"], "zero-width"),
            (["--action", String(repeating: "y", count: 41) + "=go"], "over 40 characters"),
            (["--action", "Yes=" + String(repeating: "y", count: 8193)], "over 8192 bytes"),
            (["--action", "a=1", "--action", "b=2", "--action", "c=3", "--action", "d=4", "--action", "e=5"],
             "at most 4 actions"),
            (["--action", yes, "--pane", "12"], "--pane wants a pane id like %12"),
            (["--action", yes, "--pane", "%1;kill-server"], "--pane wants a pane id like %12"),
            (["--action", yes, "--body", String(repeating: "b", count: 281)], "over 280 characters"),
            (["--action", yes, "--body", "a\u{202E}b"], "zero-width"),
        ] {
            let result = runMux(point + args)
            XCTAssertEqual(result.status, 2, "\(args)")
            XCTAssertTrue(result.output.contains(message), "\(args): \(result.output)")
        }
        XCTAssertEqual(runMux(["point", "acme-app", "--done", "--action", yes]).status, 2)
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review_card;"), ["0"])
        // The longest label that is allowed counts characters, not bytes. (A
        // character with no decomposed form: `Process` hands arguments over decomposed.)
        try store(mux: point + ["--action", String(repeating: "日", count: 40) + "=go"])
    }

    func testMuxReviewListJSONShowsACardsAnswer() throws {
        try seedPointSessions()
        try store(mux: ["point", "acme-app", "--reason", "asks a question", "--action", yes, "--action", no])
        try store(mux: ["review", "add", "--key", "billing:pr", "--text", "PR open"])
        try makeStore().recordAnswer(key: "point:localhost:acme-app", label: "No", at: 1_759_500_100)
        let result = runMux(["review", "list", "--json"])
        XCTAssertEqual(result.status, 0, result.output)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]])
        let card = try XCTUnwrap(rows.first { $0["key"] as? String == "point:localhost:acme-app" }?["card"]
            as? [String: Any])
        // Labels, and what the human picked. Not the texts: the agent wrote those.
        XCTAssertEqual(card["actions"] as? [String], ["Yes", "No"])
        XCTAssertEqual(card["answer"] as? String, "No")
        XCTAssertEqual(card["answered_at"] as? Int, 1_759_500_100)
        XCTAssertTrue(rows.first { $0["key"] as? String == "billing:pr" }?["card"] is NSNull)
        // The plain list keeps its shape.
        XCTAssertEqual(runMux(["review", "list", "--nope"]).status, 2)
    }

    func testMuxPointUpdatesInPlaceAndShowsADismissedPointerAgain() throws {
        try seedPointSessions()
        try store(mux: ["point", "acme-app", "--reason", "needs your approval"])
        let store = try makeStore()
        try store.dismiss(key: "point:localhost:acme-app")
        XCTAssertEqual(try store.reviewItems(), [])

        try self.store(mux: ["point", "acme-app", "--reason", "asks which database to use"])
        XCTAssertEqual(try sqlite(pointRows), [
            "point:localhost:acme-app|localhost|acme-app|none|blocked|asks which database to use|0",
        ])
        XCTAssertEqual(try store.reviewItems().count, 1)
    }

    func testMuxPointDoneDeletesOnlyThatPointer() throws {
        try seedPointSessions()
        try store(mux: ["point", "acme-app", "--reason", "needs your approval"])
        try store(mux: ["point", "acme-app:2", "--reason", "asks a question"])
        try store(mux: ["point", "billing", "--host", "devbox", "--reason", "needs your approval"])
        try store(mux: ["point", "acme-app:2", "--done"])
        try store(mux: ["point", "billing", "--done", "--host", "devbox"])
        XCTAssertEqual(try sqlite("SELECT key FROM review;"), ["point:localhost:acme-app"])
        // A session that is gone can still be cleared, and so can a pointer
        // through the review list.
        try store(mux: ["point", "closed", "--done"])
        try store(mux: ["review", "done", "--key", "point:localhost:acme-app"])
        XCTAssertEqual(try sqlite("SELECT key FROM review;"), [])
    }

    func testMuxPointRefusesASessionTheAppDoesNotList() throws {
        try seedPointSessions()
        let unknown = runMux(["point", "nope", "--reason", "needs your approval"])
        XCTAssertEqual(unknown.status, 2)
        XCTAssertEqual(unknown.output, "mux: point: no such session: nope on localhost\n")
        // The name exists, but on another host.
        let otherHost = runMux(["point", "billing", "--reason", "needs your approval"])
        XCTAssertEqual(otherHost.status, 2)
        XCTAssertEqual(otherHost.output, "mux: point: no such session: billing on localhost\n")
        let unknownHost = runMux(["point", "acme-app", "--host", "nas", "--reason", "needs your approval"])
        XCTAssertEqual(unknownHost.status, 2)
        XCTAssertEqual(unknownHost.output, "mux: point: no such session: acme-app on nas\n")
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])
    }

    func testMuxPointRefusesABadWindowOrReason() throws {
        try seedPointSessions()
        // A two-byte character that has no decomposed form: `Process` hands
        // arguments over decomposed, which would turn "é" into two.
        let long = String(repeating: "ß", count: 121)
        let refused: [[String]] = [
            ["point", "acme-app:two", "--reason", "needs your approval"],
            ["point", "acme-app:", "--reason", "needs your approval"],
            ["point", "acme-app"],
            ["point", "acme-app", "--reason", ""],
            ["point", "acme-app", "--reason", "   "],
            ["point", "acme-app", "--reason", long],
            ["point", "acme-app", "--reason", "needs\nyour approval"],
            ["point", "acme-app", "--reason", "needs your approval\n"],
            ["point", "acme-app", "--reason", "needs\u{1B}[2Jyour approval"],
            ["point", "acme-app", "--reason", "needs\tyour approval"],
            ["point", "--reason", "needs your approval"],
            ["point", "acme-app", "--done", "--reason", "needs your approval"],
            ["point", "acme-app", "--severity", "info", "--reason", "needs your approval"],
        ]
        for args in refused {
            XCTAssertEqual(runMux(args).status, 2, args.joined(separator: " "))
        }
        XCTAssertTrue(runMux(["point", "acme-app", "--reason", long]).output.contains("121 characters"))
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])

        // The limit counts characters, not bytes.
        try store(mux: ["point", "acme-app", "--reason", String(repeating: "ß", count: 120)])
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["1"])
    }

    func testMuxPointRefusesAWindowTheSessionDoesNotHave() throws {
        try seedPointSessions()
        let missing = runMux(["point", "acme-app:9", "--reason", "needs your approval"])
        XCTAssertEqual(missing.status, 2)
        XCTAssertEqual(missing.output, "mux: point: no such window: acme-app:9 on localhost\n")
        // A window of the same session name on another host does not count,
        // and neither does a number that only holds a listed one.
        for target in ["acme-app:3", "acme-app:0", "acme-app:12", "acme-app:27", "acme-app:71"] {
            XCTAssertEqual(
                runMux(["point", target, "--reason", "needs your approval"]).status, 2, target)
        }
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])

        try store(mux: ["point", "acme-app:7", "--reason", "needs your approval"])
        try store(mux: ["point", "billing:0", "--host", "devbox", "--reason", "needs your approval"])
        XCTAssertEqual(
            try sqlite("SELECT key FROM review ORDER BY key;"),
            ["point:devbox:billing:0", "point:localhost:acme-app:7"])
    }

    func testMuxPointWritesOneKeyForAWindowWithLeadingZeros() throws {
        try seedPointSessions()
        try store(mux: ["point", "acme-app:007", "--reason", "needs your approval"])
        try store(mux: ["point", "acme-app:7", "--reason", "asks a question"])
        try store(mux: ["point", "billing:000", "--host", "devbox", "--reason", "needs your approval"])
        XCTAssertEqual(try sqlite(pointRows), [
            "point:devbox:billing:0|devbox|billing|0|blocked|needs your approval|0",
            "point:localhost:acme-app:7|localhost|acme-app|7|blocked|asks a question|0",
        ])
        XCTAssertEqual(try sqlite("SELECT typeof(window) FROM review;"), ["integer", "integer"])
        try store(mux: ["point", "acme-app:0007", "--done"])
        XCTAssertEqual(try sqlite("SELECT key FROM review;"), ["point:devbox:billing:0"])
    }

    func testMuxPointRefusesAnOverLongWindow() throws {
        try seedPointSessions()
        let huge = String(repeating: "9", count: 23)
        for args in [
            ["point", "acme-app:\(huge)", "--reason", "needs your approval"],
            ["point", "acme-app:100000", "--reason", "needs your approval"],
            ["point", "acme-app:\(huge)", "--done"],
        ] {
            let result = runMux(args)
            XCTAssertEqual(result.status, 2, args.joined(separator: " "))
            XCTAssertEqual(result.output, "mux: point: window must be at most 5 digits\n")
        }
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])
    }

    /// A snapshot an older app build wrote has no window list: the window
    /// form is refused, never taken unchecked.
    func testMuxPointRefusesAWindowWhenTheSnapshotListsNoWindows() throws {
        try makeStore().replaceSessions([sessionRow("acme-app", windowIndexes: nil)])
        let result = runMux(["point", "acme-app:1", "--reason", "needs your approval"])
        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(
            result.output,
            "mux: point: the snapshot lists no windows for acme-app on localhost; "
                + "point at the session without a window\n")
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])
        try store(mux: ["point", "acme-app", "--reason", "needs your approval"])
        XCTAssertEqual(try sqlite("SELECT key FROM review;"), ["point:localhost:acme-app"])
    }

    /// The `sessions` table of a DB an older build made has no window list.
    /// Both the CLI and the app add the column, in either order.
    func testAnOlderDatabaseGainsTheWindowListColumn() throws {
        let oldSessions = """
        CREATE TABLE sessions (
          name TEXT NOT NULL, host TEXT NOT NULL DEFAULT 'localhost',
          attached INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'inactive',
          windows INTEGER NOT NULL DEFAULT 0, panes INTEGER NOT NULL DEFAULT 0,
          cwd TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL,
          PRIMARY KEY (host, name));
        INSERT INTO sessions(name, windows, updated_at) VALUES('acme-app', 2, 1);
        """
        let hasColumn =
            "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'window_indexes';"

        // The CLI first.
        _ = try sqlite(oldSessions)
        XCTAssertEqual(try sqlite(hasColumn), ["0"])
        let result = runMux(["point", "acme-app:1", "--reason", "needs your approval"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.output.hasPrefix("mux: point: the snapshot lists no windows"), result.output)
        XCTAssertEqual(try sqlite(hasColumn), ["1"])
        XCTAssertEqual(try sqlite("SELECT name, windows FROM sessions;"), ["acme-app|2"])
        try store(mux: ["point", "acme-app", "--reason", "needs your approval"])
        // Then the app: the column is there, and opening twice is safe.
        try makeStore().replaceSessions([sessionRow("acme-app", windowIndexes: [1, 2])])
        try makeStore().replaceSessions([sessionRow("acme-app", windowIndexes: [1, 2])])
        try store(mux: ["point", "acme-app:1", "--reason", "needs your approval"])

        // The app first.
        try tearDownWithError()
        _ = try sqlite(oldSessions)
        let store = try makeStore()
        XCTAssertEqual(try sqlite(hasColumn), ["1"])
        XCTAssertEqual(try store.sessions().map(\.windowIndexes), [nil])
        try store.replaceSessions([sessionRow("acme-app", windowIndexes: [1, 2])])
        try self.store(mux: ["point", "acme-app:2", "--reason", "needs your approval"])
        XCTAssertEqual(try sqlite("SELECT key FROM review;"), ["point:localhost:acme-app:2"])
    }

    func testMuxPointKeepsAtMostTwentyPointers() throws {
        try seedPointSessions()
        let rows = (1...20).map { n in
            "('point:localhost:old-\(n)', 'localhost', 'old-\(n)', 'blocked', 'needs your approval', \(1000 + n), \(1000 + n))"
        }
        _ = try sqlite("""
        INSERT INTO review(key, host, session, severity, text, created_at, updated_at)
        VALUES \(rows.joined(separator: ",\n"));
        """)
        try store(mux: ["review", "add", "--key", "note", "--text", "a plain review note"])
        _ = try sqlite("UPDATE review SET updated_at = 1 WHERE key = 'note';")
        let pointers = "SELECT COUNT(*) FROM review WHERE key LIKE 'point:%';"
        XCTAssertEqual(try sqlite(pointers), ["20"])

        try store(mux: ["point", "acme-app", "--reason", "needs your approval"])
        XCTAssertEqual(try sqlite(pointers), ["20"])
        let keys = try sqlite("SELECT key FROM review;")
        XCTAssertFalse(keys.contains("point:localhost:old-1"), "the oldest pointer is dropped")
        XCTAssertTrue(keys.contains("point:localhost:old-2"))
        XCTAssertTrue(keys.contains("point:localhost:acme-app"))
        XCTAssertTrue(keys.contains("note"), "only pointers are capped")

        // Updating a pointer that is already there drops nothing.
        try store(mux: ["point", "acme-app", "--reason", "asks a question"])
        XCTAssertTrue(try sqlite("SELECT key FROM review;").contains("point:localhost:old-2"))
        // Two more drop the next two oldest.
        try store(mux: ["point", "acme-app:1", "--reason", "needs your approval"])
        try store(mux: ["point", "billing", "--host", "devbox", "--reason", "needs your approval"])
        XCTAssertEqual(try sqlite(pointers), ["20"])
        let later = try sqlite("SELECT key FROM review;")
        XCTAssertFalse(later.contains("point:localhost:old-2"))
        XCTAssertFalse(later.contains("point:localhost:old-3"))
        XCTAssertTrue(later.contains("point:localhost:old-4"))
        XCTAssertEqual(ManagerReviewItem.maxPointers, 20)
    }

    func testMuxPointRefusesDirectionAndZeroWidthCharacters() throws {
        try seedPointSessions()
        let ranges: [ClosedRange<UInt32>] = [0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069]
        for value in ranges.joined() {
            let scalar = try XCTUnwrap(Unicode.Scalar(value))
            let result = runMux(["point", "acme-app", "--reason", "needs \(scalar)your approval"])
            XCTAssertEqual(result.status, 2, String(value, radix: 16))
            XCTAssertEqual(
                result.output,
                "mux: point: --reason must not contain zero-width or text-direction characters\n",
                String(value, radix: 16))
        }
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])

        // Their neighbours are text: "…" is E2 80 A6, "—" is E2 80 94.
        try store(mux: ["point", "acme-app", "--reason", "waits… on you — ‘now’"])
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["1"])
    }

    func testMuxReviewAddRefusesAPointerKey() throws {
        try seedPointSessions()
        let result = runMux(["review", "add", "--key", "point:localhost:acme-app", "--text", "t"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.output.contains("reserved for mux point"), result.output)
        XCTAssertEqual(runMux(["review", "add", "--key", "point:x", "--text", "t"]).status, 2)
        XCTAssertEqual(try sqlite("SELECT COUNT(*) FROM review;"), ["0"])
    }

    func testOnlyAPointKeyIsAPointer() {
        func item(_ key: String) -> ManagerReviewItem {
            ManagerReviewItem(
                key: key, host: "localhost", session: "acme-app", window: nil,
                severity: .blocked, text: "needs your approval", updatedAt: 1, dismissed: false)
        }
        XCTAssertEqual(ManagerReviewItem.pointerPrefix, "point:")
        XCTAssertTrue(item("point:localhost:acme-app").isPointer)
        XCTAssertFalse(item("acme-app-perms").isPointer)
        XCTAssertFalse(item("appoint:x").isPointer)
    }

    // MARK: CLI helpers

    private var muxPath: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("../app/MuxMaestro/Resources/manager/mux")
            .standardizedFileURL
    }

    @discardableResult
    private func store(mux args: [String]) throws -> String {
        let result = runMux(args)
        XCTAssertEqual(result.status, 0, "mux \(args.joined(separator: " ")) failed: \(result.output)")
        return result.output
    }

    private func runMux(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [muxPath.path] + args
        var env = ProcessInfo.processInfo.environment
        env["MUX_MANAGER_DB"] = dbPath
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "spawn failed: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Run a query against the DB with a throwaway `sqlite3`, one row per line.
    /// Used for things the store's model deliberately doesn't expose.
    private func sqlite(_ query: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    private func firstCreatedAt() throws -> Int64 {
        // Read created_at directly — the store's model doesn't expose it, so open
        // a throwaway sqlite3 to assert preservation.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "SELECT created_at FROM review ORDER BY created_at LIMIT 1;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int64(text))
    }
}
