import XCTest

/// tmux on every host, scripted: it records each call and runs nothing.
/// Shared by the server tests.
final class FakeTmux {
    private let lock = NSLock()
    private var _calls: [(host: String, args: [String])] = []
    private var _output = ""
    private var _failing = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: [(host: String, args: [String])] { locked { _calls } }
    var argv: [[String]] { calls.map(\.args) }
    /// What every call prints.
    var output: String {
        get { locked { _output } }
        set { locked { _output = newValue } }
    }
    var failing: Bool {
        get { locked { _failing } }
        set { locked { _failing = newValue } }
    }

    var source: (Host) -> MobileTmux? {
        { [self] host in
            { [self] args in
                locked {
                    guard !_failing else { return nil }
                    _calls.append((host.name, args))
                    return _output
                }
            }
        }
    }
}

final class MobileActionsTests: XCTestCase {
    private let devbox = Host(name: "devbox", sshAlias: "devbox")
    private let tmux = FakeTmux()

    private func pane(_ id: String, _ path: String, agent: Bool = true) -> TmuxPane {
        var pane = TmuxPane(id: id, index: 0, command: agent ? "claude" : "zsh", title: "", active: true)
        if agent { pane.claudeSessionId = "c\(id.dropFirst())" }
        pane.path = path
        return pane
    }

    /// Two hosts. localhost: `acme-app` (windows 1 and 2), `billing`, and the
    /// manager's own session. devbox: `infra`.
    private func snapshot() -> MobileSnapshot {
        MobileSnapshot.build([
            MobileHostInput(
                host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
                sessions: [
                    TmuxSession(name: "acme-app", attached: true, windows: [
                        TmuxWindow(index: 1, name: "checkout-fix", active: true, panes: [
                            pane("%12", "/Users/me/acme-app"), pane("%14", "/Users/me/acme-app"),
                        ]),
                        TmuxWindow(index: 2, name: "shell", active: false, panes: [
                            pane("%13", "/Users/me/acme-app/web", agent: false),
                        ]),
                    ]),
                    TmuxSession(name: "billing", attached: false, windows: [
                        TmuxWindow(index: 1, name: "proration", active: true, panes: [
                            pane("%20", "/Users/me/billing"),
                        ]),
                    ]),
                    TmuxSession(name: ManagerHome.sessionName, attached: false, windows: [
                        TmuxWindow(index: 1, name: "manager", active: true, panes: [
                            pane("%30", "/Users/me/manager"),
                        ]),
                    ]),
                ]),
            MobileHostInput(
                host: devbox, colorHex: "#f5a623", reachability: .reachable, stats: nil,
                sessions: [
                    TmuxSession(name: "infra", attached: false, windows: [
                        TmuxWindow(index: 1, name: "deploy-fix", active: true, panes: [
                            pane("%3", "/home/me/infra"),
                        ]),
                    ]),
                ]),
        ])
    }

    private func run(_ action: MobileAction, _ json: String) -> (status: Int, body: [String: Any]) {
        let response = MobileActions.perform(
            action, body: Data(json.utf8), snapshot: snapshot(), tmux: tmux.source)
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return (response.status, body ?? [:])
    }

    private func code(_ action: MobileAction, _ json: String) -> String {
        let result = run(action, json)
        return "\(result.status) \(result.body["error"] as? String ?? "ok")"
    }

    // MARK: the action list

    func testTheActionListIsFixed() {
        XCTAssertEqual(MobileAction.allCases.map(\.rawValue), [
            "new-session", "new-window", "rename-session", "rename-window",
            "kill-session", "kill-window", "kill-pane", "zoom-pane",
        ])
        for word in ["kill-server", "send-keys", "run-shell", "split-window", "kill", "", "new-window "] {
            XCTAssertNil(MobileAction(rawValue: word), word)
        }
        XCTAssertEqual(MobileAction.allCases.filter(\.isKill), [.killSession, .killWindow, .killPane])
    }

    func testRoutesNameAnActionAndRefuseAnyOtherWord() {
        let on = MobileConfig(capabilities: [.sessionActions, .kill, .find])
        let post = { (path: String) in
            MobileAPI.route(MobileRequest(method: "POST", path: path), config: on)
        }
        for action in MobileAction.allCases {
            XCTAssertEqual(post("/api/tmux/\(action.rawValue)"), .api(.tmux(action)))
        }
        for word in ["kill-server", "send-keys", "run-shell", "split-window", "NEW-WINDOW", "kill"] {
            XCTAssertEqual(post("/api/tmux/\(word)"), .unknownAction, word)
        }
        XCTAssertEqual(post("/api/tmux"), .notFound)
        XCTAssertEqual(post("/api/tmux/new-window/extra"), .notFound)
        XCTAssertEqual(
            MobileAPI.route(MobileRequest(method: "GET", path: "/api/tmux/new-window"), config: on),
            .methodNotAllowed)
        XCTAssertEqual(
            MobileAPI.route(MobileRequest(method: "GET", path: "/api/hosts/devbox/dirs"), config: on),
            .api(.dirs(host: "devbox")))
        XCTAssertEqual(
            MobileAPI.route(
                MobileRequest(method: "GET", path: "/api/threads/localhost%3A12/find", query: ["q": "tax"]),
                config: on),
            .api(.find(id: "localhost:12", query: "tax")))
    }

    func testEachSwitchOpensItsOwnRoutesAndKillNeedsBoth() {
        let route = { (method: String, path: String, capabilities: Set<MobileCapability>) in
            MobileAPI.route(
                MobileRequest(method: method, path: path), config: MobileConfig(capabilities: capabilities))
        }
        XCTAssertEqual(route("POST", "/api/tmux/new-window", []), .disabled(.sessionActions))
        XCTAssertEqual(route("POST", "/api/tmux/new-window", [.kill, .find]), .disabled(.sessionActions))
        XCTAssertEqual(route("GET", "/api/hosts/devbox/dirs", [.kill, .find]), .disabled(.sessionActions))
        XCTAssertEqual(route("POST", "/api/tmux/kill-window", [.sessionActions]), .disabled(.kill))
        XCTAssertEqual(route("POST", "/api/tmux/kill-window", [.kill]), .disabled(.sessionActions))
        XCTAssertEqual(route("POST", "/api/tmux/kill-server", []), .disabled(.kill))
        XCTAssertEqual(
            route("GET", "/api/threads/localhost%3A12/find", [.sessionActions, .kill]), .disabled(.find))
        XCTAssertEqual(route("GET", "/api/hosts", []), .api(.hosts))
    }

    // MARK: argv

    func testEachActionRunsItsExactTmuxCommandOnTheTargetsHost() {
        tmux.output = "3\t%41\n"
        let created = run(.newWindow, #"{"host":"localhost","session":"acme-app"}"#)
        XCTAssertEqual(created.status, 200)
        XCTAssertEqual(created.body["thread"] as? String, "localhost:41")
        XCTAssertEqual(run(.newWindow, #"{"thread":"localhost:13"}"#).status, 200)
        XCTAssertEqual(run(.renameSession, #"{"host":"devbox","session":"infra","name":"infra 2"}"#).status, 200)
        XCTAssertEqual(run(.renameWindow, #"{"thread":"localhost:12","name":"🌱 checkout"}"#).status, 200)
        XCTAssertEqual(run(.zoomPane, #"{"thread":"localhost:14"}"#).status, 200)
        XCTAssertEqual(run(.killPane, #"{"thread":"localhost:14","confirm":true}"#).status, 200)
        XCTAssertEqual(run(.killWindow, #"{"thread":"devbox:3","confirm":true}"#).status, 200)
        XCTAssertEqual(run(.killSession, #"{"host":"localhost","session":"billing","confirm":true}"#).status, 200)

        let format = "#{window_index}\t#{pane_id}"
        XCTAssertEqual(tmux.argv, [
            ["new-window", "-a", "-t", "=acme-app:", "-P", "-F", format, "-c", "/Users/me/acme-app"],
            ["new-window", "-a", "-t", "=acme-app:", "-P", "-F", format, "-c", "/Users/me/acme-app/web"],
            ["rename-session", "-t", "=infra", "infra 2"],
            ["rename-window", "-t", "%12", "🌱 checkout"],
            ["resize-pane", "-Z", "-t", "%14"],
            ["kill-pane", "-t", "%14"],
            ["kill-window", "-t", "%3"],
            ["kill-session", "-t", "=billing"],
        ])
        XCTAssertEqual(tmux.calls.map(\.host), [
            "localhost", "localhost", "devbox", "localhost", "localhost", "localhost", "devbox", "localhost",
        ])
    }

    func testANewSessionStartsOnlyInADirectoryTheServerOffered() {
        XCTAssertEqual(
            MobileActions.dirs(host: "localhost", snapshot: snapshot()),
            ["/Users/me/acme-app", "/Users/me/acme-app/web", "/Users/me/billing"])
        XCTAssertEqual(MobileActions.dirs(host: "devbox", snapshot: snapshot()), ["/home/me/infra"])
        XCTAssertNil(MobileActions.dirs(host: "buildbox", snapshot: snapshot()))

        let made = run(.newSession, #"{"host":"localhost","dir":"/Users/me/billing"}"#)
        XCTAssertEqual(made.status, 200)
        // The folder's name, made unique against the sessions that exist.
        XCTAssertEqual(made.body["session"] as? String, "billing-2")
        XCTAssertEqual(run(.newSession, #"{"host":"devbox"}"#).body["session"] as? String, "session")
        XCTAssertEqual(
            run(.newSession, #"{"host":"devbox","dir":"/home/me/infra","name":"api"}"#).status, 200)
        // The manager's session is hidden, and its name is still taken.
        XCTAssertEqual(
            run(.newSession, #"{"host":"localhost","name":"mux-manager"}"#).body["session"] as? String,
            "mux-manager-2")
        XCTAssertEqual(tmux.argv, [
            ["new-session", "-d", "-s", "billing-2", "-c", "/Users/me/billing"],
            ["new-session", "-d", "-s", "session"],
            ["new-session", "-d", "-s", "api", "-c", "/home/me/infra"],
            ["new-session", "-d", "-s", "mux-manager-2"],
        ])

        let before = tmux.argv.count
        for dir in [
            #""/etc""#, #""/Users/me""#, #""/Users/me/billing/..""#, #""/home/me/infra""#,
            #""~""#, #""""#, "7", #"["/Users/me/billing"]"#,
        ] {
            XCTAssertEqual(code(.newSession, #"{"host":"localhost","dir":\#(dir)}"#), "400 bad_dir", dir)
        }
        // Nothing but a host, a directory and a name is read: no command.
        XCTAssertEqual(
            run(.newSession, #"{"host":"devbox","command":"rm -rf /","shell":"sh -c id"}"#).status, 200)
        XCTAssertEqual(tmux.argv.count, before + 1)
        XCTAssertEqual(tmux.argv.last, ["new-session", "-d", "-s", "session"])
    }

    // MARK: refusals

    func testATargetThatIsNotInTheLiveTreeIsA404AndRunsNothing() {
        let stale = [
            #"{"thread":"localhost:99"}"#, #"{"thread":"devbox:12"}"#, #"{"thread":"%12"}"#,
            #"{"thread":"localhost:12; kill-server"}"#, #"{"thread":"=acme-app:1"}"#,
        ]
        for body in stale {
            for action in [MobileAction.renameWindow, .killWindow, .killPane, .zoomPane, .newWindow] {
                let full = body.dropLast() + #","name":"ok","confirm":true}"#
                XCTAssertEqual(code(action, String(full)), "404 not_found", "\(action) \(body)")
            }
        }
        for body in [
            #"{"host":"localhost","session":"nope"}"#, #"{"host":"buildbox","session":"acme-app"}"#,
            #"{"host":"devbox","session":"acme-app"}"#, #"{"host":"localhost","session":"acme-app:1"}"#,
            #"{"host":"localhost","session":"acme"}"#,
        ] {
            for action in [MobileAction.newWindow, .renameSession, .killSession] {
                let full = body.dropLast() + #","name":"ok","confirm":true}"#
                XCTAssertEqual(code(action, String(full)), "404 not_found", "\(action) \(body)")
            }
        }
        XCTAssertEqual(code(.newSession, #"{"host":"buildbox"}"#), "404 not_found")
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testABodyWithoutItsTargetIsRefused() {
        for body in ["", "[]", "nope", #"{}"#, #"{"thread":12}"#, #"{"host":["localhost"]}"#] {
            for action in MobileAction.allCases {
                XCTAssertEqual(code(action, body), "400 bad_request", "\(action) \(body)")
            }
        }
        XCTAssertEqual(code(.renameSession, #"{"host":"localhost","name":"x"}"#), "400 bad_request")
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testANameIsCheckedBeforeItReachesTmux() {
        for good in ["api", "checkout fix", "web_2", "feat/login", "🌱 mux", "日本語", "👩‍💻 dev", " padded "] {
            XCTAssertNotNil(MobileActions.name(good), good)
        }
        XCTAssertEqual(MobileActions.name(" padded "), "padded")
        XCTAssertEqual(MobileActions.name(String(repeating: "a", count: 64))?.count, 64)
        let bad: [String] = [
            "", "   ", String(repeating: "a", count: 65),
            "a:b", "a.b", "=acme", "$1", "@2", "%3", "a#b", "#(id)", "{last}", "a!", "a^", "a+", "a~",
            "a*", "a?", "[a]", "-t", "--", "a;b", "a|b", "a&b", "a`id`", "$(id)", "a'b", "a\"b", "a\\b",
            "a<b", "a>b", "a\nb", "a\tb", "a\u{0}b", "a\u{1B}[31m", "a\u{7F}", "a\u{85}b",
            "a\u{2028}b", "a\u{202E}b", "a\u{200B}b", "a\u{FEFF}b",
        ]
        for name in bad {
            XCTAssertNil(MobileActions.name(name), name.debugDescription)
            let json = String(
                decoding: try! JSONSerialization.data(withJSONObject: [
                    "host": "localhost", "session": "acme-app", "thread": "localhost:12", "name": name,
                ]), as: UTF8.self)
            XCTAssertEqual(code(.renameWindow, json), "400 bad_name", name.debugDescription)
            XCTAssertEqual(code(.renameSession, json), "400 bad_name", name.debugDescription)
            XCTAssertEqual(code(.newSession, json), "400 bad_name", name.debugDescription)
        }
        for other in ["7", "true", "null", #"["a"]"#, #"{"a":1}"#] {
            XCTAssertEqual(
                code(.renameWindow, #"{"thread":"localhost:12","name":\#(other)}"#), "400 bad_name", other)
        }
        XCTAssertEqual(code(.renameWindow, #"{"thread":"localhost:12"}"#), "400 bad_name")
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testARenameOntoAnotherSessionIsRefused() {
        let body = { (name: String) in #"{"host":"localhost","session":"acme-app","name":"\#(name)"}"# }
        XCTAssertEqual(code(.renameSession, body("billing")), "409 exists")
        XCTAssertEqual(code(.renameSession, body(ManagerHome.sessionName)), "409 exists")
        XCTAssertEqual(tmux.argv.count, 0)
        // A session of the same name on another host is another session.
        XCTAssertEqual(code(.renameSession, body("infra")), "200 ok")
    }

    func testAKillWithoutTheConfirmFieldIsRefused() {
        let targets: [(MobileAction, String)] = [
            (.killPane, #""thread":"localhost:14""#), (.killWindow, #""thread":"localhost:12""#),
            (.killSession, #""host":"localhost","session":"billing""#),
        ]
        for (action, target) in targets {
            XCTAssertEqual(code(action, "{\(target)}"), "400 confirm_required", "\(action)")
            for value in ["false", "1", #""true""#, #""yes""#, "null", "[true]"] {
                XCTAssertEqual(
                    code(action, "{\(target),\"confirm\":\(value)}"), "400 confirm_required",
                    "\(action) \(value)")
            }
        }
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testTheManagersOwnSessionTakesNoAction() {
        let session = #""host":"localhost","session":"mux-manager""#
        let thread = #""thread":"localhost:30""#
        XCTAssertEqual(code(.killSession, "{\(session),\"confirm\":true}"), "403 protected")
        XCTAssertEqual(code(.killWindow, "{\(thread),\"confirm\":true}"), "403 protected")
        XCTAssertEqual(code(.killPane, "{\(thread),\"confirm\":true}"), "403 protected")
        XCTAssertEqual(code(.renameSession, "{\(session),\"name\":\"mine\"}"), "403 protected")
        XCTAssertEqual(code(.renameWindow, "{\(thread),\"name\":\"mine\"}"), "403 protected")
        XCTAssertEqual(code(.newWindow, "{\(session)}"), "403 protected")
        XCTAssertEqual(code(.newWindow, "{\(thread)}"), "403 protected")
        XCTAssertEqual(code(.zoomPane, "{\(thread)}"), "403 protected")
        XCTAssertEqual(tmux.argv.count, 0)
        // Its directory is not offered either.
        XCTAssertFalse(
            MobileActions.dirs(host: "localhost", snapshot: snapshot())?.contains("/Users/me/manager") ?? true)
        // A session of that name on another host is not the manager's.
        let remote = MobileSnapshot.build([MobileHostInput(
            host: devbox, colorHex: "#f5a623", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: ManagerHome.sessionName, attached: false, windows: [
                TmuxWindow(index: 1, name: "w", active: true, panes: [pane("%5", "/home/me")]),
            ])])])
        let response = MobileActions.perform(
            .killSession, body: Data(#"{"host":"devbox","session":"mux-manager","confirm":true}"#.utf8),
            snapshot: remote, tmux: tmux.source)
        XCTAssertEqual(response.status, 200)
    }

    func testAFailedTmuxCallIsA503() {
        tmux.failing = true
        XCTAssertEqual(code(.zoomPane, #"{"thread":"localhost:12"}"#), "503 unavailable")
        let none = MobileActions.perform(
            .zoomPane, body: Data(#"{"thread":"localhost:12"}"#.utf8), snapshot: snapshot(),
            tmux: { _ in nil })
        XCTAssertEqual(none.status, 503)
    }

    // MARK: find

    private func thread() -> MobileThread { snapshot().thread(id: "localhost:12")! }

    private func capture(_ lines: [String], pane: String = "%12") -> String {
        "\(PaneSearch.marker)\(pane)\n" + lines.joined(separator: "\n") + "\n"
    }

    func testAQueryIsPlainTextWithALengthCap() {
        XCTAssertEqual(MobileFind.query("  tax line "), "tax line")
        XCTAssertEqual(MobileFind.query(".*[a-z]+("), ".*[a-z]+(")
        XCTAssertEqual(MobileFind.query(String(repeating: "a", count: 200))?.count, 200)
        for bad in ["", "   ", String(repeating: "a", count: 201), "a\nb", "a\tb", "a\u{1B}[31m", "a\u{0}"] {
            XCTAssertNil(MobileFind.query(bad), bad.debugDescription)
        }
    }

    func testFindReturnsTheScrollbackAndWhereTheQueryIs() throws {
        let result = MobileFind.result(
            query: "tax", capture: capture(["$ make test", "Tax line ok", "café tax, tax", "", "  ", ""]),
            thread: thread())
        XCTAssertEqual(result["text"] as? String, "$ make test\nTax line ok\ncafé tax, tax")
        XCTAssertEqual(result["truncated"] as? Bool, false)
        let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.map { $0["line"] as? Int }, [1, 2])
        // Offsets count UTF-16 units: `é` is one, though it is two bytes.
        XCTAssertEqual(matches[0]["ranges"] as? [[Int]], [[0, 3]])
        XCTAssertEqual(matches[1]["ranges"] as? [[Int]], [[5, 8], [10, 13]])
        // An uppercase letter makes the search case-sensitive, as on the Mac.
        let exact = MobileFind.result(
            query: "Tax", capture: capture(["tax", "Tax"]), thread: thread())
        XCTAssertEqual((exact["matches"] as? [[String: Any]])?.map { $0["line"] as? Int }, [1])
        // A pattern is text: it matches itself and nothing else.
        let literal = MobileFind.result(
            query: "a.c", capture: capture(["abc", "a.c"]), thread: thread())
        XCTAssertEqual((literal["matches"] as? [[String: Any]])?.map { $0["line"] as? Int }, [1])
        // Another pane's capture is not this thread's.
        let other = MobileFind.result(query: "tax", capture: capture(["tax"], pane: "%13"), thread: thread())
        XCTAssertEqual(other["text"] as? String, "")
        XCTAssertEqual((other["matches"] as? [[String: Any]])?.count, 0)
    }

    func testFindCapsItsMatchesAndItsText() throws {
        let many = MobileFind.result(
            query: "x", capture: capture(Array(repeating: "x", count: 500)), thread: thread())
        XCTAssertEqual((many["matches"] as? [[String: Any]])?.count, MobileFind.maxMatches)
        XCTAssertEqual(many["truncated"] as? Bool, true)

        let long = String(repeating: "y", count: PaneSearch.maxLineLength)
        let lines = Array(repeating: long, count: 1998) + ["oldest is gone", "newest stays"]
        let big = MobileFind.result(query: "stays", capture: capture(lines), thread: thread())
        let text = try XCTUnwrap(big["text"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, MobileFind.maxTextBytes)
        XCTAssertTrue(text.hasSuffix("newest stays"))
        let match = try XCTUnwrap((big["matches"] as? [[String: Any]])?.first)
        let kept = text.components(separatedBy: "\n")
        XCTAssertEqual(kept[try XCTUnwrap(match["line"] as? Int)], "newest stays")
        // A line is cut to the length the Mac's search shows.
        let wide = MobileFind.result(
            query: "z", capture: capture([String(repeating: "w", count: 2000) + "z"]), thread: thread())
        XCTAssertEqual((wide["text"] as? String)?.count, PaneSearch.maxLineLength)
        XCTAssertEqual((wide["matches"] as? [[String: Any]])?.count, 0)
    }

    func testFindCapturesOnlyTheThreadsOwnPane() {
        tmux.output = capture(["tax"])
        let response = MobileFind.search(thread: thread(), query: "tax", tmux: tmux.source(.local))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(tmux.argv, [[
            "display-message", "-p", "-t", "%12", "\(PaneSearch.marker)#{pane_id}", ";",
            "capture-pane", "-p", "-S", "-\(PaneSearch.captureLines)", "-t", "%12",
        ]])
        XCTAssertEqual(MobileFind.search(thread: thread(), query: "tax", tmux: nil).status, 503)
    }
}
