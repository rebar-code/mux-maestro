import XCTest

// MobileManager.swift (Foundation only) compiles into this test target: the
// manager routes, the JSON shapes of the manager home and of a turn, and the
// refusals are asserted with no socket and no manager pane.
final class MobileManagerTests: XCTestCase {
    private let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")
    private let on = MobileConfig(capabilities: [.manager])

    private func request(
        _ target: String, method: String = "GET", headers: [String: String] = [:], body: String = ""
    ) -> MobileRequest {
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
        text += "\r\n" + body
        guard case .request(let request, _) = MobileHTTP.parse(Data(text.utf8)) else {
            XCTFail("did not parse: \(target)")
            return MobileRequest(method: method, path: "/")
        }
        return request
    }

    private func snapshot() -> MobileSnapshot {
        var agent = TmuxPane(id: "%12", index: 0, command: "claude", title: "", active: true)
        agent.claudeSessionId = "c1"
        agent.attention = .waiting
        var second = TmuxPane(id: "%13", index: 1, command: "codex", title: "", active: false)
        second.codexSessionId = "x1"
        var remote = TmuxPane(id: "%3", index: 0, command: "claude", title: "", active: true)
        remote.claudeSessionId = "r1"
        return MobileSnapshot.build([
            MobileHostInput(
                host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
                sessions: [TmuxSession(name: "acme-app", attached: true, windows: [
                    TmuxWindow(index: 1, name: "checkout-fix", active: true, panes: [agent, second]),
                ])]),
            MobileHostInput(
                host: Host(name: "devbox", sshAlias: "devbox"), colorHex: "#f5a623",
                reachability: .reachable, stats: nil,
                sessions: [TmuxSession(name: "billing", attached: false, windows: [
                    TmuxWindow(index: 0, name: "invoices-pdf", active: true, panes: [remote]),
                ])]),
        ])
    }

    private func board() -> MobileManagerBoard {
        MobileManagerBoard(
            items: [
                MobileManagerItem(
                    kind: .agent, title: "acme-app · checkout-fix", detail: "Permission · Bash",
                    at: 1_759_500_000, link: .thread(id: "c1")),
                MobileManagerItem(
                    kind: .review, key: "billing:pr", title: "billing@devbox",
                    detail: "PR open 52m, CI green, no review yet", severity: .warn,
                    at: 1_759_499_000,
                    link: .open(session: "billing", window: 0, pane: nil, host: "devbox")),
                MobileManagerItem(
                    kind: .review, key: "gone", title: "reports", detail: "Session closed",
                    severity: .info, at: 1_759_498_000,
                    link: .open(session: "reports", window: nil, pane: nil, host: "localhost")),
            ],
            updates: [
                ManagerUpdate(
                    kind: .done, sessionId: "x1", host: "localhost", session: "acme-app",
                    window: 1, text: "Tests pass", at: 1_759_499_500),
                ManagerUpdate(
                    kind: .notification, sessionId: "", host: "", session: "", window: nil,
                    text: "Nightly build is green", at: 1_759_499_400),
            ])
    }

    // MARK: routes

    func testRoutesTheManagerAPIByMethod() {
        XCTAssertEqual(MobileAPI.route(request("/api/manager"), config: on), .manager)
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/text", method: "POST"), config: on), .managerText)
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/dismiss", method: "POST"), config: on),
            .managerDismiss)
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager", method: "POST"), config: on), .methodNotAllowed)
        XCTAssertEqual(MobileAPI.route(request("/api/manager/text"), config: on), .methodNotAllowed)
        XCTAssertEqual(MobileAPI.route(request("/api/manager/other", method: "POST"), config: on), .notFound)
    }

    func testEveryManagerRouteIsRefusedWhileTheSwitchIsOff() {
        for (method, path) in [("GET", "/api/manager"), ("POST", "/api/manager/text"),
                               ("POST", "/api/manager/dismiss")] {
            XCTAssertEqual(
                MobileAPI.route(request(path, method: method), config: MobileConfig()),
                .disabled(.manager), path)
            // Another feature's switch does not open it.
            XCTAssertEqual(
                MobileAPI.route(request(path, method: method), config: MobileConfig(capabilities: [.voice])),
                .disabled(.manager), path)
        }
    }

    func testAManagerWriteFromAnotherOriginIsDenied() {
        var headers = ["Host": "devmac.example.ts.net:7433", "Tailscale-User-Login": "me@example.com"]
        for path in ["/api/manager/text", "/api/manager/dismiss"] {
            headers["X-MuxMaestro"] = nil
            headers["Origin"] = "https://devmac.example.ts.net:7433"
            XCTAssertEqual(
                MobileAPI.authorize(request(path, method: "POST", headers: headers), identity: identity),
                .denied("write header"), path)
            headers["X-MuxMaestro"] = "1"
            headers["Origin"] = "https://evil.example.com"
            XCTAssertEqual(
                MobileAPI.authorize(request(path, method: "POST", headers: headers), identity: identity),
                .denied("origin"), path)
            headers["Origin"] = "http://127.0.0.1:7433"
            XCTAssertEqual(
                MobileAPI.authorize(request(path, method: "POST", headers: headers), identity: identity),
                .denied("origin"), path)
            headers["Origin"] = "https://devmac.example.ts.net:7433"
            XCTAssertEqual(
                MobileAPI.authorize(request(path, method: "POST", headers: headers), identity: identity),
                .allowed, path)
        }
    }

    // MARK: shapes

    func testALinkResolvesToTheListedThreadOrNothing() {
        let snapshot = snapshot()
        XCTAssertNil(MobileManager.threadID(for: nil, in: snapshot))
        XCTAssertEqual(MobileManager.threadID(for: .thread(id: "c1"), in: snapshot), "localhost:12")
        XCTAssertEqual(MobileManager.threadID(for: .thread(id: "x1"), in: snapshot), "localhost:13")
        XCTAssertNil(MobileManager.threadID(for: .thread(id: "nope"), in: snapshot))
        XCTAssertEqual(
            MobileManager.threadID(
                for: .open(session: "acme-app", window: 1, pane: "%13", host: "localhost"), in: snapshot),
            "localhost:13")
        XCTAssertEqual(
            MobileManager.threadID(
                for: .open(session: "acme-app", window: nil, pane: nil, host: "localhost"), in: snapshot),
            "localhost:12")
        // The same session name on another host is another thread.
        XCTAssertNil(MobileManager.threadID(
            for: .open(session: "billing", window: nil, pane: nil, host: "localhost"), in: snapshot))
        XCTAssertNil(MobileManager.threadID(
            for: .open(session: "acme-app", window: 7, pane: nil, host: "localhost"), in: snapshot))
    }

    func testManagerBodyShape() throws {
        let chat = MobileChatPage(
            messages: [
                MobileChatMessage(n: 0, role: .user, text: "what needs me?"),
                MobileChatMessage(n: 40, role: .tool, text: "mux sessions", tool: "Bash"),
                MobileChatMessage(n: 41, role: .assistant, text: "Two threads need you."),
            ], next: 90)
        let body = MobileManager.body(
            board: board(), snapshot: snapshot(), turn: nil, status: .idle, chat: chat)
        XCTAssertEqual(
            Set(body.keys), ["status", "needsYou", "review", "updates", "turn", "chat"])
        XCTAssertEqual(body["status"] as? String, "idle")
        XCTAssertTrue(body["turn"] is NSNull)

        let needsYou = try XCTUnwrap(body["needsYou"] as? [[String: Any]])
        XCTAssertEqual(needsYou.count, 1)
        XCTAssertEqual(needsYou[0]["title"] as? String, "acme-app · checkout-fix")
        XCTAssertEqual(needsYou[0]["detail"] as? String, "Permission · Bash")
        XCTAssertEqual(needsYou[0]["thread"] as? String, "localhost:12")
        XCTAssertEqual(needsYou[0]["at"] as? Int, 1_759_500_000)
        XCTAssertTrue(needsYou[0]["key"] is NSNull)
        XCTAssertTrue(needsYou[0]["severity"] is NSNull)

        let review = try XCTUnwrap(body["review"] as? [[String: Any]])
        XCTAssertEqual(review.map { $0["key"] as? String }, ["billing:pr", "gone"])
        XCTAssertEqual(review[0]["severity"] as? String, "warn")
        XCTAssertEqual(review[0]["thread"] as? String, "devbox:3")
        XCTAssertEqual(review[0]["detail"] as? String, "PR open 52m, CI green, no review yet")
        // Its session is gone: the card stays, and opens nothing.
        XCTAssertTrue(review[1]["thread"] is NSNull)

        let updates = try XCTUnwrap(body["updates"] as? [[String: Any]])
        XCTAssertEqual(updates.map { $0["kind"] as? String }, ["done", "notification"])
        XCTAssertEqual(updates[0]["thread"] as? String, "localhost:13")
        XCTAssertEqual(updates[0]["text"] as? String, "Tests pass")
        XCTAssertTrue(updates[1]["thread"] is NSNull)

        // Tool rows are the manager's plumbing; the home gets the conversation.
        let page = try XCTUnwrap(body["chat"] as? [String: Any])
        let messages = try XCTUnwrap(page["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(messages.last?["text"] as? String, "Two threads need you.")
        XCTAssertEqual(page["next"] as? UInt64, 90)
    }

    func testATurnInFlightIsInTheBodyAndReadsAsBusy() throws {
        let turn = MobileManagerTurn(prompt: "what needs me?", reply: "Two threads")
        let body = MobileManager.body(
            board: MobileManagerBoard(), snapshot: MobileSnapshot(), turn: turn, status: .idle,
            chat: MobileChatPage())
        XCTAssertEqual(body["status"] as? String, "busy")
        let sent = try XCTUnwrap(body["turn"] as? [String: Any])
        XCTAssertEqual(sent["prompt"] as? String, "what needs me?")
        XCTAssertEqual(sent["reply"] as? String, "Two threads")
        XCTAssertEqual((body["needsYou"] as? [Any])?.count, 0)
    }

    func testTheChatIsCutToItsLastRows() throws {
        let rows = (0..<50).map { MobileChatMessage(n: UInt64($0), role: .assistant, text: "line \($0)") }
        let body = MobileManager.body(
            board: MobileManagerBoard(), snapshot: MobileSnapshot(), turn: nil, status: .idle,
            chat: MobileChatPage(messages: rows, next: 50))
        let messages = try XCTUnwrap((body["chat"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, MobileManager.chatLimit)
        XCTAssertEqual(messages.last?["text"] as? String, "line 49")
    }

    func testEqualStateEncodesEquallyAndATurnChangesIt() {
        let idle = MobileManager.liveJSON(board: board(), snapshot: snapshot(), turn: nil)
        XCTAssertEqual(idle, MobileManager.liveJSON(board: board(), snapshot: snapshot(), turn: nil))
        XCTAssertNotEqual(
            idle,
            MobileManager.liveJSON(
                board: board(), snapshot: snapshot(), turn: MobileManagerTurn(prompt: "hi")))
    }

    func testStatusFollowsThePane() {
        XCTAssertEqual(MobileManagerStatus(nil), .idle)
        XCTAssertEqual(MobileManagerStatus(.idle), .idle)
        XCTAssertEqual(MobileManagerStatus(.busy), .busy)
        XCTAssertEqual(MobileManagerStatus(.waiting), .waiting)
    }

    // MARK: a turn

    func testReadsTheTextAndTheKeyOfARequest() {
        XCTAssertEqual(MobileManager.text(in: Data(#"{"text":"  what needs me?\n"}"#.utf8)), "what needs me?")
        XCTAssertNil(MobileManager.text(in: Data(#"{"text":"   "}"#.utf8)))
        XCTAssertNil(MobileManager.text(in: Data(#"{"text":7}"#.utf8)))
        XCTAssertNil(MobileManager.text(in: Data("what needs me?".utf8)))
        XCTAssertNil(MobileManager.text(in: Data()))
        XCTAssertEqual(MobileManager.key(in: Data(#"{"key":"billing:pr"}"#.utf8)), "billing:pr")
        XCTAssertNil(MobileManager.key(in: Data(#"{"text":"billing:pr"}"#.utf8)))
    }

    private func error(_ response: MobileResponse?) -> [String: String]? {
        response.flatMap { try? JSONSerialization.jsonObject(with: $0.body) } as? [String: String]
    }

    func testATurnIsRefusedWhileOneRunsOrThePaneWaitsOnAPrompt() {
        XCTAssertNil(MobileManager.refusal(status: .idle, turnRunning: false))
        // The pane is busy with something typed into its terminal: the text
        // queues there, as it does from the Mac rail.
        XCTAssertNil(MobileManager.refusal(status: .busy, turnRunning: false))

        let busy = MobileManager.refusal(status: .busy, turnRunning: true)
        XCTAssertEqual(busy?.status, 409)
        XCTAssertEqual(error(busy), ["error": "busy", "message": "A turn is running"])

        // Text typed into a pane that sits on a prompt would answer the prompt.
        let waiting = MobileManager.refusal(status: .waiting, turnRunning: false)
        XCTAssertEqual(waiting?.status, 409)
        XCTAssertEqual(error(waiting), ["error": "waiting", "message": "Manager is waiting on a prompt"])

        let off = MobileManager.refusal(status: .off, turnRunning: false)
        XCTAssertEqual(off?.status, 503)
        XCTAssertEqual(error(off), ["error": "unavailable", "message": "Manager is not running"])
        XCTAssertTrue(busy?.serialized().starts(with: Data("HTTP/1.1 409 Conflict\r\n".utf8)) ?? false)
    }

    func testTheEndEventNamesTheOutcomeAndWhatTheHumanMustKnow() {
        func end(_ outcome: ManagerTurnOutcome) -> [String: String?] {
            MobileManager.end(outcome).mapValues { $0 as? String }
        }
        XCTAssertEqual(
            end(.done(reply: "Two threads need you.")),
            ["outcome": "done", "reply": "Two threads need you.", "message": nil])
        XCTAssertEqual(
            end(.permission(reply: "Checking")),
            ["outcome": "permission", "reply": "Checking", "message": "Waiting at the keyboard"])
        XCTAssertEqual(
            end(.timeout(reply: "")), ["outcome": "timeout", "reply": "", "message": "Still working"])
        XCTAssertEqual(
            end(.refused("Manager is waiting on a prompt")),
            ["outcome": "refused", "reply": "", "message": "Manager is waiting on a prompt"])
        XCTAssertEqual(
            end(.unreachable("No mux-manager session")),
            ["outcome": "unreachable", "reply": "", "message": "No mux-manager session"])
    }
}
