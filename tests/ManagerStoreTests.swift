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
        attached: Bool = false
    ) -> ManagerSessionRow {
        ManagerSessionRow(name: name, host: host, attached: attached, state: state,
                          windows: 2, panes: 3, cwd: "/tmp/\(name)")
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
