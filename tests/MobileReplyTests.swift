import XCTest

/// A thread's pane, scripted: it records every tmux call and every copy, and
/// types nothing anywhere. Shared by the server tests.
final class FakePane {
    private let lock = NSLock()
    private var _calls: [(args: [String], stdin: String?)] = []
    private var _copies: [(name: String, data: Data, path: String)] = []
    private var _status: AttentionStatus?
    private var _statusAfterPaste: AttentionStatus?
    private var _screen: String?
    private var _existing = Set<String>()
    private var _failing = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: [(args: [String], stdin: String?)] { locked { _calls } }
    var argv: [[String]] { calls.map(\.args) }
    var copies: [(name: String, data: Data, path: String)] { locked { _copies } }
    /// The pane's own status; nil for the tree's.
    var status: AttentionStatus? {
        get { locked { _status } }
        set { locked { _status = newValue } }
    }
    /// What the status turns into once text is in the input box.
    var statusAfterPaste: AttentionStatus? {
        get { locked { _statusAfterPaste } }
        set { locked { _statusAfterPaste = newValue } }
    }
    var screen: String? {
        get { locked { _screen } }
        set { locked { _screen = newValue } }
    }
    var existing: Set<String> {
        get { locked { _existing } }
        set { locked { _existing = newValue } }
    }
    /// tmux and copies fail.
    var failing: Bool {
        get { locked { _failing } }
        set { locked { _failing = newValue } }
    }

    var io: MobilePaneIO {
        MobilePaneIO(
            tmux: { [self] args, stdin in
                locked {
                    guard !_failing else { return nil }
                    _calls.append((args, stdin.map { String(decoding: $0, as: UTF8.self) }))
                    if args.first == "paste-buffer", let after = _statusAfterPaste { _status = after }
                    return ""
                }
            },
            screen: { [self] in screen },
            status: { [self] thread in status ?? thread.status },
            copy: { [self] local, path in
                locked {
                    guard !_failing, let data = FileManager.default.contents(atPath: local) else { return false }
                    _copies.append(((local as NSString).lastPathComponent, data, path))
                    return true
                }
            },
            exists: { [self] path in existing.contains(path) })
    }

    /// The four calls of one sent text, with the buffer's name left out.
    static func sendArgv(_ argv: [[String]], target: String) -> Bool {
        guard argv.count == 4, argv[1].count == 4, argv[2].count == 8 else { return false }
        let buffer = argv[1][2]
        return argv[0] == ["copy-mode", "-q", "-t", target]
            && buffer.hasPrefix("sidekick-phone-")
            && argv[1] == ["load-buffer", "-b", buffer, "-"]
            && argv[2] == ["paste-buffer", "-p", "-r", "-d", "-b", buffer, "-t", target]
            && argv[3] == ["send-keys", "-t", target, "Enter"]
    }
}

enum DemoPrompt {
    static let permission = """
        ⏺ Bash(kubectl rollout restart deploy/web -n staging)

        ╭──────────────────────────────────────────────────────────────╮
        │ Bash command                                                 │
        │                                                              │
        │   kubectl rollout restart deploy/web -n staging              │
        │   Restart the web deployment                                 │
        │                                                              │
        │ Do you want to proceed?                                      │
        │ ❯ 1. Yes                                                     │
        │   2. Yes, and don't ask again for kubectl commands           │
        │   3. No, and tell Claude what to do differently (esc)        │
        ╰──────────────────────────────────────────────────────────────╯
        """

    static let question = """
        ────────────────────────────────────────
         ☐ Storage

        Which store should the cache use?

        ❯ 1. Redis
             Shared between instances
          2. In memory
             Lost on restart
          3. Type something.
        ────────────────────────────────────────
        """
}

final class MobileReplyTests: XCTestCase {
    private func thread(
        status: AttentionStatus = .idle, host: Host = .local, cwd: String = "/Users/me/acme-app",
        claude: String? = "c1", codex: String? = nil
    ) -> MobileThread {
        MobileThread(
            id: "\(host.name):12", host: host, hostColor: "#3291ff", session: "acme-app", window: 1,
            name: "deploy-fix", pane: "%12", command: "claude", cwd: cwd, status: status, since: nil,
            idleStage: .awake, lastPrompt: nil, lastActivityAt: nil, sessionActivity: 0,
            claudeSessionId: claude, codexSessionId: codex)
    }

    // MARK: routes

    func testEveryReplyRouteHasItsOwnSwitch() {
        let id = "localhost%3A12"
        let routes: [(String, String, MobileEndpoint, MobileCapability)] = [
            ("POST", "text", .text(id: "localhost:12"), .replies),
            ("GET", "prompt", .prompt(id: "localhost:12"), .replies),
            ("POST", "answer", .answer(id: "localhost:12"), .replies),
            ("GET", "commands", .commands(id: "localhost:12"), .replies),
            ("POST", "key", .key(id: "localhost:12"), .keyBar),
            ("POST", "upload", .upload(id: "localhost:12", name: ""), .upload),
        ]
        for (method, name, endpoint, capability) in routes {
            let request = MobileRequest(method: method, path: "/api/threads/\(id)/\(name)")
            XCTAssertEqual(endpoint.capability, capability, name)
            // Off by default, and off while every other switch is on.
            XCTAssertEqual(MobileAPI.route(request), .disabled(capability), name)
            let others = Set(MobileCapability.allCases).subtracting([capability])
            XCTAssertEqual(
                MobileAPI.route(request, config: MobileConfig(capabilities: others)),
                .disabled(capability), name)
            let on = MobileConfig(capabilities: [capability])
            XCTAssertEqual(MobileAPI.route(request, config: on), .api(endpoint), name)
            // A write is a POST and a read is a GET, never the other.
            let other = MobileRequest(
                method: method == "GET" ? "POST" : "GET", path: "/api/threads/\(id)/\(name)")
            XCTAssertEqual(MobileAPI.route(other, config: on), .methodNotAllowed, name)
        }
        XCTAssertFalse(MobileConfig().allows(.replies))
        XCTAssertFalse(MobileConfig().allows(.keyBar))
        XCTAssertFalse(MobileConfig().allows(.upload))
    }

    func testAnUploadReadsItsNameFromTheQueryAndMayCarryAFile() {
        var request = MobileRequest(method: "POST", path: "/api/threads/localhost%3A12/upload")
        request.query = ["name": "photo 1.png"]
        XCTAssertEqual(
            MobileAPI.route(request, config: MobileConfig(capabilities: [.upload])),
            .api(.upload(id: "localhost:12", name: "photo 1.png")))

        let upload = "/api/threads/localhost%3A12/upload"
        XCTAssertEqual(MobileHTTP.bodyLimit(method: "POST", path: upload), MobileReply.maxUploadBytes)
        // Only that path, and only as a POST.
        XCTAssertEqual(MobileHTTP.bodyLimit(method: "GET", path: upload), MobileHTTP.maxBodyBytes)
        for path in ["/api/threads/localhost%3A12/text", "/api/threads/upload", "/api/x/y/upload",
                     "/api/threads/a/upload/b"] {
            XCTAssertEqual(MobileHTTP.bodyLimit(method: "POST", path: path), MobileHTTP.maxBodyBytes, path)
        }
    }

    func testConfigCarriesTheUploadLimit() throws {
        let suite = "mobile-reply-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Settings.phoneUploadLimit(defaults: defaults), MobileReply.defaultUploadLimit)
        XCTAssertEqual(Settings.phoneConfig(defaults: defaults).capabilities, [])
        Settings.setPhoneUploadLimit(5_242_880, defaults: defaults)
        Settings.setPhoneCapability(.keyBar, true, defaults: defaults)
        let config = Settings.phoneConfig(defaults: defaults)
        XCTAssertEqual(config.uploadLimit, 5_242_880)
        XCTAssertEqual(config.capabilities, [.keyBar])
        // A stored value that is not one of the choices is not used.
        Settings.setPhoneUploadLimit(999_999_999, defaults: defaults)
        XCTAssertEqual(Settings.phoneUploadLimit(defaults: defaults), MobileReply.defaultUploadLimit)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: config.json()) as? [String: Any])
        XCTAssertEqual((json["upload"] as? [String: Any])?["maxBytes"] as? Int, 5_242_880)
        XCTAssertEqual((json["capabilities"] as? [String: Any])?["keyBar"] as? Bool, true)
        XCTAssertEqual((json["capabilities"] as? [String: Any])?["replies"] as? Bool, false)
    }

    // MARK: keys

    func testTheKeyWhitelistIsExactlyTheNamedKeys() {
        var expected: Set<String> = ["Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab"]
        for letter in "abcdefghijklmnopqrstuvwxyz" { expected.insert("C-\(letter)") }
        for digit in 1...9 { expected.insert("\(digit)") }
        XCTAssertEqual(MobileReply.keys, expected)
        XCTAssertEqual(MobileReply.keys.count, 43)

        XCTAssertEqual(MobileReply.key(in: Data(#"{"key":"Escape"}"#.utf8)), "Escape")
        XCTAssertEqual(MobileReply.key(in: Data(#"{"key":"C-c"}"#.utf8)), "C-c")
        for refused in [
            "F1", "0", "10", "q", "C-1", "C-C", "M-a", "C-M-a", "S-Tab", "enter", "Enter ", " Enter",
            "Enter; rm -rf /", "-t", "-X", "Space", "BSpace", "DC", "PageUp", "C-", "",
        ] {
            let body = try? JSONSerialization.data(withJSONObject: ["key": refused])
            XCTAssertNil(MobileReply.key(in: body ?? Data()), refused)
        }
        // Not a string, or no key at all.
        XCTAssertNil(MobileReply.key(in: Data(#"{"key":1}"#.utf8)))
        XCTAssertNil(MobileReply.key(in: Data(#"{"key":["Enter"]}"#.utf8)))
        XCTAssertNil(MobileReply.key(in: Data(#"{"keys":"Enter"}"#.utf8)))
        XCTAssertNil(MobileReply.key(in: Data("Enter".utf8)))
    }

    func testAKeyIsOneSendKeysCallAndNothingElse() {
        let pane = FakePane()
        XCTAssertEqual(MobileReply.press("BTab", target: "%12", io: pane.io).status, 200)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "BTab"]])
        // The whitelist is checked here too, not only where the body is read.
        XCTAssertEqual(MobileReply.press("F1", target: "%12", io: pane.io).status, 400)
        XCTAssertEqual(pane.argv.count, 1)
        pane.failing = true
        XCTAssertEqual(MobileReply.press("Enter", target: "%12", io: pane.io).status, 503)
    }

    // MARK: text

    func testTextGoesInAsOneBracketedPasteThenEnter() {
        let pane = FakePane()
        var pauses: [TimeInterval] = []
        let text = "first line\nsecond; $(rm -rf /) `x` && done"
        let response = MobileReply.send(
            text, target: "%12", io: pane.io, status: { .idle }, pause: { pauses.append($0) })
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%12"), "\(pane.argv)")
        // The text goes in over stdin: it is in no argv.
        XCTAssertEqual(pane.calls[1].stdin, text)
        XCTAssertFalse(pane.argv.joined().contains { $0.contains("rm -rf") })
        XCTAssertEqual(pauses, [MobileReply.enterDelay])
    }

    func testEachPasteUsesABufferOfItsOwn() {
        let pane = FakePane()
        _ = MobileReply.send("one", target: "%12", io: pane.io, status: { .idle }, pause: { _ in })
        _ = MobileReply.send("two", target: "%12", io: pane.io, status: { .idle }, pause: { _ in })
        XCTAssertNotEqual(pane.argv[1][2], pane.argv[5][2])
        // The default buffer of the Mac's own pastes is left alone.
        XCTAssertEqual(
            TmuxCommands.pastePrompt(session: "mux-manager").paste,
            ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "mux-manager"])
    }

    func testFreeTextIntoABusyOrWaitingPaneTypesNothing() {
        for (status, code) in [(AttentionStatus.busy, "busy"), (.waiting, "waiting")] {
            let pane = FakePane()
            let response = MobileReply.send(
                "go on", target: "%12", io: pane.io, status: { status }, pause: { _ in })
            XCTAssertEqual(response.status, 409)
            XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains(#""error":"\#(code)""#))
            XCTAssertEqual(pane.argv.count, 0, code)
        }
        // A thread that left the tree: nothing to type into.
        let pane = FakePane()
        XCTAssertEqual(
            MobileReply.send("go on", target: "%12", io: pane.io, status: { nil }, pause: { _ in }).status,
            404)
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testAPromptThatComesUpAfterThePasteGetsNoEnter() {
        for late in [AttentionStatus.waiting, .busy] {
            let pane = FakePane()
            pane.status = .idle
            pane.statusAfterPaste = late
            let response = MobileReply.send(
                "go on", target: "%12", io: pane.io, status: { pane.status }, pause: { _ in })
            XCTAssertEqual(response.status, 409)
            XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
            XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
        }
        // The thread went away between the paste and the Enter.
        let pane = FakePane()
        var asked = 0
        let gone = MobileReply.send(
            "go on", target: "%12", io: pane.io,
            status: { asked += 1; return asked == 1 ? .idle : nil }, pause: { _ in })
        XCTAssertEqual(gone.status, 404)
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
    }

    func testAPaneWithNoStatusIsReadForAPromptInstead() {
        // A shell: no hooks, nothing on screen that asks.
        let shell = FakePane()
        shell.screen = "$ make test\nok\n$ "
        XCTAssertEqual(
            MobileReply.send("ls", target: "%13", io: shell.io, status: { .unknown }, pause: { _ in }).status,
            200)

        // An agent without hooks that sits on a prompt.
        let asking = FakePane()
        asking.screen = DemoPrompt.permission
        let response = MobileReply.send(
            "go on", target: "%12", io: asking.io, status: { .unknown }, pause: { _ in })
        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(asking.argv.count, 0)

        // Our own numbered list in the input box is not a prompt.
        let list = "1. rename the flag\n2. update the docs"
        let echo = FakePane()
        XCTAssertNil(MobileReply.refusal(
            status: .unknown, screen: { "❯ 1. rename the flag\n  2. update the docs" }, pasted: list))
        XCTAssertNotNil(MobileReply.refusal(
            status: .unknown, screen: { DemoPrompt.permission }, pasted: list))
        XCTAssertEqual(echo.argv.count, 0)
        // A known status is trusted: the screen is not even read.
        XCTAssertNil(MobileReply.refusal(status: .idle, screen: { XCTFail("read"); return nil }))
    }

    func testAFailedPasteIsAnErrorAndSendsNoEnter() {
        let pane = FakePane()
        pane.failing = true
        let response = MobileReply.send("go on", target: "%12", io: pane.io, status: { .idle }, pause: { _ in })
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(pane.argv.count, 0)
    }

    // MARK: status

    func testTheHookRowIsNewerThanTheTree() {
        let now = 1_759_500_000
        func row(_ state: AgentStateRow.State, pane: String = "%12", session: String = "c1", age: Int = 1)
            -> AgentStateRow {
            AgentStateRow(
                sessionId: session, agent: "claude", state: state, reason: "", pane: pane,
                cwd: "/Users/me/acme-app", since: now - age, updatedAt: now - age)
        }
        // The tree still says idle; the hook reported a prompt a second ago.
        XCTAssertEqual(MobileReply.status(thread: thread(status: .idle), rows: [row(.waiting)], now: now), .waiting)
        XCTAssertEqual(MobileReply.status(thread: thread(status: .idle), rows: [row(.busy)], now: now), .busy)
        // No row, another pane's row, or another session's row in this pane: the tree's.
        XCTAssertEqual(MobileReply.status(thread: thread(status: .busy), rows: [], now: now), .busy)
        XCTAssertEqual(
            MobileReply.status(thread: thread(status: .idle), rows: [row(.waiting, pane: "%13")], now: now), .idle)
        XCTAssertEqual(
            MobileReply.status(thread: thread(status: .idle), rows: [row(.waiting, session: "old")], now: now),
            .idle)
        // A busy row the scan has long disagreed with is a missed Stop.
        XCTAssertEqual(
            MobileReply.status(thread: thread(status: .idle), rows: [row(.busy, age: 86_400)], now: now), .idle)
        // The hooks write this Mac's own state: never a remote pane's.
        let remote = thread(status: .idle, host: Host(name: "devbox", sshAlias: "devbox"))
        XCTAssertEqual(MobileReply.status(thread: remote, rows: [row(.waiting)], now: now), .idle)
    }

    // MARK: prompts

    func testReadsAPermissionPromptFromTheScreen() throws {
        let prompt = try XCTUnwrap(MobilePrompt.parse(screen: DemoPrompt.permission))
        XCTAssertEqual(prompt.kind, .permission)
        XCTAssertEqual(prompt.title, "Bash command")
        XCTAssertEqual(
            prompt.detail, "kubectl rollout restart deploy/web -n staging\nRestart the web deployment")
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.options, [
            .init(n: 1, label: "Yes"),
            .init(n: 2, label: "Yes, and don't ask again for kubectl commands"),
            .init(n: 3, label: "No, and tell Claude what to do differently"),
        ])
        XCTAssertEqual(prompt.json["id"] as? String, prompt.id)
        XCTAssertEqual((prompt.json["options"] as? [[String: Any]])?.count, 3)
    }

    func testReadsAQuestionWhoseOptionsCarryDescriptions() throws {
        let prompt = try XCTUnwrap(MobilePrompt.parse(screen: DemoPrompt.question))
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.question, "Which store should the cache use?")
        XCTAssertEqual(prompt.options.map(\.label), ["Redis", "In memory", "Type something."])
        XCTAssertEqual(prompt.options.map(\.n), [1, 2, 3])
    }

    func testTheCursorMayBeOnAnyChoice() throws {
        let moved = DemoPrompt.permission
            .replacingOccurrences(of: "❯ 1. Yes ", with: "  1. Yes ")
            .replacingOccurrences(of: "  3. No,", with: "❯ 3. No,")
        let prompt = try XCTUnwrap(MobilePrompt.parse(screen: moved))
        XCTAssertEqual(prompt.options.map(\.n), [1, 2, 3])
        // The same prompt, wherever the cursor is.
        XCTAssertEqual(prompt.id, MobilePrompt.parse(screen: DemoPrompt.permission)?.id)
    }

    func testAScreenWithoutALivePromptHasNone() {
        for screen in [
            "", "$ make test\nok\n",
            // A numbered list in a reply: no cursor on it.
            "Plan:\n  1. Rename the flag\n  2. Update the docs\n",
            // A cursor, but not on a list numbered from 1.
            "❯ 2. Second\n  3. Third\n",
            // One choice is not a choice.
            "❯ 1. Only\n",
            // The input box with one numbered line.
            "❯ 1. fix the login bug",
        ] {
            XCTAssertNil(MobilePrompt.parse(screen: screen), screen)
        }
    }

    func testAnotherPromptHasAnotherId() throws {
        let first = try XCTUnwrap(MobilePrompt.parse(screen: DemoPrompt.permission))
        let second = try XCTUnwrap(MobilePrompt.parse(
            screen: DemoPrompt.permission.replacingOccurrences(of: "deploy/web", with: "deploy/api")))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, MobilePrompt.parse(screen: DemoPrompt.question)?.id)
    }

    func testOnlyAWaitingPaneShowsAPrompt() {
        let pane = FakePane()
        pane.screen = DemoPrompt.permission
        XCTAssertNotNil(MobileReply.prompt(status: .waiting, io: pane.io))
        XCTAssertNotNil(MobileReply.prompt(status: .unknown, io: pane.io))
        // An old prompt still in the scrollback of a pane that moved on.
        XCTAssertNil(MobileReply.prompt(status: .idle, io: pane.io))
        XCTAssertNil(MobileReply.prompt(status: .busy, io: pane.io))
        XCTAssertNil(MobileReply.prompt(status: nil, io: pane.io))
    }

    func testAnAnswerIsTheDigitOfAChoiceOnThePaneNow() throws {
        let pane = FakePane()
        pane.screen = DemoPrompt.permission
        let id = try XCTUnwrap(MobilePrompt.parse(screen: DemoPrompt.permission)).id
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 2, target: "%12", io: pane.io, status: .waiting).status,
            200)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "2"]])

        // A choice the prompt does not have.
        for option in [0, 4, 9, -1, 12] {
            XCTAssertEqual(
                MobileReply.answer(prompt: id, option: option, target: "%12", io: pane.io, status: .waiting)
                    .status, 400)
        }
        // Another prompt took its place: the tap answers nothing.
        pane.screen = DemoPrompt.question
        let stale = MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, status: .waiting)
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(String(decoding: stale.body, as: UTF8.self), #"{"error":"stale"}"#)
        // The pane moved on, or cannot be read.
        pane.screen = DemoPrompt.permission
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, status: .busy).status, 409)
        pane.screen = nil
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, status: .waiting).status, 409)
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, status: nil).status, 404)
        XCTAssertEqual(pane.argv.count, 1)
    }

    func testReadsAnAnswerBody() {
        let answer = MobileReply.answer(in: Data(#"{"prompt":"9f2c","option":2}"#.utf8))
        XCTAssertEqual(answer?.prompt, "9f2c")
        XCTAssertEqual(answer?.option, 2)
        for body in [
            #"{"prompt":"9f2c"}"#, #"{"option":2}"#, #"{"prompt":"","option":2}"#,
            #"{"prompt":"9f2c","option":"2"}"#, #"{"prompt":"9f2c","option":true}"#,
            #"{"prompt":"9f2c","option":1.5}"#, "[]", "",
        ] {
            XCTAssertNil(MobileReply.answer(in: Data(body.utf8)), body)
        }
    }

    // MARK: upload

    func testAFileNameIsOneSafeComponent() {
        let cases: [(String, String?)] = [
            ("photo.png", "photo.png"),
            ("IMG 0042 (1).HEIC", "IMG-0042-1-.HEIC"),
            ("../../.ssh/authorized_keys", "authorized_keys"),
            ("/etc/passwd", "passwd"),
            ("..\\..\\boot.ini", "boot.ini"),
            (".env", "env"),
            ("-rf", "rf"),
            ("a\u{1B}[2Jb.txt", "a-2Jb.txt"),
            ("report\n.md", "report-.md"),
            ("$(touch x).sh", "touch-x-.sh"),
            ("résumé.pdf", "résumé.pdf"),
            ("...", nil), ("", nil), ("/", nil), ("..", nil),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(MobileReply.fileName(raw), expected, raw)
        }
        let long = String(repeating: "a", count: 300) + ".png"
        let name = MobileReply.fileName(long) ?? ""
        XCTAssertEqual(name.count, MobileReply.maxFileNameLength)
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertEqual(MobileReply.numbered("photo.png", 2), "photo-2.png")
        XCTAssertEqual(MobileReply.numbered("notes", 3), "notes-3")
    }

    func testAnUploadLandsInTheThreadsDirectoryAndItsPathIsPasted() {
        let pane = FakePane()
        let data = Data("demo".utf8)
        let response = MobileReply.upload(
            data, name: "../../etc/photo 1.png", thread: thread(), io: pane.io, limit: 1024,
            status: { .idle })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            String(decoding: response.body, as: UTF8.self),
            #"{"ok":true,"pasted":true,"path":"\/Users\/me\/acme-app\/photo-1.png"}"#)
        XCTAssertEqual(pane.copies.map(\.path), ["/Users/me/acme-app/photo-1.png"])
        XCTAssertEqual(pane.copies.first?.data, data)
        // The path is pasted, bracketed, and not submitted.
        XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
        XCTAssertEqual(pane.calls[1].stdin, "/Users/me/acme-app/photo-1.png ")
        XCTAssertEqual(Array(pane.argv[2].prefix(4)), ["paste-buffer", "-p", "-r", "-d"])
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
    }

    func testAnUploadNeverOverwritesAFile() {
        let pane = FakePane()
        pane.existing = ["/Users/me/acme-app/package.json", "/Users/me/acme-app/package-2.json"]
        let response = MobileReply.upload(
            Data("{}".utf8), name: "package.json", thread: thread(), io: pane.io, limit: 1024,
            status: { .idle })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(pane.copies.map(\.path), ["/Users/me/acme-app/package-3.json"])
    }

    func testAnUploadIsRefusedBeforeAnythingIsWritten() {
        let cases: [(Data, String, AttentionStatus?, String, Int)] = [
            (Data(count: 1025), "a.png", .idle, "/Users/me/acme-app", 413),
            (Data(), "a.png", .idle, "/Users/me/acme-app", 400),
            (Data("x".utf8), "...", .idle, "/Users/me/acme-app", 400),
            (Data("x".utf8), "a.png", .busy, "/Users/me/acme-app", 409),
            (Data("x".utf8), "a.png", .waiting, "/Users/me/acme-app", 409),
            (Data("x".utf8), "a.png", nil, "/Users/me/acme-app", 404),
            // No directory to save into, or one that is not text.
            (Data("x".utf8), "a.png", .idle, "", 503),
            (Data("x".utf8), "a.png", .idle, "relative/dir", 503),
            (Data("x".utf8), "a.png", .idle, "/Users/me/a\u{1B}b", 503),
        ]
        for (data, name, status, cwd, expected) in cases {
            let pane = FakePane()
            let response = MobileReply.upload(
                data, name: name, thread: thread(cwd: cwd), io: pane.io, limit: 1024, status: { status })
            XCTAssertEqual(response.status, expected, "\(name) \(String(describing: status)) \(cwd)")
            XCTAssertEqual(pane.copies.count, 0)
            XCTAssertEqual(pane.argv.count, 0)
        }
        // Settings cannot raise the limit past what the server holds in memory.
        XCTAssertEqual(
            MobileReply.upload(
                Data(count: MobileReply.maxUploadBytes + 1), name: "a.bin", thread: thread(),
                io: FakePane().io, limit: .max, status: { .idle }).status, 413)
    }

    func testAPromptThatComesUpDuringAnUploadGetsNoPaste() {
        let pane = FakePane()
        var asked = 0
        let response = MobileReply.upload(
            Data("x".utf8), name: "a.png", thread: thread(), io: pane.io, limit: 1024,
            status: { asked += 1; return asked == 1 ? .idle : .waiting })
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains(#""pasted":false"#))
        XCTAssertEqual(pane.copies.count, 1)
        XCTAssertEqual(pane.argv.count, 0)
    }

    // MARK: commands

    func testListsAProjectsAndTheUsersSkillsAndCommandsThenTheBuiltIns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("home/.claude/skills/commit/SKILL.md", "---\nname: commit\ndescription: Create a git commit\n---\n")
        try write("home/.claude/commands/git/tidy.md", "---\ndescription: \"Tidy branches\"\n---\nbody")
        try write("home/.claude/skills/.hidden/SKILL.md", "---\ndescription: no\n---\n")
        try write("home/.claude/skills/empty/notes.txt", "not a skill")
        try write("home/acme-app/.git/HEAD", "ref")
        try write("home/acme-app/.claude/skills/deploy/SKILL.md", "---\ndescription: Deploy to staging\n---\n")
        try write("home/acme-app/.claude/commands/commit.md", "no front matter")
        try write("home/acme-app/web/src/index.ts", "")
        try write("home/.codex/prompts/triage.md", "---\ndescription: Triage issues\n---\n")
        let home = root.appendingPathComponent("home").path

        let list = MobileCommands.list(for: thread(cwd: home + "/acme-app/web/src"), home: home)
        XCTAssertEqual(Array(list.prefix(4)), [
            .init(name: "deploy", description: "Deploy to staging", source: .skill),
            // The project's `commit` hides the user's skill of the same name.
            .init(name: "commit", description: "", source: .command),
            .init(name: "git:tidy", description: "Tidy branches", source: .command),
            .init(name: "clear", description: "Clear the conversation", source: .builtin),
        ])
        XCTAssertFalse(list.contains { $0.name.contains("hidden") || $0.name == "empty" })
        XCTAssertEqual(list.first?.json["source"] as? String, "skill")

        // A Codex thread has its own prompts and built-ins.
        let codex = MobileCommands.list(for: thread(claude: nil, codex: "x1"), home: home)
        XCTAssertEqual(codex.first, .init(name: "prompts:triage", description: "Triage issues", source: .command))
        XCTAssertTrue(codex.contains { $0.name == "approvals" })
        XCTAssertFalse(codex.contains { $0.name == "deploy" })

        // Only this Mac's disk is read: a remote thread gets the built-ins.
        let remote = MobileCommands.list(
            for: thread(host: Host(name: "devbox", sshAlias: "devbox"), cwd: home + "/acme-app"), home: home)
        XCTAssertTrue(remote.allSatisfy { $0.source == .builtin })
    }

    func testACommandNameIsOneWordAndADescriptionOneLineOfText() {
        XCTAssertEqual(MobileCommands.commandName("git:tidy"), "git:tidy")
        for refused in ["", "two words", ".hidden", "a/b", "x\u{1B}y", "a;b", String(repeating: "a", count: 81)] {
            XCTAssertNil(MobileCommands.commandName(refused), refused)
        }
        XCTAssertEqual(MobileCommands.description(in: "---\ndescription: 'Run \u{1B}[31mtests'\n---"), "Run [31mtests")
        XCTAssertEqual(MobileCommands.description(in: "description: not front matter"), "")
        XCTAssertEqual(
            MobileCommands.description(in: "---\ndescription: " + String(repeating: "a", count: 500) + "\n---")
                .count, MobileCommands.maxDescriptionLength)
    }

    // MARK: a thread's turn

    private func follow(
        _ turn: MobileThreadTurn
    ) -> (deltas: [String], outcome: ManagerTurnOutcome?) {
        let done = expectation(description: "turn ended")
        let lock = NSLock()
        var deltas: [String] = []
        var outcome: ManagerTurnOutcome?
        turn.follow(
            onDelta: { delta in lock.lock(); deltas.append(delta); lock.unlock() },
            completion: { result in lock.lock(); outcome = result; lock.unlock(); done.fulfill() })
        wait(for: [done], timeout: 5)
        lock.lock()
        defer { lock.unlock() }
        return (deltas, outcome)
    }

    func testAThreadsTurnIsItsNewAssistantRowsUntilThePaneStops() {
        let lock = NSLock()
        var statuses: [AttentionStatus?] = [.busy, .busy, .idle]
        var pages = [
            MobileChatPage(messages: [.init(n: 1, role: .assistant, text: "An older reply.")], next: 10),
            MobileChatPage(messages: [
                .init(n: 11, role: .user, text: "run the tests"),
                .init(n: 12, role: .tool, text: "make test", tool: "Bash"),
            ], next: 20),
            MobileChatPage(messages: [.init(n: 21, role: .assistant, text: "All 12 pass.")], next: 30),
            MobileChatPage(messages: [.init(n: 31, role: .assistant, text: "Pushed.")], next: 40),
        ]
        var cursors: [UInt64?] = []
        let turn = MobileThreadTurn(
            read: { after in
                lock.lock(); defer { lock.unlock() }
                cursors.append(after)
                return pages.isEmpty ? MobileChatPage(next: after ?? 0) : pages.removeFirst()
            },
            status: { lock.lock(); defer { lock.unlock() }; return statuses.count > 1 ? statuses.removeFirst() : statuses[0] },
            timing: .init(interval: 0.01, startGrace: 10, timeout: 10))
        turn.mark()
        let result = follow(turn)
        // What was there before the text went in is not the reply.
        XCTAssertEqual(result.deltas, ["All 12 pass.\n\n", "Pushed.\n\n"])
        XCTAssertEqual(result.outcome, .done(reply: "All 12 pass.\n\nPushed."))
        XCTAssertEqual(cursors, [nil, 10, 20, 30])
    }

    func testAThreadsTurnEndsOnAPromptOrAGoneThreadOrATimeout() {
        func turn(_ status: AttentionStatus?, timing: MobileThreadTurn.Timing) -> ManagerTurnOutcome? {
            let turn = MobileThreadTurn(read: { MobileChatPage(next: $0 ?? 0) }, status: { status }, timing: timing)
            turn.mark()
            return follow(turn).outcome
        }
        let quick = MobileThreadTurn.Timing(interval: 0.01, startGrace: 0.03, timeout: 0.05)
        XCTAssertEqual(turn(.waiting, timing: quick), .permission(reply: ""))
        XCTAssertEqual(turn(nil, timing: quick), .unreachable(MobileReply.unreachable))
        XCTAssertEqual(turn(.busy, timing: quick), .timeout(reply: ""))
        // A pane that never started working is done after the grace.
        XCTAssertEqual(turn(.idle, timing: quick), .done(reply: ""))
    }
}
