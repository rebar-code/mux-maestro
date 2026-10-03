import XCTest

/// A thread's pane, scripted: it records every tmux call and every copy, and
/// types nothing anywhere. Shared by the server tests.
final class FakePane {
    /// Where the terminal cursor is.
    enum Cursor: Equatable {
        /// In the input box, as a live agent keeps it; on the last line with
        /// text when the screen shows no box.
        case inBox
        /// On the last line with text: a shell, a question, a pager.
        case lastLine
        case row(Int)
        /// It cannot be read.
        case unknown
    }

    private let lock = NSLock()
    private var _cursor = Cursor.inBox
    private var _cursorAfterPaste: Cursor?
    private var _calls: [(args: [String], stdin: String?)] = []
    private var _saves: [(path: String, data: Data)] = []
    private var _status: AttentionStatus?
    private var _statusAfterPaste: AttentionStatus?
    private var _screen: String? = DemoPrompt.idle
    private var _screenAfterPaste: String?
    private var _existing = Set<String>()
    private var _failing = false
    private var _since: Int?
    private var _onPaste: (() -> Void)?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: [(args: [String], stdin: String?)] { locked { _calls } }
    var argv: [[String]] { calls.map(\.args) }
    var saves: [(path: String, data: Data)] { locked { _saves } }
    /// The pane's own status; nil for the tree's.
    var status: AttentionStatus? {
        get { locked { _status } }
        set { locked { _status = newValue } }
    }
    /// When the pane entered its status; nil for the tree's.
    var since: Int? {
        get { locked { _since } }
        set { locked { _since = newValue } }
    }
    /// What the status turns into once text is in the input box.
    var statusAfterPaste: AttentionStatus? {
        get { locked { _statusAfterPaste } }
        set { locked { _statusAfterPaste = newValue } }
    }
    /// What the pane shows. An idle agent's input box unless a test says otherwise.
    var screen: String? {
        get { locked { _screen } }
        set { locked { _screen = newValue } }
    }
    var cursor: Cursor {
        get { locked { _cursor } }
        set { locked { _cursor = newValue } }
    }
    var cursorAfterPaste: Cursor? {
        get { locked { _cursorAfterPaste } }
        set { locked { _cursorAfterPaste = newValue } }
    }

    /// The row `cursor` means on the screen as it is now.
    private var cursorRow: Int? {
        let (cursor, screen) = locked { (_cursor, _screen) }
        let lines = (screen ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        let last = lines.lastIndex { !$0.allSatisfy(\.isWhitespace) }
        switch cursor {
        case .unknown: return nil
        case .row(let row): return row
        case .lastLine: return last
        case .inBox:
            let rules = lines.indices.filter { index in
                let line = lines[index].trimmingCharacters(in: CharacterSet(charactersIn: "│ "))
                return !line.isEmpty && line.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
            }
            return rules.count >= 2 ? rules[rules.count - 2] + 1 : last
        }
    }

    /// What the pane shows once text is in the input box.
    var screenAfterPaste: String? {
        get { locked { _screenAfterPaste } }
        set { locked { _screenAfterPaste = newValue } }
    }
    /// Paths that are taken.
    var existing: Set<String> {
        get { locked { _existing } }
        set { locked { _existing = newValue } }
    }
    /// Runs once text is in the input box, before the call returns.
    var onPaste: (() -> Void)? {
        get { locked { _onPaste } }
        set { locked { _onPaste = newValue } }
    }
    /// tmux and saves fail.
    var failing: Bool {
        get { locked { _failing } }
        set { locked { _failing = newValue } }
    }

    var io: MobilePaneIO {
        MobilePaneIO(
            tmux: { [self] args, stdin in
                let result: String? = locked {
                    guard !_failing else { return nil }
                    _calls.append((args, stdin.map { String(decoding: $0, as: UTF8.self) }))
                    if args.first == "paste-buffer" {
                        if let after = _statusAfterPaste { _status = after }
                        if let after = _screenAfterPaste { _screen = after }
                        if let after = _cursorAfterPaste { _cursor = after }
                    }
                    return ""
                }
                if args.first == "paste-buffer" { onPaste?() }
                return result
            },
            screen: { [self] in screen },
            state: { [self] thread in
                MobilePaneState(
                    status: status ?? thread.status, since: since ?? thread.since,
                    remote: !thread.host.isLocal)
            },
            save: { [self] data, path in
                locked {
                    if _failing { return .failed }
                    if _existing.contains(path) { return .exists }
                    _saves.append((path, data))
                    _existing.insert(path)
                    return .saved
                }
            },
            cursorRow: { [self] in cursorRow })
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
    /// An idle agent: its last reply, then the input box between two rules.
    static let idle = input("")

    /// The same screen with `text` in the input box.
    static func input(_ text: String) -> String {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        let box = (["❯ " + (rows.first ?? "")] + rows.dropFirst().map { "  " + $0 }).joined(separator: "\n")
        return """
            ⏺ Done. 4 files changed, tests pass.

            ────────────────────────────────────────
            \(box)
            ────────────────────────────────────────
              ? for shortcuts
            """
    }

    /// Codex asking whether to trust a folder, as it draws it: no box, the
    /// cursor mark is `›`, and a hint line under the choices.
    static let codexTrust = """

          Folder access
          /Users/me/acme-app

          Trust this folder? Codex can read, edit, and run files here, subject to your permission
          settings. Continue only if you trust these files. Your trust decision will be saved.

        › 1. Trust and continue
          2. Back to Agent Command Center

          enter continue · esc back
        """

    /// An idle Claude Code pane as tmux captures it (v2.1.288), with demo
    /// names: a no-break space after the mark, and under the box a status
    /// line of the human's own, then the mode line.
    static let claudeIdle = """
        ⏺ Done. 4 files changed, tests pass.

        ────────────────────────────────────────────────────────────
        ❯\u{A0}
        ────────────────────────────────────────────────────────────
          ➜ acme-app git:(main) · ctx 42%
          ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
        """

    /// An idle Codex pane as tmux captures it (v0.160.0), with demo names.
    /// The composer has no rules: its mark, a blank row, two footer rows.
    static let codexIdle = codexInput(["Ask Codex to do anything"])

    /// The same screen with `rows` in the composer.
    static func codexInput(_ rows: [String]) -> String {
        let box = (["› " + (rows.first ?? "")] + rows.dropFirst().map { "  " + $0 }).joined(separator: "\n")
        return """

              >_ OpenAI Codex (v0.160.0)
                 ~/acme-app

              May the source be with you.



            \(box)

              GPT-6-Luna medium · ~/acme-app
              ← for agents · ? for shortcuts                              ⚠ 3 warnings · f2 to view
            """
    }

    /// A long menu, scrolled: rows above and below are off screen.
    static let scrolledMenu = """
        ────────────────────────────────────────
         ☐ Region

        Which region should the deploy use?

          ↑ 4. eu-west-1
            5. eu-central-1
          ❯ 6. us-east-1
            7. us-west-2
            8. ap-south-1
          ↓ 9. ap-northeast-1
        ────────────────────────────────────────
        """

    /// Claude Code's model menu as 2.1.289 draws it: the dialog's top edge is
    /// a row of upper-block characters, not a line rule, and rows that do not
    /// fit are counted on a line under the last one, with no arrow.
    static let modelMenu = """
         ▐▛███▜▌   Claude Code v2.1.289
        ▝▜█████▛▘  ~/acme-app

        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
         Select model
         Switch between models. Applies to this session.

         ❯ 1. Default (recommended)
           2. Large
           3. Small
           … +2 models

         Enter to confirm · Esc to exit
        """

    /// The permission prompt with the cursor moved to its third choice.
    static let permissionOnThird = permission
        .replacingOccurrences(of: "❯ 1. Yes ", with: "  1. Yes ")
        .replacingOccurrences(of: "  3. No,", with: "❯ 3. No,")

    /// A prompt with no numbered choices.
    static let yesNo = """
        ⏺ Bash(rm -rf build)

        Remove the build folder? (y/n)
        """

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
            // The key bar may read the prompt too; see the next test.
            let others = Set(MobileCapability.allCases)
                .subtracting(name == "prompt" ? [capability, .keyBar] : [capability])
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

    func testThePromptIsReadableWithTheKeyBarAloneAndNothingElseIs() {
        let keys = MobileConfig(capabilities: [.keyBar])
        let id = "/api/threads/localhost%3A12"
        XCTAssertEqual(
            MobileAPI.route(MobileRequest(method: "GET", path: id + "/prompt"), config: keys),
            .api(.prompt(id: "localhost:12")))
        // Reading only: no answer, no text, no commands.
        for (method, name) in [("POST", "answer"), ("POST", "text"), ("GET", "commands")] {
            XCTAssertEqual(
                MobileAPI.route(MobileRequest(method: method, path: id + "/" + name), config: keys),
                .disabled(.replies), name)
        }
        XCTAssertEqual(
            MobileAPI.route(MobileRequest(method: "POST", path: id + "/prompt"), config: keys),
            .methodNotAllowed)
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

    private func state(
        _ status: AttentionStatus, since: Int? = nil, remote: Bool = false
    ) -> MobilePaneState {
        MobilePaneState(status: status, since: since, remote: remote)
    }

    /// The id `GET …/prompt` would hand the phone for this pane.
    private func shownID(_ state: MobilePaneState, _ pane: FakePane) -> String? {
        MobileReply.promptBody(state: state, io: pane.io)["id"] as? String
    }

    /// `text` as a pane's screen, with the cursor where `cursor` says.
    private func seen(
        _ text: String, pasted: String = "", cursor: FakePane.Cursor = .inBox,
        after: MobileScreen.Anchor? = nil
    ) -> MobileScreen {
        let pane = FakePane()
        pane.screen = text
        pane.cursor = cursor
        return MobileScreen(text, cursorRow: pane.io.cursorRow(), pasted: pasted, after: after)
    }

    /// The prompt `GET …/prompt` would show for `screen`.
    private func shown(_ state: MobilePaneState?, _ screen: String?, io: MobilePaneIO? = nil) -> MobilePrompt? {
        MobileReply.prompt(state: state, seen: screen.map { seen($0, cursor: .lastLine) }, io: io ?? FakePane().io)
    }

    private func body(_ response: MobileResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    func testTheKeyWhitelistIsExactlyTheNamedKeys() {
        var expected: Set<String> = ["Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab"]
        for letter in "abcdefghijklmnopqrstuvwxyz" { expected.insert("C-\(letter)") }
        for digit in 1...9 { expected.insert("\(digit)") }
        XCTAssertEqual(MobileReply.keys, expected)
        XCTAssertEqual(MobileReply.keys.count, 43)

        XCTAssertEqual(MobileReply.key(in: Data(#"{"key":"Escape"}"#.utf8))?.key, "Escape")
        XCTAssertNil(MobileReply.key(in: Data(#"{"key":"Escape"}"#.utf8))?.prompt)
        let named = MobileReply.key(in: Data(#"{"key":"C-c","prompt":"9f2c"}"#.utf8))
        XCTAssertEqual(named?.key, "C-c")
        XCTAssertEqual(named?.prompt, "9f2c")
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
        XCTAssertEqual(
            MobileReply.press("BTab", prompt: nil, target: "%12", io: pane.io, state: state(.idle)).status, 200)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "BTab"]])
        // The whitelist is checked here too, not only where the body is read.
        XCTAssertEqual(
            MobileReply.press("F1", prompt: nil, target: "%12", io: pane.io, state: state(.idle)).status, 400)
        XCTAssertEqual(
            MobileReply.press("Enter", prompt: nil, target: "%12", io: pane.io, state: nil).status, 404)
        XCTAssertEqual(pane.argv.count, 1)
        pane.failing = true
        XCTAssertEqual(
            MobileReply.press("Enter", prompt: nil, target: "%12", io: pane.io, state: state(.idle)).status, 503)
        // A pane that cannot be read takes no key: what it waits on is not known.
        let blind = FakePane()
        blind.screen = nil
        XCTAssertEqual(
            MobileReply.press("Enter", prompt: nil, target: "%12", io: blind.io, state: state(.idle)).status, 503)
        XCTAssertEqual(blind.argv.count, 0)
    }

    func testAKeyIntoAWaitingPaneMustNameThePromptOnItNow() throws {
        let pane = FakePane()
        pane.screen = DemoPrompt.permission
        let waiting = state(.waiting, since: 100)
        let id = try XCTUnwrap(shownID(waiting, pane))
        let other = FakePane()
        other.screen = DemoPrompt.question

        // Enter with no prompt named, or with the id of a prompt that has gone.
        for sent in [nil, "", "9f2c", shownID(waiting, other)] {
            for key in ["Enter", "1", "Escape", "Down"] {
                let refused = MobileReply.press(key, prompt: sent, target: "%12", io: pane.io, state: waiting)
                XCTAssertEqual(refused.status, 409, key)
                XCTAssertEqual(body(refused), #"{"error":"stale"}"#, key)
            }
        }
        XCTAssertEqual(pane.argv.count, 0)

        // The key bar works like a terminal for the prompt the phone shows.
        for key in ["Down", "Enter", "2", "Escape"] {
            XCTAssertEqual(
                MobileReply.press(key, prompt: id, target: "%12", io: pane.io, state: waiting).status, 200, key)
        }
        XCTAssertEqual(pane.argv.map(\.last), ["Down", "Enter", "2", "Escape"])

        // The status says idle (a remote host's old scan), the screen shows a
        // prompt: the screen counts.
        let stale = FakePane()
        stale.screen = DemoPrompt.permission
        XCTAssertEqual(
            MobileReply.press("Enter", prompt: nil, target: "%12", io: stale.io, state: state(.idle, remote: true))
                .status, 409)
        XCTAssertEqual(stale.argv.count, 0)
    }

    func testAWaitingPaneWithNoReadableChoicesStillHasAnIdForKeys() throws {
        let pane = FakePane()
        pane.screen = DemoPrompt.yesNo
        let waiting = state(.waiting, since: 100)
        let shown = MobileReply.promptBody(state: waiting, io: pane.io)
        XCTAssertTrue(shown["prompt"] is NSNull)
        let id = try XCTUnwrap(shown["id"] as? String)
        XCTAssertEqual(
            MobileReply.press("Escape", prompt: nil, target: "%12", io: pane.io, state: waiting).status, 409)
        XCTAssertEqual(
            MobileReply.press("Escape", prompt: id, target: "%12", io: pane.io, state: waiting).status, 200)
        // The phone has no card for it, so no key of the phone's answers it.
        for key in ["Enter", "1", "2", "9"] {
            let unseen = MobileReply.press(key, prompt: id, target: "%12", io: pane.io, state: waiting)
            XCTAssertEqual(unseen.status, 409, key)
            XCTAssertEqual(body(unseen), #"{"error":"unseen","message":"Open the terminal to answer"}"#, key)
        }
        // The screen moved on under the same status: the id is another one.
        pane.screen = DemoPrompt.yesNo.replacingOccurrences(of: "build", with: "dist")
        XCTAssertEqual(
            MobileReply.press("Escape", prompt: id, target: "%12", io: pane.io, state: waiting).status, 409)
        XCTAssertEqual(pane.argv.count, 1)
        // A pane that waits on nothing has no id, and a key needs none.
        XCTAssertTrue(
            MobileReply.promptBody(state: state(.idle), io: FakePane().io)["id"] is NSNull)
        XCTAssertTrue(MobileReply.answers("Enter"))
        XCTAssertTrue(MobileReply.answers("7"))
        for key in ["Escape", "Up", "Down", "Left", "Right", "Tab", "C-c"] {
            XCTAssertFalse(MobileReply.answers(key), key)
        }
    }

    func testEveryWhitelistedKeyHasAnEffectClassAndTheGuardsUseIt() {
        // Each key that submits, however it is named.
        for key in ["Enter", "C-m", "C-j", "C-d", "C-o", "BTab"] {
            XCTAssertEqual(MobileReply.effect(of: key), .submit, key)
            XCTAssertTrue(MobileReply.answers(key), key)
        }
        for digit in 1...9 {
            XCTAssertEqual(MobileReply.effect(of: "\(digit)"), .digit(digit))
        }
        for key in ["Up", "Down", "Left", "Right", "Tab", "C-i", "C-n", "C-p", "C-f", "C-b", "C-a", "C-e"] {
            XCTAssertEqual(MobileReply.effect(of: key), .navigate, key)
        }
        for key in ["Escape", "C-c", "C-g"] { XCTAssertEqual(MobileReply.effect(of: key), .cancel, key) }
        // Nothing on the whitelist is left without a class by accident: what
        // is not named above edits the line.
        let named: Set<String> = [
            "Enter", "C-m", "C-j", "C-d", "C-o", "BTab", "Up", "Down", "Left", "Right", "Tab", "C-i",
            "C-n", "C-p", "C-f", "C-b", "C-a", "C-e", "Escape", "C-c", "C-g",
        ]
        let rest = MobileReply.keys.subtracting(named).filter { MobileReply.effect(of: $0) == .other }
        XCTAssertEqual(
            rest.sorted(),
            ["C-h", "C-k", "C-l", "C-q", "C-r", "C-s", "C-t", "C-u", "C-v", "C-w", "C-x", "C-y", "C-z"])

        // A submit key under another name is refused where Enter is.
        let waiting = state(.waiting, since: 100)
        let blind = FakePane()
        blind.screen = DemoPrompt.yesNo
        blind.cursor = .lastLine
        let id = shownID(waiting, blind)
        for key in ["C-m", "C-j", "C-d", "C-o", "BTab"] {
            XCTAssertEqual(
                MobileReply.press(key, prompt: id, target: "%12", io: blind.io, state: waiting).status, 409, key)
            XCTAssertEqual(
                MobileReply.press(key, prompt: nil, target: "%12", io: blind.io, state: state(.idle)).status,
                409, key)
        }
        XCTAssertEqual(blind.argv.count, 0)
    }

    // MARK: text

    func testTextGoesInAsOneBracketedPasteThenEnter() {
        let pane = FakePane()
        var pauses: [TimeInterval] = []
        let text = "first line\nsecond; $(rm -rf /) `x` && done"
        let response = MobileReply.send(
            text, target: "%12", io: pane.io, state: { self.state(.idle) }, pause: { pauses.append($0) })
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%12"), "\(pane.argv)")
        // The text goes in over stdin: it is in no argv.
        XCTAssertEqual(pane.calls[1].stdin, text)
        XCTAssertFalse(pane.argv.joined().contains { $0.contains("rm -rf") })
        XCTAssertEqual(pauses, [MobileReply.enterDelay])
    }

    func testEachPasteUsesABufferOfItsOwn() {
        let pane = FakePane()
        _ = MobileReply.send("one", target: "%12", io: pane.io, state: { self.state(.idle) }, pause: { _ in })
        _ = MobileReply.send("two", target: "%12", io: pane.io, state: { self.state(.idle) }, pause: { _ in })
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
                "go on", target: "%12", io: pane.io, state: { self.state(status) }, pause: { _ in })
            XCTAssertEqual(response.status, 409)
            XCTAssertTrue(body(response).contains(#""error":"\#(code)""#))
            XCTAssertEqual(pane.argv.count, 0, code)
        }
        // A thread that left the tree: nothing to type into.
        let pane = FakePane()
        XCTAssertEqual(
            MobileReply.send("go on", target: "%12", io: pane.io, state: { nil }, pause: { _ in }).status, 404)
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testTextRefusedAfterThePasteIsTakenOutOnlyWhenTheInputBoxIsInFront() {
        func refuse(_ late: AttentionStatus, screen: String?) -> (FakePane, MobileResponse) {
            let pane = FakePane()
            pane.status = .idle
            pane.statusAfterPaste = late
            pane.screenAfterPaste = screen
            let response = MobileReply.send(
                "go on\nthen push", target: "%12", io: pane.io,
                state: { pane.status.map { self.state($0) } }, pause: { _ in })
            XCTAssertEqual(response.status, 409)
            // Its own code: the phone must know the text was in the pane.
            XCTAssertTrue(body(response).contains(#""error":"not_sent""#), body(response))
            XCTAssertTrue(body(response).contains(#""reason":"\#(late.rawValue)""#))
            XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
            return (pane, response)
        }
        // The pane started a turn: its input box is still in front. One
        // Ctrl-U per line takes the text out.
        let (busy, cleared) = refuse(.busy, screen: DemoPrompt.input("go on\nthen push"))
        XCTAssertTrue(body(cleared).contains(#""cleared":true"#))
        XCTAssertEqual(busy.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer", "send-keys"])
        XCTAssertEqual(busy.argv.last, ["send-keys", "-t", "%12", "C-u", "C-u"])

        // A prompt is in front: Ctrl-U would go to the prompt. No key at all,
        // whether the screen shows the prompt yet or still shows the box.
        for screen in [DemoPrompt.permission, DemoPrompt.input("go on\nthen push"), nil] {
            let (waiting, left) = refuse(.waiting, screen: screen)
            XCTAssertTrue(body(left).contains(#""cleared":false"#))
            XCTAssertEqual(waiting.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
        }
        // Busy, and something that is not the box is in front.
        let (pager, kept) = refuse(.busy, screen: DemoPrompt.idle + "\n:")
        XCTAssertTrue(body(kept).contains(#""cleared":false"#))
        XCTAssertEqual(pager.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
        // The thread went away between the paste and the Enter: no pane to clear.
        let pane = FakePane()
        var asked = 0
        let gone = MobileReply.send(
            "go on", target: "%12", io: pane.io,
            state: { asked += 1; return asked == 1 ? self.state(.idle) : nil }, pause: { _ in })
        XCTAssertEqual(gone.status, 404)
        XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
    }

    func testAPromptOnTheScreenBeforeTheEnterWinsOverAnIdleStatus() {
        // The status never changes: only the screen shows the prompt that
        // came up after the paste. A remote pane's status is like this.
        for remote in [false, true] {
            let pane = FakePane()
            pane.screenAfterPaste = DemoPrompt.permission
            let response = MobileReply.send(
                "go on", target: "%12", io: pane.io, state: { self.state(.idle, remote: remote) },
                pause: { _ in })
            XCTAssertEqual(response.status, 409, "remote \(remote)")
            XCTAssertTrue(body(response).contains(#""reason":"waiting""#))
            XCTAssertTrue(body(response).contains(#""cleared":false"#))
            // The paste, then no key of any kind.
            XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
        }
        // And before the paste: nothing is typed at all.
        let pane = FakePane()
        pane.screen = DemoPrompt.permission
        let early = MobileReply.send(
            "go on", target: "%12", io: pane.io, state: { self.state(.idle, remote: true) }, pause: { _ in })
        XCTAssertEqual(early.status, 409)
        XCTAssertEqual(body(early), #"{"error":"waiting","message":"Thread is waiting on a prompt"}"#)
        XCTAssertEqual(pane.argv.count, 0)
        // A pane that cannot be read gets no text.
        let blind = FakePane()
        blind.screen = nil
        XCTAssertEqual(
            MobileReply.send("go on", target: "%12", io: blind.io, state: { self.state(.idle) }, pause: { _ in })
                .status, 503)
        XCTAssertEqual(blind.argv.count, 0)
    }

    func testOnlyAScreenVerifiedAsAnIdleInputBoxTakesText() {
        // Hooks or none, this Mac or another host: only an agent's input box
        // takes text.
        for unverified in [
            state(.idle), state(.unknown), state(.idle, remote: true), state(.unknown, remote: true),
        ] {
            for screen in [
                "$ make test\nok\n$ ", "", DemoPrompt.yesNo, "Overwrite config.json? [y/N] ",
                "Press Enter to continue", "Password:",
                // A dead agent's last input box with a shell or a pager under it.
                DemoPrompt.idle + "\n$ rm -i build\nremove build? [y/N] ",
                DemoPrompt.idle + "\n$ ", DemoPrompt.idle + "\n:",
                DemoPrompt.idle + "\n  a\n  b\n  c\n  d\n  e",
            ] {
                let pane = FakePane()
                pane.screen = screen
                let response = MobileReply.send(
                    "y", target: "%12", io: pane.io, state: { unverified }, pause: { _ in })
                XCTAssertEqual(response.status, 409, screen)
                XCTAssertEqual(
                    body(response), #"{"error":"no_input","message":"Thread shows no input box"}"#, screen)
                XCTAssertEqual(pane.argv.count, 0, screen)
            }
            // With the box on screen, the text goes in.
            let pane = FakePane()
            pane.screenAfterPaste = DemoPrompt.input("go on")
            XCTAssertEqual(
                MobileReply.send("go on", target: "%12", io: pane.io, state: { unverified }, pause: { _ in })
                    .status, 200)
        }
        // The agent's own footer under the box is fine: hints and a status line.
        let footer = seen(DemoPrompt.idle + "\n  ⏵⏵ accept edits on\n  main · 12% context")
        XCTAssertTrue(footer.inputBox)
        XCTAssertTrue(seen("╭──────╮\n│ > hello │\n╰──────╯\n  ? for shortcuts").inputBox)
    }

    func testOurOwnNumberedListInTheInputBoxIsNotAPrompt() {
        let list = "1. rename the flag\n2. update the docs"
        let pane = FakePane()
        pane.screenAfterPaste = DemoPrompt.input(list)
        XCTAssertEqual(
            MobileReply.send(list, target: "%12", io: pane.io, state: { self.state(.unknown) }, pause: { _ in })
                .status, 200)
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%12"))
    }

    func testTextThatOnlyMentionsAChoiceIsNotAnEchoOfThePrompt() throws {
        // The text holds the words of every choice. A substring test would
        // call the prompt an echo of it and press Enter on "1. Yes".
        let yesNo = """
            ────────────────────
            ❯ 1. Yes
              2. No
            ────────────────────
            """
        // Where the input box was before the paste: the same two rows.
        let box = MobileScreen.Anchor(top: 0, bottom: 3)
        for text in [
            "Yes or No?", "1. Yes or 2. No", "No\nYes", "1. Yes", "2. No\n1. Yes", "x 1. Yes\n2. No",
            // The reply holds the option lines among others: the box would show them all.
            "pick one:\n1. Yes\n2. No", "1. Yes\n2. No\nwhich?", "1. Yes\n\n2. No",
        ] {
            XCTAssertNotNil(seen(yesNo, pasted: text, after: box).prompt, text)
            XCTAssertFalse(seen(yesNo, pasted: text, after: box).inputBox, text)
            let pane = FakePane()
            pane.screenAfterPaste = yesNo
            let response = MobileReply.send(
                text, target: "%12", io: pane.io, state: { self.state(.idle) }, pause: { _ in })
            XCTAssertEqual(response.status, 409, text)
            XCTAssertFalse(pane.argv.contains { $0.contains("Enter") }, text)
        }
        // The box holds the text and nothing else, row for row: that is the text.
        XCTAssertNil(seen(DemoPrompt.input("pick one:\n1. Yes\n2. No"), pasted: "pick one:\n1. Yes\n2. No").prompt)
        // A list of ours in the box that was there before the paste.
        XCTAssertNil(seen(yesNo, pasted: "1. Yes\n2. No", after: box).prompt)
        XCTAssertTrue(seen(yesNo, pasted: "1. Yes\n2. No", after: box).inputBox)
        // The same lines with no box known from before, in a box somewhere
        // else, or with the cursor away from them, are a prompt.
        XCTAssertNotNil(seen(yesNo, pasted: "1. Yes\n2. No").prompt)
        XCTAssertNotNil(
            seen(yesNo, pasted: "1. Yes\n2. No", after: MobileScreen.Anchor(top: 7, bottom: 9)).prompt)
        XCTAssertNotNil(seen(yesNo, pasted: "1. Yes\n2. No", cursor: .unknown, after: box).prompt)
        XCTAssertNotNil(seen("x\n" + yesNo, pasted: "1. Yes\n2. No", cursor: .row(0), after: box).prompt)
        // The same lines outside an input box are a prompt whatever was pasted.
        XCTAssertNotNil(seen(DemoPrompt.question, pasted: "1. Redis\n2. In memory\n3. Type something.").prompt)
        // A box that is not the last thing on screen is no box, so no echo.
        XCTAssertNotNil(seen(yesNo + "\n$ ", pasted: "1. Yes\n2. No").prompt)
        XCTAssertTrue(MobileScreen.isEcho(["❯ 1. Yes", "2. No"], of: " 1. Yes \n2. No"))
        XCTAssertFalse(MobileScreen.isEcho(["❯ 1. Yes", "2. No"], of: "1. Yes\n\n2. No"))
        XCTAssertFalse(MobileScreen.isEcho(["❯ 1. Yes", "2. No"], of: ""))
        XCTAssertFalse(MobileScreen.isEcho(["1. Yes", "2. No"], of: "1. Yes\n2. No"))
        XCTAssertFalse(MobileScreen.isEcho([], of: ""))
    }

    func testAPromptAboveADeadInputBoxIsStillAPrompt() {
        // Above a live box a numbered list is scrollback. Above a box with a
        // shell under it, nothing says the list is old.
        XCTAssertNil(seen(DemoPrompt.permission + "\n" + DemoPrompt.idle).prompt)
        let stale = seen(DemoPrompt.permission + "\n" + DemoPrompt.idle + "\n$ ")
        XCTAssertNotNil(stale.prompt)
        XCTAssertFalse(stale.inputBox)
        // The box is last on screen, but the cursor is not in it: it is not
        // known to be live, so the list above it is not known to be old.
        for cursor in [FakePane.Cursor.row(9), .unknown, .lastLine] {
            let unsure = seen(DemoPrompt.permission + "\n" + DemoPrompt.idle, cursor: cursor)
            XCTAssertNotNil(unsure.prompt, "\(cursor)")
            XCTAssertFalse(unsure.inputBox, "\(cursor)")
        }
    }

    func testAFailedPasteIsAnErrorAndSendsNoEnter() {
        let pane = FakePane()
        pane.failing = true
        let response = MobileReply.send(
            "go on", target: "%12", io: pane.io, state: { self.state(.idle) }, pause: { _ in })
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(pane.argv.count, 0)
    }

    // MARK: state

    func testTheHookRowIsNewerThanTheTree() {
        let now = 1_759_500_000
        func row(_ state: AgentStateRow.State, pane: String = "%12", session: String = "c1", age: Int = 1)
            -> AgentStateRow {
            AgentStateRow(
                sessionId: session, agent: "claude", state: state, reason: "", pane: pane,
                cwd: "/Users/me/acme-app", since: now - age, updatedAt: now - age)
        }
        func status(_ thread: MobileThread, _ rows: [AgentStateRow]) -> AttentionStatus {
            MobileReply.state(thread: thread, rows: rows, now: now).status
        }
        // The tree still says idle; the hook reported a prompt a second ago.
        XCTAssertEqual(
            MobileReply.state(thread: thread(status: .idle), rows: [row(.waiting)], now: now),
            MobilePaneState(status: .waiting, since: now - 1))
        XCTAssertEqual(status(thread(status: .idle), [row(.busy)]), .busy)
        // No row, another pane's row, or another session's row in this pane: the tree's.
        XCTAssertEqual(status(thread(status: .busy), []), .busy)
        XCTAssertEqual(status(thread(status: .idle), [row(.waiting, pane: "%13")]), .idle)
        XCTAssertEqual(status(thread(status: .idle), [row(.waiting, session: "old")]), .idle)
        // A busy row the scan has long disagreed with is a missed Stop.
        XCTAssertEqual(status(thread(status: .idle), [row(.busy, age: 86_400)]), .idle)
        // The hooks write this Mac's own state: never a remote pane's, whose
        // status is marked as one that may be old.
        let remote = thread(status: .idle, host: Host(name: "devbox", sshAlias: "devbox"))
        XCTAssertEqual(
            MobileReply.state(thread: remote, rows: [row(.waiting)], now: now),
            MobilePaneState(status: .idle, since: nil, remote: true))
    }

    // MARK: prompts

    func testReadsAPermissionPromptFromTheScreen() throws {
        let prompt = try XCTUnwrap(seen(DemoPrompt.permission).prompt)
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
        XCTAssertFalse(prompt.truncated)
        XCTAssertFalse(seen(DemoPrompt.permission).inputBox)
        XCTAssertEqual(prompt.json["id"] as? String, prompt.id)
        XCTAssertEqual(prompt.json["truncated"] as? Bool, false)
        XCTAssertEqual((prompt.json["options"] as? [[String: Any]])?.count, 3)
    }

    func testReadsAQuestionWhoseOptionsCarryDescriptions() throws {
        let prompt = try XCTUnwrap(seen(DemoPrompt.question).prompt)
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.question, "Which store should the cache use?")
        XCTAssertEqual(prompt.options.map(\.label), ["Redis", "In memory", "Type something."])
        XCTAssertEqual(prompt.options.map(\.n), [1, 2, 3])
    }

    func testTheSelectedRowIsPartOfWhatThePhoneShows() throws {
        let first = try XCTUnwrap(seen(DemoPrompt.permission).prompt)
        let moved = try XCTUnwrap(seen(DemoPrompt.permissionOnThird).prompt)
        XCTAssertEqual(moved.options.map(\.n), [1, 2, 3])
        XCTAssertEqual(first.selected, 1)
        XCTAssertEqual(moved.selected, 3)
        XCTAssertEqual(moved.json["selected"] as? Int, 3)
        // The same words, so the pane's counter does not move; but Enter
        // takes another row, so it is another id.
        XCTAssertEqual(first.key, moved.key)
        XCTAssertNotEqual(first.id, moved.id)
    }

    func testRecognisesTheRealInputBoxesAndNothingShapedLikeThem() {
        // Claude Code: two rules, a no-break space after the mark, a status
        // line that ends in a percentage.
        XCTAssertTrue(seen(DemoPrompt.claudeIdle).inputBox)
        XCTAssertFalse(seen(DemoPrompt.claudeIdle, cursor: .lastLine).inputBox)
        // Codex: no rules. The mark, a blank row, the footer.
        XCTAssertTrue(seen(DemoPrompt.codexIdle, cursor: .row(8)).inputBox)
        XCTAssertTrue(seen(DemoPrompt.codexInput(["run the tests", "then push"]), cursor: .row(9)).inputBox)
        XCTAssertEqual(
            seen(DemoPrompt.codexIdle, cursor: .row(8)).anchor, MobileScreen.Anchor(top: 7, bottom: 9))
        for cursor in [FakePane.Cursor.row(2), .row(10), .lastLine, .unknown] {
            XCTAssertFalse(seen(DemoPrompt.codexIdle, cursor: cursor).inputBox, "\(cursor)")
        }
        // The same shape with something under it that waits for a key, with
        // a menu's mark instead of Codex's, or with a list in it.
        let bare = { (rows: String, footer: String) in "x\n\n\(rows)\n\n\(footer)" }
        XCTAssertTrue(seen(bare("› hello", "  ? for shortcuts"), cursor: .row(2)).inputBox)
        for (rows, footer) in [
            ("› Yes, proceed\n  No", "  enter continue · esc back"),
            ("› hello", "  Overwrite? [y/N]"), ("› hello", "$ "), ("❯ hello", "  ? for shortcuts"),
            ("> hello", "  ? for shortcuts"), ("› 1. Trust\n  2. Back", "  ? for shortcuts"),
            ("› hello", "  a\n  b\n  c\n  d\n  e"),
        ] {
            XCTAssertFalse(seen(bare(rows, footer), cursor: .row(2)).inputBox, rows + " / " + footer)
        }
    }

    func testReadsAScrolledMenuAndSaysThereIsMore() throws {
        let prompt = try XCTUnwrap(seen(DemoPrompt.scrolledMenu, cursor: .lastLine).prompt)
        XCTAssertEqual(prompt.options.map(\.n), [4, 5, 6, 7, 8, 9])
        XCTAssertEqual(prompt.options.last?.label, "ap-northeast-1")
        XCTAssertEqual(prompt.selected, 6)
        XCTAssertTrue(prompt.moreAbove)
        XCTAssertTrue(prompt.moreBelow)
        XCTAssertEqual(prompt.question, "Which region should the deploy use?")
        // A list that starts past 1 with no mark that says why is not a menu.
        XCTAssertNil(seen(DemoPrompt.scrolledMenu.replacingOccurrences(of: "↑ 4.", with: "  4.")).prompt)
        let whole = try XCTUnwrap(seen(DemoPrompt.permission).prompt)
        XCTAssertFalse(whole.moreAbove)
        XCTAssertFalse(whole.moreBelow)

        // A digit answers only a row of the card.
        let pane = FakePane()
        pane.screen = DemoPrompt.scrolledMenu
        pane.cursor = .lastLine
        let waiting = state(.waiting, since: 100)
        let id = shownID(waiting, pane)
        for digit in ["1", "2", "3"] {
            let refused = MobileReply.press(digit, prompt: id, target: "%12", io: pane.io, state: waiting)
            XCTAssertEqual(body(refused), #"{"error":"no_option","message":"Not a choice on the card"}"#)
        }
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(
            MobileReply.press("9", prompt: id, target: "%12", io: pane.io, state: waiting).status, 200)
    }

    func testReadsClaudesModelMenuWithItsBlockEdgeAndRowCount() throws {
        let prompt = try XCTUnwrap(seen(DemoPrompt.modelMenu, cursor: .lastLine).prompt)
        XCTAssertEqual(prompt.options.map(\.label), ["Default (recommended)", "Large", "Small"])
        XCTAssertTrue(prompt.moreBelow)
        XCTAssertFalse(prompt.moreAbove)
        // The banner is above the dialog's top edge: it is not the title.
        XCTAssertEqual(prompt.title, "Select model")
        XCTAssertFalse(prompt.truncated)
        // A count over a list that starts past 1 says rows are off screen above.
        let above = try XCTUnwrap(seen("… +3 more\n  4. d\n❯ 5. e\n  6. f", cursor: .lastLine).prompt)
        XCTAssertTrue(above.moreAbove)
        XCTAssertEqual(above.options.map(\.n), [4, 5, 6])
        XCTAssertNil(seen("more\n  4. d\n❯ 5. e\n  6. f", cursor: .lastLine).prompt)
        // Three dots do as well as the ellipsis; a line that only starts
        // with dots does not.
        XCTAssertEqual(seen("❯ 1. a\n  2. b\n  ... +4 rows", cursor: .lastLine).prompt?.moreBelow, true)
        XCTAssertEqual(seen("❯ 1. a\n  2. b\n  … and so on", cursor: .lastLine).prompt?.moreBelow, false)
    }

    func testReadsCodexsPromptAsItDrawsIt() throws {
        let prompt = try XCTUnwrap(seen(DemoPrompt.codexTrust, cursor: .lastLine).prompt)
        XCTAssertEqual(prompt.options, [
            .init(n: 1, label: "Trust and continue"), .init(n: 2, label: "Back to Agent Command Center"),
        ])
        XCTAssertEqual(prompt.selected, 1)
        XCTAssertTrue(prompt.question.hasSuffix("Your trust decision will be saved."))
        XCTAssertFalse(seen(DemoPrompt.codexTrust, cursor: .lastLine).inputBox)
    }

    func testAnUnverifiedPaneTakesEnterOnlyInAVerifiedBoxOrForANamedPrompt() {
        for unverified in [state(.unknown), state(.idle, remote: true), state(.busy, remote: true)] {
            // A remote pane whose old status says it is not waiting, on a
            // question with no numbered choices: nothing names it.
            for screen in [DemoPrompt.yesNo, "Overwrite config.json? [y/N] ", DemoPrompt.idle + "\n$ "] {
                let pane = FakePane()
                pane.screen = screen
                pane.cursor = .lastLine
                for key in ["Enter", "1", "9"] {
                    let refused = MobileReply.press(
                        key, prompt: nil, target: "%12", io: pane.io, state: unverified)
                    XCTAssertEqual(refused.status, 409, screen)
                    XCTAssertEqual(
                        body(refused), #"{"error":"no_input","message":"Thread shows no input box"}"#, screen)
                }
                // With nothing to name and no box, no key goes at all.
                XCTAssertEqual(
                    MobileReply.press("Escape", prompt: nil, target: "%12", io: pane.io, state: unverified)
                        .status, 409)
                XCTAssertEqual(pane.argv.count, 0)
            }
            let idle = FakePane()
            XCTAssertEqual(
                MobileReply.press("Enter", prompt: nil, target: "%12", io: idle.io, state: unverified).status,
                200)
        }
        // A first-hand status is held to the same rule: it can be old, and a
        // shell may be in front.
        for status in [AttentionStatus.idle, .busy] {
            let local = FakePane()
            local.screen = "$ "
            XCTAssertEqual(
                MobileReply.press("Enter", prompt: nil, target: "%12", io: local.io, state: state(status))
                    .status, 409)
            XCTAssertEqual(
                MobileReply.press("C-c", prompt: nil, target: "%12", io: local.io, state: state(status))
                    .status, 409)
            XCTAssertEqual(local.argv.count, 0)
        }
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
            // An answered prompt in the scrollback, above the input box.
            DemoPrompt.permission + "\n" + DemoPrompt.idle,
        ] {
            XCTAssertNil(seen(screen).prompt, screen)
        }
        XCTAssertTrue(seen(DemoPrompt.idle).inputBox)
        XCTAssertTrue(seen(DemoPrompt.permission + "\n" + DemoPrompt.idle).inputBox)
        XCTAssertTrue(seen("╭──────╮\n│ > hello │\n╰──────╯").inputBox)
        for screen in ["$ ", "> not in a box", "────\nplain text\n────", DemoPrompt.yesNo] {
            XCTAssertFalse(seen(screen).inputBox, screen)
        }
        // A list someone typed into the box on the Mac is not ours: it counts
        // as a prompt, and nothing is typed over it.
        let typed = seen(DemoPrompt.input("1. one\n2. two"))
        XCTAssertNotNil(typed.prompt)
        XCTAssertFalse(typed.inputBox)
    }

    func testALongCommandIsMarkedAsCutAndKeepsItsStart() throws {
        let long = (1...40).map { "  step-\($0) --flag value --namespace staging --timeout 120s \\" }.joined(separator: "\n")
        let boxed = """
            ╭──────────────╮
            Bash command
            \(long)
            Do you want to proceed?
            ❯ 1. Yes
              2. No
            ╰──────────────╯
            """
        let prompt = try XCTUnwrap(seen(boxed).prompt)
        XCTAssertTrue(prompt.truncated)
        XCTAssertEqual(prompt.title, "Bash command")
        XCTAssertTrue(prompt.detail.hasPrefix("step-1 --flag"))
        XCTAssertEqual(prompt.detail.count, MobileScreen.maxDetailLength)
        XCTAssertEqual(prompt.json["truncated"] as? Bool, true)

        // The top of the box scrolled off the screen: what is here is the end
        // of the command, so it is not shown as a title.
        let headless = (1...80).map { "line \($0)" }.joined(separator: "\n")
            + "\nDo you want to proceed?\n❯ 1. Yes\n  2. No"
        let cut = try XCTUnwrap(seen(headless).prompt)
        XCTAssertTrue(cut.truncated)
        XCTAssertEqual(cut.title, "")
        XCTAssertEqual(cut.question, "Do you want to proceed?")
    }

    func testAnotherPromptHasAnotherId() throws {
        let waiting = state(.waiting, since: 100)
        let io = FakePane().io
        let first = try XCTUnwrap(shown(waiting, DemoPrompt.permission))
        let second = try XCTUnwrap(shown(
            waiting, DemoPrompt.permission.replacingOccurrences(of: "deploy/web", with: "deploy/api")))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, shown(waiting, DemoPrompt.question)?.id)
        // The same words asked again later are another prompt.
        let again = try XCTUnwrap(
            shown(state(.waiting, since: 160), DemoPrompt.permission))
        XCTAssertNotEqual(first.id, again.id)
        XCTAssertEqual(
            first.id, shown(waiting, DemoPrompt.permission)?.id)
        XCTAssertEqual(first.key, again.key)
    }

    func testThePanesCounterTellsTwoPromptsWithTheSameWordsApart() throws {
        // No time on the pane at all, as on a remote host: only the counter.
        var counter = 0
        var seen: String?
        var io = FakePane().io
        io.sequence = { key in
            if let key, key != seen { counter += 1 }
            seen = key
            return counter
        }
        let waiting = state(.waiting, remote: true)
        let first = try XCTUnwrap(shown(waiting, DemoPrompt.permission, io: io))
        // Read again while it is still there: the same prompt.
        XCTAssertEqual(first.id, shown(waiting, DemoPrompt.permission, io: io)?.id)
        // Answered: the counter is told, and the same words are a new prompt.
        var answering = FakePane()
        answering.screen = DemoPrompt.permission
        var answerIO = answering.io
        answerIO.sequence = io.sequence
        XCTAssertEqual(
            MobileReply.answer(prompt: first.id, option: 1, target: "%12", io: answerIO, state: waiting).status,
            200)
        XCTAssertNil(seen)
        let second = try XCTUnwrap(shown(waiting, DemoPrompt.permission, io: io))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.key, second.key)
        // Enter on the card's prompt answers it too; an arrow does not.
        answering = FakePane()
        answering.screen = DemoPrompt.permission
        answerIO = answering.io
        answerIO.sequence = io.sequence
        XCTAssertEqual(
            MobileReply.press("Down", prompt: second.id, target: "%12", io: answerIO, state: waiting).status, 200)
        XCTAssertNotNil(seen)
        XCTAssertEqual(
            MobileReply.press("Enter", prompt: second.id, target: "%12", io: answerIO, state: waiting).status, 200)
        XCTAssertNil(seen)
    }

    func testThePromptIsWhatTheScreenShowsWhateverTheStatusSays() {
        let io = FakePane().io
        for status in [AttentionStatus.waiting, .unknown, .idle, .busy] {
            XCTAssertNotNil(shown(state(status), DemoPrompt.permission))
        }
        XCTAssertNil(shown(nil, DemoPrompt.permission))
        XCTAssertNil(shown(state(.waiting), nil))
        // An old prompt above the input box of a pane that moved on is none.
        XCTAssertNil(MobileReply.prompt(
            state: state(.idle), seen: seen(DemoPrompt.permission + "\n" + DemoPrompt.idle),
            io: FakePane().io))
    }

    func testAnAnswerIsTheDigitOfAChoiceOnThePaneNow() throws {
        let pane = FakePane()
        pane.screen = DemoPrompt.permission
        let waiting = state(.waiting, since: 100)
        let id = try XCTUnwrap(shown(waiting, DemoPrompt.permission, io: pane.io)).id
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 2, target: "%12", io: pane.io, state: waiting).status, 200)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "2"]])

        // A choice the prompt does not have.
        for option in [0, 4, 9, -1, 12] {
            XCTAssertEqual(
                MobileReply.answer(prompt: id, option: option, target: "%12", io: pane.io, state: waiting)
                    .status, 400)
        }
        // Another prompt took its place: the tap answers nothing.
        pane.screen = DemoPrompt.question
        let stale = MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, state: waiting)
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(body(stale), #"{"error":"stale"}"#)
        // The same words, asked again after the first was answered.
        pane.screen = DemoPrompt.permission
        XCTAssertEqual(
            MobileReply.answer(
                prompt: id, option: 1, target: "%12", io: pane.io, state: state(.waiting, since: 160)).status,
            409)
        // The pane moved on, or cannot be read.
        pane.screen = DemoPrompt.idle
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, state: state(.busy)).status,
            409)
        pane.screen = nil
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, state: waiting).status, 409)
        XCTAssertEqual(
            MobileReply.answer(prompt: id, option: 1, target: "%12", io: pane.io, state: nil).status, 404)
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
        XCTAssertEqual(MobileReply.numbered("photo.png", 2), "photo-2.png")
        XCTAssertEqual(MobileReply.numbered("notes", 3), "notes-3")
    }

    func testAFileNameIsCutByBytesNotCharacters() {
        let long = MobileReply.fileName(String(repeating: "a", count: 300) + ".png") ?? ""
        XCTAssertEqual(long.utf8.count, MobileReply.maxFileNameBytes)
        XCTAssertTrue(long.hasSuffix(".png"))
        // 200 characters of three bytes each fit a character cap and not a disk.
        let wide = MobileReply.fileName(String(repeating: "界", count: 200) + ".png") ?? ""
        XCTAssertLessThanOrEqual(wide.utf8.count, MobileReply.maxFileNameBytes)
        XCTAssertTrue(wide.hasSuffix(".png"))
        XCTAssertTrue(wide.hasPrefix("界"))
        // Cut between characters, never inside one.
        XCTAssertFalse(wide.unicodeScalars.contains("\u{FFFD}"))
        // With the number a taken name gets, still within 255 bytes.
        XCTAssertLessThanOrEqual(MobileReply.numbered(wide, 99).utf8.count, 255)
        let noExtension = MobileReply.fileName(String(repeating: "é", count: 300)) ?? ""
        XCTAssertLessThanOrEqual(noExtension.utf8.count, MobileReply.maxFileNameBytes)
    }

    func testAnUploadLandsInTheThreadsDirectoryAndItsPathIsPasted() {
        let pane = FakePane()
        let data = Data("demo".utf8)
        let response = MobileReply.upload(
            data, name: "../../etc/photo 1.png", thread: thread(), io: pane.io, limit: 1024,
            state: { self.state(.idle) })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            body(response), #"{"ok":true,"pasted":true,"path":"\/Users\/me\/acme-app\/photo-1.png"}"#)
        XCTAssertEqual(pane.saves.map(\.path), ["/Users/me/acme-app/photo-1.png"])
        XCTAssertEqual(pane.saves.first?.data, data)
        // The path is pasted, bracketed, and not submitted.
        XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
        XCTAssertEqual(pane.calls[1].stdin, "/Users/me/acme-app/photo-1.png ")
        XCTAssertEqual(Array(pane.argv[2].prefix(4)), ["paste-buffer", "-p", "-r", "-d"])
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
    }

    func testAPathWithMoreThanPlainCharactersIsPastedQuoted() {
        XCTAssertEqual(MobileReply.pasted(path: "/Users/me/acme-app/a_b-1.png"), "/Users/me/acme-app/a_b-1.png")
        XCTAssertEqual(MobileReply.pasted(path: "/Users/me/my app/a.png"), "'/Users/me/my app/a.png'")
        XCTAssertEqual(MobileReply.pasted(path: "/Users/me/it's/a.png"), #"'/Users/me/it'\''s/a.png'"#)
        XCTAssertEqual(MobileReply.pasted(path: "/Users/me/$(x)/a.png"), "'/Users/me/$(x)/a.png'")
        let pane = FakePane()
        _ = MobileReply.upload(
            Data("x".utf8), name: "a.png", thread: thread(cwd: "/Users/me/my app"), io: pane.io,
            limit: 1024, state: { self.state(.idle) })
        XCTAssertEqual(pane.calls[1].stdin, "'/Users/me/my app/a.png' ")
    }

    func testAnUploadNeverOverwritesAFile() {
        let pane = FakePane()
        pane.existing = ["/Users/me/acme-app/package.json", "/Users/me/acme-app/package-2.json"]
        let response = MobileReply.upload(
            Data("{}".utf8), name: "package.json", thread: thread(), io: pane.io, limit: 1024,
            state: { self.state(.idle) })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(pane.saves.map(\.path), ["/Users/me/acme-app/package-3.json"])

        // A save that fails is an error: it is never read as "the name is free".
        let down = FakePane()
        down.failing = true
        let failed = MobileReply.upload(
            Data("{}".utf8), name: "package.json", thread: thread(), io: down.io, limit: 1024,
            state: { self.state(.idle) })
        XCTAssertEqual(failed.status, 503)
        XCTAssertEqual(down.saves.count, 0)
    }

    func testAnExclusiveCreateWritesThroughNoLinkAndOverNoFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func path(_ name: String) -> String { root.appendingPathComponent(name).path }
        let data = Data("demo".utf8)

        XCTAssertEqual(FileTransfer.writeExclusive(data, to: path("new.txt")), .saved)
        XCTAssertEqual(FileManager.default.contents(atPath: path("new.txt")), data)

        // A file with that name is left as it is.
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path("taken.txt")))
        XCTAssertEqual(FileTransfer.writeExclusive(data, to: path("taken.txt")), .exists)
        XCTAssertEqual(FileManager.default.contents(atPath: path("taken.txt")), Data("keep".utf8))

        // A link to a file that does not exist yet: a plain create would
        // follow it and make the target.
        let target = path("outside.txt")
        try FileManager.default.createSymbolicLink(atPath: path("dangling"), withDestinationPath: target)
        XCTAssertEqual(FileTransfer.writeExclusive(data, to: path("dangling")), .exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))

        // A link to a file that exists: the file is not written.
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: path("taken.txt"))
        XCTAssertEqual(FileTransfer.writeExclusive(data, to: path("link")), .exists)
        XCTAssertEqual(FileManager.default.contents(atPath: path("taken.txt")), Data("keep".utf8))

        // No such folder is a failure, not a free name.
        XCTAssertEqual(FileTransfer.writeExclusive(data, to: path("missing/a.txt")), .failed)

        // The upload steps past the link to the next name.
        let pane = FakePane()
        var io = pane.io
        io.save = FileTransfer.writeExclusive
        let response = MobileReply.upload(
            data, name: "dangling", thread: thread(cwd: root.path), io: io, limit: 1024,
            state: { self.state(.idle) })
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(FileManager.default.contents(atPath: path("dangling-2")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testTheRemoteCreateIsExclusiveAndAFailedSshIsNotAFreeName() throws {
        let (ssh, args) = FileTransfer.exclusiveWriteArgv(alias: "devbox", path: "/home/me/acme app/a'b.png")
        XCTAssertEqual(ssh, Ssh.sshPath)
        XCTAssertEqual(Array(args.dropLast()), Ssh.opts(host: "devbox"))
        let command = try XCTUnwrap(args.last)
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        // `set -C` makes `>` an exclusive create.
        XCTAssertTrue(command.contains("set -C; : > \"$p\""))
        // The path is one quoted word; it is never spliced into the script bare.
        XCTAssertFalse(command.contains("acme app/a'b.png"))

        XCTAssertEqual(FileTransfer.saved(remoteOutput: "saved\n"), .saved)
        XCTAssertEqual(FileTransfer.saved(remoteOutput: "exists\n"), .exists)
        // ssh could not connect: no output. That is a failure, not "no file".
        XCTAssertEqual(FileTransfer.saved(remoteOutput: nil), .failed)
        XCTAssertEqual(FileTransfer.saved(remoteOutput: ""), .failed)
        XCTAssertEqual(FileTransfer.saved(remoteOutput: "failed"), .failed)
    }

    func testTheRemoteCreateScriptRefusesATakenNameAndADanglingLink() throws {
        // The script itself, run by this Mac's `sh` on a scratch folder.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ name: String) throws -> FileTransfer.Saved {
            let path = root.appendingPathComponent(name).path
            let command = try XCTUnwrap(FileTransfer.exclusiveWriteArgv(alias: "devbox", path: path).args.last)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data("demo".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return FileTransfer.saved(remoteOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        XCTAssertEqual(try run("it's new.txt"), .saved)
        XCTAssertEqual(
            FileManager.default.contents(atPath: root.appendingPathComponent("it's new.txt").path),
            Data("demo".utf8))
        XCTAssertEqual(try run("it's new.txt"), .exists)
        let target = root.appendingPathComponent("outside.txt").path
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dangling").path, withDestinationPath: target)
        XCTAssertEqual(try run("dangling"), .exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertEqual(try run("missing/a.txt"), .failed)
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
                data, name: name, thread: thread(cwd: cwd), io: pane.io, limit: 1024,
                state: { status.map { self.state($0) } })
            XCTAssertEqual(response.status, expected, "\(name) \(String(describing: status)) \(cwd)")
            XCTAssertEqual(pane.saves.count, 0)
            XCTAssertEqual(pane.argv.count, 0)
        }
        // A prompt on the screen of a pane whose status says idle.
        let asking = FakePane()
        asking.screen = DemoPrompt.permission
        XCTAssertEqual(
            MobileReply.upload(
                Data("x".utf8), name: "a.png", thread: thread(), io: asking.io, limit: 1024,
                state: { self.state(.idle, remote: true) }).status, 409)
        XCTAssertEqual(asking.saves.count, 0)
        // Settings cannot raise the limit past what the server holds in memory.
        XCTAssertEqual(
            MobileReply.upload(
                Data(count: MobileReply.maxUploadBytes + 1), name: "a.bin", thread: thread(),
                io: FakePane().io, limit: .max, state: { self.state(.idle) }).status, 413)
    }

    func testAPromptThatComesUpDuringAnUploadGetsNoPaste() {
        let pane = FakePane()
        var asked = 0
        let response = MobileReply.upload(
            Data("x".utf8), name: "a.png", thread: thread(), io: pane.io, limit: 1024,
            state: { asked += 1; return self.state(asked == 1 ? .idle : .waiting) })
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(body(response).contains(#""pasted":false"#))
        XCTAssertEqual(pane.saves.count, 1)
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
