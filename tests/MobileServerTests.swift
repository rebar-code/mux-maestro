import Network
import XCTest

// MobileServer.swift compiles into this test target and is driven over a real
// loopback socket: the listener, keep-alive, the auth and capability gates, the
// static bundle and the event stream are asserted as a phone would see them.
final class MobileServerTests: XCTestCase {
    private let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")
    private var server: MobileServer!
    private var port = 0
    private var root: URL!
    private var transcript: URL!
    /// The agent has written no transcript file yet.
    private var noTranscript = false
    /// The transcript of a later session in the same pane.
    private var laterTranscript: URL?
    /// The copy of a Codex rollout: what the source answers for a Codex thread.
    private var codexTranscript: URL?
    private let manager = FakeManager()
    private let pane = FakePane()
    private let tmux = FakeTmux()
    private let changes = Counter()
    private let archives = Counter()
    private let local = FakeLocal()
    private let pushTransport = FakePushTransport()
    private lazy var push = MobilePushCenter(
        keys: MemoryTokenStore(), store: MemoryTokenStore(), transport: pushTransport)
    private var home: URL { root.appendingPathComponent("home") }
    /// The request list the server reads and writes.
    private var requestsFile: URL { root.appendingPathComponent(RequestTracker.fileName) }
    private static let requestList = """
    {
      "schema": 2,
      "updated": "2026-10-03T16:20:00Z",
      "requests": [
        { "id": "req-002", "title": "Dark mode", "project": "acme-app", "state": "in_progress",
          "history": [{ "at": "2026-10-03", "by": "me", "verbatim": "dark mode please" }] },
        { "id": "req-001", "title": "Nightly backup", "project": "devbox", "state": "todo",
          "history": [
            { "at": "2026-10-02", "by": "me", "verbatim": "back devbox up every night" },
            { "at": "2026-10-03", "by": "maestro", "note": "Set it weekly by mistake. Now nightly." }
          ] }
      ]
    }

    """

    /// The manager pane, scripted. The server calls it from its own queues.
    private final class FakeManager {
        private let lock = NSLock()
        private var _status = MobileManagerStatus.idle
        private var _sent: [String] = []
        private var _queued: [Bool] = []
        private var _dismissed: [String] = []
        private var _answered: [String] = []
        /// What a turn says: the deltas, then the outcome.
        var script: (deltas: [String], outcome: ManagerTurnOutcome) = ([], .done(reply: ""))
        var transcript: String?
        /// When set, a turn says nothing until this is signalled.
        var gate: DispatchSemaphore?
        private var _screen: String? = "$ claude\n\u{1B}[32m⏺\u{1B}[0m Ready.\n\n\n"
        /// What the manager pane shows.
        var screen: String? {
            get { lock.lock(); defer { lock.unlock() }; return _screen }
            set { lock.lock(); _screen = newValue; lock.unlock() }
        }

        /// The manager's own pane, for a prompt it waits on.
        let pane = FakePane()

        var status: MobileManagerStatus {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); _status = newValue; lock.unlock() }
        }
        var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
        /// For each text sent, whether a busy pane was to hold it.
        var queued: [Bool] { lock.lock(); defer { lock.unlock() }; return _queued }
        var dismissed: [String] { lock.lock(); defer { lock.unlock() }; return _dismissed }
        /// Each answer the server recorded, as "key=label".
        var answered: [String] { lock.lock(); defer { lock.unlock() }; return _answered }

        var source: MobileServer.Manager {
            MobileServer.Manager(
                pane: { [self] in (status, transcript) },
                send: { [self] text, queue, onDelta, completion in
                    lock.lock(); _sent.append(text); _queued.append(queue); lock.unlock()
                    DispatchQueue.global().async { [self] in
                        gate?.wait()
                        script.deltas.forEach(onDelta)
                        completion(script.outcome)
                    }
                },
                dismiss: { [self] key in lock.lock(); _dismissed.append(key); lock.unlock() },
                answered: { [self] key, label, _ in
                    lock.lock(); _answered.append("\(key)=\(label)"); lock.unlock()
                },
                screen: { [self] _ in screen },
                io: { [self] in ("mux-manager", pane.io) },
                cwd: { "/Users/me/Library/Application Support/MuxMaestro/manager" })
        }
    }
    /// What the fake pane shows, and the line counts the server asked it for.
    private var screenText = "$ make test\n\u{1B}[32mok\u{1B}[0m\n\n\n"
    private var askedLines: [Int] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("_app/immutable"), withIntermediateDirectories: true)
        try Data("<html>shell</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8)
            .write(to: root.appendingPathComponent("_app/immutable/a.js"))
        transcript = root.appendingPathComponent("c1.jsonl")
        try Data((#"{"type":"user","message":{"role":"user","content":"hello"}}"# + "\n").utf8)
            .write(to: transcript)

        server = makeServer()
        start(server)
    }

    private func makeServer(
        limits: MobileServer.Limits = MobileServer.Limits(), withLocal: Bool = true
    ) -> MobileServer {
        let transcript = transcript!
        return MobileServer(staticRoot: root, sources: MobileServer.Sources(
            screen: { [weak self] thread, lines in
                self?.askedLines.append(lines)
                return thread.pane == "%12" ? (self?.screenText ?? "") : nil
            },
            transcript: { [weak self] thread in
                if thread.codexSessionId != nil, let codex = self?.codexTranscript { return (codex.path, true) }
                return self?.noTranscript == true ? nil : ((self?.laterTranscript ?? transcript).path, false)
            },
            pane: { [pane] _ in pane.io }, tmux: tmux.source,
            archive: { [archives] thread in
                archives.add()
                return thread.pane == "%12"
            },
            changed: { [changes] in changes.add() }, home: home.path,
            artifacts: withLocal ? local.artifactSource : nil,
            running: withLocal ? local.runningSource : nil),
            limits: limits, manager: manager.source,
            requests: withLocal ? RequestTracker(url: requestsFile, author: "me") : nil,
            serving: withLocal ? local.serving : nil,
            push: withLocal ? push : nil)
    }

    private func start(_ server: MobileServer) {
        let started = expectation(description: "listening")
        server.start(port: 0, identity: identity, token: "demo-token") { result in
            if case .success(let bound) = result { self.port = bound }
            started.fulfill()
        }
        wait(for: [started], timeout: 5)
        XCTAssertGreaterThan(port, 0)
        server.update(snapshot())
    }

    /// Swap the default server for one with tight limits.
    private func restart(limits: MobileServer.Limits) {
        server.stop()
        server = makeServer(limits: limits)
        start(server)
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(
        status: AttentionStatus = .busy, cwd: String = "/Users/me/acme-app"
    ) -> MobileSnapshot {
        var agent = TmuxPane(id: "%12", index: 0, command: "claude", title: "", active: true)
        agent.claudeSessionId = "c1"
        agent.attention = status
        agent.path = cwd
        let shell = TmuxPane(id: "%13", index: 0, command: "zsh", title: "", active: true)
        return MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: "acme-app", attached: true, id: "$1", windows: [
                TmuxWindow(index: 1, name: "checkout-fix", active: true, panes: [agent]),
                TmuxWindow(index: 2, name: "shell", active: false, panes: [shell]),
            ])])])
    }

    // MARK: client

    /// Send `raw` and read until `done` says the reply is whole (or 5 s pass).
    private func exchange(_ raw: String, until done: @escaping (String) -> Bool) -> String {
        let reply = LoopbackClient.exchange(
            port: port, send: Data(raw.utf8), label: "mobile-server-tests"
        ) { done(String(decoding: $0, as: UTF8.self)) }
        return String(decoding: reply, as: UTF8.self)
    }

    private func whole(_ text: String) -> Bool {
        guard let head = text.range(of: "\r\n\r\n") else { return false }
        let length = text[..<head.lowerBound].components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return text[head.upperBound...].utf8.count >= length
    }

    private func get(
        _ path: String, method: String = "GET", login: String? = "me@example.com",
        host: String = "devmac.example.ts.net:7433", token: String? = "demo-token"
    ) -> (status: Int, head: String, body: String) {
        var raw = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        if let login { raw += "Tailscale-User-Login: \(login)\r\n" }
        if let token { raw += "X-MuxMaestro-Token: \(token)\r\n" }
        raw += "\r\n"
        let text = exchange(raw, until: whole)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, parts.first ?? "", parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    private static let origin = "https://devmac.example.ts.net:7433"

    /// A POST as the app sends it; drop `origin` or `writeHeader` to be a page
    /// from somewhere else.
    private func post(
        _ path: String, json: String, origin: String? = origin, writeHeader: Bool = true,
        token: String? = "demo-token", until done: ((String) -> Bool)? = nil
    ) -> (status: Int, head: String, body: String) {
        var raw = "POST \(path) HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
            + "Tailscale-User-Login: me@example.com\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(json.utf8.count)\r\n"
        if let origin { raw += "Origin: \(origin)\r\n" }
        if writeHeader { raw += "X-MuxMaestro: 1\r\n" }
        if let token { raw += "X-MuxMaestro-Token: \(token)\r\n" }
        raw += "\r\n" + json
        let text = exchange(raw, until: done ?? whole)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, parts.first ?? "", parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func managerOn() {
        server.configure(MobileConfig(capabilities: [.manager]))
    }

    // MARK: push

    private func eventually(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { usleep(20_000) }
        XCTAssertTrue(condition(), what)
    }

    func testPushRoutesNeedTheSwitchTheTokenAndASameOriginWrite() {
        let phone = String(decoding: FakePhone().body, as: UTF8.self)
        let writes = ["/api/push/subscribe", "/api/push/unsubscribe", "/api/push/focus"]

        // Off until Settings turns it on, for every route under /api/push.
        XCTAssertEqual(get("/api/push/key").body, #"{"error":"disabled"}"#)
        XCTAssertEqual(get("/api/push/key").status, 403)
        for path in writes + ["/api/push/anything"] {
            XCTAssertEqual(post(path, json: phone).status, 403, path)
            XCTAssertEqual(post(path, json: phone).body, #"{"error":"disabled"}"#, path)
        }
        XCTAssertEqual(push.count, 0)

        server.configure(MobileConfig(capabilities: [.notifications]))
        XCTAssertEqual(get("/api/push/key", token: nil).status, 401)
        XCTAssertEqual(get("/api/push/key", token: "wrong").status, 401)
        XCTAssertEqual(get("/api/push/key", login: "other@example.com").status, 403)
        for path in writes {
            XCTAssertEqual(post(path, json: phone, token: nil).status, 401, path)
            XCTAssertEqual(post(path, json: phone, writeHeader: false).status, 403, path)
            for origin in [nil, "https://evil.example", "https://devmac.example.ts.net:8443",
                           "https://devmac.example.ts.net", "http://devmac.example.ts.net:7433"] {
                let refused = post(path, json: phone, origin: origin)
                XCTAssertEqual(refused.status, 403, "\(path) \(origin ?? "none")")
                XCTAssertEqual(refused.body, #"{"error":"forbidden"}"#)
            }
            XCTAssertEqual(get(path).status, 405, path)
        }
        XCTAssertEqual(post("/api/push/key", json: "{}").status, 405)
        XCTAssertEqual(push.count, 0)

        let key = get("/api/push/key")
        XCTAssertEqual(key.status, 200)
        XCTAssertTrue(key.body.hasPrefix(#"{"key":"B"#))
        XCTAssertEqual(post("/api/push/subscribe", json: phone).status, 200)
        XCTAssertEqual(push.count, 1)
        XCTAssertEqual(
            post("/api/push/subscribe", json: #"{"endpoint":"https://127.0.0.1/x","keys":{}}"#).body,
            #"{"error":"bad_subscription"}"#)
        XCTAssertEqual(post("/api/push/unsubscribe", json: phone).status, 200)
        XCTAssertEqual(push.count, 0)
    }

    func testPushRoutesAnswer503WhereNothingIsSent() {
        server.stop()
        server = makeServer(withLocal: false)
        start(server)
        server.configure(MobileConfig(capabilities: [.notifications]))
        XCTAssertEqual(get("/api/push/key").status, 503)
    }

    func testAThreadThatStartsToWaitOrFinishesNotifiesThePhoneOnce() {
        let phone = FakePhone()
        let body = String(decoding: phone.body, as: UTF8.self)
        server.configure(MobileConfig(capabilities: [.notifications]))
        XCTAssertEqual(post("/api/push/subscribe", json: body).status, 200)

        // The tree as it was at the start (busy) sent nothing.
        server.update(snapshot(status: .waiting))
        eventually("one push") { pushTransport.requests.count == 1 }
        server.update(snapshot(status: .waiting))
        server.update(snapshot(status: .busy))
        server.update(snapshot(status: .idle))
        eventually("a second push") { pushTransport.requests.count == 2 }
        XCTAssertEqual(
            pushTransport.requests.compactMap { try? phone.open($0)["kind"] as? String }, ["waiting", "done"])
        XCTAssertEqual(try? phone.open(pushTransport.requests[0])["thread"] as? String, "localhost:12")

        // The phone shows the thread: nothing for it.
        let focus = String(decoding: phone.focus("localhost:12"), as: UTF8.self)
        XCTAssertEqual(post("/api/push/focus", json: focus).status, 200)
        server.update(snapshot(status: .waiting))
        // The switch is off: nothing at all, and nothing old when it comes back.
        server.configure(MobileConfig())
        server.update(snapshot(status: .busy))
        server.update(snapshot(status: .waiting))
        server.configure(MobileConfig(capabilities: [.notifications]))
        server.update(snapshot(status: .waiting))
        XCTAssertEqual(get("/api/push/key").status, 200)
        usleep(200_000)
        XCTAssertEqual(pushTransport.requests.count, 2)
    }

    func testANewPairingCodeForgetsThePhones() {
        server.configure(MobileConfig(capabilities: [.notifications]))
        let body = String(decoding: FakePhone().body, as: UTF8.self)
        XCTAssertEqual(post("/api/push/subscribe", json: body).status, 200)
        XCTAssertEqual(push.count, 1)
        server.setToken("next-token")
        eventually("forgotten") { push.count == 0 }
    }

    // MARK: tests

    func testRefusesEveryRequestWithoutThisMacsIdentity() {
        XCTAssertEqual(get("/api/threads", login: nil).status, 403)
        XCTAssertEqual(get("/api/threads", login: "other@example.com").status, 403)
        XCTAssertEqual(get("/", login: nil).status, 403)
        // The right login under another name: a rebinding page, or plain loopback.
        let rebound = get("/api/threads", host: "127.0.0.1:\(port)")
        XCTAssertEqual(rebound.status, 403)
        XCTAssertEqual(rebound.body, #"{"error":"forbidden"}"#)
    }

    func testTheAPINeedsThePairingTokenAndTheBundleDoesNot() {
        // The right login and host are public values; without the token they
        // are not enough.
        for path in ["/api/threads", "/api/hosts", "/api/config", "/api/events",
                     "/api/threads/localhost%3A12/chat", "/api/threads/localhost%3A12/screen",
                     "/api/manager"] {
            let refused = get(path, token: nil)
            XCTAssertEqual(refused.status, 401, path)
            XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#, path)
            XCTAssertEqual(get(path, token: "wrong-token").status, 401, path)
        }
        XCTAssertEqual(get("/", token: nil).status, 200)
        XCTAssertEqual(get("/_app/immutable/a.js", token: nil).status, 200)
        // The token never replaces the identity check.
        XCTAssertEqual(get("/api/threads", login: nil).status, 403)
    }

    func testANewTokenSignsTheOldOneOutAndClosesItsStream() {
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        var rotated = false
        // The exchange ends when the server closes the stream.
        let text = exchange(raw) { [self] received in
            if !rotated, received.contains("event: hosts") {
                rotated = true
                server.setToken("next-token")
            }
            return false
        }
        XCTAssertTrue(text.contains("event: hosts"))
        XCTAssertEqual(get("/api/threads").status, 401)
        XCTAssertEqual(get("/api/threads", token: "next-token").status, 200)
    }

    func testOneConnectionOverTheCapIsClosed() {
        restart(limits: MobileServer.Limits(maxConnections: 2))
        let held = (0..<2).map { _ -> NWConnection in
            let connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            let ready = expectation(description: "connected")
            connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            connection.start(queue: .global())
            wait(for: [ready], timeout: 5)
            return connection
        }
        // Let the listener register both before the third arrives.
        usleep(200_000)
        XCTAssertEqual(get("/api/threads").status, 0)
        held.forEach { $0.cancel() }
        usleep(200_000)
        XCTAssertEqual(get("/api/threads").status, 200)
    }

    func testAnIdleConnectionIsClosedAndAStreamIsNot() {
        restart(limits: MobileServer.Limits(idleTimeout: 0.2))
        let idle = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let closed = expectation(description: "idle connection closed")
        idle.start(queue: .global())
        idle.receive(minimumIncompleteLength: 1, maximumLength: 16) { _, _, complete, error in
            if complete || error != nil { closed.fulfill() }
        }
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        var waited = false
        let text = exchange(raw) { [self] received in
            if !waited, received.contains("event: hosts") {
                waited = true
                usleep(400_000)
                // The sweep runs with the tree update; the stream outlives it.
                server.update(snapshot(status: .waiting))
            }
            return received.contains(#""status":"waiting""#)
        }
        wait(for: [closed], timeout: 5)
        XCTAssertTrue(text.contains(#""status":"waiting""#))
    }

    func testAStreamOverItsBacklogIsClosed() {
        // Smaller than one event: the first write is already over the limit.
        restart(limits: MobileServer.Limits(streamBacklog: 16))
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        let started = Date()
        let text = exchange(raw) { _ in false }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertFalse(text.contains("event: threads"))
    }

    func testServesThreadsHostsAndConfig() throws {
        let threads = get("/api/threads")
        XCTAssertEqual(threads.status, 200)
        XCTAssertTrue(threads.head.contains("Cache-Control: no-store"))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(threads.body.utf8)) as? [String: Any])
        XCTAssertEqual(
            (body["threads"] as? [[String: Any]])?.map { $0["id"] as? String },
            ["localhost:12", "localhost:13"])
        XCTAssertTrue(get("/api/hosts").body.contains(#""name":"localhost""#))
        let config = get("/api/config")
        XCTAssertEqual(config.status, 200)
        XCTAssertTrue(config.body.contains(#""grouping":"recent""#))
        XCTAssertTrue(config.body.contains(#""replies":false"#))
    }

    func testADisabledFeatureAnswers403UntilItsSwitchIsOn() {
        let refused = get("/api/terminal/localhost%3A12")
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(refused.body, #"{"error":"disabled"}"#)
        XCTAssertEqual(get("/api/manager").status, 403)

        server.configure(MobileConfig(capabilities: [.liveTerminal], grouping: .host))
        // On: past the gate. The route is a WebSocket, so a plain request
        // is told to upgrade and is given nothing.
        XCTAssertEqual(get("/api/terminal/localhost%3A12").status, 426)
        XCTAssertEqual(get("/api/manager").status, 403)
        XCTAssertTrue(get("/api/config").body.contains(#""liveTerminal":true"#))
    }

    func testARemoteClaudeThreadAndARemoteCodexThreadHaveChat() throws {
        // The copy of the remote rollout, named as `RemoteTranscriptMirror` names it.
        let rollout = root.appendingPathComponent("codex.x1.jsonl")
        try Data((#"{"timestamp":"2026-10-02T10:00:05.000Z","type":"response_item","payload":"#
            + #"{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the build"}]}}"#
            + "\n").utf8).write(to: rollout)
        codexTranscript = rollout
        var claude = TmuxPane(id: "%3", index: 0, command: "claude", title: "", active: true)
        claude.claudeSessionId = "r1"
        var codex = TmuxPane(id: "%4", index: 0, command: "codex", title: "", active: true)
        codex.codexSessionId = "x1"
        server.update(MobileSnapshot.build([MobileHostInput(
            host: Host(name: "devbox", sshAlias: "devbox"), colorHex: "#f5a623", reachability: .reachable,
            stats: nil,
            sessions: [TmuxSession(name: "infra", attached: false, id: "$1", windows: [
                TmuxWindow(index: 0, name: "api", active: true, panes: [claude]),
                TmuxWindow(index: 1, name: "worker", active: false, panes: [codex]),
            ])])]))
        // The source answers the copy of the remote transcript: read like a local one.
        let chat = get("/api/threads/devbox%3A3/chat")
        XCTAssertEqual(chat.status, 200)
        XCTAssertTrue(chat.body.contains(#""text":"hello""#))
        XCTAssertTrue(chat.body.contains(#""session":"c1""#))
        let codexChat = get("/api/threads/devbox%3A4/chat")
        XCTAssertEqual(codexChat.status, 200)
        XCTAssertTrue(codexChat.body.contains(#""text":"fix the build""#), codexChat.body)
        XCTAssertTrue(codexChat.body.contains(#""session":"codex.x1""#), codexChat.body)
        XCTAssertFalse(get("/api/threads").body.contains(#""chat":false"#))
    }

    func testServesChatAndScreenAndA404ForAStaleId() {
        let chat = get("/api/threads/localhost%3A12/chat")
        XCTAssertEqual(chat.status, 200)
        XCTAssertTrue(chat.body.contains(#""text":"hello""#))
        // Colour escapes pass through; trailing blank rows of the pane are cut.
        let screen = get("/api/threads/localhost%3A12/screen")
        XCTAssertEqual(
            screen.body,
            #"{"lines":2000,"max":10000,"text":"$ make test\n\u001b[32mok\u001b[0m"}"#)
        XCTAssertTrue(screen.head.contains("ETag: \""))
        // A shell has a screen and no chat.
        XCTAssertEqual(get("/api/threads/localhost%3A13/chat").status, 404)
        XCTAssertEqual(get("/api/threads/localhost%3A13/screen").status, 503)
        XCTAssertEqual(get("/api/threads/localhost%3A99/screen").status, 404)
        XCTAssertEqual(get("/api/threads/localhost%3A99/chat").status, 404)
        XCTAssertEqual(get("/api/threads", method: "POST").status, 403)
    }

    private func chatPage(_ query: String = "") throws -> [String: Any] {
        let chat = get("/api/threads/localhost%3A12/chat" + query)
        XCTAssertEqual(chat.status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chat.body.utf8)) as? [String: Any])
    }

    private func texts(_ page: [String: Any]) -> [String] {
        (page["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    func testChatFollowsASecondSessionInTheSamePane() throws {
        let first = try chatPage()
        XCTAssertEqual(texts(first), ["hello"])
        XCTAssertEqual(first["session"] as? String, "c1")
        let next = try XCTUnwrap(first["next"] as? Int)

        // The agent starts again in the pane (`/clear`, a crash, a new run):
        // a new transcript, here longer than the cursor into the old one.
        let later = root.appendingPathComponent("c2.jsonl")
        let lines = ["first of the new session", "second of the new session"].map {
            #"{"type":"user","message":{"role":"user","content":"\#($0)"}}"# + "\n"
        }
        try Data(lines.joined().utf8).write(to: later)
        laterTranscript = later

        // The cursor is a place in the old file. The new one is read from its
        // start, and the phone is told to drop the old conversation.
        let moved = try chatPage("?after=\(next)&session=c1")
        XCTAssertEqual(moved["reset"] as? Bool, true)
        XCTAssertEqual(texts(moved), ["first of the new session", "second of the new session"])
        XCTAssertEqual(moved["session"] as? String, "c2")

        // From there the cursor works as before.
        let after = try XCTUnwrap(moved["next"] as? Int)
        let quiet = try chatPage("?after=\(after)&session=c2")
        XCTAssertEqual(quiet["reset"] as? Bool, false)
        XCTAssertEqual(texts(quiet), [])
    }

    func testANewSessionWithNoTranscriptYetEmptiesTheChat() throws {
        let first = try chatPage()
        let next = try XCTUnwrap(first["next"] as? Int)
        noTranscript = true
        let moved = try chatPage("?after=\(next)&session=c1")
        XCTAssertEqual(moved["reset"] as? Bool, true)
        XCTAssertEqual(texts(moved), [])
        // Its first message then arrives as a new conversation.
        noTranscript = false
        let started = try chatPage("?after=0&session=")
        XCTAssertEqual(started["reset"] as? Bool, true)
        XCTAssertEqual(texts(started), ["hello"])
    }

    func testASlashCommandTheUserSentIsAChatRow() throws {
        let command = "<command-message>review</command-message>\\n<command-name>/review</command-name>\\n"
            + "<command-args>did we answer the last email?</command-args>"
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"user","message":{"role":"user","content":"\#(command)"}}"# + "\n").utf8))
        try handle.close()
        XCTAssertEqual(texts(try chatPage()), ["hello", "/review did we answer the last email?"])
    }

    func testAnAgentWithNoTranscriptYetHasAnEmptyChat() {
        // Claude has its session id at once; its transcript file comes with
        // the first message.
        noTranscript = true
        let chat = get("/api/threads/localhost%3A12/chat")
        XCTAssertEqual(chat.status, 200)
        XCTAssertEqual(chat.body, #"{"messages":[],"next":0,"reset":false}"#)
        XCTAssertEqual(get("/api/threads/localhost%3A13/chat").status, 404)
        XCTAssertEqual(get("/api/threads/localhost%3A99/chat").status, 404)
    }

    func testAnAgentThePhoneStartedHasChatBeforeItHasASessionId() throws {
        actionsOn()
        noTranscript = true
        // The new window's pane is %13: a shell until the agent is up.
        tmux.output = "2\t%13\n"
        XCTAssertEqual(get("/api/threads/localhost%3A13/chat").status, 404)
        let made = post("/api/tmux/new-window", json: #"{"thread":"localhost:12","agent":"codex"}"#)
        XCTAssertEqual(made.status, 200)
        server.update(snapshot())
        let chat = get("/api/threads/localhost%3A13/chat")
        XCTAssertEqual(chat.status, 200)
        XCTAssertEqual(chat.body, #"{"messages":[],"next":0,"reset":false}"#)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get("/api/threads").body.utf8)) as? [String: Any])
        let threads = try XCTUnwrap(body["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.map { $0["chat"] as? Bool }, [true, true])
    }

    func testScreenLinesReachThePaneClamped() {
        _ = get("/api/threads/localhost%3A12/screen")
        _ = get("/api/threads/localhost%3A12/screen?lines=4000")
        _ = get("/api/threads/localhost%3A12/screen?lines=999999")
        _ = get("/api/threads/localhost%3A12/screen?lines=-50")
        _ = get("/api/threads/localhost%3A12/screen?lines=5;kill-server")
        XCTAssertEqual(askedLines, [2000, 4000, 10_000, 2000, 2000])
    }

    func testAnUnchangedScreenIsNotSentAgain() throws {
        let first = get("/api/threads/localhost%3A12/screen")
        let tag = try XCTUnwrap(first.head.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("ETag: ") }?.dropFirst("ETag: ".count))
        let raw = "GET /api/threads/localhost%3A12/screen HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n"
            + "If-None-Match: \(tag)\r\n\r\n"
        let same = exchange(raw, until: whole)
        XCTAssertTrue(same.hasPrefix("HTTP/1.1 304 Not Modified\r\n"))
        XCTAssertTrue(same.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(same.contains("ETag: \(tag)\r\n"))
        XCTAssertTrue(same.hasSuffix("\r\n\r\n"))

        // New output: the same validator now gets the new body.
        screenText += "more\n"
        let changed = exchange(raw, until: whole)
        XCTAssertTrue(changed.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(changed.contains("more"))
        XCTAssertFalse(changed.contains("ETag: \(tag)\r\n"))
    }

    func testServesTheBundleWithTheShellAsFallback() {
        let shell = get("/")
        XCTAssertEqual(shell.status, 200)
        XCTAssertEqual(shell.body, "<html>shell</html>")
        XCTAssertTrue(shell.head.contains("Cache-Control: no-cache"))
        XCTAssertTrue(shell.head.contains("Content-Type: text/html"))
        let script = get("/_app/immutable/a.js")
        XCTAssertEqual(script.body, "console.log(1)")
        XCTAssertTrue(script.head.contains("immutable"))
        // A client-side route gets the shell; a missing file does not.
        XCTAssertEqual(get("/t/localhost%3A12").body, "<html>shell</html>")
        XCTAssertEqual(get("/_app/immutable/missing.js").status, 404)
        XCTAssertEqual(get("/..%2F..%2Fetc%2Fpasswd").status, 404)
        let head = get("/", method: "HEAD")
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.body, "")
    }

    /// The shell can run its own scripts and nothing else. A page made from
    /// a blob takes the policy of the page that made it, so a file with a
    /// script in it runs nothing even when it is opened as a page.
    func testEveryBundleResponseCarriesTheShellsContentSecurityPolicy() throws {
        try Data("<html><script>start()</script>shell</html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        // The one socket address in it is the app's own, on the request's port.
        let policy = MobileAPI.shellPolicy(
            html: "<html><script>start()</script>shell</html>",
            socket: "wss://devmac.example.ts.net:7433")
        XCTAssertTrue(policy.contains("script-src 'self' 'sha256-"), policy)
        XCTAssertTrue(policy.contains("connect-src 'self' wss://devmac.example.ts.net:7433;"), policy)
        for path in ["/", "/_app/immutable/a.js", "/t/localhost%3A12"] {
            let served = get(path)
            XCTAssertEqual(served.status, 200, path)
            XCTAssertTrue(served.head.contains("Content-Security-Policy: \(policy)\r\n"), served.head)
            XCTAssertTrue(served.head.contains("script-src 'self'"), path)
            XCTAssertTrue(served.head.contains("object-src 'none'"), path)
            XCTAssertTrue(served.head.contains("base-uri 'none'"), path)
            XCTAssertFalse(served.head.contains("unsafe-eval"), path)
        }
        // The shell changed: the next response has the new script's hash.
        try Data("<html><script>other()</script>shell</html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        XCTAssertFalse(get("/").head.contains("Content-Security-Policy: \(policy)\r\n"))
        XCTAssertTrue(get("/").head.contains("script-src 'self' 'sha256-"))
        // An API answer is data, not a page of the shell.
        XCTAssertFalse(get("/api/threads").head.contains("script-src"))
    }

    func testAnswersTwoRequestsOnOneConnection() {
        let one = "GET /api/hosts HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        let text = exchange(one + one) { $0.components(separatedBy: "HTTP/1.1 200 OK").count == 3
            && $0.hasSuffix("}") }
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 200 OK").count, 3)
    }

    func testEventStreamSendsTheListsThenAChange() {
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        var pushed = false
        let text = exchange(raw) { [self] received in
            // Once the first lists are in, change one thread: a second event follows.
            if !pushed, received.contains("event: hosts") {
                pushed = true
                server.update(snapshot(status: .waiting))
            }
            return received.components(separatedBy: "event: threads").count == 3
        }
        XCTAssertTrue(text.contains("Content-Type: text/event-stream"))
        let events = text.components(separatedBy: "\n\n").filter { $0.contains("event: ") }
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events[0].contains("event: config"))
        XCTAssertTrue(events[1].contains("event: threads"))
        XCTAssertTrue(events[1].contains(#""status":"busy""#))
        XCTAssertTrue(events[2].contains("event: hosts"))
        XCTAssertTrue(events[3].contains(#""status":"waiting""#))
        XCTAssertTrue(server.hasRecentClient)
    }

    func testAnUnchangedTreeSendsNoEvent() {
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        var pushed = false
        let text = exchange(raw) { [self] received in
            if !pushed, received.contains("event: hosts") {
                pushed = true
                server.update(snapshot())
                server.update(snapshot())
                server.configure(MobileConfig(grouping: .directory))
            }
            return received.contains(#""grouping":"directory""#)
        }
        // The config change arrived, and no thread event came before it.
        XCTAssertEqual(text.components(separatedBy: "event: threads").count, 2)
        XCTAssertEqual(text.components(separatedBy: "event: config").count, 3)
    }

    func testListensOnLoopbackOnlyAndStops() {
        server.stop()
        XCTAssertEqual(get("/api/threads").status, 0)
    }

    // MARK: manager

    func testManagerRoutesAnswer403WhileTheSwitchIsOff() {
        for refused in [
            get("/api/manager"),
            post("/api/manager/text", json: #"{"text":"what needs me?"}"#),
            post("/api/manager/dismiss", json: #"{"key":"billing:pr"}"#),
        ] {
            XCTAssertEqual(refused.status, 403)
            XCTAssertEqual(refused.body, #"{"error":"disabled"}"#)
        }
        XCTAssertEqual(manager.sent, [])
        XCTAssertEqual(manager.dismissed, [])
    }

    // MARK: The request list

    private func requestsOnDisk() -> String {
        (try? String(contentsOf: requestsFile, encoding: .utf8)) ?? "<no file>"
    }

    func testTheRequestListIsServedAsTheFileHoldsIt() throws {
        managerOn()
        // No file yet is an empty list.
        let none = get("/api/requests")
        XCTAssertEqual(none.status, 200)
        XCTAssertEqual(none.body, #"{"schema":2,"requests":[]}"#)

        try Data(Self.requestList.utf8).write(to: requestsFile)
        let list = get("/api/requests")
        XCTAssertEqual(list.status, 200)
        XCTAssertEqual(list.body, Self.requestList)
        XCTAssertTrue(list.head.contains("Cache-Control: no-store"))
    }

    func testATickFromThePhoneIsWrittenToTheFile() throws {
        managerOn()
        try Data(Self.requestList.utf8).write(to: requestsFile)
        let ticked = post("/api/requests/state", json: #"{"id":"req-001","state":"done"}"#)
        XCTAssertEqual(ticked.status, 200)
        // The answer is the list after the write, and so is the file.
        XCTAssertEqual(ticked.body, requestsOnDisk())
        XCTAssertTrue(requestsOnDisk().contains(
            #"{ "id": "req-001", "title": "Nightly backup", "project": "devbox", "state": "done","#))
        // The other request is as it was; only the time changed besides.
        XCTAssertTrue(requestsOnDisk().contains(
            #"{ "id": "req-002", "title": "Dark mode", "project": "acme-app", "state": "in_progress","#
                + "\n" + #"      "history": [{ "at": "2026-10-03", "by": "me", "verbatim": "dark mode please" }] },"#))
        XCTAssertFalse(requestsOnDisk().contains("2026-10-03T16:20:00Z"))
        XCTAssertEqual(get("/api/requests").body, requestsOnDisk())

        // The history has what it had, and one entry more: who ticked, and what.
        XCTAssertTrue(requestsOnDisk().contains(
            #"{ "at": "2026-10-03", "by": "maestro", "note": "Set it weekly by mistake. Now nightly." },"#))
        XCTAssertTrue(requestsOnDisk().contains(
            #""by": "me", "note": "State changed from todo to done on the phone." }"#), requestsOnDisk())

        // And back: one more entry, none taken away.
        XCTAssertEqual(
            post("/api/requests/state", json: #"{"id":"req-001","state":"todo"}"#).status, 200)
        XCTAssertTrue(requestsOnDisk().contains(
            #""id": "req-001", "title": "Nightly backup", "project": "devbox", "state": "todo""#))
        XCTAssertTrue(requestsOnDisk().contains(
            #""note": "State changed from todo to done on the phone." },"#))
        XCTAssertTrue(requestsOnDisk().contains(
            #""note": "State changed from done to todo on the phone." }"#))
    }

    func testThePhoneCannotWriteAHistoryEntryOfItsOwn() throws {
        managerOn()
        try Data(Self.requestList.utf8).write(to: requestsFile)
        // The body's own `history`, `by` and `note` are not read: the entry is the server's.
        let body = #"{"id":"req-001","state":"done","by":"maestro","note":"forged","history":[]}"#
        XCTAssertEqual(post("/api/requests/state", json: body).status, 200)
        XCTAssertFalse(requestsOnDisk().contains("forged"))
        XCTAssertTrue(requestsOnDisk().contains(
            #""by": "me", "note": "State changed from todo to done on the phone." }"#))
        XCTAssertTrue(requestsOnDisk().contains(#""verbatim": "back devbox up every night" }"#))
        // There is no other write on the list.
        for path in ["/api/requests", "/api/requests/history", "/api/requests/req-001"] {
            XCTAssertNotEqual(post(path, json: body).status, 200, path)
        }
    }

    func testABadTickIsRefusedAndWritesNothing() throws {
        managerOn()
        try Data(Self.requestList.utf8).write(to: requestsFile)
        XCTAssertEqual(
            post("/api/requests/state", json: #"{"id":"req-001","state":"finished"}"#).status, 400)
        XCTAssertEqual(post("/api/requests/state", json: #"{"state":"done"}"#).status, 400)
        let missing = post("/api/requests/state", json: #"{"id":"req-999","state":"done"}"#)
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(missing.body, #"{"error":"not_found"}"#)
        // A page from somewhere else cannot tick.
        XCTAssertEqual(
            post("/api/requests/state", json: #"{"id":"req-001","state":"done"}"#, writeHeader: false)
                .status, 403)
        XCTAssertEqual(
            post("/api/requests/state", json: #"{"id":"req-001","state":"done"}"#, origin: "https://evil.example")
                .status, 403)
        XCTAssertEqual(get("/api/requests/state").status, 405)
        XCTAssertEqual(requestsOnDisk(), Self.requestList)
    }

    func testAListThatDoesNotReadIsAnErrorAndIsLeftAlone() throws {
        managerOn()
        let half = String(Self.requestList.prefix(120))
        try Data(half.utf8).write(to: requestsFile)
        let list = get("/api/requests")
        XCTAssertEqual(list.status, 500)
        XCTAssertEqual(list.body, #"{"error":"corrupt","message":"requests.json is not valid JSON"}"#)
        let ticked = post("/api/requests/state", json: #"{"id":"req-001","state":"done"}"#)
        XCTAssertEqual(ticked.status, 500)
        XCTAssertEqual(ticked.body, #"{"error":"corrupt","message":"requests.json is not valid JSON"}"#)
        XCTAssertEqual(requestsOnDisk(), half)
    }

    func testTheRequestRoutesNeedTheManagerSwitchAndAList() throws {
        try Data(Self.requestList.utf8).write(to: requestsFile)
        for refused in [
            get("/api/requests"),
            post("/api/requests/state", json: #"{"id":"req-001","state":"done"}"#),
        ] {
            XCTAssertEqual(refused.status, 403)
            XCTAssertEqual(refused.body, #"{"error":"disabled"}"#)
        }
        XCTAssertEqual(get("/api/requests", token: nil).status, 401)
        XCTAssertEqual(requestsOnDisk(), Self.requestList)

        // A server with no list (the dev server) says so.
        server.stop()
        server = makeServer(withLocal: false)
        start(server)
        managerOn()
        XCTAssertEqual(get("/api/requests").status, 503)
        XCTAssertEqual(
            post("/api/requests/state", json: #"{"id":"req-001","state":"done"}"#).status, 503)
        XCTAssertEqual(requestsOnDisk(), Self.requestList)
    }

    func testAManagerPostFromAnotherOriginIsRefusedAndTypesNothing() {
        managerOn()
        let body = #"{"text":"what needs me?"}"#
        for refused in [
            post("/api/manager/text", json: body, origin: "https://evil.example.com"),
            post("/api/manager/text", json: body, origin: "http://127.0.0.1:\(port)"),
            post("/api/manager/text", json: body, origin: nil),
            post("/api/manager/text", json: body, writeHeader: false),
            post("/api/manager/dismiss", json: #"{"key":"billing:pr"}"#, origin: "https://evil.example.com"),
        ] {
            XCTAssertEqual(refused.status, 403)
            XCTAssertEqual(refused.body, #"{"error":"forbidden"}"#)
        }
        XCTAssertEqual(manager.sent, [])
        XCTAssertEqual(manager.dismissed, [])
    }

    /// The turn route types into an agent that has a shell: the right login,
    /// host, origin and write header are not enough without the pairing token.
    func testAManagerPostWithoutThePairingTokenIsRefusedAndTypesNothing() {
        managerOn()
        let text = #"{"text":"what needs me?"}"#
        for (path, body) in [("/api/manager/text", text), ("/api/manager/dismiss", #"{"key":"billing:pr"}"#)] {
            for token in [nil, "wrong-token", ""] {
                let refused = post(path, json: body, token: token)
                XCTAssertEqual(refused.status, 401, path)
                XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#, path)
            }
        }
        XCTAssertEqual(get("/api/manager", token: nil).status, 401)
        XCTAssertEqual(manager.sent, [])
        XCTAssertEqual(manager.dismissed, [])
        // The same POST with the token goes through.
        manager.script = ([], .done(reply: "ok"))
        let turn = post("/api/manager/text", json: text) { $0.contains("event: end") }
        XCTAssertEqual(turn.status, 200)
        XCTAssertEqual(manager.sent, ["what needs me?"])
    }

    func testServesTheManagerHomeWithItsChat() throws {
        managerOn()
        let file = root.appendingPathComponent("manager.jsonl")
        try Data((
            #"{"type":"user","message":{"role":"user","content":"what needs me?"}}"# + "\n"
                + #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Two threads need you."}]}}"#
                + "\n").utf8).write(to: file)
        manager.transcript = file.path
        server.updateManager(MobileManagerBoard(items: [
            MobileManagerItem(
                kind: .agent, title: "acme-app · checkout-fix", detail: "Permission · Bash",
                at: 1_759_500_000, link: .thread(id: "c1")),
            MobileManagerItem(
                kind: .review, key: "acme-app:pr", title: "acme-app", detail: "PR open, CI green",
                severity: .warn, at: 1_759_499_000,
                link: .open(session: "acme-app", window: 1, pane: nil, host: "localhost")),
        ]))
        let home = get("/api/manager")
        XCTAssertEqual(home.status, 200)
        XCTAssertTrue(home.head.contains("Cache-Control: no-store"))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(home.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["status"] as? String, "idle")
        XCTAssertEqual((body["needsYou"] as? [[String: Any]])?.first?["thread"] as? String, "localhost:12")
        XCTAssertEqual((body["review"] as? [[String: Any]])?.first?["key"] as? String, "acme-app:pr")
        XCTAssertNil(body["chat"])

        // The chat is its own route, with the cursor a thread's chat has.
        let chat = get("/api/manager/chat")
        XCTAssertEqual(chat.status, 200)
        let page = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(chat.body.utf8)) as? [String: Any])
        let messages = page["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.map { $0["text"] as? String }, ["what needs me?", "Two threads need you."])
        XCTAssertEqual(messages?.map { $0["role"] as? String }, ["user", "assistant"])
        let next = try XCTUnwrap(page["next"] as? Int)
        XCTAssertTrue(get("/api/manager/chat?after=\(next)").body.contains(#""messages":[]"#))
    }

    func testTheManagerChatIsEmptyUntilThePaneHasATranscript() {
        managerOn()
        manager.transcript = nil
        let chat = get("/api/manager/chat")
        XCTAssertEqual(chat.status, 200)
        XCTAssertEqual(chat.body, #"{"messages":[],"next":0,"reset":false}"#)
    }

    func testServesTheManagerPanesScreenLikeAThreads() {
        managerOn()
        let screen = get("/api/manager/screen?lines=50")
        XCTAssertEqual(screen.status, 200)
        // Colour escapes are kept, and the empty rows at the end are cut.
        XCTAssertTrue(screen.body.contains(#""lines":50"#))
        XCTAssertTrue(screen.body.contains("Ready."))
        XCTAssertTrue(screen.body.contains(#"\u001b[32m"#))
        XCTAssertFalse(screen.body.contains(#"Ready.\n"#))
        XCTAssertTrue(screen.head.contains("ETag: "))

        manager.screen = nil
        XCTAssertEqual(get("/api/manager/screen").status, 503)
    }

    func testTheManagerChatAndScreenNeedTheSwitchAndTheToken() {
        for path in ["/api/manager/chat", "/api/manager/screen"] {
            let off = get(path)
            XCTAssertEqual(off.status, 403, path)
            XCTAssertEqual(off.body, #"{"error":"disabled"}"#, path)
        }
        managerOn()
        for path in ["/api/manager/chat", "/api/manager/screen"] {
            XCTAssertEqual(get(path, token: nil).status, 401, path)
            XCTAssertEqual(get(path).status, 200, path)
        }
    }

    func testTheSpinnerLineOfARunningTurnGoesOutOnTheEventStream() {
        var limits = MobileServer.Limits()
        limits.spinnerPoll = 0.05
        restart(limits: limits)
        managerOn()
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        var step = 0
        let text = exchange(raw) { [self] received in
            if step == 0, received.contains("event: manager") {
                step = 1
                manager.screen = "✻ Incubating… (3s · esc to interrupt)\n│ >  │\n"
                server.managerTurnBegan("summarise the morning")
            }
            if step == 1, received.contains(#"{"text":"Incubating… 3s"}"#) {
                step = 2
                manager.screen = "✻ Incubating… (4s · esc to interrupt)\n│ >  │\n"
            }
            if step == 2, received.contains(#"{"text":"Incubating… 4s"}"#) {
                step = 3
                // The pane stops showing a spinner: the phone is told that too.
                manager.screen = "⏺ All quiet.\n│ >  │\n"
            }
            if step == 3, received.contains(#"event: manager-spinner\#ndata: {"text":null}"#) {
                step = 4
                server.managerTurnEnded()
            }
            return step == 4 && received.components(separatedBy: #""turn":null"#).count >= 3
        }
        XCTAssertEqual(step, 4)
        let spinners = text.components(separatedBy: "\n\n").filter { $0.contains("event: manager-spinner") }
        // Sent only when the line changed, not on every poll.
        XCTAssertEqual(spinners.count, 3)

        // The turn is over: the pane is no longer read.
        manager.screen = "✻ Musing… (1s)\n"
        usleep(200_000)
        XCTAssertTrue(get("/api/manager").body.contains(#""turn":null"#))
    }

    func testAManagerTurnStreamsTheReplyThenEnds() {
        managerOn()
        manager.script = (["Two threads ", "need you."], .done(reply: "Two threads need you."))
        let turn = post("/api/manager/text", json: #"{"text":"what needs me?"}"#) {
            $0.contains("event: end") && $0.hasSuffix("\n\n")
        }
        XCTAssertEqual(turn.status, 200)
        XCTAssertTrue(turn.head.contains("Content-Type: text/event-stream"))
        XCTAssertEqual(manager.sent, ["what needs me?"])
        let events = turn.body.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(events, [
            "event: delta\ndata: {\"text\":\"Two threads \"}",
            "event: delta\ndata: {\"text\":\"need you.\"}",
            "event: end\ndata: {\"message\":null,\"outcome\":\"done\",\"reply\":\"Two threads need you.\"}",
        ])
    }

    func testATurnIsRefusedWhileTheManagerWaitsOnAPromptOrRunsATurn() {
        managerOn()
        manager.status = .waiting
        let waiting = post("/api/manager/text", json: #"{"text":"what needs me?"}"#)
        XCTAssertEqual(waiting.status, 409)
        XCTAssertEqual(waiting.body, #"{"error":"waiting","message":"Maestro is waiting on a prompt"}"#)

        // Busy with a turn the app does not track: it may reach a prompt.
        manager.status = .busy
        let paneBusy = post("/api/manager/text", json: #"{"text":"what needs me?"}"#)
        XCTAssertEqual(paneBusy.status, 409)
        XCTAssertEqual(paneBusy.body, #"{"error":"busy","message":"Maestro is busy"}"#)

        // A turn the Mac rail started is still running.
        manager.status = .idle
        server.managerTurnBegan("summarise the morning")
        let busy = post("/api/manager/text", json: #"{"text":"what needs me?"}"#)
        XCTAssertEqual(busy.status, 409)
        XCTAssertEqual(busy.body, #"{"error":"busy","message":"A turn is running"}"#)
        XCTAssertTrue(get("/api/manager").body.contains(#""status":"busy""#))

        // The manager runs, but its pane's state is not known yet.
        manager.status = .unknown
        server.managerTurnEnded()
        let unknown = post("/api/manager/text", json: #"{"text":"what needs me?"}"#)
        XCTAssertEqual(unknown.status, 503)
        XCTAssertEqual(unknown.body, #"{"error":"not_ready","message":"Maestro is not ready"}"#)
        XCTAssertTrue(get("/api/manager").body.contains(#""status":"unknown""#))

        manager.status = .off
        XCTAssertEqual(post("/api/manager/text", json: #"{"text":"what needs me?"}"#).status, 503)
        XCTAssertEqual(post("/api/manager/text", json: #"{"text":" "}"#).status, 400)
        XCTAssertEqual(manager.sent, [])
    }

    func testTheDriversLateRefusalEndsTheStreamWithItsReason() {
        managerOn()
        manager.script = ([], .refused("Maestro is waiting on a prompt"))
        let turn = post("/api/manager/text", json: #"{"text":"what needs me?"}"#) {
            $0.contains("event: end") && $0.hasSuffix("\n\n")
        }
        XCTAssertEqual(turn.status, 200)
        XCTAssertTrue(turn.body.contains(
            #"{"message":"Maestro is waiting on a prompt","outcome":"refused","reply":""}"#))
    }

    private func reviewBoard() -> MobileManagerBoard {
        MobileManagerBoard(items: [MobileManagerItem(
            kind: .review, key: "billing:pr", title: "billing", detail: "PR open, CI green",
            severity: .warn, at: 1_759_499_000, link: nil)])
    }

    // MARK: cards

    private static let cardKey = "point:localhost:acme-app:2"

    /// A pointer at acme-app:2 with two answers. Its pane is %13: not the
    /// first thread of the list, and not the Maestro's.
    private func cardBoard(pane: String? = "%13") -> (board: MobileManagerBoard, id: String) {
        let card = MobileCard(
            title: "asks whether to run the migration",
            source: MobileCard.Source(host: "localhost", session: "acme-app", window: 2, pane: pane),
            card: ManagerCard(pane: pane, actions: [
                ManagerCard.Action(label: "Yes", text: "yes, run it"),
                ManagerCard.Action(label: "No", text: "no, stop.\nExplain why first."),
            ]))
        let board = MobileManagerBoard(items: [MobileManagerItem(
            kind: .review, key: Self.cardKey, title: "acme-app", detail: card.title,
            severity: .blocked, at: 1_759_499_000,
            link: .open(session: "acme-app", window: 2, pane: nil, host: "localhost"),
            pointer: true, card: card)])
        return (board, MobileCards.id(key: Self.cardKey, card: card))
    }

    private func cardsOn() {
        server.configure(MobileConfig(capabilities: [.manager, .replies]))
        pane.status = .idle
    }

    private func act(_ action: Int, card: String) -> (status: Int, head: String, body: String) {
        post("/api/manager/act", json: #"{"key":"\#(Self.cardKey)","action":\#(action),"card":"\#(card)"}"#)
    }

    func testACardTapPastesItsTextIntoTheSourcePaneAndNotTheMaestros() throws {
        cardsOn()
        let (board, id) = cardBoard()
        server.updateManager(board)
        // The phone gets the card with the pointer, and no text of an action.
        let home = get("/api/manager").body
        XCTAssertTrue(home.contains(#""source":"localhost:13""#), home)
        XCTAssertTrue(home.contains(#""link":"\/t\/localhost:13""#), home)
        XCTAssertFalse(home.contains("Explain why first"), home)

        let sent = act(1, card: id)
        XCTAssertEqual(sent.status, 200, sent.body)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sent.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["thread"] as? String, "localhost:13")
        XCTAssertEqual((body["answered"] as? [String: Any])?["label"] as? String, "No")
        // One buffer, one bracketed paste, then a separate Enter, all at %13.
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%13"), "\(pane.argv)")
        // Both lines went in as one paste: the newline is text, not Enter.
        XCTAssertEqual(pane.calls[1].stdin, "no, stop.\nExplain why first.")
        // Nothing was typed into the Maestro's own pane, and no turn was run.
        XCTAssertEqual(manager.pane.argv.count, 0)
        XCTAssertEqual(manager.sent, [])
        XCTAssertEqual(manager.answered, ["\(Self.cardKey)=No"])
    }

    func testACardTapThatDoesNotLandSaysWhyAndRecordsNoAnswer() {
        cardsOn()
        let (board, id) = cardBoard()
        server.updateManager(board)
        // The session is working: its next prompt could take the Enter.
        pane.status = .busy
        let busy = act(0, card: id)
        XCTAssertEqual(busy.status, 409)
        XCTAssertEqual(busy.body, #"{"error":"busy","message":"Thread is busy"}"#)
        // It is on a prompt of its own.
        pane.status = .waiting
        let waiting = act(0, card: id)
        XCTAssertEqual(waiting.status, 409)
        XCTAssertEqual(waiting.body, #"{"error":"waiting","message":"Thread is waiting on a prompt"}"#)
        // tmux does not answer.
        pane.status = .idle
        pane.failing = true
        XCTAssertEqual(act(0, card: id).status, 503)
        pane.failing = false
        XCTAssertEqual(manager.answered, [])

        // The tap can be tried again, and lands once.
        XCTAssertTrue(get("/api/manager").body.contains(#""answered":null"#))
        let before = pane.argv.count
        XCTAssertEqual(act(0, card: id).status, 200)
        XCTAssertEqual(manager.answered, ["\(Self.cardKey)=Yes"])
        let after = pane.argv.count
        XCTAssertGreaterThan(after, before)
        // The app's list has not heard of the answer yet: a second tap sends
        // nothing, and the phone is already told the card is answered.
        let again = act(1, card: id)
        XCTAssertEqual(again.status, 409)
        XCTAssertEqual(again.body, #"{"error":"answered","message":"Already answered"}"#)
        XCTAssertEqual(pane.argv.count, after)
        XCTAssertEqual(manager.answered, ["\(Self.cardKey)=Yes"])
        XCTAssertTrue(get("/api/manager").body.contains(#""answered":{"#))
        // The same list again, still without the answer: it stays answered.
        server.updateManager(board)
        XCTAssertTrue(get("/api/manager").body.contains(#""answered":{"#))
        XCTAssertEqual(act(0, card: id).status, 409)
        // The pointer is cleared and the same question is asked again: it is open.
        server.updateManager(MobileManagerBoard())
        server.updateManager(board)
        XCTAssertTrue(get("/api/manager").body.contains(#""answered":null"#))
        XCTAssertEqual(act(0, card: id).status, 200)
        XCTAssertEqual(manager.answered, ["\(Self.cardKey)=Yes", "\(Self.cardKey)=Yes"])
    }

    func testACardTapWithNoOnePaneToGoToTypesNothing() {
        cardsOn()
        // Its pane is gone.
        let (gone, goneID) = cardBoard(pane: "%99")
        server.updateManager(gone)
        let missing = act(0, card: goneID)
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(missing.body, #"{"error":"source_gone","message":"Session is gone"}"#)
        // The card changed since the phone drew it.
        let (board, id) = cardBoard()
        server.updateManager(board)
        let stale = act(0, card: goneID)
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(stale.body, #"{"error":"changed","message":"Card changed"}"#)
        // Not a button, not a card, not a request.
        XCTAssertEqual(act(2, card: id).status, 400)
        XCTAssertEqual(
            post("/api/manager/act", json: #"{"key":"nope","action":0,"card":"x"}"#).status, 404)
        XCTAssertEqual(post("/api/manager/act", json: "{}").status, 400)
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(manager.answered, [])
    }

    func testACardTapPassesTheWriteChecksAndNeedsBothSwitches() {
        let (board, id) = cardBoard()
        server.updateManager(board)
        let json = #"{"key":"\#(Self.cardKey)","action":0,"card":"\#(id)"}"#
        // The Maestro switch alone does not type into a thread.
        managerOn()
        pane.status = .idle
        XCTAssertEqual(post("/api/manager/act", json: json).body, #"{"error":"disabled"}"#)
        cardsOn()
        XCTAssertEqual(post("/api/manager/act", json: json, token: nil).status, 401)
        XCTAssertEqual(
            post("/api/manager/act", json: json, origin: "https://evil.example.com").status, 403)
        XCTAssertEqual(post("/api/manager/act", json: json, writeHeader: false).status, 403)
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(manager.answered, [])
    }

    func testDismissPassesOnTheKeyOfAReviewItemOnly() {
        managerOn()
        server.updateManager(reviewBoard())
        let done = post("/api/manager/dismiss", json: #"{"key":"billing:pr"}"#)
        XCTAssertEqual(done.status, 200)
        XCTAssertEqual(done.body, #"{"ok":true}"#)
        XCTAssertEqual(manager.dismissed, ["billing:pr"])

        // A key no review item has is not passed on.
        let missing = post("/api/manager/dismiss", json: #"{"key":"no-such-item"}"#)
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(missing.body, #"{"error":"not_found"}"#)
        XCTAssertEqual(post("/api/manager/dismiss", json: "{}").status, 400)
        let long = String(repeating: "k", count: MobileManager.maxKeyBytes + 1)
        XCTAssertEqual(post("/api/manager/dismiss", json: #"{"key":"\#(long)"}"#).status, 413)
        XCTAssertEqual(manager.dismissed, ["billing:pr"])
    }

    func testATextWithAKeyPressOrOverTheSizeLimitIsRefusedAndTypesNothing() {
        managerOn()
        // JSON escapes, as a client would send them: ESC [ Z is Shift+Tab,
        // U+0003 is Ctrl-C, a carriage return is Enter.
        for text in [#"a\u001b[Zb"#, #"a\u0003b"#, #"first\rsecond"#, #"a\u007fb"#, #"a\u009bZb"#] {
            let refused = post("/api/manager/text", json: #"{"text":"\#(text)"}"#)
            XCTAssertEqual(refused.status, 400, text)
            XCTAssertEqual(refused.body, #"{"error":"bad_request"}"#, text)
        }
        let long = String(repeating: "a", count: MobileManager.maxTextBytes + 1)
        let tooLong = post("/api/manager/text", json: #"{"text":"\#(long)"}"#)
        XCTAssertEqual(tooLong.status, 413)
        XCTAssertEqual(tooLong.body, #"{"error":"too_large"}"#)
        XCTAssertEqual(manager.sent, [])

        // Newlines are text: one request is one prompt.
        manager.script = ([], .done(reply: "ok"))
        let turn = post("/api/manager/text", json: #"{"text":"first\nsecond"}"#) {
            $0.contains("event: end")
        }
        XCTAssertEqual(turn.status, 200)
        XCTAssertEqual(manager.sent, ["first\nsecond"])
    }

    func testATextWithTheQueueModeGoesToABusyManager() {
        managerOn()
        manager.status = .busy
        manager.script = ([], .done(reply: "ok"))
        // Without the mode a busy pane refuses, as it always did.
        XCTAssertEqual(post("/api/manager/text", json: #"{"text":"and the builds?"}"#).status, 409)
        XCTAssertEqual(manager.sent, [])
        let queued = post("/api/manager/text", json: #"{"text":"and the builds?","mode":"queue"}"#) {
            $0.contains("event: end")
        }
        XCTAssertEqual(queued.status, 200)
        XCTAssertTrue(queued.body.contains(#""outcome":"done""#))
        XCTAssertEqual(manager.sent, ["and the builds?"])
        XCTAssertEqual(manager.queued, [true])

        // Only the busy status is dropped: a prompt still refuses the text.
        manager.status = .waiting
        let waiting = post("/api/manager/text", json: #"{"text":"again","mode":"queue"}"#)
        XCTAssertEqual(waiting.status, 409)
        XCTAssertEqual(waiting.body, #"{"error":"waiting","message":"Maestro is waiting on a prompt"}"#)
        // A mode that is not known is refused before anything is typed.
        manager.status = .busy
        XCTAssertEqual(post("/api/manager/text", json: #"{"text":"again","mode":"now"}"#).status, 400)
        XCTAssertEqual(manager.sent, ["and the builds?"])

        // A turn the app follows still refuses: the phone holds that text itself.
        server.managerTurnBegan("summarise the morning")
        let running = post("/api/manager/text", json: #"{"text":"again","mode":"queue"}"#)
        XCTAssertEqual(running.status, 409)
        XCTAssertEqual(running.body, #"{"error":"busy","message":"A turn is running"}"#)
        XCTAssertEqual(manager.sent, ["and the builds?"])
    }

    func testASecondPhoneIsRefusedWhileTheFirstOnesTurnRuns() {
        managerOn()
        let gate = DispatchSemaphore(value: 0)
        manager.gate = gate
        manager.script = (["Two threads need you."], .done(reply: "Two threads need you."))
        let first = expectation(description: "first turn")
        var firstBody = ""
        DispatchQueue.global().async { [self] in
            firstBody = post("/api/manager/text", json: #"{"text":"what needs me?"}"#) {
                $0.contains("event: end") && $0.hasSuffix("\n\n")
            }.body
            first.fulfill()
        }
        // Wait until the first turn is with the manager, then send a second.
        let deadline = Date().addingTimeInterval(5)
        while manager.sent.isEmpty, Date() < deadline { usleep(10_000) }
        let second = post("/api/manager/text", json: #"{"text":"and the builds?"}"#)
        XCTAssertEqual(second.status, 409)
        XCTAssertEqual(second.body, #"{"error":"busy","message":"A turn is running"}"#)

        gate.signal()
        wait(for: [first], timeout: 5)
        XCTAssertTrue(firstBody.contains(#""outcome":"done""#))
        XCTAssertEqual(manager.sent, ["what needs me?"])

        // The first turn ended: the next one goes through.
        manager.gate = nil
        let third = post("/api/manager/text", json: #"{"text":"and the builds?"}"#) {
            $0.contains("event: end")
        }
        XCTAssertEqual(third.status, 200)
        XCTAssertEqual(manager.sent, ["what needs me?", "and the builds?"])
    }

    func testAQuietTurnStreamIsPingedOnItsOwnTimer() {
        var limits = MobileServer.Limits()
        limits.turnPing = 0.1
        restart(limits: limits)
        managerOn()
        let gate = DispatchSemaphore(value: 0)
        manager.gate = gate
        manager.script = ([], .done(reply: "ok"))
        // No tree update arrives while the turn is quiet: the ping is the stream's own.
        var released = false
        let turn = post("/api/manager/text", json: #"{"text":"what needs me?"}"#) {
            if !released, $0.components(separatedBy: ": ping\n\n").count >= 3 {
                released = true
                gate.signal()
            }
            return $0.contains("event: end")
        }
        if !released { gate.signal() }
        XCTAssertEqual(turn.status, 200)
        XCTAssertGreaterThanOrEqual(turn.body.components(separatedBy: ": ping\n\n").count, 3)
        XCTAssertTrue(turn.body.contains(#""outcome":"done""#))
    }

    func testAPhoneThatHangsUpMidTurnLeavesTheServerWorking() {
        managerOn()
        let gate = DispatchSemaphore(value: 0)
        manager.gate = gate
        manager.script = (["Two threads ", "need you."], .done(reply: "Two threads need you."))
        // Read the stream's head only, then close the connection.
        let head = post("/api/manager/text", json: #"{"text":"what needs me?"}"#) {
            $0.contains("\r\n\r\n")
        }
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(manager.sent, ["what needs me?"])
        // The turn is still running on the Mac: a new one is refused.
        XCTAssertEqual(post("/api/manager/text", json: #"{"text":"again"}"#).status, 409)

        // It ends with nobody listening. Nothing breaks, and the next turn runs.
        gate.signal()
        manager.gate = nil
        let deadline = Date().addingTimeInterval(5)
        var next = (status: 0, head: "", body: "")
        repeat {
            // A refusal is whole once its body is in; a stream only at its end event.
            next = post("/api/manager/text", json: #"{"text":"again"}"#) {
                $0.contains("event: end") || (!$0.hasPrefix("HTTP/1.1 200") && self.whole($0))
            }
            if next.status != 200 { usleep(20_000) }
        } while next.status != 200 && Date() < deadline
        XCTAssertEqual(next.status, 200)
        XCTAssertTrue(next.body.contains(#""outcome":"done""#))
        XCTAssertEqual(manager.sent, ["what needs me?", "again"])
        XCTAssertEqual(get("/api/threads").status, 200)
    }

    func testTheEventStreamFollowsAMacSideTurnOnlyWhileTheSwitchIsOn() {
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        // Off: a turn on the Mac sends the phone nothing about the manager.
        var pushed = false
        let quiet = exchange(raw) { [self] received in
            if !pushed, received.contains("event: hosts") {
                pushed = true
                server.managerTurnBegan("summarise the morning")
                server.update(snapshot(status: .waiting))
            }
            return received.components(separatedBy: "event: threads").count == 3
        }
        XCTAssertFalse(quiet.contains("event: manager"))
        server.managerTurnEnded()

        managerOn()
        var step = 0
        let text = exchange(raw) { [self] received in
            if step == 0, received.contains("event: manager") {
                step = 1
                server.managerTurnBegan("summarise the morning")
                server.managerTurnAppended("All quiet.")
                server.managerTurnEnded()
            }
            return received.components(separatedBy: "event: manager").count == 5
        }
        let events = text.components(separatedBy: "\n\n").filter { $0.contains("event: manager") }
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events[0].contains(#""turn":null"#))
        XCTAssertTrue(events[1].contains(#""turn":{"prompt":"summarise the morning","reply":"","spinner":null}"#))
        // The reply grows by a small event of its own, not by the board again.
        XCTAssertEqual(events[2], "event: manager-delta\ndata: {\"text\":\"All quiet.\"}")
        XCTAssertTrue(events[3].hasPrefix("event: manager\n"))
        XCTAssertTrue(events[3].contains(#""turn":null"#))
    }

    func testAPhoneThatJoinsMidTurnGetsTheReplySoFar() {
        managerOn()
        server.managerTurnBegan("summarise the morning")
        server.managerTurnAppended("All quiet")
        let raw = "GET /api/events HTTP/1.1\r\nHost: devmac.example.ts.net\r\n"
            + "Tailscale-User-Login: me@example.com\r\nX-MuxMaestro-Token: demo-token\r\n\r\n"
        let text = exchange(raw) { $0.contains("event: manager") && $0.hasSuffix("\n\n") }
        XCTAssertTrue(text.contains(#""turn":{"prompt":"summarise the morning","reply":"All quiet","spinner":null}"#))
        XCTAssertTrue(get("/api/manager").body.contains(#""reply":"All quiet""#))
    }

    // MARK: replies

    private func repliesOn() {
        server.configure(MobileConfig(
            capabilities: [.replies, .keyBar, .upload], uploadLimit: 64, uploadFolder: "/Users/me/uploads"))
        pane.status = .idle
    }

    private static let thread = "/api/threads/localhost%3A12"

    /// Every write to a thread, with a body the route would take.
    private var writes: [(path: String, body: String)] {
        [
            (Self.thread + "/text", #"{"text":"run the tests"}"#),
            (Self.thread + "/key", #"{"key":"Enter"}"#),
            (Self.thread + "/answer", #"{"prompt":"9f2c","option":1}"#),
            (Self.thread + "/upload?name=notes.txt", "demo"),
        ]
    }

    func testReplyRoutesAnswer403WhileTheirSwitchesAreOff() {
        pane.status = .idle
        for write in writes {
            let refused = post(write.path, json: write.body)
            XCTAssertEqual(refused.status, 403, write.path)
            XCTAssertEqual(refused.body, #"{"error":"disabled"}"#, write.path)
        }
        XCTAssertEqual(get(Self.thread + "/prompt").status, 403)
        XCTAssertEqual(get(Self.thread + "/commands").status, 403)

        // Each switch opens its own routes and no other.
        server.configure(MobileConfig(capabilities: [.replies]))
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter"}"#).status, 403)
        XCTAssertEqual(post(Self.thread + "/upload?name=notes.txt", json: "demo").status, 403)
        server.configure(MobileConfig(capabilities: [.keyBar, .upload, .manager, .voice]))
        XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"run the tests"}"#).status, 403)
        XCTAssertEqual(post(Self.thread + "/answer", json: #"{"prompt":"9f2c","option":1}"#).status, 403)
        XCTAssertEqual(get(Self.thread + "/commands").status, 403)
        // The key bar may read the prompt: a key into a waiting pane names it.
        XCTAssertEqual(get(Self.thread + "/prompt").status, 200)
        server.configure(MobileConfig(capabilities: [.upload, .manager, .voice]))
        XCTAssertEqual(get(Self.thread + "/prompt").status, 403)
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(pane.saves.count, 0)
    }

    func testAReplyWriteWithoutThePairingTokenIsRefusedAndTypesNothing() {
        repliesOn()
        for write in writes {
            for token in [nil, "wrong-token", ""] {
                let refused = post(write.path, json: write.body, token: token)
                XCTAssertEqual(refused.status, 401, write.path)
                XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#, write.path)
            }
        }
        XCTAssertEqual(get(Self.thread + "/prompt", token: nil).status, 401)
        XCTAssertEqual(get(Self.thread + "/commands", token: nil).status, 401)
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(pane.saves.count, 0)
    }

    func testAReplyWriteFromAnotherOriginIsRefusedAndTypesNothing() {
        repliesOn()
        for write in writes {
            for refused in [
                post(write.path, json: write.body, origin: "https://evil.example.com"),
                // This Mac's name, but another `tailscale serve` port.
                post(write.path, json: write.body, origin: "https://devmac.example.ts.net:8443"),
                post(write.path, json: write.body, origin: "https://devmac.example.ts.net"),
                post(write.path, json: write.body, origin: "http://devmac.example.ts.net:7433"),
                post(write.path, json: write.body, origin: "http://127.0.0.1:\(port)"),
                post(write.path, json: write.body, origin: nil),
                post(write.path, json: write.body, writeHeader: false),
            ] {
                XCTAssertEqual(refused.status, 403, write.path)
                XCTAssertEqual(refused.body, #"{"error":"forbidden"}"#, write.path)
            }
        }
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(pane.saves.count, 0)
    }

    func testATextIsPastedIntoItsThreadsPaneAndSubmitted() {
        repliesOn()
        let sent = post(Self.thread + "/text", json: #"{"text":"run the tests\nthen push"}"#)
        XCTAssertEqual(sent.status, 200)
        XCTAssertEqual(sent.body, #"{"ok":true}"#)
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%12"), "\(pane.argv)")
        XCTAssertEqual(pane.calls[1].stdin, "run the tests\nthen push")
    }

    func testAThreadTextWithAKeyPressOrOverTheSizeLimitTypesNothing() {
        repliesOn()
        for text in [#"a\u001b[Zb"#, #"a\u0003b"#, #"first\rsecond"#, #"a\u007fb"#, #"a\u009bZb"#, #"a\u0000b"#] {
            let refused = post(Self.thread + "/text", json: #"{"text":"\#(text)"}"#)
            XCTAssertEqual(refused.status, 400, text)
            XCTAssertEqual(refused.body, #"{"error":"bad_request"}"#, text)
        }
        for body in ["{}", #"{"text":""}"#, #"{"text":7}"#, "run the tests"] {
            XCTAssertEqual(post(Self.thread + "/text", json: body).status, 400, body)
        }
        let long = String(repeating: "a", count: MobileManager.maxTextBytes + 1)
        let tooLong = post(Self.thread + "/text", json: #"{"text":"\#(long)"}"#)
        XCTAssertEqual(tooLong.status, 413)
        XCTAssertEqual(tooLong.body, #"{"error":"too_large"}"#)
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testFreeTextIntoABusyOrWaitingThreadIsRefused() {
        repliesOn()
        pane.status = .busy
        let busy = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(busy.status, 409)
        XCTAssertEqual(busy.body, #"{"error":"busy","message":"Thread is busy"}"#)
        pane.status = .waiting
        let waiting = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(waiting.status, 409)
        XCTAssertEqual(waiting.body, #"{"error":"waiting","message":"Thread is waiting on a prompt"}"#)
        // The tree's own status counts when the pane has no newer one.
        pane.status = nil
        XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"go on"}"#).status, 409)
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testAPromptThatComesUpBetweenThePasteAndTheEnterGetsNoEnter() {
        repliesOn()
        pane.statusAfterPaste = .waiting
        let refused = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(refused.status, 409)
        // Its own code, and the text is taken out of the input box again.
        XCTAssertEqual(
            refused.body,
            #"{"cleared":false,"error":"not_sent","message":"Thread is waiting on a prompt","reason":"waiting"}"#)
        // A prompt is in front now: no key goes to it, not even one that clears.
        XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
    }

    func testTextRefusedForABusyPaneIsTakenOutOfItsInputBox() {
        repliesOn()
        pane.statusAfterPaste = .busy
        pane.screenAfterPaste = DemoPrompt.input("go on")
        let refused = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(
            refused.body,
            #"{"cleared":true,"error":"not_sent","message":"Thread is busy","reason":"busy"}"#)
        XCTAssertEqual(pane.argv.last, ["send-keys", "-t", "%12", "C-u"])
    }

    func testTextWithTheQueueModeGoesIntoABusyPane() {
        repliesOn()
        pane.status = .busy
        // Without the mode a busy pane refuses, as it always did.
        XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"go on"}"#).status, 409)
        XCTAssertEqual(pane.argv.count, 0)
        let queued = post(Self.thread + "/text", json: #"{"text":"go on","mode":"queue"}"#)
        XCTAssertEqual(queued.status, 200)
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%12"), "\(pane.argv)")
        // A mode that is not known is refused before anything is typed.
        XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"go on","mode":"now"}"#).status, 400)
        XCTAssertEqual(pane.argv.count, 4)
    }

    func testTextWithTheInterruptModePressesEscapeAndPastesNothing() {
        repliesOn()
        pane.status = .busy
        let cut = post(Self.thread + "/text", json: #"{"text":"go on","mode":"interrupt"}"#)
        XCTAssertEqual(cut.body, #"{"interrupted":true,"ok":true}"#)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "Escape"]])
    }

    func testAPromptOnTheScreenRefusesTextWhateverTheStatusSays() {
        repliesOn()
        // The status stays idle throughout; only the screen shows the prompt.
        pane.screenAfterPaste = DemoPrompt.permission
        let late = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(late.status, 409)
        XCTAssertTrue(late.body.contains(#""error":"not_sent""#), late.body)
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
        // Still on the screen: the next text is refused before any paste.
        let before = pane.argv.count
        let early = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(early.status, 409)
        XCTAssertEqual(early.body, #"{"error":"waiting","message":"Thread is waiting on a prompt"}"#)
        XCTAssertEqual(pane.argv.count, before)
    }

    func testAShellPaneWithNoStatusTakesNoFreeText() {
        repliesOn()
        // The shell window: no hooks, so no status, and no input box on screen.
        pane.status = nil
        pane.screen = "$ make test\nok\n$ "
        let refused = post("/api/threads/localhost%3A13/text", json: #"{"text":"ls"}"#)
        XCTAssertEqual(refused.status, 409)
        XCTAssertEqual(refused.body, #"{"error":"no_input","message":"Thread shows no input box"}"#)
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testAStaleThreadIdIsA404AndTypesNothing() {
        repliesOn()
        for id in ["localhost%3A99", "devbox%3A12", "%2512", "..", "localhost%3A12%2F..%2F13"] {
            let base = "/api/threads/\(id)"
            XCTAssertEqual(post(base + "/text", json: #"{"text":"go on"}"#).status, 404, id)
            XCTAssertEqual(post(base + "/key", json: #"{"key":"Enter"}"#).status, 404, id)
            XCTAssertEqual(post(base + "/answer", json: #"{"prompt":"9f2c","option":1}"#).status, 404, id)
            XCTAssertEqual(post(base + "/upload?name=notes.txt", json: "demo").status, 404, id)
            XCTAssertEqual(get(base + "/prompt").status, 404, id)
            XCTAssertEqual(get(base + "/commands").status, 404, id)
        }
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(pane.saves.count, 0)
    }

    func testAKeyOffTheWhitelistIsRefusedAndAWhitelistedOneIsPressed() {
        repliesOn()
        for key in ["F1", "C-1", "M-a", "q", "0", "10", "Enter; kill-server", "-X", ""] {
            let refused = post(Self.thread + "/key", json: #"{"key":"\#(key)"}"#)
            XCTAssertEqual(refused.status, 400, key)
            XCTAssertEqual(refused.body, #"{"error":"bad_key"}"#, key)
        }
        XCTAssertEqual(pane.argv.count, 0)

        // A pane at work still takes a key: Ctrl-C stops it.
        for (status, key) in [(AttentionStatus.busy, "C-c"), (.idle, "BTab"), (.idle, "3")] {
            pane.status = status
            XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"\#(key)"}"#).status, 200, key)
        }
        XCTAssertEqual(pane.argv, [
            ["send-keys", "-t", "%12", "C-c"], ["send-keys", "-t", "%12", "BTab"],
            ["send-keys", "-t", "%12", "3"],
        ])
    }

    func testAKeyIntoAWaitingPaneNeedsTheIdOfThePromptOnItNow() throws {
        repliesOn()
        pane.status = .waiting
        pane.screen = DemoPrompt.permission
        func shownID() throws -> String {
            try XCTUnwrap(
                (JSONSerialization.jsonObject(with: Data(get(Self.thread + "/prompt").body.utf8))
                    as? [String: Any])?["id"] as? String)
        }
        let id = try shownID()

        // Enter with no prompt named, or one that is not on the pane.
        for body in [#"{"key":"Enter"}"#, #"{"key":"Enter","prompt":"9f2c"}"#, #"{"key":"1","prompt":""}"#] {
            let refused = post(Self.thread + "/key", json: body)
            XCTAssertEqual(refused.status, 409, body)
            XCTAssertEqual(refused.body, #"{"error":"stale"}"#, body)
        }
        XCTAssertEqual(pane.argv.count, 0)
        // With the id of the prompt on the pane, the key bar works as a terminal.
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(id)"}"#).status, 200)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "Enter"]])

        // The prompt changed after the phone drew its card: the old id is stale.
        pane.screen = DemoPrompt.question
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(id)"}"#).status, 409)
        // The same words asked again are another prompt too.
        pane.screen = DemoPrompt.permission
        pane.since = 1_759_500_060
        XCTAssertNotEqual(try shownID(), id)
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(id)"}"#).status, 409)
        XCTAssertEqual(pane.argv.count, 1)
    }

    func testAKeyWaitsItsTurnBehindAnotherWriteToTheSameThread() {
        repliesOn()
        // A text is between its paste and its Enter.
        let gate = DispatchSemaphore(value: 0)
        let pasted = expectation(description: "pasted")
        pane.onPaste = { pasted.fulfill(); gate.wait() }
        let sent = expectation(description: "sent")
        DispatchQueue.global().async {
            _ = self.post(Self.thread + "/text", json: #"{"text":"go on"}"#)
            sent.fulfill()
        }
        wait(for: [pasted], timeout: 5)
        let key = post(Self.thread + "/key", json: #"{"key":"Enter"}"#)
        XCTAssertEqual(key.status, 409)
        XCTAssertEqual(key.body, #"{"error":"busy","message":"A reply is being sent"}"#)
        gate.signal()
        wait(for: [sent], timeout: 5)
        // Only the text's own Enter was pressed.
        XCTAssertEqual(pane.argv.filter { $0.contains("Enter") }.count, 1)
    }

    func testAWaitingThreadShowsItsPromptAndTakesATappedAnswer() throws {
        repliesOn()
        pane.status = .waiting
        pane.screen = DemoPrompt.permission
        let shown = get(Self.thread + "/prompt")
        XCTAssertEqual(shown.status, 200)
        let prompt = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: Data(shown.body.utf8)) as? [String: Any])?["prompt"]
                as? [String: Any])
        XCTAssertEqual(prompt["kind"] as? String, "permission")
        XCTAssertEqual(prompt["title"] as? String, "Bash command")
        let id = try XCTUnwrap(prompt["id"] as? String)

        // Free text is still refused; the tapped answer goes through.
        XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"yes"}"#).status, 409)
        XCTAssertEqual(post(Self.thread + "/answer", json: #"{"prompt":"\#(id)","option":4}"#).status, 400)
        XCTAssertEqual(post(Self.thread + "/answer", json: #"{"prompt":"\#(id)","option":"1"}"#).status, 400)
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(post(Self.thread + "/answer", json: #"{"prompt":"\#(id)","option":2}"#).status, 200)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "2"]])

        // The pane moved to another prompt: the old card answers nothing.
        pane.screen = DemoPrompt.question
        let stale = post(Self.thread + "/answer", json: #"{"prompt":"\#(id)","option":1}"#)
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(stale.body, #"{"error":"stale"}"#)
        // A pane that shows its input box again has no prompt.
        pane.status = .idle
        pane.screen = DemoPrompt.permission + "\n" + DemoPrompt.idle
        XCTAssertEqual(get(Self.thread + "/prompt").body, #"{"id":null,"prompt":null,"suggestion":null}"#)
        XCTAssertEqual(pane.argv.count, 1)
    }

    func testAnUploadIsSavedInTheUploadFolderUnderASafeName() {
        // The folder is the one in Settings, never the thread's directory.
        repliesOn()
        let saved = post(Self.thread + "/upload?name=..%2F..%2F.ssh%2Fauthorized_keys", json: "demo key")
        XCTAssertEqual(saved.status, 200)
        XCTAssertEqual(saved.body, #"{"ok":true,"pasted":true,"path":"\/Users\/me\/uploads\/authorized_keys"}"#)
        XCTAssertEqual(pane.saves.map(\.path), ["/Users/me/uploads/authorized_keys"])
        XCTAssertEqual(pane.saves.first?.data, Data("demo key".utf8))
        XCTAssertEqual(pane.calls[1].stdin, "/Users/me/uploads/authorized_keys ")
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
    }

    func testAnUploadOverTheLimitOrIntoABusyThreadSavesNothing() {
        repliesOn()
        let big = post(Self.thread + "/upload?name=big.bin", json: String(repeating: "a", count: 65))
        XCTAssertEqual(big.status, 413)
        XCTAssertEqual(big.body, #"{"error":"too_large"}"#)
        XCTAssertEqual(post(Self.thread + "/upload", json: "demo").status, 400)
        XCTAssertEqual(post(Self.thread + "/upload?name=...", json: "demo").status, 400)
        XCTAssertEqual(post(Self.thread + "/upload?name=a.txt", json: "").status, 400)
        pane.status = .busy
        XCTAssertEqual(post(Self.thread + "/upload?name=a.txt", json: "demo").status, 409)
        pane.status = .waiting
        XCTAssertEqual(post(Self.thread + "/upload?name=a.txt", json: "demo").status, 409)
        XCTAssertEqual(pane.saves.count, 0)
        XCTAssertEqual(pane.argv.count, 0)

        // Past the limit in Settings, a large upload is refused on its headers:
        // none of its body is waited for.
        server.configure(MobileConfig(capabilities: [.upload], uploadLimit: 5_242_880))
        let early = "POST \(Self.thread)/upload?name=a.bin HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
            + "Tailscale-User-Login: me@example.com\r\nOrigin: \(Self.origin)\r\nX-MuxMaestro: 1\r\n"
            + "X-MuxMaestro-Token: demo-token\r\nContent-Length: 6000000\r\n\r\n"
        let refused = exchange(early, until: whole)
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 413"), refused)
        XCTAssertTrue(refused.hasSuffix(#"{"error":"too_large"}"#), refused)
        XCTAssertEqual(pane.saves.count, 0)

        // A switch that is off holds no megabytes either: refused on the headers.
        server.configure(MobileConfig(capabilities: [.replies]))
        let off = exchange(
            early.replacingOccurrences(of: "6000000", with: "20000000"), until: whole)
        XCTAssertTrue(off.hasPrefix("HTTP/1.1 403"), off)
        XCTAssertTrue(off.hasSuffix(#"{"error":"disabled"}"#), off)
        server.configure(MobileConfig(capabilities: [.upload], uploadLimit: 5_242_880))

        // Past what any setting allows, the request is refused as it is read.
        let raw = "POST \(Self.thread)/upload?name=a.bin HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
            + "Content-Length: \(MobileReply.maxUploadBytes + 1)\r\n\r\n"
        XCTAssertTrue(exchange(raw, until: whole).hasPrefix("HTTP/1.1 413"))
    }

    func testListsAThreadsCommandsFromItsHomeAndTheBuiltIns() throws {
        let skill = home.appendingPathComponent(".claude/skills/deploy")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\ndescription: Deploy to staging\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        repliesOn()
        let listed = get(Self.thread + "/commands")
        XCTAssertEqual(listed.status, 200)
        let commands = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [String: Any])?["commands"]
                as? [[String: Any]])
        XCTAssertEqual(commands.first?["name"] as? String, "deploy")
        XCTAssertEqual(commands.first?["description"] as? String, "Deploy to staging")
        XCTAssertTrue(commands.contains { $0["name"] as? String == "compact" })
    }

    // MARK: session actions and find

    private final class Counter {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }
        func add() {
            lock.lock()
            _count += 1
            lock.unlock()
        }
    }

    private func actionsOn() {
        server.configure(MobileConfig(capabilities: [.sessionActions, .kill, .find]))
    }

    /// Every session action, with a body the route would take.
    private var actions: [(path: String, body: String)] {
        [
            ("/api/tmux/new-session", #"{"host":"localhost","dir":"/Users/me/acme-app"}"#),
            ("/api/tmux/new-window", #"{"host":"localhost","session":"acme-app"}"#),
            ("/api/tmux/rename-session", #"{"host":"localhost","session":"acme-app","name":"shop"}"#),
            ("/api/tmux/rename-window", #"{"thread":"localhost:12","name":"cart"}"#),
            ("/api/tmux/zoom-pane", #"{"thread":"localhost:12"}"#),
            ("/api/tmux/kill-pane", #"{"thread":"localhost:12","confirm":true}"#),
            ("/api/tmux/kill-window", #"{"thread":"localhost:12","confirm":true}"#),
            ("/api/tmux/kill-session", #"{"thread":"localhost:12","confirm":true}"#),
            ("/api/tmux/archive-window", #"{"thread":"localhost:12"}"#),
        ]
    }

    private static let find = thread + "/find?q=test"
    private static let dirs = "/api/hosts/localhost/dirs"

    func testActionAndFindRoutesAnswer403WhileTheirSwitchesAreOff() {
        for action in actions {
            let refused = post(action.path, json: action.body)
            XCTAssertEqual(refused.status, 403, action.path)
            XCTAssertEqual(refused.body, #"{"error":"disabled"}"#, action.path)
        }
        XCTAssertEqual(get(Self.find).status, 403)
        XCTAssertEqual(get(Self.dirs).status, 403)

        // Every other switch on: still refused.
        server.configure(MobileConfig(capabilities: [.replies, .keyBar, .upload, .manager, .voice]))
        for action in actions { XCTAssertEqual(post(action.path, json: action.body).status, 403, action.path) }
        XCTAssertEqual(get(Self.find).status, 403)

        // Session actions without Kill: the kills stay refused. Find is its own.
        server.configure(MobileConfig(capabilities: [.sessionActions]))
        for action in actions where action.path.contains("kill") {
            XCTAssertEqual(post(action.path, json: action.body).status, 403, action.path)
        }
        XCTAssertEqual(get(Self.find).status, 403)
        // Kill without session actions opens nothing.
        server.configure(MobileConfig(capabilities: [.kill, .find]))
        for action in actions { XCTAssertEqual(post(action.path, json: action.body).status, 403, action.path) }
        XCTAssertEqual(get(Self.dirs).status, 403)
        XCTAssertEqual(tmux.argv.count, 0)
        XCTAssertEqual(changes.count, 0)
        XCTAssertEqual(archives.count, 0)
    }

    func testAnArchiveIsTheMacsOwnAndNeedsNoKillSwitch() {
        server.configure(MobileConfig(capabilities: [.sessionActions]))
        let done = post("/api/tmux/archive-window", json: #"{"thread":"localhost:12"}"#)
        XCTAssertEqual(done.status, 200)
        XCTAssertEqual(done.body, #"{"ok":true}"#)
        XCTAssertEqual(archives.count, 1)
        // The tree is loaded again, so the phone drops the row.
        XCTAssertEqual(changes.count, 1)

        // The Mac did not archive it.
        let failed = post("/api/tmux/archive-window", json: #"{"thread":"localhost:13"}"#)
        XCTAssertEqual(failed.status, 409)
        XCTAssertTrue(failed.body.contains(#""error":"failed""#), failed.body)
        XCTAssertEqual(post("/api/tmux/archive-window", json: #"{"thread":"localhost:99"}"#).status, 404)
        XCTAssertEqual(archives.count, 2)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testAnActionOrFindWithoutThePairingTokenIsRefusedAndRunsNothing() {
        actionsOn()
        for action in actions {
            for token in [nil, "", "wrong", "demo-tokeN", "demo-token-2"] as [String?] {
                let refused = post(action.path, json: action.body, token: token)
                XCTAssertEqual(refused.status, 401, action.path)
                XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#, action.path)
            }
        }
        XCTAssertEqual(get(Self.find, token: nil).status, 401)
        XCTAssertEqual(get(Self.find, token: "wrong").status, 401)
        XCTAssertEqual(get(Self.dirs, token: nil).status, 401)
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testAnActionFromAnotherOriginIsRefusedAndRunsNothing() {
        actionsOn()
        for action in actions {
            for origin in [
                nil, "https://evil.example", "http://devmac.example.ts.net:7433",
                "https://devmac.example.ts.net", "https://devmac.example.ts.net:5173", "null",
            ] as [String?] {
                let refused = post(action.path, json: action.body, origin: origin)
                XCTAssertEqual(refused.status, 403, "\(action.path) \(origin ?? "none")")
                XCTAssertEqual(refused.body, #"{"error":"forbidden"}"#, action.path)
            }
            XCTAssertEqual(post(action.path, json: action.body, writeHeader: false).status, 403, action.path)
        }
        // Not this Mac's login, or not its name: a read is refused too.
        XCTAssertEqual(get(Self.find, login: "other@example.com").status, 403)
        XCTAssertEqual(get(Self.find, login: nil).status, 403)
        XCTAssertEqual(get(Self.find, host: "127.0.0.1:7433").status, 403)
        XCTAssertEqual(tmux.argv.count, 0)
        XCTAssertEqual(changes.count, 0)
    }

    func testAnUnknownActionIsA400AndRunsNothing() {
        actionsOn()
        for word in ["kill-server", "send-keys", "run-shell", "split-window", "kill", "new-window%3Bkill-server"] {
            let refused = post("/api/tmux/\(word)", json: #"{"thread":"localhost:12","confirm":true}"#)
            XCTAssertEqual(refused.status, 400, word)
            XCTAssertEqual(refused.body, #"{"error":"bad_action"}"#, word)
        }
        XCTAssertEqual(get("/api/tmux/new-window").status, 405)
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testAnActionOnATargetThatIsNotInTheLiveTreeIsA404() {
        actionsOn()
        // A thread action names a thread; a session action a host and a session.
        let byThread = ["rename-window", "zoom-pane", "kill-pane", "kill-window", "new-window"]
        for id in ["localhost:99", "devbox:12", "%12", "localhost:12/../13"] {
            for action in byThread {
                let body = #"{"thread":"\#(id)","name":"x","confirm":true}"#
                XCTAssertEqual(post("/api/tmux/\(action)", json: body).status, 404, "\(action) \(id)")
            }
        }
        let bySession = ["new-window", "rename-session"]
        for (host, session) in [("localhost", "gone"), ("devbox", "acme-app"), ("localhost", "acme")] {
            for action in bySession {
                let body = #"{"host":"\#(host)","session":"\#(session)","name":"x","confirm":true}"#
                XCTAssertEqual(post("/api/tmux/\(action)", json: body).status, 404, "\(action) \(host)")
            }
        }
        XCTAssertEqual(post("/api/tmux/new-session", json: #"{"host":"devbox"}"#).status, 404)
        XCTAssertEqual(get("/api/hosts/devbox/dirs").status, 404)
        XCTAssertEqual(get("/api/threads/localhost%3A99/find?q=test").status, 404)
        XCTAssertEqual(tmux.argv.count, 0)
        XCTAssertEqual(changes.count, 0)
    }

    func testABadNameIsA400AndRunsNothing() {
        actionsOn()
        for name in ["a:b", "a.b", "-t", "=acme", "$(id)", "a;b", "", String(repeating: "a", count: 65)] {
            for (path, target) in [
                ("/api/tmux/rename-window", #""thread":"localhost:12""#),
                ("/api/tmux/rename-session", #""host":"localhost","session":"acme-app""#),
                ("/api/tmux/new-session", #""host":"localhost""#),
            ] {
                let refused = post(path, json: "{\(target),\"name\":\"\(name)\"}")
                XCTAssertEqual(refused.status, 400, "\(path) \(name)")
                XCTAssertEqual(refused.body, #"{"error":"bad_name"}"#, "\(path) \(name)")
            }
        }
        XCTAssertEqual(tmux.argv.count, 0)
    }

    func testAKillWithoutConfirmIsRefusedAndWithItRuns() {
        actionsOn()
        let kills: [(String, String, [String])] = [
            ("/api/tmux/kill-pane", #""thread":"localhost:12""#, ["kill-pane", "-t", "%12"]),
            ("/api/tmux/kill-window", #""thread":"localhost:13""#, ["kill-window", "-t", "%13"]),
            ("/api/tmux/kill-session", #""thread":"localhost:12""#, ["kill-session", "-t", "$1"]),
        ]
        for (path, target, _) in kills {
            for body in ["{\(target)}", "{\(target),\"confirm\":false}", "{\(target),\"confirm\":\"true\"}"] {
                let refused = post(path, json: body)
                XCTAssertEqual(refused.status, 400, "\(path) \(body)")
                XCTAssertEqual(refused.body, #"{"error":"confirm_required"}"#, path)
            }
        }
        XCTAssertEqual(tmux.argv.count, 0)
        XCTAssertEqual(changes.count, 0)

        for (path, target, _) in kills {
            XCTAssertEqual(post(path, json: "{\(target),\"confirm\":true}").status, 200, path)
        }
        XCTAssertEqual(tmux.argv, kills.map(\.2))
        // The app is told to load the tree again after each one.
        XCTAssertEqual(changes.count, 3)
    }

    func testANewWindowAnswersWithItsThreadAndTheDirectoriesAreServed() throws {
        actionsOn()
        tmux.output = "3\t%41\n"
        let made = post("/api/tmux/new-window", json: #"{"host":"localhost","session":"acme-app"}"#)
        XCTAssertEqual(made.status, 200)
        XCTAssertEqual(made.body, #"{"ok":true,"thread":"localhost:41"}"#)
        XCTAssertEqual(tmux.argv.last, [
            "new-window", "-a", "-t", "$1:", "-P", "-F", "#{window_index}\t#{pane_id}",
            "-c", "/Users/me/acme-app",
        ])
        // Where the threads work, and the home to start browsing from.
        let offered = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get(Self.dirs).body.utf8)) as? [String: Any])
        XCTAssertEqual(offered["dirs"] as? [String], ["/Users/me/acme-app"])
        XCTAssertEqual(offered["home"] as? String, home.path)
        // A directory of the home tree is listed from the disk.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("code/acme app"), withIntermediateDirectories: true)
        let asked = home.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let listed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get(Self.dirs + "?path=\(asked)%2Fcode").body.utf8))
                as? [String: Any])
        XCTAssertEqual(listed["dirs"] as? [String], [home.path + "/code/acme app"])
        XCTAssertEqual(listed["parent"] as? String, home.path)
        XCTAssertEqual(get(Self.dirs + "?path=%2Fetc").body, #"{"error":"bad_dir"}"#)
        XCTAssertEqual(get(Self.dirs + "?path=\(asked)%2Fcode%2F..%2F..").status, 400)
        // And a session starts in one, with an agent and its first prompt.
        let spun = post(
            "/api/tmux/new-session",
            json: #"{"host":"localhost","dir":"\#(home.path)/code/acme app","agent":"claude","prompt":"it's $(id)"}"#)
        XCTAssertEqual(spun.status, 200)
        XCTAssertTrue(spun.body.contains(#""thread":"localhost:41""#), spun.body)
        XCTAssertTrue(spun.body.contains(#""agent":"claude""#), spun.body)
        XCTAssertEqual(tmux.argv.suffix(2), [
            ["new-session", "-d", "-s", "acme app", "-P", "-F", "#{window_index}\t#{pane_id}",
             "-c", home.path + "/code/acme app"],
            ["send-keys", "-t", "%41", #"claude 'it'\''s $(id)'"#, "Enter"],
        ])
        // A directory the server did not offer starts nothing.
        let before = tmux.argv.count
        let refused = post("/api/tmux/new-session", json: #"{"host":"localhost","dir":"/etc"}"#)
        XCTAssertEqual(refused.status, 400)
        XCTAssertEqual(refused.body, #"{"error":"bad_dir"}"#)
        XCTAssertEqual(tmux.argv.count, before)
        // No directory: this Mac's home, from the server's own settings.
        XCTAssertEqual(post("/api/tmux/new-session", json: #"{"host":"localhost"}"#).status, 200)
        XCTAssertEqual(tmux.argv.last, ["new-session", "-d", "-s", "session", "-c", home.path])
        tmux.missing = true
        XCTAssertEqual(post("/api/tmux/zoom-pane", json: #"{"thread":"localhost:12"}"#).status, 503)
    }

    func testAStaleKillIsDoneAndAnyOtherTmuxErrorIsA409() {
        actionsOn()
        tmux.failing = true
        tmux.failure = "can't find pane: %12"
        let gone = post("/api/tmux/kill-window", json: #"{"thread":"localhost:12","confirm":true}"#)
        XCTAssertEqual(gone.status, 200)
        XCTAssertEqual(gone.body, #"{"gone":true,"ok":true}"#)
        // The tree is loaded again, so the phone drops the row.
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(post("/api/tmux/zoom-pane", json: #"{"thread":"localhost:12"}"#).status, 404)

        tmux.failure = "server exited unexpectedly"
        let failed = post("/api/tmux/kill-window", json: #"{"thread":"localhost:12","confirm":true}"#)
        XCTAssertEqual(failed.status, 409)
        XCTAssertTrue(failed.body.contains(#""error":"failed""#), failed.body)
        XCTAssertEqual(changes.count, 1)
    }

    func testOnlySoManyFindsRunAtOnce() {
        restart(limits: MobileServer.Limits(maxFinds: 1))
        actionsOn()
        tmux.output = "\(PaneSearch.marker)%12\n$ make test\nok\n"
        let gate = DispatchSemaphore(value: 0)
        tmux.gate = gate
        let first = expectation(description: "first find answered")
        var status = 0
        DispatchQueue.global().async {
            status = self.get(Self.find).status
            first.fulfill()
        }
        // The first find is inside tmux now.
        let deadline = Date().addingTimeInterval(5)
        while tmux.argv.count < 1, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(tmux.argv.count, 1)
        let second = get(Self.find)
        XCTAssertEqual(second.status, 409)
        XCTAssertTrue(second.body.contains(#""error":"busy""#), second.body)
        XCTAssertEqual(tmux.argv.count, 1)

        tmux.gate = nil
        gate.signal()
        wait(for: [first], timeout: 5)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(get(Self.find).status, 200)
    }

    func testFindSearchesTheThreadsPaneAndRefusesABadQuery() throws {
        actionsOn()
        tmux.output = "\(PaneSearch.marker)%12\n$ make test\nok\n"
        let found = get(Self.find)
        XCTAssertEqual(found.status, 200)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(found.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "$ make test\nok")
        XCTAssertEqual((body["matches"] as? [[String: Any]])?.first?["line"] as? Int, 0)
        XCTAssertEqual(tmux.argv.count, 1)
        XCTAssertEqual(tmux.argv[0].suffix(2), ["-t", "%12"])

        let long = String(repeating: "a", count: MobileFind.maxQueryLength + 1)
        for query in ["", "%20%20", long, "a%0Ab", "a%1B%5B31m"] {
            let refused = get(Self.thread + "/find?q=\(query)")
            XCTAssertEqual(refused.status, 400, query)
            XCTAssertEqual(refused.body, #"{"error":"bad_query"}"#, query)
        }
        XCTAssertEqual(get(Self.thread + "/find").status, 400)
        XCTAssertEqual(tmux.argv.count, 1)
        // A find is a read: it does not make the app load the tree again.
        XCTAssertEqual(changes.count, 0)
    }

    // MARK: artifacts and local servers

    /// What the transcript, the Running scan and `PhoneLink` would answer,
    /// scripted. It records what the server asks of them.
    private final class FakeLocal {
        typealias Open = (port: Int, https: Bool, thread: String, label: String, host: String?)
        private let lock = NSLock()
        private var _artifacts: MobileArtifactSource?
        private var _running: RunningSet?
        private var _opened = MobileServing.Opened.ok
        private var _mappings: [MobilePortMapping] = []
        private var _opens: [Open] = []
        private var _closes: [Int] = []
        private var _reads = 0

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var artifacts: MobileArtifactSource? {
            get { locked { _artifacts } }
            set { locked { _artifacts = newValue } }
        }
        var running: RunningSet? {
            get { locked { _running } }
            set { locked { _running = newValue } }
        }
        var opened: MobileServing.Opened {
            get { locked { _opened } }
            set { locked { _opened = newValue } }
        }
        var mappings: [MobilePortMapping] {
            get { locked { _mappings } }
            set { locked { _mappings = newValue } }
        }
        var opens: [Open] { locked { _opens } }
        var closes: [Int] { locked { _closes } }
        /// How often the transcript or the Running scan was asked.
        var reads: Int { locked { _reads } }

        var artifactSource: (MobileThread) -> MobileArtifactSource? {
            { [self] _ in locked { _reads += 1; return _artifacts } }
        }
        var runningSource: (MobileThread) -> RunningSet? {
            { [self] _ in locked { _reads += 1; return _running } }
        }
        var serving: MobileServer.Serving {
            MobileServer.Serving(
                open: { [self] port, https, thread, label, host in
                    locked { _opens.append((port, https, thread, label, host)); return _opened }
                },
                close: { [self] port in
                    locked { _closes.append(port); return _mappings.contains { $0.port == port } }
                },
                list: { [self] in locked { _mappings } })
        }
    }

    /// The folder the thread works in, for the tests that read files.
    private var project: URL { root.appendingPathComponent("acme-app") }

    private func localOn() {
        server.configure(MobileConfig(capabilities: [.artifacts, .localServers]))
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        server.update(snapshot(cwd: project.path))
    }

    /// A dev server on https, one on http, and a Supabase stack, on this Mac.
    private func demoRunning() -> RunningSet {
        RunningSet(
            known: true,
            resources: [
                RunningResource(
                    kind: .server(port: 5173), host: Running.localHostName, paneID: "%12",
                    label: "acme-app", tooltip: "", url: "https://localhost:5173", pid: 4242),
                RunningResource(
                    kind: .server(port: 6006), host: Running.localHostName, paneID: "%12",
                    label: "acme-app", tooltip: "", url: "http://localhost:6006", pid: 4243),
                RunningResource(
                    kind: .server(port: port), host: Running.localHostName, paneID: "%12",
                    label: "acme-app", tooltip: "", url: "http://localhost:\(port)", pid: 4244),
                RunningResource(
                    kind: .container(name: "acme-app", ports: [54322, 54323], count: 10),
                    host: Running.localHostName, paneID: "%12", label: "acme-app", tooltip: "",
                    url: "http://localhost:54323",
                    links: [
                        RunningLink(label: "Studio", url: "http://localhost:54323", action: .open),
                        RunningLink(
                            label: "DB", url: "postgresql://postgres:postgres@localhost:54322/postgres",
                            action: .copy),
                    ],
                    isSupabaseStack: true),
            ],
            unknowns: [])
    }

    private func demoFile(_ name: String, _ text: String) throws -> Artifact {
        let url = project.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return Artifact(
            kind: ArtifactScanner.kind(of: url.path), path: url.path,
            at: Date(timeIntervalSince1970: 1_700_000_000), exists: true)
    }

    private static let artifacts = thread + "/artifacts"
    private static let file = thread + "/file?id=0123456789abcdef0123456789abcdef"
    private static let running = thread + "/running"
    private static let openBody = #"{"thread":"localhost:12","port":5173}"#
    private static let closeBody = #"{"port":5173}"#
    private var localReads: [String] { [Self.artifacts, Self.file, Self.running, "/api/servers"] }
    private var localWrites: [(path: String, body: String)] {
        [("/api/servers/open", Self.openBody), ("/api/servers/close", Self.closeBody)]
    }

    func testArtifactAndServerRoutesAnswer403WhileTheirSwitchesAreOff() {
        local.running = demoRunning()
        let allRefused = { [self] (note: String) in
            for path in localReads {
                let refused = get(path)
                XCTAssertEqual(refused.status, 403, "\(note) \(path)")
                XCTAssertEqual(refused.body, #"{"error":"disabled"}"#, "\(note) \(path)")
            }
            for write in localWrites {
                let refused = post(write.path, json: write.body)
                XCTAssertEqual(refused.status, 403, "\(note) \(write.path)")
                XCTAssertEqual(refused.body, #"{"error":"disabled"}"#, "\(note) \(write.path)")
            }
        }
        allRefused("default")
        // Every other switch on: still refused.
        server.configure(MobileConfig(capabilities: Set(MobileCapability.allCases)
            .subtracting([.artifacts, .localServers])))
        allRefused("others on")

        // Each switch opens its own routes only.
        server.configure(MobileConfig(capabilities: [.artifacts]))
        XCTAssertEqual(get(Self.artifacts).status, 200)
        XCTAssertEqual(get(Self.running).status, 403)
        XCTAssertEqual(get("/api/servers").status, 403)
        for write in localWrites { XCTAssertEqual(post(write.path, json: write.body).status, 403) }
        XCTAssertEqual(local.opens.count, 0)
        XCTAssertEqual(local.closes, [])

        server.configure(MobileConfig(capabilities: [.localServers]))
        XCTAssertEqual(get(Self.running).status, 200)
        XCTAssertEqual(get(Self.artifacts).status, 403)
        XCTAssertEqual(get(Self.file).status, 403)
        // Stop is its own switch, and its route is not built.
        XCTAssertEqual(post("/api/servers/5173/stop", json: "{}").status, 403)
    }

    func testAnArtifactOrServerRequestWithoutThePairingTokenIsRefusedAndReadsNothing() {
        localOn()
        local.running = demoRunning()
        for token in [nil, "", "wrong", "demo-tokeN", "demo-token-2"] as [String?] {
            for path in localReads {
                let refused = get(path, token: token)
                XCTAssertEqual(refused.status, 401, path)
                XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#, path)
            }
            for write in localWrites {
                let refused = post(write.path, json: write.body, token: token)
                XCTAssertEqual(refused.status, 401, write.path)
                XCTAssertEqual(refused.body, #"{"error":"unpaired"}"#, write.path)
            }
        }
        XCTAssertEqual(local.reads, 0)
        XCTAssertEqual(local.opens.count, 0)
        XCTAssertEqual(local.closes, [])
    }

    func testAServerWriteFromAnotherOriginIsRefusedAndPublishesNothing() {
        localOn()
        local.running = demoRunning()
        local.mappings = [MobilePortMapping(
            port: 5173, thread: "localhost:12", label: "acme-app", https: true, openedAt: Date())]
        for write in localWrites {
            for origin in [
                nil, "https://evil.example", "http://devmac.example.ts.net:7433",
                "https://devmac.example.ts.net", "https://devmac.example.ts.net:5173", "null",
            ] as [String?] {
                let refused = post(write.path, json: write.body, origin: origin)
                XCTAssertEqual(refused.status, 403, "\(write.path) \(origin ?? "none")")
                XCTAssertEqual(refused.body, #"{"error":"forbidden"}"#, write.path)
            }
            XCTAssertEqual(post(write.path, json: write.body, writeHeader: false).status, 403, write.path)
            // A write is never a GET.
            XCTAssertEqual(get(write.path).status, 405, write.path)
        }
        // Not this Mac's login, or not its name: a read is refused too.
        for path in localReads {
            XCTAssertEqual(get(path, login: "other@example.com").status, 403, path)
            XCTAssertEqual(get(path, login: nil).status, 403, path)
            XCTAssertEqual(get(path, host: "127.0.0.1:7433").status, 403, path)
            XCTAssertEqual(get(path, host: "evil.example").status, 403, path)
        }
        XCTAssertEqual(local.reads, 0)
        XCTAssertEqual(local.opens.count, 0)
        XCTAssertEqual(local.closes, [])
    }

    func testListsAThreadsArtifactsAndServesOneFileByItsId() throws {
        localOn()
        let plan = try demoFile("PLAN.md", "# Plan")
        let page = try demoFile("report.html", "<script>alert(1)</script>")
        let picture = try demoFile("drawing.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
        let secret = try demoFile(".env", "TOKEN=1")
        local.artifacts = ([plan, page, picture, secret], [ArtifactWebItem(
            url: "https://example.com/docs", host: "example.com", path: "/docs", at: nil, live: nil)])

        let listed = get(Self.artifacts)
        XCTAssertEqual(listed.status, 200)
        XCTAssertTrue(listed.head.contains("Cache-Control: no-store"))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [String: Any])
        let files = try XCTUnwrap(body["files"] as? [[String: Any]])
        XCTAssertEqual(files.map { $0["name"] as? String }, ["PLAN.md", "report.html", "drawing.svg"])
        XCTAssertEqual(files.map { $0["kind"] as? String }, ["markdown", "html", "image"])
        XCTAssertEqual((body["links"] as? [[String: Any]])?.first?["url"] as? String, "https://example.com/docs")
        // The list no longer says where the thread runs: any host has files.
        XCTAssertNil(body["remote"])

        let types = [
            "text/plain; charset=utf-8", "text/html; charset=utf-8", "image/svg+xml",
        ]
        for (index, artifact) in [plan, page, picture].enumerated() {
            let id = try XCTUnwrap(files[index]["id"] as? String)
            XCTAssertEqual(id, MobileArtifacts.id(path: artifact.path))
            let served = get(Self.thread + "/file?id=\(id)")
            XCTAssertEqual(served.status, 200, artifact.name)
            XCTAssertTrue(served.head.contains("Content-Type: \(types[index])\r\n"), served.head)
            XCTAssertTrue(served.head.contains("X-Content-Type-Options: nosniff"), artifact.name)
            XCTAssertTrue(served.head.contains(
                "Content-Security-Policy: sandbox; default-src 'none'; style-src 'unsafe-inline'; "
                    + "img-src data:; font-src data:"), artifact.name)
            XCTAssertTrue(served.head.contains("Content-Disposition: attachment"), artifact.name)
            XCTAssertTrue(served.head.contains("Cross-Origin-Resource-Policy: same-origin"), artifact.name)
            XCTAssertTrue(served.head.contains("Cache-Control: no-store"), artifact.name)
        }
        XCTAssertEqual(
            get(Self.thread + "/file?id=\(MobileArtifacts.id(path: page.path))").body,
            "<script>alert(1)</script>")
        // A file is read, never written.
        XCTAssertEqual(get(Self.thread + "/file?id=\(MobileArtifacts.id(path: plan.path))", method: "POST").status, 403)
    }

    func testAFileIsOnlyEverNamedByAnIdOfTheThreadsOwnList() throws {
        localOn()
        let plan = try demoFile("PLAN.md", "# Plan")
        let secret = try demoFile(".env", "TOKEN=1")
        let other = try demoFile("notes.txt", "not in the list")
        local.artifacts = ([plan, secret], [])
        let encoded = { (text: String) in
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        }
        for query in [
            "", "?id=", "?path=\(encoded(plan.path))", "?path=/etc/passwd", "?id=\(encoded(plan.path))",
            "?id=\(encoded(other.path))", "?id=PLAN.md", "?id=..%2F..%2F..%2Fetc%2Fpasswd",
            "?id=%2e%2e%2f%2e%2e%2fetc%2fpasswd", "?id=..", "?id=%2Fetc%2Fpasswd",
            "?id=\(MobileArtifacts.id(path: other.path))", "?id=\(MobileArtifacts.id(path: secret.path))",
            "?id=\(MobileArtifacts.id(path: plan.path))%00", "?id=\(MobileArtifacts.id(path: plan.path).uppercased())",
        ] {
            let refused = get(Self.thread + "/file" + query)
            XCTAssertEqual(refused.status, 404, query)
            XCTAssertEqual(refused.body, #"{"error":"not_found"}"#, query)
        }
        // A path in the URL is no route at all.
        XCTAssertEqual(get(Self.thread + "/file/..%2F..%2Fetc%2Fpasswd").status, 404)
        XCTAssertEqual(get(Self.thread + "/file/" + MobileArtifacts.id(path: plan.path)).status, 404)
        // A thread that is not in the live tree has no list.
        let id = MobileArtifacts.id(path: plan.path)
        XCTAssertEqual(get("/api/threads/localhost%3A99/file?id=\(id)").status, 404)
        XCTAssertEqual(get("/api/threads/localhost%3A99/artifacts").status, 404)
        XCTAssertEqual(get(Self.thread + "/file?id=\(id)").status, 200)
    }

    func testASymlinkAnOversizeFileAndAMissingFileAreNotServed() throws {
        localOn()
        let fm = FileManager.default
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("notes.txt"))
        let link = project.appendingPathComponent("shot.png").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: outside.path + "/notes.txt")
        let folder = project.appendingPathComponent("out").path
        try fm.createSymbolicLink(atPath: folder, withDestinationPath: outside.path)
        let big = project.appendingPathComponent("big.log")
        XCTAssertTrue(fm.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(MobileArtifacts.maxFileBytes) + 1)
        try handle.close()
        let gone = project.appendingPathComponent("gone.md").path
        let paths = [link, folder + "/notes.txt", big.path, gone]
        local.artifacts = (paths.map {
            Artifact(kind: ArtifactScanner.kind(of: $0), path: $0, at: Date(), exists: true)
        }, [])

        let status = { [self] (path: String) in
            get(Self.thread + "/file?id=\(MobileArtifacts.id(path: path))")
        }
        XCTAssertEqual(status(link).status, 404)
        XCTAssertEqual(status(folder + "/notes.txt").status, 404)
        XCTAssertEqual(status(gone).status, 404)
        let large = status(big.path)
        XCTAssertEqual(large.status, 413)
        XCTAssertEqual(large.body, #"{"error":"too_large"}"#)
    }

    /// A transcript can name any path: an edit that was refused still lists
    /// its file. Only what lies in the thread's own folder reaches the phone.
    func testAListedFileOutsideTheThreadsFolderIsNotOfferedAndAnswers404() throws {
        localOn()
        let fm = FileManager.default
        let plan = try demoFile("PLAN.md", "# Plan")
        var outsiders: [Artifact] = []
        for relative in [
            ".config/gh/hosts.yml", ".kube/config", ".docker/config.json", ".git-credentials", ".pgpass",
            ".zsh_history", "other-app/notes.md",
        ] {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: url)
            outsiders.append(Artifact(kind: .file, path: url.path, at: Date(), exists: true))
        }
        local.artifacts = (outsiders + [plan], [])

        let listed = get(Self.artifacts)
        XCTAssertEqual(listed.status, 200)
        XCTAssertFalse(listed.body.contains("hosts.yml"))
        XCTAssertFalse(listed.body.contains("other-app"))
        let files = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [String: Any])?["files"]
                as? [[String: Any]])
        XCTAssertEqual(files.map { $0["name"] as? String }, ["PLAN.md"])
        for outsider in outsiders {
            let refused = get(Self.thread + "/file?id=\(MobileArtifacts.id(path: outsider.path))")
            XCTAssertEqual(refused.status, 404, outsider.path)
            XCTAssertFalse(refused.body.contains("secret"), outsider.path)
        }
        XCTAssertEqual(get(Self.thread + "/file?id=\(MobileArtifacts.id(path: plan.path))").body, "# Plan")
    }

    func testServesWhatAThreadHasRunningWithoutAnyAddress() throws {
        localOn()
        local.running = demoRunning()
        let listed = get(Self.running)
        XCTAssertEqual(listed.status, 200)
        XCTAssertFalse(listed.body.contains("postgres"))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["known"] as? Bool, true)
        let servers = try XCTUnwrap(body["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.map { $0["port"] as? Int }, [5173, 6006, port])
        // The phone server's own port is listed and can never be opened.
        XCTAssertEqual(servers.map { $0["mappable"] as? Bool }, [true, true, false])
        XCTAssertEqual(servers.map { $0["https"] as? Bool }, [true, false, false])
        let links = try XCTUnwrap((body["stacks"] as? [[String: Any]])?.first?["links"] as? [[String: Any]])
        XCTAssertEqual(links.map { $0["label"] as? String }, ["Studio", "DB"])
        XCTAssertEqual(links.map { $0["mappable"] as? Bool }, [true, false])

        XCTAssertEqual(get("/api/threads/localhost%3A99/running").status, 404)
        // The pane went away between the tree and the scan.
        local.running = nil
        XCTAssertEqual(get(Self.running).status, 404)
    }

    func testOpeningAServerPublishesOnlyAPortRunningReportsForThatThread() throws {
        localOn()
        local.running = demoRunning()
        let opened = post("/api/servers/open", json: Self.openBody)
        XCTAssertEqual(opened.status, 200)
        XCTAssertEqual(opened.body, #"{"port":5173,"url":"https:\/\/devmac.example.ts.net:5173\/"}"#)
        XCTAssertEqual(local.opens.count, 1)
        // What it is comes from the Mac's own list: https, and its label.
        XCTAssertEqual(local.opens[0].port, 5173)
        XCTAssertEqual(local.opens[0].https, true)
        XCTAssertEqual(local.opens[0].thread, "localhost:12")
        XCTAssertEqual(local.opens[0].label, "acme-app")
        XCTAssertEqual(post("/api/servers/open", json: #"{"thread":"localhost:12","port":54323}"#).status, 200)
        XCTAssertEqual(local.opens[1].https, false)
        XCTAssertEqual(local.opens[1].label, "acme-app Studio")

        // A host, a URL or a scheme in the body is not read.
        let stuffed = post("/api/servers/open", json: """
            {"thread":"localhost:12","port":6006,"host":"evil.example","url":"http://evil.example:80",
            "target":"http://169.254.169.254","https":true,"funnel":true,"label":"x"}
            """)
        XCTAssertEqual(stuffed.status, 200)
        XCTAssertEqual(stuffed.body, #"{"port":6006,"url":"https:\/\/devmac.example.ts.net:6006\/"}"#)
        XCTAssertEqual(local.opens[2].port, 6006)
        XCTAssertEqual(local.opens[2].https, false)
        XCTAssertEqual(local.opens[2].label, "acme-app")
        XCTAssertNil(local.opens[2].host)
        let count = local.opens.count

        // Not a port number.
        for body in [
            "", "{}", #"{"thread":"localhost:12"}"#, #"{"thread":"localhost:12","port":"5173"}"#,
            #"{"thread":"localhost:12","port":true}"#, #"{"thread":"localhost:12","port":5173.5}"#,
            #"{"thread":"localhost:12","port":-5173}"#, #"{"thread":"localhost:12","port":65536}"#,
            #"{"thread":"localhost:12","port":"localhost:5173"}"#,
            #"{"thread":"localhost:12","port":"http://evil.example"}"#, #"{"port":5173}"#,
        ] {
            let refused = post("/api/servers/open", json: body)
            XCTAssertEqual(refused.status, 400, body)
            XCTAssertEqual(refused.body, #"{"error":"bad_request"}"#, body)
        }
        // The phone server's own port, and a privileged one.
        for port in [self.port, 22, 80, 443, 1023] {
            let refused = post("/api/servers/open", json: #"{"thread":"localhost:12","port":\#(port)}"#)
            XCTAssertEqual(refused.status, 403, "\(port)")
            XCTAssertEqual(refused.body, #"{"error":"refused"}"#, "\(port)")
        }
        // Nothing of this thread runs there: not listed, the database, another thread's.
        for port in [3000, 54322, 8080] {
            let refused = post("/api/servers/open", json: #"{"thread":"localhost:12","port":\#(port)}"#)
            XCTAssertEqual(refused.status, 404, "\(port)")
            XCTAssertEqual(refused.body, #"{"error":"not_running"}"#, "\(port)")
        }
        // A thread that is not in the live tree.
        let stale = post("/api/servers/open", json: #"{"thread":"localhost:99","port":5173}"#)
        XCTAssertEqual(stale.status, 404)
        XCTAssertEqual(stale.body, #"{"error":"not_found"}"#)
        // The server it named has stopped since.
        local.running = RunningSet(known: true, resources: [], unknowns: [])
        XCTAssertEqual(post("/api/servers/open", json: Self.openBody).body, #"{"error":"not_running"}"#)
        XCTAssertEqual(local.opens.count, count)
    }

    func testAPortOnAnotherHostIsOpenedWithTheHostRunningNamesAndNoOther() {
        localOn()
        local.running = RunningSet(
            known: true,
            resources: [RunningResource(
                kind: .server(port: 3000), host: "devbox", paneID: "%12", label: "acme-app",
                tooltip: "", url: nil, pid: 4242)],
            unknowns: [])
        let opened = post(
            "/api/servers/open",
            json: #"{"thread":"localhost:12","port":3000,"host":"evil.example","alias":"-oProxyCommand=id"}"#)
        XCTAssertEqual(opened.status, 200)
        XCTAssertEqual(local.opens.count, 1)
        XCTAssertEqual(local.opens[0].port, 3000)
        XCTAssertEqual(local.opens[0].host, "devbox")
        // A port that host runs, but not for this thread, and a privileged one.
        XCTAssertEqual(post("/api/servers/open", json: #"{"thread":"localhost:12","port":3001}"#).status, 404)
        XCTAssertEqual(post("/api/servers/open", json: #"{"thread":"localhost:12","port":22}"#).status, 403)
        XCTAssertEqual(local.opens.count, 1)
    }

    func testTheLinksRefusalsReachThePhoneAndMappingsAreListedAndClosed() throws {
        localOn()
        local.running = demoRunning()
        local.opened = .taken
        let taken = post("/api/servers/open", json: Self.openBody)
        XCTAssertEqual(taken.status, 409)
        XCTAssertEqual(taken.body, #"{"error":"taken"}"#)
        local.opened = .limit
        XCTAssertEqual(post("/api/servers/open", json: Self.openBody).body, #"{"error":"limit"}"#)
        local.opened = .refused
        XCTAssertEqual(post("/api/servers/open", json: Self.openBody).status, 403)
        local.opened = .unavailable("tailscale serve failed")
        let failed = post("/api/servers/open", json: Self.openBody)
        XCTAssertEqual(failed.status, 503)
        XCTAssertEqual(failed.body, #"{"error":"unavailable","message":"tailscale serve failed"}"#)

        XCTAssertEqual(get("/api/servers").body, #"{"mappings":[],"max":5}"#)
        local.mappings = [
            MobilePortMapping(port: 6006, thread: "localhost:12", label: "storybook", https: false, openedAt: Date()),
            MobilePortMapping(port: 5173, thread: "localhost:12", label: "acme-app", https: true, openedAt: Date()),
        ]
        let listed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get("/api/servers").body.utf8)) as? [String: Any])
        let mappings = try XCTUnwrap(listed["mappings"] as? [[String: Any]])
        XCTAssertEqual(mappings.map { $0["port"] as? Int }, [5173, 6006])
        XCTAssertEqual(mappings[0]["url"] as? String, "https://devmac.example.ts.net:5173/")

        XCTAssertEqual(post("/api/servers/close", json: Self.closeBody).body, #"{"ok":true}"#)
        // Not a mapping this app made.
        let unknown = post("/api/servers/close", json: #"{"port":3000}"#)
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(local.closes, [5173, 3000])
        for body in ["", "{}", #"{"port":"5173"}"#, #"{"port":true}"#, #"{"port":5173.5}"#] {
            XCTAssertEqual(post("/api/servers/close", json: body).status, 400, body)
        }
        XCTAssertEqual(local.closes, [5173, 3000])
    }

    func testWithoutASourceTheArtifactAndServerRoutesAnswer503() {
        server.stop()
        server = makeServer(withLocal: false)
        start(server)
        localOn()
        for path in localReads { XCTAssertEqual(get(path).status, 503, path) }
        for write in localWrites { XCTAssertEqual(post(write.path, json: write.body).status, 503, write.path) }
    }

    // MARK: replies, second review

    private func promptID() throws -> String {
        try XCTUnwrap(
            (JSONSerialization.jsonObject(with: Data(get(Self.thread + "/prompt").body.utf8))
                as? [String: Any])?["id"] as? String)
    }

    func testAnInputBoxWithAnythingButItsFooterBelowItIsNotAnInputBox() {
        repliesOn()
        // The agent exited: its last input box is still on screen, and a
        // shell prompt is under it. Text and Enter would go to the shell.
        for below in ["$ rm -i build\nremove build? [y/N] ", "$ ", ":", "  (END)\n~\n~\n~\n~\n~"] {
            for id in ["localhost%3A12", "localhost%3A13"] {
                pane.status = id.hasSuffix("12") ? .idle : nil
                pane.screen = DemoPrompt.idle + "\n" + below
                let refused = post("/api/threads/\(id)/text", json: #"{"text":"y"}"#)
                XCTAssertEqual(refused.status, 409, below)
                XCTAssertEqual(
                    refused.body, #"{"error":"no_input","message":"Thread shows no input box"}"#, below)
            }
        }
        XCTAssertEqual(pane.argv.count, 0)
        // The box with only its footer under it takes text.
        pane.status = .idle
        pane.screen = DemoPrompt.idle
        XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"go on"}"#).status, 200)
    }

    func testNoKeyGoesToAPromptThatCameUpAfterThePaste() {
        repliesOn()
        // By status, and by screen alone.
        for byScreen in [false, true] {
            pane.status = .idle
            pane.screen = DemoPrompt.idle
            pane.statusAfterPaste = byScreen ? nil : .waiting
            pane.screenAfterPaste = DemoPrompt.permission
            let before = pane.argv.count
            let refused = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
            XCTAssertEqual(refused.status, 409)
            // The text may still be in the hidden input box: the phone is told so.
            XCTAssertEqual(
                refused.body,
                #"{"cleared":false,"error":"not_sent","message":"Thread is waiting on a prompt","reason":"waiting"}"#)
            // The paste, and nothing after it: no Ctrl-U, no Enter.
            XCTAssertEqual(
                pane.argv.dropFirst(before).map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
        }
    }

    func testANumberedPromptIsNeverDroppedForAStaleBoxOrPassedAsAnEcho() {
        repliesOn()
        // A prompt, a stale input box under it, and a shell line under that.
        pane.screen = DemoPrompt.permission + "\n" + DemoPrompt.idle + "\n$ "
        let stale = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(stale.body, #"{"error":"waiting","message":"Thread is waiting on a prompt"}"#)
        XCTAssertEqual(pane.argv.count, 0)

        // A prompt drawn between two rules with the cursor on its first row,
        // and a reply that holds its option lines.
        pane.screen = DemoPrompt.idle
        pane.screenAfterPaste = "────────\n❯ 1. Yes\n  2. No\n────────"
        let echo = post(Self.thread + "/text", json: #"{"text":"pick one:\n1. Yes\n2. No"}"#)
        XCTAssertEqual(echo.status, 409)
        XCTAssertTrue(echo.body.contains(#""reason":"waiting""#), echo.body)
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })
    }

    func testTheSameWordsAskedAgainAreAnotherPromptEvenWithNoTimeOnThePane() throws {
        repliesOn()
        // No `since` at all, as on a remote host.
        pane.status = .waiting
        pane.screen = DemoPrompt.permission
        let first = try promptID()
        XCTAssertEqual(try promptID(), first)
        XCTAssertEqual(post(Self.thread + "/answer", json: #"{"prompt":"\#(first)","option":1}"#).status, 200)
        // The agent asks the very same thing again.
        let second = try promptID()
        XCTAssertNotEqual(second, first)
        let old = post(Self.thread + "/answer", json: #"{"prompt":"\#(first)","option":1}"#)
        XCTAssertEqual(old.status, 409)
        XCTAssertEqual(old.body, #"{"error":"stale"}"#)
        XCTAssertEqual(pane.argv.count, 1)

        // The pane left the waiting state and came back, seen only in the tree.
        pane.status = nil
        server.update(snapshot(status: .waiting))
        let third = try promptID()
        server.update(snapshot(status: .busy))
        server.update(snapshot(status: .waiting))
        XCTAssertNotEqual(try promptID(), third)
        // The prompt went away and the same one came back.
        let fourth = try promptID()
        pane.screen = DemoPrompt.idle
        _ = get(Self.thread + "/prompt")
        pane.screen = DemoPrompt.permission
        XCTAssertNotEqual(try promptID(), fourth)
    }

    func testEnterAndDigitsAnswerOnlyAPromptThePhoneCanShow() throws {
        repliesOn()
        // A waiting pane with no choices to read: the phone has no card for it.
        pane.status = .waiting
        pane.screen = DemoPrompt.yesNo
        let blind = try promptID()
        for key in ["Enter", "1", "9"] {
            let refused = post(Self.thread + "/key", json: #"{"key":"\#(key)","prompt":"\#(blind)"}"#)
            XCTAssertEqual(refused.status, 409, key)
            XCTAssertEqual(refused.body, #"{"error":"unseen","message":"Open the terminal to answer"}"#, key)
        }
        XCTAssertEqual(pane.argv.count, 0)
        // Escape and the arrows stay: they answer nothing.
        for key in ["Escape", "Down", "Up"] {
            XCTAssertEqual(
                post(Self.thread + "/key", json: #"{"key":"\#(key)","prompt":"\#(blind)"}"#).status, 200, key)
        }
        // A prompt with a card takes Enter with that card's id.
        pane.screen = DemoPrompt.permission
        let card = try promptID()
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(card)"}"#).status, 200)
        XCTAssertEqual(pane.argv.map(\.last), ["Escape", "Down", "Up", "Enter"])
    }

    // MARK: replies, third review

    private func shownPrompt() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get(Self.thread + "/prompt").body.utf8)) as? [String: Any])
    }

    func testEnterAfterAnArrowNeedsTheIdOfTheRowThatIsSelectedNow() throws {
        repliesOn()
        pane.status = .waiting
        pane.screen = DemoPrompt.permission
        pane.cursor = .lastLine
        let first = try shownPrompt()
        let id = try XCTUnwrap(first["id"] as? String)
        // The card is told which row Enter would take.
        XCTAssertEqual((first["prompt"] as? [String: Any])?["selected"] as? Int, 1)

        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Down","prompt":"\#(id)"}"#).status, 200)
        // The cursor moved to "No": the card the phone holds still marks "Yes".
        pane.screen = DemoPrompt.permissionOnThird
        let stale = post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(id)"}"#)
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(stale.body, #"{"error":"stale"}"#)
        XCTAssertEqual(pane.argv.map(\.last), ["Down"])

        let moved = try shownPrompt()
        let movedID = try XCTUnwrap(moved["id"] as? String)
        XCTAssertNotEqual(movedID, id)
        XCTAssertEqual((moved["prompt"] as? [String: Any])?["selected"] as? Int, 3)
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(movedID)"}"#).status, 200)
        XCTAssertEqual(pane.argv.map(\.last), ["Down", "Enter"])
    }

    func testEnterIntoAPaneWithNoFirstHandStatusNeedsAnInputBoxOrAPromptId() {
        repliesOn()
        // The shell window: no hooks. It shows a question with no numbered
        // choices, so there is no prompt id to hold a key to.
        let shell = "/api/threads/localhost%3A13"
        pane.status = nil
        pane.cursor = .lastLine
        for screen in [DemoPrompt.yesNo, "$ rm -i build\nremove build? [y/N] ", "Press Enter to continue"] {
            pane.screen = screen
            for key in ["Enter", "1"] {
                let refused = post(shell + "/key", json: #"{"key":"\#(key)"}"#)
                XCTAssertEqual(refused.status, 409, screen)
                XCTAssertEqual(
                    refused.body, #"{"error":"no_input","message":"Thread shows no input box"}"#, screen)
            }
        }
        XCTAssertEqual(pane.argv.count, 0)
        // An agent's idle input box, with the cursor in it, takes keys.
        pane.screen = DemoPrompt.idle
        pane.cursor = .inBox
        XCTAssertEqual(post(shell + "/key", json: #"{"key":"Escape"}"#).status, 200)
        XCTAssertEqual(post(shell + "/key", json: #"{"key":"Enter"}"#).status, 200)
        XCTAssertEqual(pane.argv.map(\.last), ["Escape", "Enter"])
    }

    func testALookAlikeUnderTheBoxIsNotAFooter() {
        repliesOn()
        let box = "────────────\n❯ \n────────────\n"
        // Indented like a footer, but each waits for a key. A terminal has
        // its cursor on such a line, not in the box.
        for below in [
            "  Overwrite? [y/N] ", " Password:", " $ ", "  ❯ Yes, proceed\n    No, go back",
            "\t? for shortcuts", "\u{A0}\u{A0}? for shortcuts", "\u{3000}? for shortcuts",
            "  Continue?",
        ] {
            for cursor in [FakePane.Cursor.lastLine, .inBox] {
                pane.screen = box + below
                pane.cursor = cursor
                let refused = post(Self.thread + "/text", json: #"{"text":"y"}"#)
                XCTAssertEqual(refused.status, 409, "\(below) \(cursor)")
                XCTAssertEqual(
                    refused.body, #"{"error":"no_input","message":"Thread shows no input box"}"#, below)
            }
        }
        // A real footer, but the cursor is not in the box, or cannot be read.
        for cursor in [FakePane.Cursor.lastLine, .unknown, .row(0)] {
            pane.screen = box + "  ? for shortcuts"
            pane.cursor = cursor
            XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"y"}"#).status, 409, "\(cursor)")
        }
        XCTAssertEqual(pane.argv.count, 0)
        // The agent's own footer, a status line of the human's own included,
        // with the cursor in the box.
        pane.screen = box + "  ➜ acme-app git:(main) 12% context\n  ⏵⏵ auto mode on (shift+tab to cycle)"
        pane.cursor = .inBox
        XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"go on"}"#).status, 200)
    }

    func testAPromptAboveABoxAndAnEchoAreJudgedByWhereTheCursorAndTheBoxAre() {
        repliesOn()
        // A prompt above a box that is last on screen. The cursor is not in
        // that box, so nothing says the box is live and the prompt is old.
        pane.screen = DemoPrompt.permission + "\n" + DemoPrompt.idle
        pane.cursor = .row(9)
        let above = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(above.status, 409)
        XCTAssertEqual(above.body, #"{"error":"waiting","message":"Thread is waiting on a prompt"}"#)
        XCTAssertEqual(pane.argv.count, 0)

        // The reply is exactly the option lines of a prompt that comes up
        // between two rules after the paste.
        let list = #"{"text":"1. Yes\n2. No"}"#
        let menu = "\n\n\n\n\n\n────────\n❯ 1. Yes\n  2. No\n────────"
        // A menu parks the cursor away from its rows.
        pane.screen = DemoPrompt.idle
        pane.cursor = .inBox
        pane.screenAfterPaste = menu
        pane.cursorAfterPaste = .row(0)
        let parked = post(Self.thread + "/text", json: list)
        XCTAssertEqual(parked.status, 409)
        XCTAssertTrue(parked.body.contains(#""reason":"waiting""#), parked.body)
        // Even with the cursor on it, it is not where the input box was.
        pane.screen = DemoPrompt.idle
        pane.cursor = .inBox
        pane.screenAfterPaste = menu
        pane.cursorAfterPaste = .inBox
        let moved = post(Self.thread + "/text", json: list)
        XCTAssertEqual(moved.status, 409)
        XCTAssertFalse(pane.argv.contains { $0.contains("Enter") })

        // The same text in the box that was there before the paste is ours.
        pane.screen = DemoPrompt.idle
        pane.cursor = .inBox
        pane.screenAfterPaste = DemoPrompt.input("1. Yes\n2. No")
        pane.cursorAfterPaste = .inBox
        XCTAssertEqual(post(Self.thread + "/text", json: list).status, 200)
    }

    func testReadsCodexsOwnPromptAndTakesNoTextOverIt() throws {
        repliesOn()
        pane.status = nil
        pane.screen = DemoPrompt.codexTrust
        // Codex parks the cursor under its menu.
        pane.cursor = .lastLine
        let shell = "/api/threads/localhost%3A13"
        let shown = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get(shell + "/prompt").body.utf8)) as? [String: Any])
        let prompt = try XCTUnwrap(shown["prompt"] as? [String: Any])
        XCTAssertEqual(
            (prompt["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String },
            ["Trust and continue", "Back to Agent Command Center"])
        XCTAssertEqual(prompt["selected"] as? Int, 1)
        XCTAssertEqual(post(shell + "/text", json: #"{"text":"go on"}"#).status, 409)
        XCTAssertEqual(post(shell + "/key", json: #"{"key":"Enter"}"#).status, 409)
        XCTAssertEqual(pane.argv.count, 0)
    }

    // MARK: replies, fourth review

    private static let shell = "/api/threads/localhost%3A13"

    func testEveryKeyThatSubmitsIsHeldToTheRulesForEnter() throws {
        repliesOn()
        // Ctrl-M and Ctrl-J are Enter to a terminal; Ctrl-D ends the input.
        let submits = ["Enter", "C-m", "C-j", "C-d"]
        // A pane with no first-hand status on a y/N question.
        pane.status = nil
        pane.screen = "$ rm -i build\nremove build? [y/N] "
        pane.cursor = .lastLine
        for key in submits {
            let refused = post(Self.shell + "/key", json: #"{"key":"\#(key)"}"#)
            XCTAssertEqual(refused.status, 409, key)
            XCTAssertEqual(
                refused.body, #"{"error":"no_input","message":"Thread shows no input box"}"#, key)
        }
        // A waiting pane whose prompt cannot be read: the phone has no card.
        pane.status = .waiting
        pane.screen = DemoPrompt.yesNo
        let blind = try promptID()
        for key in submits {
            let refused = post(Self.thread + "/key", json: #"{"key":"\#(key)","prompt":"\#(blind)"}"#)
            XCTAssertEqual(refused.status, 409, key)
            XCTAssertEqual(refused.body, #"{"error":"unseen","message":"Open the terminal to answer"}"#, key)
        }
        XCTAssertEqual(pane.argv.count, 0)
    }

    func testEnterIntoALocalPaneWithAShellInFrontIsRefusedWhateverItsStatusSays() {
        repliesOn()
        // The hooks last said idle; the agent has since exited to a shell.
        for status in [AttentionStatus.idle, .busy] {
            pane.status = status
            pane.cursor = .lastLine
            for screen in ["$ rm -i build\nremove build? [y/N] ", "$ ", DemoPrompt.idle + "\n$ "] {
                pane.screen = screen
                for key in ["Enter", "C-m", "3"] {
                    let refused = post(Self.thread + "/key", json: #"{"key":"\#(key)"}"#)
                    XCTAssertEqual(refused.status, 409, "\(status) \(screen) \(key)")
                    XCTAssertEqual(
                        refused.body, #"{"error":"no_input","message":"Thread shows no input box"}"#)
                }
            }
        }
        XCTAssertEqual(pane.argv.count, 0)
        // The box takes them.
        pane.screen = DemoPrompt.claudeIdle
        pane.cursor = .inBox
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"C-c"}"#).status, 200)
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter"}"#).status, 200)
        XCTAssertEqual(pane.argv.map(\.last), ["C-c", "Enter"])
    }

    func testTextGoesIntoARealCodexComposerAndARealClaudeBox() {
        repliesOn()
        // Codex has no hooks here: the shell window stands in for it.
        pane.status = nil
        pane.screen = DemoPrompt.codexIdle
        pane.cursor = .row(8)
        pane.screenAfterPaste = DemoPrompt.codexInput(["run the tests", "then push"])
        pane.cursorAfterPaste = .row(9)
        let codex = post(Self.shell + "/text", json: #"{"text":"run the tests\nthen push"}"#)
        XCTAssertEqual(codex.status, 200, codex.body)
        XCTAssertTrue(FakePane.sendArgv(pane.argv, target: "%13"), "\(pane.argv)")

        // Claude Code with a status line that ends in a percentage.
        pane.status = .idle
        pane.screen = DemoPrompt.claudeIdle
        pane.screenAfterPaste = nil
        pane.cursor = .inBox
        pane.cursorAfterPaste = nil
        let claude = post(Self.thread + "/text", json: #"{"text":"go on"}"#)
        XCTAssertEqual(claude.status, 200, claude.body)

        // Codex with its cursor somewhere else, or its own menu, takes nothing.
        let before = pane.argv.count
        pane.status = nil
        pane.screen = DemoPrompt.codexIdle
        pane.cursor = .row(2)
        XCTAssertEqual(post(Self.shell + "/text", json: #"{"text":"go on"}"#).status, 409)
        pane.screen = DemoPrompt.codexTrust
        pane.cursor = .lastLine
        XCTAssertEqual(post(Self.shell + "/text", json: #"{"text":"go on"}"#).status, 409)
        XCTAssertEqual(pane.argv.count, before)
    }

    func testALineUnderTheBoxThatAsksOrOffersAChoiceIsNotAFooter() {
        repliesOn()
        let box = "────────────\n❯ \n────────────\n"
        pane.cursor = .inBox
        for below in [
            "  Press Enter to continue", "  (Y)es / (N)o", "  ● Yes, proceed", "  --More--(45%)",
            "  ○ No, go back", "  [x] overwrite", "  Continue?", "  (END)", "  y/n", "  enter continue · esc back",
        ] {
            pane.screen = box + below
            let refused = post(Self.thread + "/text", json: #"{"text":"y"}"#)
            XCTAssertEqual(refused.status, 409, below)
        }
        XCTAssertEqual(pane.argv.count, 0)
        // A status line of the human's own is a footer, a percentage included.
        for below in ["  ➜ acme-app git:(main) · ctx 42%", "  12% context left", "  main ✗ 3 files · 87%"] {
            pane.screen = box + below
            XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"go on"}"#).status, 200, below)
        }
    }

    func testADigitAnswersOnlyAChoiceTheCardShows() throws {
        repliesOn()
        pane.status = .waiting
        pane.cursor = .lastLine
        pane.screen = DemoPrompt.permission
        var id = try promptID()
        for digit in ["4", "7", "9"] {
            let refused = post(Self.thread + "/key", json: #"{"key":"\#(digit)","prompt":"\#(id)"}"#)
            XCTAssertEqual(refused.status, 409, digit)
            XCTAssertEqual(refused.body, #"{"error":"no_option","message":"Not a choice on the card"}"#, digit)
        }
        XCTAssertEqual(pane.argv.count, 0)

        // A long menu, scrolled: the card holds every row on screen and says
        // there are more.
        pane.screen = DemoPrompt.scrolledMenu
        let shown = try shownPrompt()
        let prompt = try XCTUnwrap(shown["prompt"] as? [String: Any])
        XCTAssertEqual(
            (prompt["options"] as? [[String: Any]])?.compactMap { $0["n"] as? Int }, [4, 5, 6, 7, 8, 9])
        XCTAssertEqual(prompt["selected"] as? Int, 6)
        XCTAssertEqual(prompt["moreAbove"] as? Bool, true)
        XCTAssertEqual(prompt["moreBelow"] as? Bool, true)
        id = try XCTUnwrap(shown["id"] as? String)
        // Row 9 is on the card; row 2 is off screen.
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"2","prompt":"\#(id)"}"#).status, 409)
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"9","prompt":"\#(id)"}"#).status, 200)
        XCTAssertEqual(pane.argv.map(\.last), ["9"])
    }

    // MARK: replies, fifth review

    func testARowCountUnderTheLastChoiceMeansMoreBelow() throws {
        repliesOn()
        pane.status = .waiting
        pane.cursor = .lastLine
        pane.screen = DemoPrompt.modelMenu
        let prompt = try XCTUnwrap(try shownPrompt()["prompt"] as? [String: Any])
        XCTAssertEqual((prompt["options"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(prompt["moreBelow"] as? Bool, true)
        XCTAssertEqual(prompt["moreAbove"] as? Bool, false)
        // The dialog's own title, not the banner above its top edge.
        XCTAssertEqual(prompt["title"] as? String, "Select model")
        XCTAssertEqual(prompt["truncated"] as? Bool, false)
    }

    func testEveryKeyNeedsAnInputBoxOrAPromptToName() {
        repliesOn()
        // "Press any key": no card, and the status does not say waiting. Any
        // key at all would answer it.
        for status in [AttentionStatus.idle, .busy, nil] {
            pane.status = status
            pane.cursor = .lastLine
            let thread = status == nil ? Self.shell : Self.thread
            for screen in ["Press any key to continue", "$ less notes.txt\n(END)", "$ "] {
                pane.screen = screen
                for key in ["Escape", "Down", "Tab", "C-c", "C-u", "C-z", "Enter", "1"] {
                    let refused = post(thread + "/key", json: #"{"key":"\#(key)"}"#)
                    XCTAssertEqual(refused.status, 409, "\(screen) \(key)")
                    XCTAssertEqual(
                        refused.body, #"{"error":"no_input","message":"Thread shows no input box"}"#)
                }
            }
        }
        XCTAssertEqual(pane.argv.count, 0)
        // An agent at work shows its box: Ctrl-C and Escape reach it.
        pane.status = .busy
        pane.screen = DemoPrompt.claudeIdle
        pane.cursor = .inBox
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"C-c"}"#).status, 200)
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Escape"}"#).status, 200)
        XCTAssertEqual(pane.argv.map(\.last), ["C-c", "Escape"])
    }

    func testMorePagerAndAnyKeyLinesAreNotAFooterAndAColonIsFine() {
        repliesOn()
        let box = "────────────\n❯ \n────────────\n"
        pane.cursor = .inBox
        for below in ["  -- More --", "  --More--", "  Hit any key to continue", "  Overwrite (y or n)",
                      "  press any key"] {
            pane.screen = box + below
            XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"y"}"#).status, 409, below)
        }
        XCTAssertEqual(pane.argv.count, 0)
        // A status line may end in a colon.
        for below in ["  ➜ acme-app git:(main) model:", "  branch: main · ctx:"] {
            pane.screen = box + below
            XCTAssertEqual(post(Self.thread + "/text", json: #"{"text":"go on"}"#).status, 200, below)
        }
    }

    // MARK: uploads for the reply box

    func testAnUploadForTheManagerIsSavedInTheUploadFolderAndTypesNothing() {
        let upload = "/api/manager/upload"
        // The Manager switch alone is not enough: a file needs the Upload switch too.
        managerOn()
        XCTAssertEqual(post(upload + "?name=shot.png", json: "demo").status, 403)
        server.configure(MobileConfig(capabilities: [.upload], uploadLimit: 64))
        XCTAssertEqual(post(upload + "?name=shot.png", json: "demo").status, 403)

        let home = "/Users/me/my uploads"
        server.configure(MobileConfig(capabilities: [.manager, .upload], uploadLimit: 64, uploadFolder: home))
        // The manager at work can still be given a file: nothing goes to its pane.
        for status in [MobileManagerStatus.idle, .busy, .waiting] {
            manager.status = status
            XCTAssertEqual(post(upload + "?name=shot.png", json: "demo").status, 200, "\(status)")
        }
        XCTAssertEqual(manager.pane.argv.count, 0)
        XCTAssertEqual(manager.pane.saves.map(\.path), [
            "\(home)/shot.png", "\(home)/shot-2.png", "\(home)/shot-3.png",
        ])
        // The path comes back as it should be typed: quoted, since it holds a space.
        let named = post(upload + "?name=..%2Fa.png", json: "demo")
        XCTAssertTrue(named.body.contains(#""pasted":false"#), named.body)
        XCTAssertTrue(named.body.contains(#""text":"'\/Users\/me\/my uploads\/a.png'""#), named.body)
        XCTAssertEqual(manager.pane.saves.last?.path, "\(home)/a.png")

        // Every other rule of an upload holds: the size cap and the name.
        XCTAssertEqual(post(upload + "?name=..", json: "demo").status, 400)
        XCTAssertEqual(post(upload, json: "demo").status, 400)
        XCTAssertEqual(
            post(upload + "?name=big.bin", json: String(repeating: "a", count: 65)).status, 413)
        // No manager: nowhere to save.
        manager.status = .off
        XCTAssertEqual(post(upload + "?name=late.png", json: "demo").status, 503)
        XCTAssertEqual(manager.pane.saves.count, 4)
    }

    func testAnUploadForTheReplyBoxIsSavedAndTypesNothing() {
        repliesOn()
        // The phone puts the path into its own reply box, so nothing goes to
        // the pane: a pane at work or on a prompt can still be given a file.
        for status in [AttentionStatus.idle, .busy, .waiting] {
            pane.status = status
            let saved = post(Self.thread + "/upload?name=shot.png&paste=0", json: "demo")
            XCTAssertEqual(saved.status, 200, "\(status)")
            XCTAssertTrue(saved.body.contains(#""pasted":false"#), saved.body)
        }
        XCTAssertEqual(pane.argv.count, 0)
        // Never over a file that is there: each one gets its own name.
        XCTAssertEqual(pane.saves.map(\.path), [
            "/Users/me/uploads/shot.png", "/Users/me/uploads/shot-2.png", "/Users/me/uploads/shot-3.png",
        ])
        // The path comes back as it should be typed: quoted when it needs it.
        let first = post(Self.thread + "/upload?name=a.png&paste=0", json: "demo")
        XCTAssertEqual(
            first.body,
            #"{"ok":true,"pasted":false,"path":"\/Users\/me\/uploads\/a.png","text":"\/Users\/me\/uploads\/a.png"}"#)

        // Every other rule holds: the switch, the size cap, the name, the thread.
        XCTAssertEqual(post(Self.thread + "/upload?name=..&paste=0", json: "demo").status, 400)
        XCTAssertEqual(
            post(Self.thread + "/upload?name=big.bin&paste=0", json: String(repeating: "a", count: 65)).status,
            413)
        XCTAssertEqual(post("/api/threads/localhost%3A99/upload?name=a.png&paste=0", json: "demo").status, 404)
        XCTAssertEqual(
            post(Self.thread + "/upload?name=a.png&paste=0", json: "demo", token: nil).status, 401)
        server.configure(MobileConfig(capabilities: [.replies, .keyBar]))
        XCTAssertEqual(post(Self.thread + "/upload?name=a.png&paste=0", json: "demo").status, 403)
        // Without the flag an upload still pastes, and is still refused for a busy pane.
        repliesOn()
        pane.status = .busy
        XCTAssertEqual(post(Self.thread + "/upload?name=b.png", json: "demo").status, 409)
    }

    // MARK: the manager's own prompt

    private func managerPrompt() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get("/api/manager/prompt").body.utf8)) as? [String: Any])
    }

    func testTheManagerHomeShowsTheManagersPromptAndTakesATappedAnswer() throws {
        server.configure(MobileConfig(capabilities: [.manager, .replies]))
        manager.status = .waiting
        manager.pane.screen = DemoPrompt.question
        manager.pane.cursor = .lastLine
        let shown = try managerPrompt()
        let prompt = try XCTUnwrap(shown["prompt"] as? [String: Any])
        XCTAssertEqual(prompt["question"] as? String, "Which store should the cache use?")
        XCTAssertEqual(prompt["selected"] as? Int, 1)
        XCTAssertEqual((prompt["options"] as? [[String: Any]])?.count, 3)
        let id = try XCTUnwrap(shown["id"] as? String)

        // The same guards as a thread's card: the id, and a choice on the card.
        XCTAssertEqual(post("/api/manager/answer", json: #"{"prompt":"9f2c","option":1}"#).status, 409)
        XCTAssertEqual(post("/api/manager/answer", json: #"{"prompt":"\#(id)","option":7}"#).status, 400)
        XCTAssertEqual(manager.pane.argv.count, 0)
        XCTAssertEqual(post("/api/manager/answer", json: #"{"prompt":"\#(id)","option":2}"#).status, 200)
        XCTAssertEqual(manager.pane.argv, [["send-keys", "-t", "mux-manager", "2"]])
        // Answered: the same words after this are another prompt.
        XCTAssertNotEqual(try XCTUnwrap(try managerPrompt()["id"] as? String), id)
        XCTAssertEqual(post("/api/manager/answer", json: #"{"prompt":"\#(id)","option":1}"#).status, 409)
        // It typed into the manager's pane and no other, and sent no turn.
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(manager.sent, [])
        // A manager that waits on nothing has no card.
        manager.status = .idle
        manager.pane.screen = DemoPrompt.claudeIdle
        manager.pane.cursor = .inBox
        XCTAssertEqual(get("/api/manager/prompt").body, #"{"id":null,"prompt":null,"suggestion":null}"#)
    }

    func testCancelBacksOutOfThePromptTheCardShows() throws {
        server.configure(MobileConfig(capabilities: [.manager, .replies]))
        manager.status = .waiting
        manager.pane.screen = DemoPrompt.question
        manager.pane.cursor = .lastLine
        let id = try XCTUnwrap(try managerPrompt()["id"] as? String)
        XCTAssertEqual(post("/api/manager/answer", json: #"{"prompt":"9f2c","cancel":true}"#).status, 409)
        XCTAssertEqual(manager.pane.argv.count, 0)
        XCTAssertEqual(post("/api/manager/answer", json: #"{"prompt":"\#(id)","cancel":true}"#).status, 200)
        XCTAssertEqual(manager.pane.argv, [["send-keys", "-t", "mux-manager", "Escape"]])

        // The same for a thread's card.
        pane.status = .waiting
        pane.screen = DemoPrompt.permission
        pane.cursor = .lastLine
        let thread = try promptID()
        XCTAssertEqual(post(Self.thread + "/answer", json: #"{"prompt":"\#(thread)","cancel":true}"#).status, 200)
        XCTAssertEqual(pane.argv, [["send-keys", "-t", "%12", "Escape"]])
        // Neither an option and a cancel, nor a cancel that is not true.
        for body in [#"{"prompt":"x","cancel":false}"#, #"{"prompt":"x","cancel":"yes"}"#, #"{"prompt":"x"}"#] {
            XCTAssertEqual(post("/api/manager/answer", json: body).status, 400, body)
        }
    }

    func testTheManagersPromptRoutesNeedTheManagerSwitchAndTheirOwn() {
        manager.status = .waiting
        manager.pane.screen = DemoPrompt.question
        manager.pane.cursor = .lastLine
        let answer = #"{"prompt":"9f2c","option":1}"#
        let key = #"{"key":"Escape"}"#
        // Replies and the key bar without the manager switch, and the reverse.
        for capabilities in [[MobileCapability.replies, .keyBar], [.manager], [.manager, .voice, .upload]] {
            server.configure(MobileConfig(capabilities: Set(capabilities)))
            for refused in [
                get("/api/manager/prompt"), post("/api/manager/answer", json: answer),
                post("/api/manager/key", json: key),
            ] {
                XCTAssertEqual(refused.status, 403, "\(capabilities)")
                XCTAssertEqual(refused.body, #"{"error":"disabled"}"#)
            }
        }
        // The key bar alone reads the prompt and presses keys, but answers nothing.
        server.configure(MobileConfig(capabilities: [.manager, .keyBar]))
        XCTAssertEqual(get("/api/manager/prompt").status, 200)
        XCTAssertEqual(post("/api/manager/answer", json: answer).status, 403)
        server.configure(MobileConfig(capabilities: [.manager, .replies]))
        XCTAssertEqual(post("/api/manager/key", json: key).status, 403)
        // The token and the origin, as for every write.
        server.configure(MobileConfig(capabilities: [.manager, .replies, .keyBar]))
        for path in ["/api/manager/answer", "/api/manager/key"] {
            let body = path.hasSuffix("key") ? key : answer
            XCTAssertEqual(post(path, json: body, token: nil).status, 401, path)
            XCTAssertEqual(post(path, json: body, origin: "https://evil.example.com").status, 403, path)
            XCTAssertEqual(post(path, json: body, writeHeader: false).status, 403, path)
        }
        XCTAssertEqual(get("/api/manager/prompt", token: nil).status, 401)
        XCTAssertEqual(manager.pane.argv.count, 0)
        // A manager that is not running has no pane.
        manager.status = .off
        XCTAssertEqual(post("/api/manager/key", json: key).status, 503)
    }

    func testAPromptThatCannotBeReadIsAnsweredFromTheTerminalViewWithTheKeyBar() throws {
        server.configure(MobileConfig(capabilities: [.manager, .replies, .keyBar]))
        manager.status = .waiting
        manager.pane.screen = DemoPrompt.yesNo
        manager.pane.cursor = .lastLine
        let shown = try managerPrompt()
        XCTAssertTrue(shown["prompt"] is NSNull)
        let id = try XCTUnwrap(shown["id"] as? String)
        // No card: Enter is refused, unless the phone shows the terminal,
        // where the human reads the prompt itself.
        let unseen = post("/api/manager/key", json: #"{"key":"Enter","prompt":"\#(id)"}"#)
        XCTAssertEqual(unseen.status, 409)
        XCTAssertEqual(unseen.body, #"{"error":"unseen","message":"Open the terminal to answer"}"#)
        XCTAssertEqual(
            post("/api/manager/key", json: #"{"key":"Enter","prompt":"\#(id)","terminal":true}"#).status, 200)
        // The terminal view does not lift the id check.
        XCTAssertEqual(
            post("/api/manager/key", json: #"{"key":"Enter","prompt":"9f2c","terminal":true}"#).status, 409)
        XCTAssertEqual(post("/api/manager/key", json: #"{"key":"Enter","terminal":true}"#).status, 409)
        XCTAssertEqual(manager.pane.argv, [["send-keys", "-t", "mux-manager", "Enter"]])

        // The same for a thread.
        repliesOn()
        pane.status = .waiting
        pane.screen = DemoPrompt.yesNo
        pane.cursor = .lastLine
        let thread = try promptID()
        XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(thread)"}"#).status, 409)
        XCTAssertEqual(
            post(Self.thread + "/key", json: #"{"key":"Enter","prompt":"\#(thread)","terminal":true}"#).status,
            200)
    }

    func testAQuestionDrawnInColumnsGivesACardThatPointsToTheTerminal() throws {
        server.configure(MobileConfig(capabilities: [.manager, .replies]))
        manager.status = .waiting
        manager.pane.screen = DemoPrompt.columns
        manager.pane.cursor = .lastLine
        let prompt = try XCTUnwrap(try managerPrompt()["prompt"] as? [String: Any])
        let labels = (prompt["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
        XCTAssertEqual(labels.count, 3)
        XCTAssertEqual(labels.first, "Sidebar on the")
        // No piece of the preview box in a label, and the card says it does
        // not hold everything.
        XCTAssertFalse(labels.joined().unicodeScalars.contains { (0x2500...0x259F).contains($0.value) })
        XCTAssertEqual(prompt["truncated"] as? Bool, true)
        XCTAssertEqual(prompt["question"] as? String, "Which layout should the page use?")
    }
}
