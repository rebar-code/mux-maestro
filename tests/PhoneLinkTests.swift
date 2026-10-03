import XCTest

// PhoneLink.swift compiles into this test target. The tailscale CLI is a fake
// runner, so the exact argv to publish and unpublish the server is asserted.
private final class FakeTailscale: CommandRunner {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var status: String? = """
        {"Self":{"DNSName":"devmac.example.ts.net.","UserID":1001},
         "User":{"1001":{"LoginName":"me@example.com"}}}
        """
    var serving: String? = "{}"
    var serveFails = false

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        recorded.append(args)
        lock.unlock()
        if args == MobileTailnet.statusArgv { return status }
        if args == MobileTailnet.serveStatusArgv { return serving }
        if args.contains("--bg"), serveFails { return nil }
        return ""
    }
}

/// The Keychain's stand-in: one token in memory.
private final class MemoryTokens: PhoneTokenStore {
    var token: String?
    var refuses = false

    func load() -> String? { token }

    func save(_ token: String) -> Bool {
        guard !refuses else { return false }
        self.token = token
        return true
    }
}

final class PhoneLinkTests: XCTestCase {
    private var tokens: MemoryTokens!
    private var tailscale: FakeTailscale!
    private var server: MobileServer!
    private var states: [PhoneLink.State] = []
    private let lock = NSLock()

    override func setUp() {
        tailscale = FakeTailscale()
        tokens = MemoryTokens()
        server = MobileServer(staticRoot: nil, sources: MobileServer.Sources(
            screen: { _ in nil }, transcript: { _ in nil }))
        states = []
    }

    override func tearDown() {
        server.stop()
    }

    /// A link on a free port (0), whose state changes land in `states`.
    private func link(
        tailscalePath: String? = "/usr/local/bin/tailscale", port: Int = 0, keepAwake: Bool = false
    ) -> PhoneLink {
        let link = PhoneLink(
            server: server, runner: tailscale, tailscalePath: { tailscalePath },
            port: { port }, keepAwake: { keepAwake }, tokens: tokens, notify: { $0() })
        link.onChange = { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            self.states.append(state)
            self.lock.unlock()
        }
        return link
    }

    private func settle(_ link: PhoneLink, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while link.state == .starting, Date() < deadline { usleep(10_000) }
        XCTAssertNotEqual(link.state, .starting, file: file, line: line)
    }

    func testTurningOnStartsTheListenerThenPublishesIt() throws {
        let link = link()
        XCTAssertEqual(link.state, .off)
        link.turnOn()
        settle(link)
        guard case .on(let url, let pairing) = link.state else { return XCTFail("\(link.state)") }
        let port = try XCTUnwrap(URL(string: url)?.port)
        XCTAssertEqual(url, "https://devmac.example.ts.net:\(port)/")
        // The first start makes the pairing token and stores it.
        let token = try XCTUnwrap(tokens.token)
        XCTAssertEqual(token.count, 43)
        XCTAssertEqual(pairing, url + "#pair=" + token)
        XCTAssertEqual(tailscale.calls, [
            ["status", "--json"],
            ["serve", "status", "--json"],
            ["serve", "--bg", "--https=\(port)", "http://127.0.0.1:\(port)"],
        ])
        XCTAssertTrue(link.isOn)

        link.turnOff()
        while link.state != .off { usleep(10_000) }
        XCTAssertEqual(tailscale.calls.last, ["serve", "--https=\(port)", "off"])
        XCTAssertEqual(states.first, .starting)
        XCTAssertEqual(states.last, .off)
    }

    func testTheStoredTokenIsReusedAndRotationReplacesIt() {
        tokens.token = "stored-token"
        let link = link()
        link.turnOn()
        settle(link)
        guard case .on(let url, let pairing) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertEqual(pairing, url + "#pair=stored-token")

        link.rotateToken()
        let deadline = Date().addingTimeInterval(5)
        while tokens.token == "stored-token", Date() < deadline { usleep(10_000) }
        let fresh = tokens.token ?? ""
        XCTAssertNotEqual(fresh, "stored-token")
        while link.state == .on(url: url, pairing: pairing), Date() < deadline { usleep(10_000) }
        XCTAssertEqual(link.state, .on(url: url, pairing: url + "#pair=" + fresh))
        link.shutdown()
    }

    func testNoStoredTokenMeansNothingIsPublished() {
        tokens.refuses = true
        let link = link()
        link.turnOn()
        settle(link)
        XCTAssertEqual(link.state, .failed("Keychain refused the pairing token"))
        XCTAssertFalse(tailscale.calls.contains { $0.contains("--bg") })
    }

    func testALeftoverMappingOfOursIsRemovedAndAnotherProjectsIsNot() {
        tailscale.serving = """
            {"Web":{"devmac.example.ts.net:7433":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7433"}}}}}
            """
        let ours = link(port: 7433)
        ours.removeLeftoverMapping()
        ours.shutdown()  // drains the link's queue
        XCTAssertEqual(tailscale.calls, [["serve", "status", "--json"], ["serve", "--https=7433", "off"]])

        tailscale.serving = """
            {"Web":{"devmac.example.ts.net:7433":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}
            """
        let theirs = link(port: 7433)
        theirs.removeLeftoverMapping()
        theirs.shutdown()
        XCTAssertEqual(tailscale.calls.filter { $0.last == "off" }.count, 1)
    }

    /// Bug: Phone access switched itself back off after a relaunch. A killed app
    /// leaves its `tailscale serve` mapping behind, and while that mapping
    /// exists the loopback listener cannot bind the port ("Port N is in use").
    /// Our own leftover must be removed before the listener starts.
    func testOurOwnLeftoverMappingIsRemovedBeforeTheListenerStarts() throws {
        tailscale.serving = """
            {"Web":{"devmac.example.ts.net:0":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:0"}}}}}
            """
        let link = link()
        link.turnOn()
        settle(link)
        guard case .on(let url, _) = link.state else { return XCTFail("\(link.state)") }
        let port = try XCTUnwrap(URL(string: url)?.port)
        XCTAssertEqual(tailscale.calls, [
            ["status", "--json"],
            ["serve", "status", "--json"],
            ["serve", "--https=0", "off"],
            ["serve", "--bg", "--https=\(port)", "http://127.0.0.1:\(port)"],
        ])
        link.shutdown()
    }

    func testNoTailscaleOrNoLoginFailsBeforeAnythingListens() {
        let missing = link(tailscalePath: nil)
        missing.turnOn()
        settle(missing)
        XCTAssertEqual(missing.state, .failed("Tailscale is not installed"))
        XCTAssertEqual(tailscale.calls, [])

        tailscale.status = nil
        let signedOut = link()
        signedOut.turnOn()
        settle(signedOut)
        XCTAssertEqual(signedOut.state, .failed("Tailscale is not signed in"))
        XCTAssertFalse(tailscale.calls.contains { $0.contains("--bg") })
    }

    func testAPortAnotherProjectServesIsLeftAlone() {
        tailscale.serving = """
            {"Web":{"devmac.example.ts.net:7433":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}
            """
        let link = link(port: 7433)
        link.turnOn()
        settle(link)
        XCTAssertEqual(link.state, .failed("Tailscale already serves port 7433"))
        XCTAssertFalse(tailscale.calls.contains { $0.first == "serve" && $0.contains("--bg") })
        XCTAssertFalse(tailscale.calls.contains { $0.last == "off" })
    }

    func testAFailedServeStopsTheListenerAndUnpublishesNothing() {
        tailscale.serveFails = true
        let link = link()
        link.turnOn()
        settle(link)
        XCTAssertEqual(link.state, .failed("tailscale serve failed"))
        link.shutdown()
        XCTAssertFalse(tailscale.calls.contains { $0.last == "off" })
    }

    func testKeepsTheMacAwakeOnlyWhileOnAndAskedTo() {
        let plain = link()
        plain.turnOn()
        settle(plain)
        XCTAssertFalse(plain.isKeepingAwake)
        plain.shutdown()

        let awake = link(keepAwake: true)
        awake.turnOn()
        settle(awake)
        XCTAssertTrue(awake.isKeepingAwake)
        awake.shutdown()
        XCTAssertFalse(awake.isKeepingAwake)
    }
}
