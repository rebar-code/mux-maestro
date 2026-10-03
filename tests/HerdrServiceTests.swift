import XCTest

// HerdrService.swift drives the herdr CLI through the shared CommandRunner seam.
// These tests assert the exact argv it emits and how it assembles the tree —
// against a fake runner, with no real herdr spawned. Reuses the FakeRunner
// pattern from TmuxServiceTests via a local copy (test targets don't share
// fileprivate helpers across files).
private final class HerdrFakeRunner: CommandRunner {
    private(set) var calls: [(path: String, args: [String])] = []
    var responses: [String: String?] = [:]
    var defaultResponse: String? = ""

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        calls.append((path, args))
        let key = args.joined(separator: " ")
        if let scripted = responses[key] { return scripted }
        return defaultResponse
    }
    var argSequences: [[String]] { calls.map(\.args) }
}

final class HerdrServiceTests: XCTestCase {
    private let herdr = "/opt/homebrew/bin/herdr"

    private func make(_ runner: HerdrFakeRunner, path: String? = "/opt/homebrew/bin/herdr") -> HerdrService {
        HerdrService(runner: runner, herdrPath: path)
    }

    // MARK: availability

    func testUnavailableWhenNoPath() {
        let svc = make(HerdrFakeRunner(), path: nil)
        XCTAssertFalse(svc.isAvailable)
        XCTAssertTrue(svc.loadTree().isEmpty)
        XCTAssertNil(svc.attachCommand(session: "default"))
        XCTAssertFalse(svc.stopSession(name: "default"))
        XCTAssertFalse(svc.deleteSession(name: "default"))
    }

    // MARK: loadTree — issues the three list calls + assembles

    func testLoadTreeIssuesThreeListCallsAndAssembles() {
        let runner = HerdrFakeRunner()
        runner.responses["session list --json"] =
            #"{"sessions":[{"name":"default","default":true,"running":true}]}"#
        runner.responses["tab list"] =
            #"{"result":{"type":"tab_list","tabs":[{"tab_id":"w:1","workspace_id":"w","number":1,"label":"1","agent_status":"working","focused":true}]}}"#
        runner.responses["pane list"] =
            #"{"result":{"type":"pane_list","panes":[{"pane_id":"w-1","tab_id":"w:1","agent":"claude","agent_status":"working","cwd":"/p","focused":true}]}}"#
        let svc = make(runner)

        let tree = svc.loadTree()

        // The exact argv sequence: session list --json, tab list, pane list.
        XCTAssertEqual(runner.argSequences, [
            ["session", "list", "--json"],
            ["tab", "list"],
            ["pane", "list"],
        ])
        // Assembled session → tab → pane.
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "default")
        XCTAssertEqual(tree[0].tabs.count, 1)
        XCTAssertEqual(tree[0].tabs[0].panes.first?.agent, "claude")
    }

    func testLoadTreeEmptyWhenNoSessions() {
        let runner = HerdrFakeRunner()
        runner.responses["session list --json"] = #"{"sessions":[]}"#
        let svc = make(runner)
        XCTAssertTrue(svc.loadTree().isEmpty)
        // Should not bother calling tab/pane list when there are no sessions.
        XCTAssertEqual(runner.argSequences, [["session", "list", "--json"]])
    }

    func testLoadTreeToleratesTabPaneFailure() {
        // session list works but tab/pane list fail (nil) — still returns the
        // session with no tabs rather than crashing.
        let runner = HerdrFakeRunner()
        runner.responses["session list --json"] =
            #"{"sessions":[{"name":"default","running":true}]}"#
        runner.responses["tab list"] = .some(nil)
        runner.responses["pane list"] = .some(nil)
        let svc = make(runner)
        let tree = svc.loadTree()
        XCTAssertEqual(tree.count, 1)
        XCTAssertTrue(tree[0].tabs.isEmpty)
    }

    func testLoadTreeEmptyWhenSessionListFails() {
        let runner = HerdrFakeRunner()
        runner.responses["session list --json"] = .some(nil)
        let svc = make(runner)
        XCTAssertTrue(svc.loadTree().isEmpty)
    }

    // MARK: attach / lifecycle argv

    func testAttachCommand() {
        let svc = make(HerdrFakeRunner())
        XCTAssertEqual(svc.attachCommand(session: "default"),
                       "\(herdr) session attach 'default'")
    }

    func testStopSessionArgv() {
        let runner = HerdrFakeRunner()
        let svc = make(runner)
        XCTAssertTrue(svc.stopSession(name: "default"))
        XCTAssertEqual(runner.argSequences, [["session", "stop", "default"]])
    }

    func testDeleteSessionArgv() {
        let runner = HerdrFakeRunner()
        let svc = make(runner)
        XCTAssertTrue(svc.deleteSession(name: "work"))
        XCTAssertEqual(runner.argSequences, [["session", "delete", "work"]])
    }

    func testStopReturnsFalseOnCommandFailure() {
        let runner = HerdrFakeRunner()
        runner.responses["session stop default"] = .some(nil)
        let svc = make(runner)
        XCTAssertFalse(svc.stopSession(name: "default"))
    }
}
