import XCTest

// MobileAPI.swift (Foundation only) compiles into this test target: the HTTP
// parser, the router, the auth decision, the capability check and the JSON
// shapes are asserted with no socket.
final class MobileAPITests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("fixtures/mobile")

    private let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")

    private func request(
        _ target: String, method: String = "GET", headers: [String: String] = [:]
    ) -> MobileRequest {
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        guard case .request(let request, _) = MobileHTTP.parse(Data(text.utf8)) else {
            XCTFail("did not parse: \(target)")
            return MobileRequest(method: method, path: "/")
        }
        return request
    }

    private var trusted: [String: String] {
        ["Host": "devmac.example.ts.net:7433", "Tailscale-User-Login": "me@example.com"]
    }

    // MARK: parser

    func testParsesRequestLineQueryAndHeaders() {
        let raw = "GET /api/threads/localhost%3A12/chat?after=42&x=a+b HTTP/1.1\r\n"
            + "Host: devmac.example.ts.net:7433\r\nTailscale-User-Login:  me@example.com \r\n\r\n"
        guard case .request(let request, let consumed) = MobileHTTP.parse(Data(raw.utf8)) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(consumed, raw.utf8.count)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/threads/localhost%3A12/chat")
        XCTAssertEqual(request.segments, ["api", "threads", "localhost:12", "chat"])
        XCTAssertEqual(request.query, ["after": "42", "x": "a b"])
        XCTAssertEqual(request.header("Tailscale-User-Login"), "me@example.com")
        XCTAssertEqual(request.header("HOST"), "devmac.example.ts.net:7433")
    }

    func testIncompleteUntilHeadersAndBodyArrive() {
        XCTAssertEqual(MobileHTTP.parse(Data("GET / HTTP/1.1\r\nHost: a".utf8)), .incomplete)
        let head = "POST /api/x HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        XCTAssertEqual(MobileHTTP.parse(Data((head + "abc").utf8)), .incomplete)
        guard case .request(let request, let consumed) = MobileHTTP.parse(Data((head + "abcdeGET").utf8))
        else { return XCTFail("expected a request") }
        XCTAssertEqual(request.body, Data("abcde".utf8))
        // The next request's bytes stay in the buffer.
        XCTAssertEqual(consumed, head.utf8.count + 5)
    }

    func testRejectsMalformedAndOversizedRequests() {
        XCTAssertEqual(MobileHTTP.parse(Data("nonsense\r\n\r\n".utf8)), .invalid(400))
        XCTAssertEqual(MobileHTTP.parse(Data("GET http://x/ HTTP/1.1\r\n\r\n".utf8)), .invalid(400))
        XCTAssertEqual(MobileHTTP.parse(Data("GET / HTTP/1.1\r\nbroken\r\n\r\n".utf8)), .invalid(400))
        XCTAssertEqual(
            MobileHTTP.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)),
            .invalid(400))
        XCTAssertEqual(
            MobileHTTP.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)),
            .invalid(413))
        XCTAssertEqual(
            MobileHTTP.parse(Data(repeating: UInt8(ascii: "a"), count: MobileHTTP.maxHeaderBytes + 1)),
            .invalid(431))
    }

    func testResponseSerializesStatusLengthAndHeadBody() {
        let response = MobileResponse.json(["a": 1])
        let text = String(decoding: response.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"a\":1}"))
        let head = String(decoding: response.serialized(head: true, keepAlive: false), as: UTF8.self)
        XCTAssertTrue(head.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(head.contains("Connection: close\r\n"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
    }

    // MARK: router

    func testRoutesTheReadAPI() {
        XCTAssertEqual(MobileAPI.route(request("/api/config")), .api(.config))
        XCTAssertEqual(MobileAPI.route(request("/api/threads")), .api(.threads))
        XCTAssertEqual(MobileAPI.route(request("/api/hosts")), .api(.hosts))
        XCTAssertEqual(MobileAPI.route(request("/api/events")), .api(.events))
        XCTAssertEqual(
            MobileAPI.route(request("/api/threads/localhost%3A12/chat?after=42")),
            .api(.chat(id: "localhost:12", after: 42)))
        XCTAssertEqual(
            MobileAPI.route(request("/api/threads/devbox%3A3/chat")), .api(.chat(id: "devbox:3", after: nil)))
        XCTAssertEqual(
            MobileAPI.route(request("/api/threads/devbox%3A3/screen")),
            .api(.screen(id: "devbox:3", lines: 2000)))
        XCTAssertEqual(
            MobileAPI.route(request("/api/threads/devbox%3A3/screen?lines=4000")),
            .api(.screen(id: "devbox:3", lines: 4000)))
        XCTAssertEqual(MobileAPI.route(request("/api/nope")), .notFound)
        XCTAssertEqual(MobileAPI.route(request("/api/threads/a/b/c")), .notFound)
        XCTAssertEqual(MobileAPI.route(request("/api/threads", method: "POST")), .methodNotAllowed)
        XCTAssertEqual(MobileAPI.route(request("/", method: "DELETE")), .methodNotAllowed)
    }

    func testRoutesStaticFilesAndRefusesTraversal() {
        XCTAssertEqual(MobileAPI.route(request("/")), .asset("index.html"))
        XCTAssertEqual(
            MobileAPI.route(request("/_app/immutable/chunks/a.js")), .asset("_app/immutable/chunks/a.js"))
        XCTAssertEqual(MobileAPI.route(request("/t/localhost%3A12")), .asset("t/localhost:12"))
        XCTAssertEqual(MobileAPI.route(request("/../secret")), .notFound)
        XCTAssertEqual(MobileAPI.route(request("/a/%2e%2e/b")), .notFound)
        XCTAssertEqual(MobileAPI.route(request("/a%2Fb/..%2F..%2Fetc")), .notFound)
        XCTAssertEqual(MobileAPI.route(request("/.env")), .notFound)
        XCTAssertTrue(MobileAPI.isClientRoute("t/localhost:12"))
        XCTAssertFalse(MobileAPI.isClientRoute("_app/version.json"))
    }

    func testContentTypesAndCaching() {
        XCTAssertEqual(MobileAPI.contentType(forPath: "index.html"), "text/html; charset=utf-8")
        XCTAssertEqual(
            MobileAPI.contentType(forPath: "manifest.webmanifest"),
            "application/manifest+json; charset=utf-8")
        XCTAssertEqual(MobileAPI.contentType(forPath: "icon-192.png"), "image/png")
        XCTAssertEqual(
            MobileAPI.cacheControl(forPath: "_app/immutable/chunks/a.js"),
            "public, max-age=31536000, immutable")
        XCTAssertEqual(MobileAPI.cacheControl(forPath: "service-worker.js"), "no-cache")
        XCTAssertEqual(MobileAPI.cacheControl(forPath: "index.html"), "no-cache")
    }

    // MARK: screen lines and validators

    func testScreenLinesAreDigitsOnlyAndClamped() {
        XCTAssertEqual(MobileAPI.screenLines(nil), 2000)
        XCTAssertEqual(MobileAPI.screenLines("500"), 500)
        XCTAssertEqual(MobileAPI.screenLines("10000"), 10_000)
        XCTAssertEqual(MobileAPI.screenLines("10001"), 10_000)
        XCTAssertEqual(MobileAPI.screenLines("999999999"), 10_000)
        XCTAssertEqual(MobileAPI.screenLines("0"), 1)
        // Not all digits, or too long to be a count: the default, never an error
        // and never a value passed on to tmux.
        for raw in ["", "-5", "+5", "5e3", "12a", " 12", "1.5", "0x10", "１２", "99999999999999999999",
                    "500;rm", "500 -t %1"] {
            XCTAssertEqual(MobileAPI.screenLines(raw), 2000, raw)
        }
    }

    func testEtagMatchesOnlyTheSameBody() {
        let a = MobileAPI.etag(Data("one".utf8)), b = MobileAPI.etag(Data("two".utf8))
        XCTAssertEqual(a, MobileAPI.etag(Data("one".utf8)))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("\"") && a.hasSuffix("\""))
        XCTAssertTrue(MobileAPI.isFresh(request("/", headers: ["If-None-Match": a]), etag: a))
        XCTAssertTrue(MobileAPI.isFresh(request("/", headers: ["If-None-Match": "\(b), \(a)"]), etag: a))
        XCTAssertFalse(MobileAPI.isFresh(request("/", headers: ["If-None-Match": b]), etag: a))
        XCTAssertFalse(MobileAPI.isFresh(request("/"), etag: a))
    }

    // MARK: capabilities

    func testADisabledCapabilityRefusesEveryPathUnderIt() {
        let off = MobileConfig()
        let gated: [(String, String, MobileCapability)] = [
            ("GET", "/api/manager", .manager),
            ("POST", "/api/manager/text", .manager),
            ("POST", "/api/voice", .voice),
            ("POST", "/api/threads/localhost%3A1/text", .replies),
            ("POST", "/api/threads/localhost%3A1/key", .replies),
            ("POST", "/api/threads/localhost%3A1/upload", .upload),
            ("GET", "/api/threads/localhost%3A1/artifacts", .artifacts),
            ("GET", "/api/threads/localhost%3A1/file?path=a", .artifacts),
            ("POST", "/api/tmux/new-window", .sessionActions),
            ("POST", "/api/tmux/kill", .kill),
            ("POST", "/api/servers/open", .localServers),
            ("POST", "/api/servers/5173/stop", .stopServers),
            ("POST", "/api/push/subscribe", .notifications),
            ("GET", "/api/terminal/localhost%3A1", .liveTerminal),
        ]
        for (method, path, capability) in gated {
            XCTAssertEqual(
                MobileAPI.route(request(path, method: method), config: off), .disabled(capability), path)
        }
    }

    func testAnEnabledCapabilityReachesTheRouterAndOthersStayOff() {
        let config = MobileConfig(capabilities: [.replies])
        // Its routes are not built yet, so the router answers, not the gate.
        XCTAssertEqual(
            MobileAPI.route(request("/api/threads/localhost%3A1/text", method: "POST"), config: config),
            .notFound)
        XCTAssertEqual(
            MobileAPI.route(request("/api/threads/localhost%3A1/upload", method: "POST"), config: config),
            .disabled(.upload))
        // Kill has its own switch: session actions alone do not allow it.
        let actions = MobileConfig(capabilities: [.sessionActions])
        XCTAssertEqual(
            MobileAPI.route(request("/api/tmux/kill", method: "POST"), config: actions), .disabled(.kill))
    }

    func testEveryBuiltRouteBelongsToTheMasterCapability() {
        for path in ["/api/config", "/api/threads", "/api/hosts", "/api/events",
                     "/api/threads/localhost%3A1/chat", "/api/threads/localhost%3A1/screen"] {
            guard case .api(let endpoint) = MobileAPI.route(request(path)) else {
                XCTFail(path)
                continue
            }
            XCTAssertEqual(endpoint.capability, .access, path)
        }
        // The master capability is on whenever the server answers at all.
        XCTAssertTrue(MobileConfig().allows(.access))
    }

    // MARK: pairing token

    func testOnlyTheAPINeedsThePairingToken() {
        XCTAssertTrue(MobileAPI.needsToken(request("/api/threads")))
        XCTAssertTrue(MobileAPI.needsToken(request("/api/manager")))
        XCTAssertFalse(MobileAPI.needsToken(request("/")))
        XCTAssertFalse(MobileAPI.needsToken(request("/_app/immutable/a.js")))
        XCTAssertFalse(MobileAPI.needsToken(request("/t/localhost%3A1")))
    }

    func testThePairingTokenMustMatchExactly() {
        let good = request("/api/threads", headers: ["X-MuxMaestro-Token": "s3cret-token"])
        XCTAssertTrue(MobileAPI.hasToken(good, token: "s3cret-token"))
        XCTAssertFalse(MobileAPI.hasToken(good, token: "s3cret-token2"))
        XCTAssertFalse(MobileAPI.hasToken(good, token: "s3cret-toke"))
        XCTAssertFalse(MobileAPI.hasToken(good, token: "S3cret-token"))
        // Nothing is paired until a token exists.
        XCTAssertFalse(MobileAPI.hasToken(good, token: nil))
        XCTAssertFalse(MobileAPI.hasToken(good, token: ""))
        XCTAssertFalse(MobileAPI.hasToken(request("/api/threads"), token: "s3cret-token"))
        XCTAssertFalse(MobileAPI.hasToken(
            request("/api/threads", headers: ["X-MuxMaestro-Token": ""]), token: "s3cret-token"))
    }

    func testNewTokensAreLongDistinctAndURLSafe() {
        let tokens = (0..<50).map { _ in MobileTailnet.newToken() }
        XCTAssertEqual(Set(tokens).count, 50)
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for token in tokens {
            XCTAssertEqual(token.count, 43)
            XCTAssertTrue(token.unicodeScalars.allSatisfy(allowed.contains))
        }
        XCTAssertEqual(
            MobileTailnet.pairingURL(identity: identity, port: 7433, token: "abc"),
            "https://devmac.example.ts.net:7433/#pair=abc")
    }

    func testConfigJSONListsEveryCapability() throws {
        let config = MobileConfig(capabilities: [.voice], grouping: .host)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: config.json()) as? [String: Any])
        let capabilities = try XCTUnwrap(object["capabilities"] as? [String: Bool])
        XCTAssertEqual(Set(capabilities.keys), Set(MobileCapability.allCases.map(\.rawValue)))
        XCTAssertEqual(capabilities.filter(\.value).map(\.key).sorted(), ["access", "voice"])
        XCTAssertEqual(object["grouping"] as? String, "host")
        XCTAssertFalse(MobileConfig().allows(.manager))
    }

    // MARK: auth

    func testAllowsOnlyThisMacsLoginThroughItsTailnetName() {
        XCTAssertEqual(MobileAPI.authorize(request("/api/threads", headers: trusted), identity: identity), .allowed)
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/threads", headers: [
                "Host": "DevMac.Example.ts.net", "Tailscale-User-Login": "ME@example.com",
            ]), identity: identity),
            .allowed)
    }

    func testDeniesAMissingOrForeignLogin() {
        XCTAssertEqual(
            MobileAPI.authorize(
                request("/", headers: ["Host": "devmac.example.ts.net:7433"]), identity: identity),
            .denied("login"))
        XCTAssertEqual(
            MobileAPI.authorize(request("/", headers: [
                "Host": "devmac.example.ts.net:7433", "Tailscale-User-Login": "other@example.com",
            ]), identity: identity),
            .denied("login"))
        XCTAssertEqual(
            MobileAPI.authorize(request("/", headers: trusted), identity: nil), .denied("no identity"))
    }

    func testDeniesAnotherHostName() {
        // A loopback request, or a rebinding page under its own name.
        for host in ["127.0.0.1:7433", "localhost:7433", "evil.example.com", "devmac.example.ts.net.evil.example.com"] {
            XCTAssertEqual(
                MobileAPI.authorize(request("/", headers: [
                    "Host": host, "Tailscale-User-Login": "me@example.com",
                ]), identity: identity),
                .denied("host"), host)
        }
    }

    func testAWriteNeedsTheCustomHeaderAndTheSameOrigin() {
        var headers = trusted
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .denied("write header"))
        headers["X-MuxMaestro"] = "1"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .denied("origin"))
        headers["Origin"] = "https://evil.example.com"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .denied("origin"))
        headers["Origin"] = "http://devmac.example.ts.net:7433"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .denied("origin"))
        // The right name on another port is another `tailscale serve` mapping.
        headers["Origin"] = "https://devmac.example.ts.net:5173"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .denied("origin"))
        headers["Origin"] = "https://devmac.example.ts.net"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .denied("origin"))
        headers["Origin"] = "https://devmac.example.ts.net:7433"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .allowed)
        // Port 443 is the one an origin and a Host header both leave out.
        headers["Host"] = "devmac.example.ts.net"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .denied("origin"))
        headers["Origin"] = "https://devmac.example.ts.net"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .allowed)
        headers["Origin"] = "https://devmac.example.ts.net:443"
        XCTAssertEqual(
            MobileAPI.authorize(request("/api/x", method: "POST", headers: headers), identity: identity),
            .allowed)
    }

    // MARK: snapshot

    private func pane(
        _ id: String, command: String = "zsh", active: Bool = false, claude: String? = nil,
        attention: AttentionStatus = .unknown
    ) -> TmuxPane {
        var pane = TmuxPane(id: id, index: 0, command: command, title: "", active: active)
        pane.path = "/Users/me/code/acme-app"
        pane.claudeSessionId = claude
        pane.attention = attention
        return pane
    }

    private func snapshot() -> MobileSnapshot {
        var waiting = pane("%12", command: "claude", active: true, claude: "c1", attention: .waiting)
        waiting.agentState = AgentPaneState(sessionId: "c1", state: .waiting, since: 1_759_500_000)
        waiting.lastPrompt = LastPrompt(text: "fix the failing checkout test", at: 1_759_499_000)
        waiting.lastActivityAt = 1_759_499_900
        var dozing = pane("%13", command: "claude", claude: "c2", attention: .idle)
        dozing.idleStage = .dozing
        let local = [
            TmuxSession(name: "acme-app", attached: true, windows: [
                TmuxWindow(index: 1, name: "💤 checkout-fix", active: true,
                           panes: [waiting, dozing, pane("%14")]),
                TmuxWindow(index: 2, name: "shell", active: false,
                           panes: [pane("%15"), pane("%16", active: true)]),
            ], activity: 1_759_400_000),
        ]
        let devbox = Host(name: "devbox", sshAlias: "devbox")
        let remote = [
            TmuxSession(name: "billing", attached: false, windows: [
                TmuxWindow(index: 0, name: "proration", active: true,
                           panes: [pane("%3", command: "claude", active: true, claude: "r1", attention: .busy)]),
            ]),
        ]
        var stats = HostStats()
        stats.cpuPercent = 38
        stats.cores = 8
        return MobileSnapshot.build([
            MobileHostInput(host: .local, colorHex: "#3291ff", reachability: .reachable,
                            stats: stats, sessions: local),
            MobileHostInput(host: devbox, colorHex: "#f5a623", reachability: .reachable,
                            stats: nil, sessions: remote),
            MobileHostInput(host: Host(name: "buildbox", sshAlias: "buildbox"), colorHex: "#a371f7",
                            reachability: .unreachable, stats: nil, sessions: []),
        ])
    }

    func testEveryAgentPaneIsAThreadAndAPlainWindowHasOne() {
        let snapshot = snapshot()
        XCTAssertEqual(
            snapshot.threads.map(\.id),
            ["localhost:12", "localhost:13", "localhost:16", "devbox:3"])
        // Two agent panes share window 1; the shell pane beside them is not a thread.
        XCTAssertEqual(snapshot.threads.map(\.panes), [2, 2, 1, 1])
        XCTAssertEqual(snapshot.threads[0].name, "checkout-fix")
        XCTAssertEqual(snapshot.hosts.map(\.threads), [3, 1, 0])
    }

    func testThreadJSONShape() throws {
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshot().threadsJSON()) as? [String: Any])
        let threads = try XCTUnwrap(body["threads"] as? [[String: Any]])
        let first = threads[0]
        XCTAssertEqual(first["id"] as? String, "localhost:12")
        XCTAssertEqual(first["host"] as? String, "localhost")
        XCTAssertEqual(first["hostColor"] as? String, "#3291ff")
        XCTAssertEqual(first["local"] as? Bool, true)
        XCTAssertEqual(first["session"] as? String, "acme-app")
        XCTAssertEqual(first["window"] as? Int, 1)
        XCTAssertEqual(first["pane"] as? String, "%12")
        XCTAssertEqual(first["command"] as? String, "claude")
        XCTAssertEqual(first["cwd"] as? String, "/Users/me/code/acme-app")
        XCTAssertEqual(first["status"] as? String, "waiting")
        XCTAssertEqual(first["since"] as? Int, 1_759_500_000)
        XCTAssertEqual(first["idleStage"] as? String, "awake")
        XCTAssertEqual((first["lastPrompt"] as? [String: Any])?["text"] as? String,
                       "fix the failing checkout test")
        XCTAssertEqual((first["lastPrompt"] as? [String: Any])?["at"] as? Int, 1_759_499_000)
        XCTAssertEqual(first["lastActivityAt"] as? Int, 1_759_499_900)
        XCTAssertEqual(first["sessionActivity"] as? Int, 1_759_400_000)
        XCTAssertEqual(first["chat"] as? Bool, true)
        // The session ids stay on the Mac.
        XCTAssertNil(first["claudeSessionId"])

        XCTAssertEqual(threads[1]["idleStage"] as? String, "dozing")
        XCTAssertTrue(threads[1]["since"] is NSNull)
        XCTAssertTrue(threads[2]["lastPrompt"] is NSNull)
        XCTAssertEqual(threads[2]["chat"] as? Bool, false)
        // A remote agent has no transcript on this Mac: terminal only.
        XCTAssertEqual(threads[3]["chat"] as? Bool, false)
        XCTAssertEqual(threads[3]["local"] as? Bool, false)
        XCTAssertEqual(threads[3]["hostColor"] as? String, "#f5a623")
    }

    func testHostsJSONShape() throws {
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshot().hostsJSON()) as? [String: Any])
        let hosts = try XCTUnwrap(body["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.map { $0["name"] as? String }, ["localhost", "devbox", "buildbox"])
        XCTAssertEqual(hosts[0]["color"] as? String, "#3291ff")
        XCTAssertEqual(hosts[0]["reachability"] as? String, "reachable")
        let stats = try XCTUnwrap(hosts[0]["stats"] as? [String: Any])
        XCTAssertEqual(stats["cpuPercent"] as? Double, 38)
        XCTAssertEqual(stats["cores"] as? Int, 8)
        XCTAssertTrue(stats["load1"] is NSNull)
        XCTAssertTrue(hosts[1]["stats"] is NSNull)
        XCTAssertEqual(hosts[2]["reachability"] as? String, "unreachable")
    }

    func testAStaleIdResolvesToNothingAndEqualSnapshotsEncodeEqually() {
        let snapshot = snapshot()
        XCTAssertEqual(snapshot.thread(id: "devbox:3")?.pane, "%3")
        XCTAssertNil(snapshot.thread(id: "devbox:12"))
        XCTAssertNil(snapshot.thread(id: "localhost:3"))
        XCTAssertEqual(snapshot.threadsJSON(), self.snapshot().threadsJSON())
    }

    // MARK: chat

    func testClaudeTranscriptBecomesChatRows() throws {
        let path = Self.fixtures.appendingPathComponent("claude.jsonl").path
        let page = try XCTUnwrap(MobileChat.read(path: path, codex: false, after: nil))
        XCTAssertFalse(page.reset)
        XCTAssertEqual(page.messages.map(\.role), [.user, .assistant, .tool, .tool, .assistant])
        XCTAssertEqual(page.messages[0].text, "fix the failing checkout test and open a PR")
        XCTAssertEqual(page.messages[2].tool, "Read")
        XCTAssertEqual(page.messages[2].text, "tests/checkout.spec.ts")
        XCTAssertEqual(page.messages[3].tool, "Bash")
        XCTAssertEqual(page.messages[3].text, "pnpm exec playwright test tests/checkout.spec.ts")
        XCTAssertEqual(page.messages[4].text, "Edited. The page is up on the dev server.")
        // Row numbers increase, so the client can key and order on them.
        XCTAssertEqual(page.messages.map(\.n), page.messages.map(\.n).sorted())
        XCTAssertEqual(Set(page.messages.map(\.n)).count, page.messages.count)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).uint64Value
        XCTAssertEqual(page.next, size)
    }

    func testCodexRolloutBecomesChatRows() throws {
        let path = Self.fixtures.appendingPathComponent("codex.jsonl").path
        let page = try XCTUnwrap(MobileChat.read(path: path, codex: true, after: nil))
        XCTAssertEqual(page.messages.map(\.role), [.user, .tool, .assistant])
        XCTAssertEqual(page.messages[0].text, "wire the search box to the new index")
        XCTAssertEqual(page.messages[1].tool, "shell")
        XCTAssertEqual(page.messages[1].text, "rg searchIndex")
    }

    func testChatCursorReturnsOnlyNewRowsAndSkipsAHalfWrittenLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-chat-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = #"{"type":"user","message":{"role":"user","content":"one"}}"# + "\n"
        let second = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"two"}]}}"#
        try Data((first + second).utf8).write(to: url)

        // The second line has no newline yet: it is still being written.
        let page = try XCTUnwrap(MobileChat.read(path: url.path, codex: false, after: nil))
        XCTAssertEqual(page.messages.map(\.text), ["one"])
        XCTAssertEqual(page.next, UInt64(first.utf8.count))

        try Data((first + second + "\n").utf8).write(to: url)
        let more = try XCTUnwrap(MobileChat.read(path: url.path, codex: false, after: page.next))
        XCTAssertEqual(more.messages.map(\.text), ["two"])
        XCTAssertFalse(more.reset)
        XCTAssertGreaterThan(more.messages[0].n, page.messages[0].n)

        let none = try XCTUnwrap(MobileChat.read(path: url.path, codex: false, after: more.next))
        XCTAssertEqual(none.messages, [])
        XCTAssertEqual(none.next, more.next)

        // A transcript rewritten shorter than the cursor starts over.
        try Data(first.utf8).write(to: url)
        let reset = try XCTUnwrap(MobileChat.read(path: url.path, codex: false, after: more.next))
        XCTAssertTrue(reset.reset)
        XCTAssertEqual(reset.messages.map(\.text), ["one"])
        XCTAssertNil(MobileChat.read(path: url.path + ".missing", codex: false, after: nil))
    }

    // MARK: tailscale

    private let status = """
        {"Self":{"DNSName":"devmac.example.ts.net.","UserID":1001,"TailscaleIPs":["100.64.0.1"]},
         "User":{"1001":{"LoginName":"me@example.com"},"1002":{"LoginName":"other@example.com"}},
         "Peer":{"k":{"DNSName":"devbox.example.ts.net.","UserID":1002}},
         "CurrentTailnet":{"MagicDNSEnabled":true}}
        """

    func testIdentityIsThisMacsLoginAndName() {
        XCTAssertEqual(
            MobileTailnet.identity(statusJSON: status),
            MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net"))
        XCTAssertNil(MobileTailnet.identity(statusJSON: "{}"))
        XCTAssertNil(MobileTailnet.identity(statusJSON: #"{"Self":{"DNSName":"","UserID":1}}"#))
        // Signed out: no user for the id.
        XCTAssertNil(MobileTailnet.identity(
            statusJSON: #"{"Self":{"DNSName":"devmac.example.ts.net.","UserID":1},"User":{}}"#))
    }

    func testServeArgvAndURL() {
        XCTAssertEqual(
            MobileTailnet.serveOnArgv(port: 7433),
            ["serve", "--bg", "--https=7433", "http://127.0.0.1:7433"])
        XCTAssertEqual(MobileTailnet.serveOffArgv(port: 7433), ["serve", "--https=7433", "off"])
        XCTAssertEqual(
            MobileTailnet.url(identity: identity, port: 7433), "https://devmac.example.ts.net:7433/")
        XCTAssertEqual(MobileTailnet.url(identity: identity, port: 443), "https://devmac.example.ts.net/")
    }

    func testAPortAnotherProjectServesIsTaken() {
        let serving = """
            {"TCP":{"443":{"HTTPS":true},"7433":{"HTTPS":true},"9000":{"TCPForward":"127.0.0.1:9000"}},
             "Web":{"devmac.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},
                    "devmac.example.ts.net:7433":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7433"}}}}}
            """
        XCTAssertTrue(MobileTailnet.portTaken(serveStatusJSON: serving, port: 443))
        // Our own mapping left from a crash is ours to reuse.
        XCTAssertFalse(MobileTailnet.portTaken(serveStatusJSON: serving, port: 7433))
        XCTAssertTrue(MobileTailnet.portTaken(serveStatusJSON: serving, port: 9000))
        XCTAssertFalse(MobileTailnet.portTaken(serveStatusJSON: serving, port: 7434))
        XCTAssertFalse(MobileTailnet.portTaken(serveStatusJSON: "{}", port: 7433))

        // Only a mapping to our own listener counts as a leftover of ours.
        XCTAssertTrue(MobileTailnet.servesOurs(serveStatusJSON: serving, port: 7433))
        XCTAssertFalse(MobileTailnet.servesOurs(serveStatusJSON: serving, port: 443))
        XCTAssertFalse(MobileTailnet.servesOurs(serveStatusJSON: serving, port: 9000))
        XCTAssertFalse(MobileTailnet.servesOurs(serveStatusJSON: serving, port: 7434))
        XCTAssertFalse(MobileTailnet.servesOurs(serveStatusJSON: "{}", port: 7433))
    }
}
