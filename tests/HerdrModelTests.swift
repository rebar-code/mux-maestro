import XCTest

// HerdrModel.swift (Foundation-only, no AppKit) compiles into this test target,
// so the herdr JSON parsing + command construction + attention mapping are
// asserted against the real captured JSON shapes — no herdr process spawned.
final class HerdrModelTests: XCTestCase {
    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    // MARK: session list --json

    func testParseSessionsFromRealJSON() {
        // Exact shape captured from `herdr session list --json` (herdr 0.6.10).
        let json = """
        {"sessions":[{"default":true,"name":"default","running":true,\
        "session_dir":"/Users/me/.config/herdr",\
        "socket_path":"/Users/me/.config/herdr/herdr.sock"}]}
        """
        let sessions = HerdrModel.parseSessions(data(json))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "default")
        XCTAssertTrue(sessions[0].isDefault)
        XCTAssertTrue(sessions[0].running)
        XCTAssertTrue(sessions[0].tabs.isEmpty)  // tabs attached separately
    }

    func testParseSessionsSkipsNamelessAndHandlesMissingFlags() {
        let json = """
        {"sessions":[{"name":""},{"name":"work"}]}
        """
        let sessions = HerdrModel.parseSessions(data(json))
        XCTAssertEqual(sessions.map(\.name), ["work"])
        XCTAssertFalse(sessions[0].isDefault)  // defaults when flag absent
        XCTAssertFalse(sessions[0].running)
    }

    func testParseSessionsEmptyOnGarbage() {
        XCTAssertTrue(HerdrModel.parseSessions(data("not json")).isEmpty)
        XCTAssertTrue(HerdrModel.parseSessions(data("{}")).isEmpty)
    }

    // MARK: tab list (already JSON, no --json flag)

    func testParseTabsFromRealEnvelope() {
        // Exact shape from `herdr tab list` (a {id,result:{type,tabs}} envelope).
        let json = """
        {"id":"cli:tab:list","result":{"tabs":[\
        {"agent_status":"unknown","focused":false,"label":"1","number":1,\
        "pane_count":1,"tab_id":"w65:1","workspace_id":"w65"},\
        {"agent_status":"working","focused":true,"label":"two","number":2,\
        "pane_count":1,"tab_id":"w65:2","workspace_id":"w65"}],"type":"tab_list"}}
        """
        let tabs = HerdrModel.parseTabs(data(json))
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0].id, "w65:1")
        XCTAssertEqual(tabs[0].workspaceID, "w65")
        XCTAssertEqual(tabs[0].number, 1)
        XCTAssertEqual(tabs[0].label, "1")
        XCTAssertEqual(tabs[0].agentStatus, .unknown)
        XCTAssertFalse(tabs[0].focused)
        XCTAssertEqual(tabs[1].label, "two")
        XCTAssertEqual(tabs[1].agentStatus, .working)
        XCTAssertTrue(tabs[1].focused)
    }

    func testParseTabsEmptyOnMissingResult() {
        XCTAssertTrue(HerdrModel.parseTabs(data("{}")).isEmpty)
        XCTAssertTrue(HerdrModel.parseTabs(data("garbage")).isEmpty)
    }

    // MARK: pane list

    func testParsePanesFromRealEnvelope() {
        let json = """
        {"id":"cli:pane:list","result":{"panes":[\
        {"agent_status":"unknown","cwd":"/Users/me/p","focused":false,\
        "pane_id":"w65-1","tab_id":"w65:1","workspace_id":"w65"},\
        {"agent":"claude","agent_status":"working","cwd":"/Users/me/q",\
        "focused":true,"pane_id":"w65-2","tab_id":"w65:2","workspace_id":"w65"}\
        ],"type":"pane_list"}}
        """
        let panes = HerdrModel.parsePanes(data(json))
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].id, "w65-1")
        XCTAssertEqual(panes[0].tabID, "w65:1")
        XCTAssertNil(panes[0].agent)           // empty/absent agent → nil
        XCTAssertEqual(panes[0].cwd, "/Users/me/p")
        XCTAssertEqual(panes[0].agentStatus, .unknown)
        XCTAssertEqual(panes[1].agent, "claude")
        XCTAssertEqual(panes[1].agentStatus, .working)
        XCTAssertTrue(panes[1].focused)
    }

    // MARK: assemble — nest panes under tabs under the running session

    func testAssembleNestsAndSorts() {
        let sessions = [HerdrSession(name: "default", isDefault: true, running: true, tabs: [])]
        let tabs = [
            HerdrTab(id: "t2", workspaceID: "w", number: 2, label: "2",
                     agentStatus: .idle, focused: false, panes: []),
            HerdrTab(id: "t1", workspaceID: "w", number: 1, label: "1",
                     agentStatus: .idle, focused: true, panes: []),
        ]
        let panes = [
            HerdrPane(id: "p-b", tabID: "t1", agent: nil, agentStatus: .idle,
                      cwd: nil, focused: false),
            HerdrPane(id: "p-a", tabID: "t1", agent: "claude", agentStatus: .working,
                      cwd: nil, focused: true),
            HerdrPane(id: "p-c", tabID: "t2", agent: nil, agentStatus: .idle,
                      cwd: nil, focused: false),
        ]
        let tree = HerdrModel.assemble(sessions: sessions, tabs: tabs, panes: panes)
        XCTAssertEqual(tree.count, 1)
        // Tabs sorted by number.
        XCTAssertEqual(tree[0].tabs.map(\.number), [1, 2])
        // Panes nested under the right tab, sorted by id.
        XCTAssertEqual(tree[0].tabs[0].panes.map(\.id), ["p-a", "p-b"])
        XCTAssertEqual(tree[0].tabs[1].panes.map(\.id), ["p-c"])
    }

    func testAssembleGivesNoTabsToStoppedSession() {
        let sessions = [HerdrSession(name: "old", isDefault: false, running: false, tabs: [])]
        let tabs = [HerdrTab(id: "t1", workspaceID: "w", number: 1, label: "1",
                             agentStatus: .working, focused: true, panes: [])]
        let tree = HerdrModel.assemble(sessions: sessions, tabs: tabs, panes: [])
        XCTAssertTrue(tree[0].tabs.isEmpty)  // not running → no tabs attached
    }

    // MARK: agent status → attention mapping

    func testAgentStatusMapsToAttention() {
        XCTAssertEqual(HerdrAgentStatus.blocked.attention, .waiting)
        XCTAssertEqual(HerdrAgentStatus.working.attention, .busy)
        XCTAssertEqual(HerdrAgentStatus.idle.attention, .idle)
        XCTAssertEqual(HerdrAgentStatus.unknown.attention, .unknown)
        XCTAssertEqual(HerdrAgentStatus(raw: "nonsense"), .unknown)
        XCTAssertEqual(HerdrAgentStatus(raw: nil), .unknown)
    }

    func testSessionAttentionRollsUpMostUrgent() {
        // A session with one working pane and one blocked pane surfaces blocked
        // (needs you) — most-attention-worthy wins, like the tmux sort.
        let blockedTab = HerdrTab(id: "t1", workspaceID: "w", number: 1, label: "1",
            agentStatus: .working, focused: false,
            panes: [HerdrPane(id: "p1", tabID: "t1", agent: "claude",
                agentStatus: .blocked, cwd: nil, focused: false)])
        let s = HerdrSession(name: "default", isDefault: true, running: true,
            tabs: [blockedTab])
        XCTAssertEqual(HerdrModel.sessionAttention(s), .waiting)
    }

    func testSessionAttentionUnknownWhenNoTabs() {
        let s = HerdrSession(name: "default", isDefault: true, running: true, tabs: [])
        XCTAssertEqual(HerdrModel.sessionAttention(s), .unknown)
    }

    // MARK: command construction

    func testAttachCommandQuotesSession() {
        let cmd = HerdrModel.attachCommand(herdrPath: "/opt/homebrew/bin/herdr", session: "default")
        XCTAssertEqual(cmd, "/opt/homebrew/bin/herdr session attach 'default'")
    }

    func testAttachCommandEscapesQuotes() {
        let cmd = HerdrModel.attachCommand(herdrPath: "/h", session: "a'b")
        XCTAssertEqual(cmd, "/h session attach 'a'\\''b'")
    }

    func testStopAndDeleteArgv() {
        XCTAssertEqual(HerdrModel.stopArgv(session: "default"), ["session", "stop", "default"])
        XCTAssertEqual(HerdrModel.deleteArgv(session: "x"), ["session", "delete", "x"])
        XCTAssertEqual(HerdrModel.sessionListArgv, ["session", "list", "--json"])
        XCTAssertEqual(HerdrModel.tabListArgv, ["tab", "list"])
        XCTAssertEqual(HerdrModel.paneListArgv, ["pane", "list"])
    }
}
