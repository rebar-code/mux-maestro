import XCTest

/// tmux on every host, scripted: it records each call and runs nothing.
/// Shared by the server tests.
final class FakeTmux {
    private let lock = NSLock()
    private var _calls: [(host: String, args: [String])] = []
    private var _output = ""
    private var _failing = false
    private var _failure = ""
    private var _missing = false
    private var _gate: DispatchSemaphore?

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
    /// Every call exits non-zero.
    var failing: Bool {
        get { locked { _failing } }
        set { locked { _failing = newValue } }
    }
    /// What a failing call prints.
    var failure: String {
        get { locked { _failure } }
        set { locked { _failure = newValue } }
    }
    /// The host has no tmux to call.
    var missing: Bool {
        get { locked { _missing } }
        set { locked { _missing = newValue } }
    }
    /// A call waits here until it is signalled.
    var gate: DispatchSemaphore? {
        get { locked { _gate } }
        set { locked { _gate = newValue } }
    }

    var source: (Host) -> MobileTmux? {
        { [self] host in
            { [self] args in
                let (answer, gate): ((ok: Bool, output: String)?, DispatchSemaphore?) = locked {
                    guard !_missing else { return (nil, nil) }
                    _calls.append((host.name, args))
                    return (_failing ? (false, _failure) : (true, _output), _gate)
                }
                gate?.wait()
                return answer
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
                    TmuxSession(name: "acme-app", attached: true, id: "$1", windows: [
                        TmuxWindow(index: 1, name: "checkout-fix", active: true, panes: [
                            pane("%12", "/Users/me/acme-app"), pane("%14", "/Users/me/acme-app"),
                        ]),
                        TmuxWindow(index: 2, name: "shell", active: false, panes: [
                            pane("%13", "/Users/me/acme-app/web", agent: false),
                        ]),
                    ]),
                    TmuxSession(name: "billing", attached: false, id: "$2", windows: [
                        TmuxWindow(index: 1, name: "proration", active: true, panes: [
                            pane("%20", "/Users/me/billing"),
                        ]),
                    ]),
                    TmuxSession(name: ManagerHome.sessionName, attached: false, id: "$3", windows: [
                        TmuxWindow(index: 1, name: "manager", active: true, panes: [
                            pane("%30", "/Users/me/manager"),
                        ]),
                    ]),
                ]),
            MobileHostInput(
                host: devbox, colorHex: "#f5a623", reachability: .reachable, stats: nil,
                sessions: [
                    TmuxSession(name: "infra", attached: false, id: "$0", windows: [
                        TmuxWindow(index: 1, name: "deploy-fix", active: true, panes: [
                            pane("%3", "/home/me/infra"),
                        ]),
                    ]),
                ]),
        ])
    }

    private func run(_ action: MobileAction, _ json: String) -> (status: Int, body: [String: Any]) {
        let response = MobileActions.perform(
            action, body: Data(json.utf8), snapshot: snapshot(), home: "/Users/me", tmux: tmux.source)
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
            "kill-session", "kill-window", "kill-pane", "zoom-pane", "archive-window",
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
            .api(.dirs(host: "devbox", path: nil)))
        XCTAssertEqual(
            MobileAPI.route(
                MobileRequest(method: "GET", path: "/api/hosts/devbox/dirs", query: ["path": "/home/me/code"]),
                config: on),
            .api(.dirs(host: "devbox", path: "/home/me/code")))
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

    /// The Mac can undo an archive, so the kill switch is not asked for.
    func testAnArchiveNeedsSessionActionsAndNotKill() {
        let route = { (capabilities: Set<MobileCapability>) in
            MobileAPI.route(
                MobileRequest(method: "POST", path: "/api/tmux/archive-window"),
                config: MobileConfig(capabilities: capabilities))
        }
        XCTAssertEqual(route([.sessionActions]), .api(.tmux(.archiveWindow)))
        XCTAssertEqual(route([.kill, .find]), .disabled(.sessionActions))
        XCTAssertEqual(route([]), .disabled(.sessionActions))
        XCTAssertFalse(MobileAction.archiveWindow.isKill)
        XCTAssertEqual(MobileEndpoint.tmux(.archiveWindow).capability, .sessionActions)
    }

    // MARK: archive

    private func archive(
        _ json: String, archived: Bool = true
    ) -> (code: String, asked: [MobileThread]) {
        var asked: [MobileThread] = []
        let response = MobileActions.perform(
            .archiveWindow, body: Data(json.utf8), snapshot: snapshot(), tmux: tmux.source,
            archive: { thread in
                asked.append(thread)
                return archived
            })
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        return ("\(response.status) \(body["error"] as? String ?? "ok")", asked)
    }

    func testAnArchiveGoesToTheMacWithTheThreadsOwnWindowAndRunsNoTmux() throws {
        // No `confirm` field.
        let done = archive(#"{"thread":"localhost:13"}"#)
        XCTAssertEqual(done.code, "200 ok")
        let thread = try XCTUnwrap(done.asked.first)
        XCTAssertEqual(done.asked.count, 1)
        XCTAssertEqual(thread.host, .local)
        XCTAssertEqual(thread.session, "acme-app")
        XCTAssertEqual(thread.window, 2)
        XCTAssertEqual(thread.pane, "%13")

        let remote = archive(#"{"thread":"devbox:3"}"#)
        XCTAssertEqual(remote.code, "200 ok")
        XCTAssertEqual(remote.asked.first?.host, devbox)
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testAnArchiveOfAThreadThatIsNotInTheLiveTreeIsA404() {
        for body in [
            #"{"thread":"localhost:99"}"#, #"{"thread":"devbox:12"}"#, #"{"thread":"%12"}"#,
            #"{"thread":"localhost:12; kill-server"}"#,
        ] {
            let stale = archive(body)
            XCTAssertEqual(stale.code, "404 not_found", body)
            XCTAssertTrue(stale.asked.isEmpty, body)
        }
        XCTAssertEqual(archive(#"{"host":"localhost","session":"acme-app"}"#).code, "400 bad_request")
        XCTAssertEqual(archive("[]").code, "400 bad_request")
    }

    func testTheManagersOwnWindowIsNotArchived() {
        let manager = archive(#"{"thread":"localhost:30"}"#)
        XCTAssertEqual(manager.code, "403 protected")
        XCTAssertTrue(manager.asked.isEmpty)
    }

    func testAnArchiveThatDidNotRunIsA409AndWithoutAMacA503() {
        XCTAssertEqual(archive(#"{"thread":"localhost:12"}"#, archived: false).code, "409 failed")
        // The dev server: tmux or not, there is nothing to archive with.
        XCTAssertEqual(code(.archiveWindow, #"{"thread":"localhost:12"}"#), "503 unavailable")
        XCTAssertEqual(tmux.argv.count, 0)
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
        XCTAssertEqual(run(.killSession, #"{"thread":"localhost:20","confirm":true}"#).status, 200)

        let format = "#{window_index}\t#{pane_id}"
        XCTAssertEqual(tmux.argv, [
            ["new-window", "-a", "-t", "$1:", "-P", "-F", format, "-c", "/Users/me/acme-app"],
            ["new-window", "-a", "-t", "$1:", "-P", "-F", format, "-c", "/Users/me/acme-app/web"],
            ["rename-session", "-t", "$0", "infra 2"],
            ["rename-window", "-t", "%12", "--", "🌱 checkout"],
            ["resize-pane", "-Z", "-t", "%14"],
            ["kill-pane", "-t", "%14"],
            ["kill-window", "-t", "%3"],
            ["kill-session", "-t", "$2"],
        ])
        // No session name is in any command: a session is its id.
        for word in tmux.argv.joined() {
            XCTAssertFalse(word.contains("billing") || word.contains("acme-app:") || word.contains("infra:"), word)
        }
        XCTAssertEqual(tmux.calls.map(\.host), [
            "localhost", "localhost", "devbox", "localhost", "localhost", "localhost", "devbox", "localhost",
        ])
    }

    func testARemoteClaudeStartHasAChatAndALocalCodexStartToo() {
        tmux.output = "3\t%41\n"
        let far = run(.newWindow, #"{"host":"devbox","session":"infra","agent":"claude"}"#)
        XCTAssertEqual(far.body["chat"] as? Bool, true)
        XCTAssertEqual(MobileActions.startedThread(.json(far.body)), "devbox:41")
        let near = run(.newWindow, #"{"thread":"localhost:13","agent":"codex"}"#)
        XCTAssertEqual(MobileActions.startedThread(.json(near.body)), "localhost:41")
    }

    func testANewWindowStartsTheAskedAgentInTheNewPane() {
        tmux.output = "3\t%41\n"
        let claude = run(.newWindow, #"{"thread":"localhost:13","agent":"claude"}"#)
        XCTAssertEqual(claude.status, 200)
        XCTAssertEqual(claude.body["thread"] as? String, "localhost:41")
        XCTAssertEqual(claude.body["agent"] as? String, "claude")
        let codex = run(.newWindow, #"{"host":"devbox","session":"infra","agent":"codex"}"#)
        XCTAssertEqual(codex.body["thread"] as? String, "devbox:41")
        XCTAssertEqual(codex.body["agent"] as? String, "codex")
        // Which starts have a chat to open: any local agent, and a remote
        // Claude. A remote Codex has no transcript on this Mac, so it is
        // never marked as a chat that would stay empty.
        XCTAssertEqual(claude.body["chat"] as? Bool, true)
        XCTAssertEqual(codex.body["chat"] as? Bool, false)
        let started = { (body: [String: Any]) -> String? in
            MobileActions.startedThread(.json(body))
        }
        XCTAssertEqual(started(claude.body), "localhost:41")
        XCTAssertNil(started(codex.body))
        // No agent, or null, is a bare shell.
        let shell = run(.newWindow, #"{"thread":"localhost:13","agent":null}"#)
        XCTAssertEqual(shell.status, 200)
        XCTAssertNil(shell.body["agent"])

        let format = "#{window_index}\t#{pane_id}"
        XCTAssertEqual(tmux.argv, [
            ["new-window", "-a", "-t", "$1:", "-P", "-F", format, "-c", "/Users/me/acme-app/web"],
            ["send-keys", "-t", "%41", "claude", "Enter"],
            ["new-window", "-a", "-t", "$0:", "-P", "-F", format, "-c", "/home/me/infra"],
            ["send-keys", "-t", "%41", "codex", "Enter"],
            ["new-window", "-a", "-t", "$1:", "-P", "-F", format, "-c", "/Users/me/acme-app/web"],
        ])
        XCTAssertEqual(tmux.calls.map(\.host), ["localhost", "localhost", "devbox", "devbox", "localhost"])
    }

    func testANewWindowRefusesAnAgentItDoesNotKnow() {
        for bad in [#""vim""#, #""Claude""#, #""claude; date""#, #""""#, "1", "true", #"["claude"]"#] {
            XCTAssertEqual(
                code(.newWindow, #"{"thread":"localhost:13","agent":\#(bad)}"#), "400 bad_agent", bad)
        }
        XCTAssertTrue(tmux.argv.isEmpty)
    }

    func testAWindowWhoseAgentDidNotStartIsStillMade() {
        // tmux printed no pane id: there is no pane to type the command into.
        tmux.output = ""
        let made = run(.newWindow, #"{"thread":"localhost:13","agent":"claude"}"#)
        XCTAssertEqual(made.status, 200)
        XCTAssertNil(made.body["agent"])
        XCTAssertEqual(tmux.argv.count, 1)
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
            // No directory is the home directory: `~` for the remote shell
            // to expand, this Mac's own path here.
            ["new-session", "-d", "-s", "session", "-c", "~"],
            ["new-session", "-d", "-s", "api", "-c", "/home/me/infra"],
            ["new-session", "-d", "-s", "mux-manager-2", "-c", "/Users/me"],
        ])

        let before = tmux.argv.count
        for dir in [
            #""/etc""#, #""/Users/me/billing/..""#, #""/home/me/infra""#,
            #""~""#, #""""#, "7", #"["/Users/me/billing"]"#,
        ] {
            XCTAssertEqual(code(.newSession, #"{"host":"localhost","dir":\#(dir)}"#), "400 bad_dir", dir)
        }
        // Nothing but a host, a directory and a name is read: no command.
        XCTAssertEqual(
            run(.newSession, #"{"host":"devbox","command":"rm -rf /","shell":"sh -c id"}"#).status, 200)
        XCTAssertEqual(tmux.argv.count, before + 1)
        XCTAssertEqual(tmux.argv.last, ["new-session", "-d", "-s", "session", "-c", "~"])
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
            for action in [MobileAction.newWindow, .renameSession] {
                let full = body.dropLast() + #","name":"ok","confirm":true}"#
                XCTAssertEqual(code(action, String(full)), "404 not_found", "\(action) \(body)")
            }
        }
        XCTAssertEqual(code(.killSession, #"{"thread":"localhost:99","confirm":true}"#), "404 not_found")
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
        // A session is killed by one of its threads, never by its name.
        XCTAssertEqual(
            code(.killSession, #"{"host":"localhost","session":"billing","confirm":true}"#),
            "400 bad_request")
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
            (.killSession, #""thread":"localhost:20""#),
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
        XCTAssertEqual(code(.killSession, "{\(thread),\"confirm\":true}"), "403 protected")
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
            sessions: [TmuxSession(name: ManagerHome.sessionName, attached: false, id: "$4", windows: [
                TmuxWindow(index: 1, name: "w", active: true, panes: [pane("%5", "/home/me")]),
            ])])])
        let response = MobileActions.perform(
            .killSession, body: Data(#"{"thread":"devbox:5","confirm":true}"#.utf8),
            snapshot: remote, tmux: tmux.source)
        XCTAssertEqual(response.status, 200)
    }

    func testAHostWithoutTmuxIsA503AndATmuxErrorIsA409() {
        tmux.missing = true
        XCTAssertEqual(code(.zoomPane, #"{"thread":"localhost:12"}"#), "503 unavailable")
        let none = MobileActions.perform(
            .zoomPane, body: Data(#"{"thread":"localhost:12"}"#.utf8), snapshot: snapshot(),
            tmux: { _ in nil })
        XCTAssertEqual(none.status, 503)

        tmux.missing = false
        tmux.failing = true
        tmux.failure = "duplicate session: api"
        XCTAssertEqual(code(.zoomPane, #"{"thread":"localhost:12"}"#), "409 failed")
        XCTAssertEqual(code(.killPane, #"{"thread":"localhost:12","confirm":true}"#), "409 failed")
        XCTAssertEqual(code(.newSession, #"{"host":"devbox"}"#), "409 failed")
    }

    func testAKillOfATargetThatIsAlreadyGoneIsDone() {
        tmux.failing = true
        for gone in ["can't find pane: %12", "can't find session: $2", "no server running on /tmp/tmux"] {
            tmux.failure = gone
            for (action, target) in [
                (MobileAction.killPane, "localhost:12"), (.killWindow, "localhost:12"),
                (.killSession, "localhost:20"),
            ] {
                let result = run(action, #"{"thread":"\#(target)","confirm":true}"#)
                XCTAssertEqual(result.status, 200, "\(action) \(gone)")
                XCTAssertEqual(result.body["gone"] as? Bool, true, "\(action) \(gone)")
            }
            // Anything else has nothing left to act on.
            XCTAssertEqual(code(.zoomPane, #"{"thread":"localhost:12"}"#), "404 not_found", gone)
            XCTAssertEqual(
                code(.renameWindow, #"{"thread":"localhost:12","name":"cart"}"#), "404 not_found", gone)
            XCTAssertEqual(code(.newWindow, #"{"thread":"localhost:12"}"#), "404 not_found", gone)
        }
    }

    // MARK: what reaches tmux is the tree's own

    private func tree(
        _ sessions: [(name: String, pane: String, path: String)], host: Host = .local, ids: [String]? = nil
    ) -> MobileSnapshot {
        MobileSnapshot.build([MobileHostInput(
            host: host, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: sessions.enumerated().map { index, session in
                // The id is the pane's number with a `$`, unless the test gives one.
                TmuxSession(name: session.name, attached: false, id: ids?[index] ?? "$\(session.pane.dropFirst())", windows: [
                    TmuxWindow(index: 1, name: "w", active: true, panes: [pane(session.pane, session.path)]),
                ])
            })])
    }

    private func status(_ action: MobileAction, _ fields: [String: Any], in snapshot: MobileSnapshot) -> String {
        let body = try! JSONSerialization.data(withJSONObject: fields)
        let response = MobileActions.perform(
            action, body: body, snapshot: snapshot, home: "/Users/me", tmux: tmux.source)
        let error = ((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any])?["error"]
        return "\(response.status) \(error as? String ?? "ok")"
    }

    func testASessionWhoseNameEndsInASemicolonTakesNoAction() {
        // tmux reads an argument that ends in `;` as the end of a command:
        // `rename-session -t =x; kill-server` would be two commands.
        let snapshot = tree([("x;", "%7", "/Users/me/x"), ("keep", "%8", "/Users/me/keep")])
        let named: [String: Any] = ["host": "localhost", "session": "x;", "name": "kill-server"]
        XCTAssertEqual(status(.renameSession, named, in: snapshot), "404 not_found")
        XCTAssertEqual(status(.newWindow, named, in: snapshot), "404 not_found")
        let byThread: [String: Any] = ["thread": "localhost:7", "name": "kill-server", "confirm": true]
        XCTAssertEqual(status(.renameSession, byThread, in: snapshot), "404 not_found")
        XCTAssertEqual(status(.newWindow, byThread, in: snapshot), "404 not_found")
        XCTAssertEqual(status(.killSession, byThread, in: snapshot), "404 not_found")
        XCTAssertEqual(tmux.argv.count, 0)

        // Nothing built for any target ends in `;`, whatever the phone sent.
        for action in MobileAction.allCases {
            for name in ["ok", "kill-server", "x;", ";"] {
                _ = status(action, [
                    "host": "localhost", "session": "keep", "thread": "localhost:8",
                    "name": name, "confirm": true,
                ], in: snapshot)
            }
        }
        XCTAssertFalse(tmux.argv.isEmpty)
        for argv in tmux.argv {
            XCTAssertFalse(argv.contains { $0.hasSuffix(";") }, "\(argv)")
        }
    }

    func testASessionOfAGroupIsTargetedByItsOwnId() {
        // `a` and `a-view` are one group: they share pane %0, and the tree
        // shows only `a`. A pane id would let tmux pick either session.
        let snapshot = tree([("a", "%0", "/Users/me/a")], ids: ["$5"])
        XCTAssertEqual(status(.killSession, ["thread": "localhost:0", "confirm": true], in: snapshot), "200 ok")
        XCTAssertEqual(
            status(.renameSession, ["host": "localhost", "session": "a", "name": "b"], in: snapshot), "200 ok")
        XCTAssertEqual(status(.newWindow, ["thread": "localhost:0"], in: snapshot), "200 ok")
        XCTAssertEqual(tmux.argv[0], ["kill-session", "-t", "$5"])
        XCTAssertEqual(tmux.argv[1], ["rename-session", "-t", "$5", "b"])
        XCTAssertEqual(Array(tmux.argv[2].prefix(4)), ["new-window", "-a", "-t", "$5:"])
        for argv in tmux.argv { XCTAssertFalse(argv.contains("%0"), "\(argv)") }

        // A tree without the id (an older reading of it), or with one that is
        // not `$` and digits, takes no session action. A window is still its pane.
        for id in ["", "a", "$", "$5;", "$5 ; kill-server", "=a", "%0"] {
            let odd = tree([("a", "%0", "/Users/me/a")], ids: [id])
            let before = tmux.argv.count
            XCTAssertEqual(status(.killSession, ["thread": "localhost:0", "confirm": true], in: odd), "409 failed", id)
            XCTAssertEqual(
                status(.renameSession, ["thread": "localhost:0", "name": "b"], in: odd), "409 failed", id)
            XCTAssertEqual(status(.newWindow, ["thread": "localhost:0"], in: odd), "409 failed", id)
            XCTAssertEqual(tmux.argv.count, before, id)
            XCTAssertEqual(status(.zoomPane, ["thread": "localhost:0"], in: odd), "200 ok", id)
        }
    }

    func testADirectoryGoesToTmuxInTheTreesOwnBytes() {
        let composed = "/Users/me/caf\u{E9}", decomposed = "/Users/me/cafe\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let snapshot = tree([("cafe", "%7", composed)])
        XCTAssertEqual(status(.newSession, ["host": "localhost", "dir": decomposed], in: snapshot), "200 ok")
        let sent = try! XCTUnwrap(tmux.argv.last?.last)
        XCTAssertEqual(Array(sent.utf8), Array(composed.utf8))
    }

    func testASemicolonIsFoundByItsByte() {
        // U+0600 joins the `;` after it into one character: the string no
        // longer "ends with ;" for Swift, and its last byte is still `;`.
        let joined = "x\u{0600};"
        XCTAssertFalse(joined.hasSuffix(";"))
        XCTAssertTrue(MobileActions.endsInSemicolon(joined))
        XCTAssertTrue(MobileActions.endsInSemicolon("x;"))
        // A mark after the `;` makes another byte the last one.
        XCTAssertFalse(MobileActions.endsInSemicolon("x;\u{301}"))
        XCTAssertFalse(MobileActions.endsInSemicolon(""))

        let snapshot = tree([(joined, "%7", "/Users/me/x"), ("ok", "%8", "/Users/me/d\u{0600};")])
        XCTAssertEqual(status(.killSession, ["thread": "localhost:7", "confirm": true], in: snapshot), "404 not_found")
        XCTAssertEqual(status(.newWindow, ["thread": "localhost:7"], in: snapshot), "404 not_found")
        XCTAssertEqual(tmux.argv.count, 0)
        XCTAssertEqual(MobileActions.dirs(host: "localhost", snapshot: snapshot), ["/Users/me/x"])
        XCTAssertNil(MobileActions.name(joined))
    }

    func testTheTreesOwnNameIsUsedWhenThePhoneSendsAnEqualOne() {
        // The same name in two encodings: equal as strings, different bytes.
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let snapshot = tree([(composed, "%7", "/Users/me/cafe"), ("keep", "%8", "/Users/me/keep")])

        XCTAssertEqual(
            status(.newWindow, ["host": "localhost", "session": decomposed], in: snapshot), "200 ok")
        XCTAssertEqual(
            status(.renameSession, ["host": "localhost", "session": decomposed, "name": "bar"], in: snapshot),
            "200 ok")
        // The target is the tree's id: no name at all.
        XCTAssertEqual(tmux.argv.count, 2)
        XCTAssertEqual(tmux.argv[0][3], "$7:")
        XCTAssertEqual(tmux.argv[1], ["rename-session", "-t", "$7", "bar"])
        // A name that equals a taken one is taken, in either encoding.
        XCTAssertEqual(
            status(.renameSession, ["host": "localhost", "session": "keep", "name": decomposed], in: snapshot),
            "409 exists")
        XCTAssertEqual(tmux.argv.count, 2)
    }

    func testANameIsCappedInBytesAndTakesNoOtherSpace() {
        // 64 characters, each many bytes long.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(String(repeating: family, count: 64).count, 64)
        XCTAssertNil(MobileActions.name(String(repeating: family, count: 64)))
        XCTAssertNil(MobileActions.name(String(repeating: "é", count: 65)))
        XCTAssertNotNil(MobileActions.name(String(repeating: "é", count: 64)))
        XCTAssertNil(MobileActions.name(String(repeating: "日", count: 43)))
        XCTAssertNotNil(MobileActions.name(String(repeating: "日", count: 42)))
        XCTAssertEqual(String(repeating: "日", count: 42).utf8.count, 126)
        XCTAssertLessThanOrEqual(MobileActions.maxNameBytes, 128)
        for space in ["a\u{A0}b", "a\u{3000}b", "a\u{2003}b", "a\u{202F}b", "a\u{1680}b"] {
            XCTAssertNil(MobileActions.name(space), space.debugDescription)
        }
        XCTAssertNotNil(MobileActions.name("a b"))
    }

    func testADirectoryThatTmuxWouldExpandOrSplitIsNotUsed() {
        let snapshot = tree([
            ("fmt", "%7", "/Users/me/#{session_name}"), ("hash", "%8", "/Users/me/c#"),
            ("semi", "%9", "/Users/me/x;"), ("plain", "%10", "/Users/me/plain"),
        ])
        XCTAssertEqual(MobileActions.dirs(host: "localhost", snapshot: snapshot), ["/Users/me/plain"])
        for dir in ["/Users/me/#{session_name}", "/Users/me/c#", "/Users/me/x;"] {
            XCTAssertEqual(
                status(.newSession, ["host": "localhost", "dir": dir], in: snapshot), "400 bad_dir", dir)
        }
        XCTAssertEqual(tmux.argv.count, 0)
        // A new window in such a directory starts without `-c`.
        XCTAssertEqual(status(.newWindow, ["thread": "localhost:7"], in: snapshot), "200 ok")
        XCTAssertEqual(tmux.argv, [["new-window", "-a", "-t", "$7:", "-P", "-F", "#{window_index}\t#{pane_id}"]])
        // A home directory that cannot be an argument is left out too.
        let odd = MobileActions.perform(
            .newSession, body: Data(#"{"host":"localhost"}"#.utf8), snapshot: snapshot,
            home: "/Users/#{x}", tmux: tmux.source)
        XCTAssertEqual(odd.status, 200)
        XCTAssertEqual(tmux.argv.last, ["new-session", "-d", "-s", "session"])
    }

    func testARemoteHostsActionsRunOnThatHostByPaneId() {
        let snapshot = tree([("infra", "%3", "/home/me/infra")], host: devbox)
        tmux.output = "2\t%9\n"
        XCTAssertEqual(status(.newWindow, ["host": "devbox", "session": "infra"], in: snapshot), "200 ok")
        XCTAssertEqual(status(.renameWindow, ["thread": "devbox:3", "name": "deploy"], in: snapshot), "200 ok")
        XCTAssertEqual(status(.killSession, ["thread": "devbox:3", "confirm": true], in: snapshot), "200 ok")
        XCTAssertEqual(status(.newSession, ["host": "devbox"], in: snapshot), "200 ok")
        XCTAssertEqual(tmux.calls.map(\.host), ["devbox", "devbox", "devbox", "devbox"])
        XCTAssertEqual(tmux.argv, [
            ["new-window", "-a", "-t", "$3:", "-P", "-F", "#{window_index}\t#{pane_id}", "-c", "/home/me/infra"],
            ["rename-window", "-t", "%3", "--", "deploy"],
            ["kill-session", "-t", "$3"],
            ["new-session", "-d", "-s", "session", "-c", "~"],
        ])
        // A thread of another host with the same pane number is not this one.
        XCTAssertEqual(status(.killPane, ["thread": "localhost:3", "confirm": true], in: snapshot), "404 not_found")
    }

    // MARK: spin up on a host

    private let format = "#{window_index}\t#{pane_id}"

    /// `perform` with a home for the remote host, as its `resolveHome` gives.
    private func spin(
        _ action: MobileAction, _ fields: [String: Any], remoteHome: String? = "/home/me"
    ) -> (status: Int, body: [String: Any]) {
        let response = MobileActions.perform(
            action, body: try! JSONSerialization.data(withJSONObject: fields), snapshot: snapshot(),
            home: "/Users/me", tmux: tmux.source, hostHome: { _ in remoteHome })
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return (response.status, body ?? [:])
    }

    private func refusal(_ action: MobileAction, _ fields: [String: Any], remoteHome: String? = "/home/me") -> String {
        let result = spin(action, fields, remoteHome: remoteHome)
        return "\(result.status) \(result.body["error"] as? String ?? "ok")"
    }

    /// What a POSIX shell makes of `script`: the arguments `claude` gets, when
    /// the script calls it. nil when the shell did not exit 0.
    private func claudeArguments(of script: String, shell: String = "/bin/sh") -> [String]? {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        // The script is read from a file, as typed lines are: not from `-c`.
        process.arguments = ["-c", "claude() { for a in \"$@\"; do printf '%s\\0' \"$a\"; done; }\n" + script]
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func testANewSessionStartsAnAgentWithItsPromptInADirectoryOfTheHomeTree() {
        tmux.output = "1\t%41\n"
        let local = spin(.newSession, [
            "host": "localhost", "dir": "/Users/me/code/acme-app", "agent": "claude", "prompt": "fix the login test",
        ])
        XCTAssertEqual(local.status, 200)
        XCTAssertEqual(local.body["session"] as? String, "acme-app-2")
        XCTAssertEqual(local.body["thread"] as? String, "localhost:41")
        XCTAssertEqual(local.body["agent"] as? String, "claude")
        let remote = spin(.newSession, [
            "host": "devbox", "dir": "/home/me/code/acme app", "agent": "codex", "prompt": "it's broken",
        ])
        XCTAssertEqual(remote.status, 200)
        XCTAssertEqual(remote.body["thread"] as? String, "devbox:41")
        XCTAssertEqual(remote.body["agent"] as? String, "codex")
        // An agent and no prompt: the bare command.
        XCTAssertEqual(spin(.newSession, ["host": "devbox", "agent": "claude", "prompt": "  \n"]).status, 200)
        // No agent: a shell, and tmux is not asked for the pane.
        let shell = spin(.newSession, ["host": "devbox", "dir": "/home/me"])
        XCTAssertNil(shell.body["thread"])
        XCTAssertNil(shell.body["agent"])

        XCTAssertEqual(tmux.argv, [
            ["new-session", "-d", "-s", "acme-app-2", "-P", "-F", format, "-c", "/Users/me/code/acme-app"],
            ["send-keys", "-t", "%41", "claude 'fix the login test'", "Enter"],
            ["new-session", "-d", "-s", "acme app", "-P", "-F", format, "-c", "/home/me/code/acme app"],
            ["send-keys", "-t", "%41", #"codex 'it'\''s broken'"#, "Enter"],
            ["new-session", "-d", "-s", "session", "-P", "-F", format, "-c", "~"],
            ["send-keys", "-t", "%41", "claude", "Enter"],
            ["new-session", "-d", "-s", "me", "-c", "/home/me"],
        ])
        XCTAssertEqual(tmux.calls.map(\.host), [
            "localhost", "localhost", "devbox", "devbox", "devbox", "devbox", "devbox",
        ])
        // The answer names the thread and the agent: the phone opens its chat.
        let answer = MobileActions.perform(
            .newSession, body: Data(#"{"host":"localhost","agent":"claude","prompt":"hi"}"#.utf8),
            snapshot: snapshot(), home: "/Users/me", tmux: tmux.source)
        XCTAssertEqual(MobileActions.startedThread(answer), "localhost:41")
    }

    func testANewWindowTakesAPromptToo() {
        tmux.output = "3\t%41\n"
        XCTAssertEqual(
            spin(.newWindow, ["thread": "localhost:13", "agent": "claude", "prompt": "run the tests"]).status, 200)
        XCTAssertEqual(tmux.argv.last, ["send-keys", "-t", "%41", "claude 'run the tests'", "Enter"])
        XCTAssertEqual(refusal(.newWindow, ["thread": "localhost:13", "prompt": "run the tests"]), "400 bad_prompt")
    }

    func testASessionWhosePaneTmuxDidNotNameIsStillMade() {
        tmux.output = ""
        let made = spin(.newSession, ["host": "localhost", "agent": "claude", "prompt": "hi"])
        XCTAssertEqual(made.status, 200)
        XCTAssertEqual(made.body["session"] as? String, "session")
        XCTAssertNil(made.body["agent"])
        XCTAssertEqual(tmux.argv.count, 1)
    }

    /// Prompts a shell would run, were one of them ever read as a command.
    private static let hostile = [
        "$(touch /tmp/mm-pwned)", "`touch /tmp/mm-pwned`", "a; touch /tmp/mm-pwned", "a && b || c | d > /tmp/mm-pwned",
        "it's", "'; touch /tmp/mm-pwned; '", "''''", #"say "hi" to $USER and ${HOME}"#, "line one\nline two\n\n$(id)",
        #"back\slash \' \\ end\"#, #"\"#, #"'\''"#, "!! !$ !-1", "* ? [a-z] {a,b} ~ # comment", "caf\u{E9} 日本語 🌱",
        "a\u{2028}b", "x = 1 < 2 & y",
    ]

    func testAPromptIsOneQuotedWordWhateverItHolds() throws {
        XCTAssertEqual(MobileActions.shellWord("it's"), #"'it'\''s'"#)
        // A backslash is never inside the quotes: fish reads one there.
        XCTAssertEqual(MobileActions.shellWord(#"a\b"#), #"'a'\\'b'"#)
        XCTAssertEqual(MobileActions.shellWord(""), "''")
        for prompt in Self.hostile {
            let word = MobileActions.shellWord(prompt)
            for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
                XCTAssertEqual(
                    claudeArguments(of: "claude \(word)", shell: shell), [prompt], "\(shell) \(prompt.debugDescription)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/mm-pwned"))
    }

    func testAPromptStaysOneArgumentHereAndThroughSsh() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A stand-in for the remote tmux: it prints the arguments it got.
        let echo = folder.appendingPathComponent("argv").path
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done\n".write(
            toFile: echo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: echo)

        for prompt in Self.hostile {
            tmux.output = "1\t%41\n"
            let fields: [String: Any] = [
                "host": "devbox", "dir": "/home/me/code/it's $(here) `x`", "agent": "claude", "prompt": prompt,
            ]
            XCTAssertEqual(spin(.newSession, fields).status, 200, prompt.debugDescription)
            let (create, start) = (tmux.argv[tmux.argv.count - 2], tmux.argv[tmux.argv.count - 1])
            XCTAssertEqual(create.last, "/home/me/code/it's $(here) `x`")
            XCTAssertEqual(start.count, 5)
            // The pane's shell gives the agent the prompt as one argument.
            XCTAssertEqual(claudeArguments(of: start[3]), [prompt], prompt.debugDescription)

            // Over ssh: the remote login shell reads the joined words again,
            // and tmux still gets each argument as it was.
            for argv in [create, start] {
                let transport = SshTmuxTransport(host: "devbox", remoteTmux: echo, moshPath: nil)
                let sent = try XCTUnwrap(transport.command(forTmux: argv)).args
                let remote = sent.suffix(argv.count + 1).joined(separator: " ")
                let process = Process(), out = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", remote]
                process.standardOutput = out
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let got = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
                    .map { String(decoding: $0, as: UTF8.self) }
                XCTAssertEqual(got, argv, prompt.debugDescription)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/mm-pwned"))
    }

    func testAPromptIsTextOfALengthTheNewPaneCanTake() {
        tmux.output = "1\t%41\n"
        let ask = { (prompt: Any) -> [String: Any] in ["host": "localhost", "agent": "claude", "prompt": prompt] }
        for bad in ["a\u{1B}[2Jb", "a\u{03}", "a\u{7F}", "a\u{0}b", "a\u{9B}b", "a\rb", "a\u{8}"] {
            XCTAssertEqual(refusal(.newSession, ask(bad)), "400 bad_prompt", bad.debugDescription)
        }
        // Not text at all, and a word the agent would read as an option.
        for bad in [7, true, ["a"], ["a": "b"]] as [Any] {
            XCTAssertEqual(refusal(.newSession, ask(bad)), "400 bad_prompt", "\(bad)")
        }
        XCTAssertEqual(refusal(.newSession, ask("--dangerously-skip-permissions")), "400 bad_prompt")
        XCTAssertEqual(refusal(.newSession, ask("  -p hi")), "400 bad_prompt")
        // A prompt needs an agent to read it.
        XCTAssertEqual(refusal(.newSession, ["host": "localhost", "prompt": "hi"]), "400 bad_prompt")
        XCTAssertEqual(tmux.argv.count, 0)

        // The cap is on the typed word: a new pane's terminal holds 1024
        // bytes before its shell reads, and drops the rest.
        XCTAssertLessThanOrEqual("codex ".utf8.count + MobileActions.maxPromptBytes + 1, 1000)
        let fits = String(repeating: "a", count: MobileActions.maxPromptBytes - 2)
        XCTAssertEqual(refusal(.newSession, ask(fits)), "200 ok")
        XCTAssertEqual(refusal(.newSession, ask(fits + "a")), "413 too_large")
        // A quote is four bytes once it is quoted.
        XCTAssertEqual(refusal(.newSession, ask(String(repeating: "'", count: 300))), "413 too_large")
        XCTAssertEqual(tmux.argv.count, 2)

        // A tab would ask the shell to complete a word: it is typed as a
        // space. A Windows line end is a line end.
        XCTAssertEqual(refusal(.newSession, ask("a\tb\r\nc")), "200 ok")
        XCTAssertEqual(tmux.argv.last?[3], "claude 'a b\nc'")
        XCTAssertEqual(refusal(.newSession, ask(NSNull())), "200 ok")
        XCTAssertEqual(tmux.argv.last?[3], "claude")
    }

    func testANewSessionRefusesAnAgentItDoesNotKnow() {
        for bad in ["vim", "Claude", "claude; date", "claude --help", "", 1, true, ["claude"]] as [Any] {
            XCTAssertEqual(refusal(.newSession, ["host": "localhost", "agent": bad]), "400 bad_agent", "\(bad)")
        }
        XCTAssertTrue(tmux.argv.isEmpty)
    }

    func testADirectoryIsInTheHostsHomeTree() {
        let home = "/home/me"
        XCTAssertEqual(MobileActions.inHome("/home/me", home: home), "/home/me")
        XCTAssertEqual(MobileActions.inHome("/home/me/", home: home), "/home/me")
        XCTAssertEqual(MobileActions.inHome("/home/me/code//acme-app/", home: home), "/home/me/code/acme-app")
        XCTAssertEqual(MobileActions.inHome("/home/me/it's $(x) `y` & z", home: home), "/home/me/it's $(x) `y` & z")
        XCTAssertEqual(MobileActions.inHome("/home/me/code", home: "/home/me/"), "/home/me/code")
        for bad in [
            "/", "/home", "/etc", "/home/me2", "/home/me2/code", "/home/other/code", "code", "~", "~/code", "",
            "/home/me/..", "/home/me/../other", "/home/me/code/../../other", "/home/me/code/..", "/home/me/./code",
            "/home/me/.ssh", "/home/me/code/.git", "/home/me/code/.git/hooks", "/home/me/a\nb", "/home/me/a#b",
            "/home/me/x;", "/home/me/a\u{1B}b", "/home/me/\u{0}",
        ] {
            XCTAssertNil(MobileActions.inHome(bad, home: home), bad.debugDescription)
        }
        // The same name in other bytes is another directory on the host.
        XCTAssertNil(MobileActions.inHome("/home/cafe\u{301}/code", home: "/home/caf\u{E9}"))
        // No home, or the whole disk as one: nothing is inside it.
        for home in ["", "/", "home/me", "/home/me#"] {
            XCTAssertNil(MobileActions.inHome("/home/me/code", home: home), home)
        }
    }

    func testANewSessionStartsNowhereOutsideTheHomeTree() {
        for dir in ["/etc", "/Users/other/code", "/Users/me/..", "/Users/me/code/../../other", "/Users/me/.ssh", "~/code"] {
            XCTAssertEqual(refusal(.newSession, ["host": "localhost", "dir": dir]), "400 bad_dir", dir)
        }
        for dir in ["/etc", "/Users/me/code", "/home/me/../other", "/home/me/.ssh", "/home/me2"] {
            XCTAssertEqual(refusal(.newSession, ["host": "devbox", "dir": dir]), "400 bad_dir", dir)
        }
        // A remote host that does not say where its home is offers its
        // threads' directories and no other.
        XCTAssertEqual(
            refusal(.newSession, ["host": "devbox", "dir": "/home/me/code"], remoteHome: nil), "400 bad_dir")
        XCTAssertEqual(tmux.argv.count, 0)
        XCTAssertEqual(
            refusal(.newSession, ["host": "devbox", "dir": "/home/me/infra"], remoteHome: nil), "200 ok")
        // A thread works outside the home tree: its directory is still offered.
        let outside = tree([("srv", "%7", "/srv/acme-app")])
        XCTAssertEqual(status(.newSession, ["host": "localhost", "dir": "/srv/acme-app"], in: outside), "200 ok")
    }

    // MARK: the directory list

    /// A remote host's shell, scripted: it records each command.
    private final class FakeShell {
        var home: String? = "/home/me"
        var output: String?
        private(set) var argv: [[String]] = []

        var source: (Host) -> MobileActions.HostShell? {
            { [self] host in
                host.isLocal ? nil : MobileActions.HostShell(
                    home: { [self] in home },
                    run: { [self] in
                        argv.append($0)
                        return output
                    })
            }
        }
    }

    private func browse(
        _ host: String, _ path: String?, home: String = "/Users/me", shell: FakeShell = FakeShell()
    ) -> (status: Int, body: [String: Any]) {
        let response = MobileActions.browse(
            host: host, path: path, snapshot: snapshot(), home: home, shell: shell.source)
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return (response.status, body ?? [:])
    }

    func testWithNoPathTheListIsWhereThreadsWorkAndTheHome() {
        let local = browse("localhost", nil)
        XCTAssertEqual(local.status, 200)
        XCTAssertEqual(
            local.body["dirs"] as? [String], ["/Users/me/acme-app", "/Users/me/acme-app/web", "/Users/me/billing"])
        XCTAssertEqual(local.body["home"] as? String, "/Users/me")
        let shell = FakeShell()
        let remote = browse("devbox", nil, shell: shell)
        XCTAssertEqual(remote.body["dirs"] as? [String], ["/home/me/infra"])
        XCTAssertEqual(remote.body["home"] as? String, "/home/me")
        // Nothing is run for it.
        XCTAssertTrue(shell.argv.isEmpty)
        // A host that does not say where its home is still has its list.
        shell.home = nil
        let lost = browse("devbox", nil, shell: shell)
        XCTAssertEqual(lost.status, 200)
        XCTAssertEqual(lost.body["dirs"] as? [String], ["/home/me/infra"])
        XCTAssertNil(lost.body["home"])
        XCTAssertEqual(browse("buildbox", nil).status, 404)
        XCTAssertEqual(browse("buildbox", "/home/me").status, 404)
    }

    func testARemoteListIsOneCommandWithThePathAsItsOwnWord() {
        let shell = FakeShell()
        shell.output = "/home/me\n/home/me/code\nacme-app/\nnotes.txt\nbilling/\n.cache/\nit's $(x)/\nlink@\nc#/\nweb\n"
        let listed = browse("devbox", "/home/me/code/", shell: shell)
        XCTAssertEqual(listed.status, 200)
        XCTAssertEqual(listed.body["path"] as? String, "/home/me/code")
        XCTAssertEqual(listed.body["parent"] as? String, "/home/me")
        XCTAssertEqual(listed.body["home"] as? String, "/home/me")
        // Directories only, no dot-directory, and none tmux could not take.
        XCTAssertEqual(listed.body["dirs"] as? [String], [
            "/home/me/code/acme-app", "/home/me/code/billing", "/home/me/code/it's $(x)",
        ])
        // The script is fixed. The path is the word after `--`: `$1`.
        XCTAssertEqual(shell.argv, [["sh", "-c", MobileActions.listScript, "--", "/home/me/code"]])
        XCTAssertFalse(MobileActions.listScript.contains("/home"))

        let hostile = "/home/me/$(touch /tmp/mm-pwned); `id` 'x' \"y\""
        _ = browse("devbox", hostile, shell: shell)
        XCTAssertEqual(shell.argv.last, ["sh", "-c", MobileActions.listScript, "--", hostile])

        // The home has no parent to go up to.
        shell.output = "/home/me\n/home/me\ncode/\n"
        let top = browse("devbox", "/home/me", shell: shell)
        XCTAssertEqual(top.body["dirs"] as? [String], ["/home/me/code"])
        XCTAssertNil(top.body["parent"])
    }

    func testARemoteListRefusesWhatIsNotInTheHomeTree() {
        let shell = FakeShell()
        shell.output = "/home/me\n/home/me/code\nacme-app/\n"
        for bad in ["/etc", "/home/other", "/home/me/..", "/home/me/code/../..", "/home/me/.ssh", "code", "", "~"] {
            let refused = browse("devbox", bad, shell: shell)
            XCTAssertEqual(refused.status, 400, bad)
            XCTAssertEqual(refused.body["error"] as? String, "bad_dir", bad)
        }
        XCTAssertTrue(shell.argv.isEmpty)
        // A link in the home tree that leaves it: the host says where the
        // directory really is, and that is not listed.
        shell.output = "/home/me\n/etc\nssh/\nssl/\n"
        XCTAssertEqual(browse("devbox", "/home/me/link", shell: shell).body["error"] as? String, "bad_dir")
        shell.output = "/home/me\n/home/me2\ncode/\n"
        XCTAssertEqual(browse("devbox", "/home/me/link", shell: shell).status, 400)
        // The command failed: no such directory, or no way to the host.
        shell.output = nil
        XCTAssertEqual(browse("devbox", "/home/me/gone", shell: shell).status, 404)
        shell.output = "/home/me\n"
        XCTAssertEqual(browse("devbox", "/home/me/code", shell: shell).status, 404)
        // No home is known: nothing is browsed.
        shell.home = nil
        let before = shell.argv.count
        XCTAssertEqual(browse("devbox", "/home/me/code", shell: shell).status, 503)
        XCTAssertEqual(shell.argv.count, before)
    }

    func testAListIsCapped() {
        let shell = FakeShell()
        let names = (0..<(MobileActions.maxListedDirs + 50)).map { String(format: "d%04d/", $0) }
        shell.output = "/home/me\n/home/me\n" + names.joined(separator: "\n") + "\n"
        let dirs = browse("devbox", "/home/me", shell: shell).body["dirs"] as? [String]
        XCTAssertEqual(dirs?.count, MobileActions.maxListedDirs)
        XCTAssertEqual(dirs?.first, "/home/me/d0000")
    }

    func testTheListScriptPrintsTheHomeThenTheDirectoryThenItsEntries() throws {
        // The script itself, run here by `sh` with a home of its own.
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try files.createDirectory(at: home.appendingPathComponent("code/acme-app"), withIntermediateDirectories: true)
        try files.createDirectory(at: home.appendingPathComponent("code/.git"), withIntermediateDirectories: true)
        try files.createDirectory(at: home.appendingPathComponent("code/-rf"), withIntermediateDirectories: true)
        try "x".write(to: home.appendingPathComponent("code/notes.txt"), atomically: true, encoding: .utf8)
        try files.createSymbolicLink(atPath: home.appendingPathComponent("code/etc").path, withDestinationPath: "/etc")
        defer { try? files.removeItem(at: home) }

        let run = { (path: String) -> String? in
            let process = Process(), out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = MobileActions.listArgv(path)
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = out
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }
        let code = home.appendingPathComponent("code").path
        let printed = try XCTUnwrap(run(code))
        XCTAssertEqual(
            MobileActions.parseListing(printed, dir: code), [code + "/-rf", code + "/acme-app"])
        // A path that starts with a dash is a path, and a link out of the
        // home tree is seen where it really is.
        XCTAssertEqual(MobileActions.parseListing(try XCTUnwrap(run(code + "/-rf")), dir: code + "/-rf"), [])
        let linked = try XCTUnwrap(run(code + "/etc"))
        XCTAssertNil(MobileActions.parseListing(linked, dir: code + "/etc"))
        XCTAssertNil(run(code + "/gone"))
    }

    func testALocalListIsReadFromTheDiskAndStaysInTheHomeTree() throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)")
        try files.createDirectory(at: home.appendingPathComponent("code/acme-app"), withIntermediateDirectories: true)
        try files.createDirectory(at: home.appendingPathComponent("code/billing"), withIntermediateDirectories: true)
        try files.createDirectory(at: home.appendingPathComponent("code/.git"), withIntermediateDirectories: true)
        try "x".write(to: home.appendingPathComponent("code/notes.txt"), atomically: true, encoding: .utf8)
        try files.createSymbolicLink(atPath: home.appendingPathComponent("code/etc").path, withDestinationPath: "/etc")
        defer { try? files.removeItem(at: home) }

        let shell = FakeShell()
        let code = home.path + "/code"
        let listed = browse("localhost", code, home: home.path, shell: shell)
        XCTAssertEqual(listed.status, 200)
        XCTAssertEqual(listed.body["path"] as? String, code)
        XCTAssertEqual(listed.body["parent"] as? String, home.path)
        // No file, no dot-directory, and no link: it may leave the home tree.
        XCTAssertEqual(listed.body["dirs"] as? [String], [code + "/acme-app", code + "/billing"])
        XCTAssertEqual(browse("localhost", home.path, home: home.path).body["dirs"] as? [String], [code])
        XCTAssertNil(browse("localhost", home.path, home: home.path).body["parent"])

        XCTAssertEqual(browse("localhost", code + "/etc", home: home.path).body["error"] as? String, "bad_dir")
        XCTAssertEqual(browse("localhost", "/etc", home: home.path).body["error"] as? String, "bad_dir")
        XCTAssertEqual(browse("localhost", code + "/..", home: home.path).body["error"] as? String, "bad_dir")
        XCTAssertEqual(browse("localhost", code + "/.git", home: home.path).body["error"] as? String, "bad_dir")
        XCTAssertEqual(browse("localhost", code + "/gone", home: home.path).status, 404)
        XCTAssertEqual(browse("localhost", code + "/notes.txt", home: home.path).status, 404)
        // This Mac's list runs no command.
        XCTAssertTrue(shell.argv.isEmpty)
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
        // A pane that went since the tree was read is a 404.
        tmux.failing = true
        tmux.failure = "can't find pane: %12"
        XCTAssertEqual(MobileFind.search(thread: thread(), query: "tax", tmux: tmux.source(.local)).status, 404)
        tmux.failure = "ssh: connect to host devbox port 22: Operation timed out"
        XCTAssertEqual(MobileFind.search(thread: thread(), query: "tax", tmux: tmux.source(.local)).status, 503)
    }
}
