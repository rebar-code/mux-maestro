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

    /// The manager pane, scripted. The server calls it from its own queues.
    private final class FakeManager {
        private let lock = NSLock()
        private var _status = MobileManagerStatus.idle
        private var _sent: [String] = []
        private var _dismissed: [String] = []
        /// What a turn says: the deltas, then the outcome.
        var script: (deltas: [String], outcome: ManagerTurnOutcome) = ([], .done(reply: ""))
        var transcript: String?

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
            transcript: { _ in (transcript.path, false) }), limits: limits, manager: manager.source)
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

        // A turn the Mac rail started is still running.
        manager.status = .idle
        server.managerTurnBegan("summarise the morning")
        let busy = post("/api/manager/text", json: #"{"text":"what needs me?"}"#)
        XCTAssertEqual(busy.status, 409)
        XCTAssertEqual(busy.body, #"{"error":"busy","message":"A turn is running"}"#)
        XCTAssertTrue(get("/api/manager").body.contains(#""status":"busy""#))

        manager.status = .off
        server.managerTurnEnded()
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

    func testDismissPassesTheKeyOn() {
        managerOn()
        let done = post("/api/manager/dismiss", json: #"{"key":"billing:pr"}"#)
        XCTAssertEqual(done.status, 200)
        XCTAssertEqual(done.body, #"{"ok":true}"#)
        XCTAssertEqual(manager.dismissed, ["billing:pr"])
        XCTAssertEqual(post("/api/manager/dismiss", json: "{}").status, 400)
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
        XCTAssertTrue(events[2].contains(#""reply":"All quiet.""#))
        XCTAssertTrue(events[3].contains(#""turn":null"#))
    }
}
