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
    private let manager = FakeManager()
    private let pane = FakePane()
    private let tmux = FakeTmux()
    private let changes = Counter()
    private var home: URL { root.appendingPathComponent("home") }

    /// The manager pane, scripted. The server calls it from its own queues.
    private final class FakeManager {
        private let lock = NSLock()
        private var _status = MobileManagerStatus.idle
        private var _sent: [String] = []
        private var _dismissed: [String] = []
        /// What a turn says: the deltas, then the outcome.
        var script: (deltas: [String], outcome: ManagerTurnOutcome) = ([], .done(reply: ""))
        var transcript: String?
        /// When set, a turn says nothing until this is signalled.
        var gate: DispatchSemaphore?

        var status: MobileManagerStatus {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); _status = newValue; lock.unlock() }
        }
        var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
        var dismissed: [String] { lock.lock(); defer { lock.unlock() }; return _dismissed }

        var source: MobileServer.Manager {
            MobileServer.Manager(
                pane: { [self] in (status, transcript) },
                send: { [self] text, onDelta, completion in
                    lock.lock(); _sent.append(text); lock.unlock()
                    DispatchQueue.global().async { [self] in
                        gate?.wait()
                        script.deltas.forEach(onDelta)
                        completion(script.outcome)
                    }
                },
                dismiss: { [self] key in lock.lock(); _dismissed.append(key); lock.unlock() })
        }
    }

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

    private func makeServer(limits: MobileServer.Limits = MobileServer.Limits()) -> MobileServer {
        let transcript = transcript!
        return MobileServer(staticRoot: root, sources: MobileServer.Sources(
            screen: { thread in thread.pane == "%12" ? "$ make test\nok\n\n\n" : nil },
            transcript: { _ in (transcript.path, false) },
            pane: { [pane] _ in pane.io }, tmux: tmux.source,
            changed: { [changes] in changes.add() }, home: home.path),
            limits: limits, manager: manager.source)
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

    private func snapshot(status: AttentionStatus = .busy) -> MobileSnapshot {
        var agent = TmuxPane(id: "%12", index: 0, command: "claude", title: "", active: true)
        agent.claudeSessionId = "c1"
        agent.attention = status
        agent.path = "/Users/me/acme-app"
        let shell = TmuxPane(id: "%13", index: 0, command: "zsh", title: "", active: true)
        return MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: "acme-app", attached: true, windows: [
                TmuxWindow(index: 1, name: "checkout-fix", active: true, panes: [agent]),
                TmuxWindow(index: 2, name: "shell", active: false, panes: [shell]),
            ])])])
    }

    // MARK: client

    /// Send `raw` and read until `done` says the reply is whole (or 5 s pass).
    private func exchange(_ raw: String, until done: @escaping (String) -> Bool) -> String {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "mobile-server-tests")
        let finished = DispatchSemaphore(value: 0)
        var received = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { received.append(data) }
                if complete || error != nil || done(String(decoding: received, as: UTF8.self)) {
                    finished.signal()
                } else {
                    read()
                }
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
        read()
        _ = finished.wait(timeout: .now() + 5)
        connection.cancel()
        return queue.sync { String(decoding: received, as: UTF8.self) }
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
        let refused = get("/api/threads/localhost%3A12/artifacts")
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(refused.body, #"{"error":"disabled"}"#)
        XCTAssertEqual(get("/api/manager").status, 403)

        server.configure(MobileConfig(capabilities: [.artifacts], grouping: .host))
        // On, but its route arrives in a later PR: past the gate, not found.
        XCTAssertEqual(get("/api/threads/localhost%3A12/artifacts").status, 404)
        XCTAssertEqual(get("/api/manager").status, 403)
        XCTAssertTrue(get("/api/config").body.contains(#""artifacts":true"#))
    }

    func testServesChatAndScreenAndA404ForAStaleId() {
        let chat = get("/api/threads/localhost%3A12/chat")
        XCTAssertEqual(chat.status, 200)
        XCTAssertTrue(chat.body.contains(#""text":"hello""#))
        // Trailing blank rows of the pane are cut.
        XCTAssertEqual(get("/api/threads/localhost%3A12/screen").body, #"{"text":"$ make test\nok"}"#)
        // A shell has a screen and no chat.
        XCTAssertEqual(get("/api/threads/localhost%3A13/chat").status, 404)
        XCTAssertEqual(get("/api/threads/localhost%3A13/screen").status, 503)
        XCTAssertEqual(get("/api/threads/localhost%3A99/screen").status, 404)
        XCTAssertEqual(get("/api/threads/localhost%3A99/chat").status, 404)
        XCTAssertEqual(get("/api/threads", method: "POST").status, 403)
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
        let messages = (body["chat"] as? [String: Any])?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.map { $0["text"] as? String }, ["what needs me?", "Two threads need you."])
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
        XCTAssertEqual(waiting.body, #"{"error":"waiting","message":"Manager is waiting on a prompt"}"#)

        // Busy with a turn the app does not track: it may reach a prompt.
        manager.status = .busy
        let paneBusy = post("/api/manager/text", json: #"{"text":"what needs me?"}"#)
        XCTAssertEqual(paneBusy.status, 409)
        XCTAssertEqual(paneBusy.body, #"{"error":"busy","message":"Manager is busy"}"#)

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
        XCTAssertEqual(unknown.body, #"{"error":"not_ready","message":"Manager is not ready"}"#)
        XCTAssertTrue(get("/api/manager").body.contains(#""status":"unknown""#))

        manager.status = .off
        XCTAssertEqual(post("/api/manager/text", json: #"{"text":"what needs me?"}"#).status, 503)
        XCTAssertEqual(post("/api/manager/text", json: #"{"text":" "}"#).status, 400)
        XCTAssertEqual(manager.sent, [])
    }

    func testTheDriversLateRefusalEndsTheStreamWithItsReason() {
        managerOn()
        manager.script = ([], .refused("Manager is waiting on a prompt"))
        let turn = post("/api/manager/text", json: #"{"text":"what needs me?"}"#) {
            $0.contains("event: end") && $0.hasSuffix("\n\n")
        }
        XCTAssertEqual(turn.status, 200)
        XCTAssertTrue(turn.body.contains(
            #"{"message":"Manager is waiting on a prompt","outcome":"refused","reply":""}"#))
    }

    private func reviewBoard() -> MobileManagerBoard {
        MobileManagerBoard(items: [MobileManagerItem(
            kind: .review, key: "billing:pr", title: "billing", detail: "PR open, CI green",
            severity: .warn, at: 1_759_499_000, link: nil)])
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
        XCTAssertTrue(events[1].contains(#""turn":{"prompt":"summarise the morning","reply":""}"#))
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
        XCTAssertTrue(text.contains(#""turn":{"prompt":"summarise the morning","reply":"All quiet"}"#))
        XCTAssertTrue(get("/api/manager").body.contains(#""reply":"All quiet""#))
    }

    // MARK: replies

    private func repliesOn() {
        server.configure(MobileConfig(capabilities: [.replies, .keyBar, .upload], uploadLimit: 64))
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
        XCTAssertEqual(get(Self.thread + "/prompt").status, 403)
        XCTAssertEqual(pane.argv.count, 0)
        XCTAssertEqual(pane.copies.count, 0)
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
        XCTAssertEqual(pane.copies.count, 0)
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
        XCTAssertEqual(pane.copies.count, 0)
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
        XCTAssertEqual(pane.argv.map(\.first), ["copy-mode", "load-buffer", "paste-buffer"])
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
        XCTAssertEqual(pane.copies.count, 0)
    }

    func testAKeyOffTheWhitelistIsRefusedAndAWhitelistedOneIsPressed() {
        repliesOn()
        for key in ["F1", "C-1", "M-a", "q", "0", "10", "Enter; kill-server", "-X", ""] {
            let refused = post(Self.thread + "/key", json: #"{"key":"\#(key)"}"#)
            XCTAssertEqual(refused.status, 400, key)
            XCTAssertEqual(refused.body, #"{"error":"bad_key"}"#, key)
        }
        XCTAssertEqual(pane.argv.count, 0)

        // A pane on a prompt, or at work, still takes a key: Escape backs out.
        for (status, key) in [(AttentionStatus.waiting, "Escape"), (.busy, "C-c"), (.idle, "BTab"), (.idle, "3")] {
            pane.status = status
            XCTAssertEqual(post(Self.thread + "/key", json: #"{"key":"\#(key)"}"#).status, 200, key)
        }
        XCTAssertEqual(pane.argv, [
            ["send-keys", "-t", "%12", "Escape"], ["send-keys", "-t", "%12", "C-c"],
            ["send-keys", "-t", "%12", "BTab"], ["send-keys", "-t", "%12", "3"],
        ])
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
        // A pane that is not waiting shows no prompt.
        pane.status = .busy
        XCTAssertEqual(get(Self.thread + "/prompt").body, #"{"prompt":null}"#)
        XCTAssertEqual(pane.argv.count, 1)
    }

    func testAnUploadIsSavedInTheThreadsDirectoryUnderASafeName() {
        repliesOn()
        let saved = post(Self.thread + "/upload?name=..%2F..%2F.ssh%2Fauthorized_keys", json: "demo key")
        XCTAssertEqual(saved.status, 200)
        XCTAssertEqual(saved.body, #"{"ok":true,"pasted":true,"path":"\/Users\/me\/acme-app\/authorized_keys"}"#)
        XCTAssertEqual(pane.copies.map(\.path), ["/Users/me/acme-app/authorized_keys"])
        XCTAssertEqual(pane.copies.first?.data, Data("demo key".utf8))
        XCTAssertEqual(pane.calls[1].stdin, "/Users/me/acme-app/authorized_keys ")
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
        XCTAssertEqual(pane.copies.count, 0)
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
        XCTAssertEqual(pane.copies.count, 0)

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
            ("/api/tmux/kill-session", #"{"host":"localhost","session":"acme-app","confirm":true}"#),
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
        let bySession = ["new-window", "rename-session", "kill-session"]
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
            ("/api/tmux/kill-session", #""host":"localhost","session":"acme-app""#,
             ["kill-session", "-t", "=acme-app"]),
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
            "new-window", "-a", "-t", "=acme-app:", "-P", "-F", "#{window_index}\t#{pane_id}",
            "-c", "/Users/me/acme-app",
        ])
        XCTAssertEqual(get(Self.dirs).body, #"{"dirs":["\/Users\/me\/acme-app"]}"#)
        // A directory the server did not offer starts nothing.
        let before = tmux.argv.count
        let refused = post("/api/tmux/new-session", json: #"{"host":"localhost","dir":"/etc"}"#)
        XCTAssertEqual(refused.status, 400)
        XCTAssertEqual(refused.body, #"{"error":"bad_dir"}"#)
        XCTAssertEqual(tmux.argv.count, before)
        tmux.failing = true
        XCTAssertEqual(post("/api/tmux/zoom-pane", json: #"{"thread":"localhost:12"}"#).status, 503)
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
}
