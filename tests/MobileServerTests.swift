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

    private func makeServer(limits: MobileServer.Limits = MobileServer.Limits()) -> MobileServer {
        let transcript = transcript!
        return MobileServer(staticRoot: root, sources: MobileServer.Sources(
            screen: { [weak self] thread, lines in
                self?.askedLines.append(lines)
                return thread.pane == "%12" ? (self?.screenText ?? "") : nil
            },
            transcript: { _ in (transcript.path, false) }), limits: limits)
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
}
