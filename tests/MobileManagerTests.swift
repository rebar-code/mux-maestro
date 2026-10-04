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
        XCTAssertEqual(MobileAPI.route(request("/api/manager"), config: on), .api(.manager))
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/text", method: "POST"), config: on),
            .api(.managerText))
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/dismiss", method: "POST"), config: on),
            .api(.managerDismiss))
        for endpoint in [MobileEndpoint.manager, .managerText, .managerDismiss] {
            XCTAssertEqual(endpoint.capability, .manager)
        }
        XCTAssertEqual(MobileEndpoint.managerText.method, "POST")
        XCTAssertEqual(MobileEndpoint.managerDismiss.method, "POST")
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

    func testAManagerRequestNeedsThePairingToken() {
        for (method, path) in [("GET", "/api/manager"), ("POST", "/api/manager/text"),
                               ("POST", "/api/manager/dismiss")] {
            XCTAssertTrue(MobileAPI.needsToken(request(path, method: method)), path)
            XCTAssertFalse(MobileAPI.hasToken(request(path, method: method), token: "demo-token"), path)
            XCTAssertFalse(MobileAPI.hasToken(
                request(path, method: method, headers: ["X-MuxMaestro-Token": "other"]),
                token: "demo-token"), path)
            XCTAssertTrue(MobileAPI.hasToken(
                request(path, method: method, headers: ["X-MuxMaestro-Token": "demo-token"]),
                token: "demo-token"), path)
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
        let body = MobileManager.body(
            board: board(), snapshot: snapshot(), turn: nil, status: .idle)
        // The chat is its own route, read the way a thread's chat is.
        XCTAssertEqual(Set(body.keys), ["status", "needsYou", "review", "updates", "turn"])
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
    }

    func testATurnInFlightIsInTheBodyAndReadsAsBusy() throws {
        let turn = MobileManagerTurn(
            prompt: "what needs me?", reply: "Two threads", spinner: "Incubating… 12s")
        let body = MobileManager.body(
            board: MobileManagerBoard(), snapshot: MobileSnapshot(), turn: turn, status: .idle)
        XCTAssertEqual(body["status"] as? String, "busy")
        let sent = try XCTUnwrap(body["turn"] as? [String: Any])
        XCTAssertEqual(sent["prompt"] as? String, "what needs me?")
        XCTAssertEqual(sent["reply"] as? String, "Two threads")
        XCTAssertEqual(sent["spinner"] as? String, "Incubating… 12s")
        XCTAssertTrue(MobileManagerTurn(prompt: "hi").json["spinner"] is NSNull)
        XCTAssertEqual((body["needsYou"] as? [Any])?.count, 0)
    }

    // MARK: spinner

    func testReadsTheSpinnerLineOfAWorkingPane() {
        let pane = """
        ⏺ Bash(mux sessions)
          ⎿  12 sessions

        ✻ Incubating… (4m 48s · ↓ 2.1k tokens · esc to interrupt)

        ╭──────────────────────────────╮
        │ >                            │
        ╰──────────────────────────────╯
          ? for shortcuts
        """
        XCTAssertEqual(MobileSpinner.line(in: pane), "Incubating… 4m 48s")
        XCTAssertEqual(
            MobileSpinner.line(in: "✢ Reticulating splines… (12s · esc to interrupt)"),
            "Reticulating splines… 12s")
        XCTAssertEqual(
            MobileSpinner.line(in: "· Thinking… (1h 2m 3s · ↑ 14.2k tokens)"), "Thinking… 1h 2m 3s")
        // No time in the brackets, or no brackets: the verb alone.
        XCTAssertEqual(MobileSpinner.line(in: "✶ Compacting… (esc to interrupt)"), "Compacting…")
        XCTAssertEqual(MobileSpinner.line(in: "* Musing…"), "Musing…")
    }

    func testTheSpinnerLineIsReadThroughColourEscapes() {
        let pane = "\u{1B}[38;5;174m✻\u{1B}[39m \u{1B}[1mIncubating…\u{1B}[22m"
            + " \u{1B}[2m(48s · esc to interrupt)\u{1B}[0m\n\u{1B}[2m╭───╮\u{1B}[0m\n"
        XCTAssertEqual(MobileSpinner.line(in: pane), "Incubating… 48s")
        XCTAssertEqual(MobileSpinner.strip("\u{1B}[1;32mok\u{1B}[0m"), "ok")
    }

    func testAPaneThatIsNotWorkingHasNoSpinnerLine() {
        XCTAssertNil(MobileSpinner.line(in: ""))
        XCTAssertNil(MobileSpinner.line(in: "⏺ Done. Two threads need you.\n\n│ >   │\n  ? for shortcuts"))
        // An ellipsis in ordinary text, a bullet list, and a prompt are not it.
        XCTAssertNil(MobileSpinner.line(in: "⏺ Still looking… (one moment)"))
        XCTAssertNil(MobileSpinner.line(in: "> wait…"))
        XCTAssertNil(MobileSpinner.line(in: "* a bullet with no ellipsis"))
        // An old spinner line far up the scrollback is not the pane's state now.
        let old = "✻ Incubating… (4m 48s)\n" + (0..<MobileSpinner.tail).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertNil(MobileSpinner.line(in: old))
    }

    func testTheElapsedTimeIsTheBracketsFirstTimePart() {
        XCTAssertEqual(MobileSpinner.elapsed(in: " (4m 48s · ↓ 2.1k tokens · esc to interrupt)"), "4m 48s")
        XCTAssertEqual(MobileSpinner.elapsed(in: " (esc to interrupt · 7s)"), "7s")
        XCTAssertNil(MobileSpinner.elapsed(in: " (esc to interrupt)"))
        XCTAssertNil(MobileSpinner.elapsed(in: " 48s"))
        XCTAssertNil(MobileSpinner.elapsed(in: " (2.1k tokens)"))
    }

    func testTheManagerChatAndScreenAreManagerRoutes() {
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/chat"), config: on), .api(.managerChat(after: nil)))
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/chat?after=120"), config: on),
            .api(.managerChat(after: 120)))
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/screen"), config: on),
            .api(.managerScreen(lines: MobileAPI.screenLinesDefault)))
        XCTAssertEqual(
            MobileAPI.route(request("/api/manager/screen?lines=99999999"), config: on),
            .api(.managerScreen(lines: MobileAPI.screenLinesMax)))
        for path in ["/api/manager/chat", "/api/manager/screen"] {
            XCTAssertEqual(MobileAPI.route(request(path), config: MobileConfig()), .disabled(.manager), path)
            XCTAssertEqual(
                MobileAPI.route(request(path, method: "POST"), config: on), .methodNotAllowed, path)
            XCTAssertTrue(MobileAPI.needsToken(request(path)), path)
        }
        XCTAssertEqual(MobileEndpoint.managerChat(after: nil).capability, .manager)
        XCTAssertEqual(MobileEndpoint.managerScreen(lines: 10).capability, .manager)
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
        // No status yet is not idle: the pane may be on a prompt.
        XCTAssertEqual(MobileManagerStatus(nil), .unknown)
        XCTAssertEqual(MobileManagerStatus(.idle), .idle)
        XCTAssertEqual(MobileManagerStatus(.busy), .busy)
        XCTAssertEqual(MobileManagerStatus(.waiting), .waiting)
    }

    // MARK: a turn

    private func body(_ name: String, _ value: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [name: value])) ?? Data()
    }

    func testReadsTheTextAndTheKeyOfARequest() {
        XCTAssertEqual(
            MobileManager.text(in: Data(#"{"text":"  what needs me?\n"}"#.utf8)), .value("what needs me?"))
        XCTAssertEqual(MobileManager.text(in: Data(#"{"text":"   "}"#.utf8)), .invalid)
        XCTAssertEqual(MobileManager.text(in: Data(#"{"text":7}"#.utf8)), .invalid)
        XCTAssertEqual(MobileManager.text(in: Data("what needs me?".utf8)), .invalid)
        XCTAssertEqual(MobileManager.text(in: Data()), .invalid)
        XCTAssertEqual(MobileManager.key(in: Data(#"{"key":"billing:pr"}"#.utf8)), .value("billing:pr"))
        XCTAssertEqual(MobileManager.key(in: Data(#"{"text":"billing:pr"}"#.utf8)), .invalid)
        XCTAssertEqual(MobileManager.Field.invalid.refusal?.status, 400)
        XCTAssertEqual(MobileManager.Field.tooLong.refusal?.status, 413)
        XCTAssertNil(MobileManager.Field.value("x").refusal)
    }

    /// The text is pasted into a terminal: a control character there is a key.
    func testATextWithAKeyPressInItIsRefused() {
        let keys: [(String, String)] = [
            ("Shift+Tab", "a\u{1B}[Zb"),
            ("Escape", "stop\u{1B}"),
            ("Ctrl-C", "a\u{03}b"),
            ("Ctrl-D", "a\u{04}b"),
            ("carriage return", "first\rsecond"),
            ("CRLF", "first\r\nsecond"),
            ("NUL", "a\u{00}b"),
            ("backspace", "a\u{08}b"),
            ("unit separator", "a\u{1F}b"),
            ("DEL", "a\u{7F}b"),
            ("C1 CSI", "a\u{9B}Zb"),
            ("first C1", "a\u{80}b"),
            ("last C1", "a\u{9F}b"),
        ]
        for (name, text) in keys {
            XCTAssertEqual(MobileManager.text(in: body("text", text)), .invalid, name)
        }
        for scalar in (0x00...0x1F).compactMap(Unicode.Scalar.init) where scalar != "\n" && scalar != "\t" {
            XCTAssertFalse(MobileManager.isText(scalar), "U+\(String(scalar.value, radix: 16))")
        }
        for scalar in (0x7F...0x9F).compactMap(Unicode.Scalar.init) {
            XCTAssertFalse(MobileManager.isText(scalar), "U+\(String(scalar.value, radix: 16))")
        }
    }

    func testNewlineTabAndOrdinaryTextAreKept() {
        let text = "first line\n\tsecond: caf\u{E9} \u{2014} \u{1F44D} ~ \u{A0}end"
        XCTAssertEqual(MobileManager.text(in: body("text", text)), .value(text))
        XCTAssertTrue(MobileManager.isText(" "))
        XCTAssertTrue(MobileManager.isText("~"))
        XCTAssertTrue(MobileManager.isText("\u{A0}"))
    }

    func testTheTextAndTheKeyHaveASizeLimit() {
        let most = String(repeating: "a", count: MobileManager.maxTextBytes)
        XCTAssertEqual(MobileManager.text(in: body("text", most)), .value(most))
        XCTAssertEqual(MobileManager.text(in: body("text", most + "a")), .tooLong)
        // The limit is in bytes: a two-byte letter counts twice.
        let wide = String(repeating: "\u{E9}", count: MobileManager.maxTextBytes / 2 + 1)
        XCTAssertEqual(MobileManager.text(in: body("text", wide)), .tooLong)
        let key = String(repeating: "k", count: MobileManager.maxKeyBytes)
        XCTAssertEqual(MobileManager.key(in: body("key", key)), .value(key))
        XCTAssertEqual(MobileManager.key(in: body("key", key + "k")), .tooLong)
        XCTAssertEqual(MobileManager.maxTextBytes, 8192)
        XCTAssertEqual(MobileManager.maxKeyBytes, 256)
    }

    func testOnlyAReviewItemOnTheBoardCanBeDismissed() {
        XCTAssertTrue(MobileManager.hasReview("billing:pr", in: board()))
        XCTAssertFalse(MobileManager.hasReview("nope", in: board()))
        XCTAssertFalse(MobileManager.hasReview("billing:pr", in: MobileManagerBoard()))
    }

    private func error(_ response: MobileResponse?) -> [String: String]? {
        response.flatMap { try? JSONSerialization.jsonObject(with: $0.body) } as? [String: String]
    }

    func testATurnIsRefusedUnlessThePaneIsIdle() {
        XCTAssertNil(MobileManager.refusal(status: .idle, turnRunning: false))
        // The pane is busy with no turn the app tracks (a turn that timed out,
        // or one typed into its terminal). It may reach a prompt before the
        // Enter lands, so the phone does not send into it.
        let paneBusy = MobileManager.refusal(status: .busy, turnRunning: false)
        XCTAssertEqual(paneBusy?.status, 409)
        XCTAssertEqual(error(paneBusy), ["error": "busy", "message": "Maestro is busy"])

        let busy = MobileManager.refusal(status: .busy, turnRunning: true)
        XCTAssertEqual(busy?.status, 409)
        XCTAssertEqual(error(busy), ["error": "busy", "message": "A turn is running"])

        // Text typed into a pane that sits on a prompt would answer the prompt.
        let waiting = MobileManager.refusal(status: .waiting, turnRunning: false)
        XCTAssertEqual(waiting?.status, 409)
        XCTAssertEqual(error(waiting), ["error": "waiting", "message": "Maestro is waiting on a prompt"])

        let unknown = MobileManager.refusal(status: .unknown, turnRunning: false)
        XCTAssertEqual(unknown?.status, 503)
        XCTAssertEqual(error(unknown), ["error": "not_ready", "message": "Maestro is not ready"])

        let off = MobileManager.refusal(status: .off, turnRunning: false)
        XCTAssertEqual(off?.status, 503)
        XCTAssertEqual(error(off), ["error": "unavailable", "message": "Maestro is not running"])
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
            end(.refused("Maestro is waiting on a prompt")),
            ["outcome": "refused", "reply": "", "message": "Maestro is waiting on a prompt"])
        XCTAssertEqual(
            end(.unreachable("The Maestro session is not running")),
            ["outcome": "unreachable", "reply": "", "message": "The Maestro session is not running"])
    }
}
