import Network
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
    /// When set, the serve status is what the serve calls so far add up to,
    /// as the real CLI answers. `serving` is not read then.
    var live = false
    private var proxies: [Int: String] = [:]

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        recorded.append(args)
        defer { lock.unlock() }
        if args == MobileTailnet.statusArgv { return status }
        if args == MobileTailnet.serveStatusArgv { return live ? liveStatus : serving }
        if args.contains("--bg"), serveFails { return nil }
        if args.count == 4, args[1] == "--bg", let port = Int(args[2].dropFirst("--https=".count)) {
            proxies[port] = args[3]
        }
        if args.count == 3, args[2] == "off", let port = Int(args[1].dropFirst("--https=".count)) {
            proxies[port] = nil
        }
        return ""
    }

    private var liveStatus: String {
        let web = proxies.map {
            #""devmac.example.ts.net:\#($0.key)":{"Handlers":{"/":{"Proxy":"\#($0.value)"}}}"#
        }
        return "{\"Web\":{\(web.joined(separator: ","))}}"
    }
}

/// The stored mappings (port and target), in memory.
private final class MemoryPorts: PhonePortStore {
    var stored: [Int: String] = [:]

    func load() -> [Int: String] { stored }
    func save(_ ports: [Int: String]) { stored = ports }
}

/// The Keychain's stand-in: one token in memory.
private final class MemoryTokens: PhoneTokenStore {
    var token: String?
    var refuses = false
    /// When set, a read blocks until it is signalled: the Keychain dialog
    /// waiting for a click.
    var dialog: DispatchSemaphore?
    /// Reads fail; what is stored stays stored.
    var unreadable = false

    func load() -> String? {
        dialog?.wait()
        return unreadable ? nil : token
    }

    func read() -> PhoneTokenRead {
        dialog?.wait()
        return unreadable ? .failed : token.map(PhoneTokenRead.found) ?? .missing
    }

    func save(_ token: String) -> Bool {
        guard !refuses else { return false }
        self.token = token
        return true
    }
}

final class PhoneLinkTests: XCTestCase {
    private var tokens: MemoryTokens!
    private var tailscale: FakeTailscale!
    private var ports: MemoryPorts!
    /// The clock the link reads; a test moves it.
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var published: [[Int]] = []
    private var server: MobileServer!
    private var push: MobilePushCenter!
    private var states: [PhoneLink.State] = []
    private let lock = NSLock()

    override func setUp() {
        tailscale = FakeTailscale()
        tokens = MemoryTokens()
        ports = MemoryPorts()
        published = []
        push = MobilePushCenter(
            keys: MemoryTokenStore(), store: MemoryTokenStore(), transport: FakePushTransport())
        server = MobileServer(staticRoot: nil, sources: MobileServer.Sources(
            screen: { _, _ in nil }, transcript: { _ in nil }), push: push)
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
            port: { port }, keepAwake: { keepAwake }, tokens: tokens, ports: ports,
            now: { [unowned self] in self.clock }, keychainNotice: 0.05, notify: { $0() })
        link.onMappings = { [weak self] mappings in
            guard let self else { return }
            self.lock.lock()
            self.published.append(mappings.map(\.port))
            self.lock.unlock()
        }
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
        while link.state == .starting || link.state == .waitingForKeychain, Date() < deadline {
            usleep(10_000)
        }
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

    /// Bug: a new build makes macOS ask for the pairing token again, and the
    /// start sat in the Keychain read with the pane still saying "Starting…".
    func testASlowKeychainReadSaysSoAndThenStarts() {
        tokens.token = "stored-token"
        let dialog = DispatchSemaphore(value: 0)
        tokens.dialog = dialog
        let link = link()
        link.turnOn()
        let deadline = Date().addingTimeInterval(5)
        while link.state != .waitingForKeychain, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(link.state, .waitingForKeychain)
        XCTAssertFalse(link.isOn)
        // Nothing is published while the read is pending.
        XCTAssertFalse(tailscale.calls.contains { $0.contains("--bg") })

        dialog.signal()  // the user clicked Allow
        tokens.dialog = nil
        settle(link)
        guard case .on(_, let pairing) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertTrue(pairing.hasSuffix("#pair=stored-token"))
        link.shutdown()
    }

    func testAFastKeychainReadNeverShowsTheNotice() {
        tokens.token = "stored-token"
        let link = link()
        link.turnOn()
        settle(link)
        XCTAssertTrue(link.isOn)
        usleep(150_000)  // past the notice delay
        XCTAssertFalse(states.contains(.waitingForKeychain))
        XCTAssertTrue(link.isOn)
        link.shutdown()
    }

    func testATokenThatCannotBeReadIsNotReplaced() {
        tokens.token = "stored-token"
        tokens.unreadable = true
        XCTAssertEqual(push.subscribe(FakePhone().body).status, 200)
        let link = link()
        link.turnOn()
        settle(link)
        // The phones hold the stored token: a new one would sign them all out.
        XCTAssertEqual(link.state, .failed("Keychain did not give the pairing token"))
        XCTAssertEqual(tokens.token, "stored-token")
        XCTAssertFalse(tailscale.calls.contains { $0.contains("--bg") })
        XCTAssertEqual(push.count, 1)

        tokens.unreadable = false
        link.turnOn()
        settle(link)
        guard case .on(_, let pairing) = link.state else { return XCTFail("\(link.state)") }
        XCTAssertTrue(pairing.hasSuffix("#pair=stored-token"))
        // The same token as before: the phones stay subscribed.
        XCTAssertEqual(push.count, 1)
        link.shutdown()
    }

    func testANewTokenMadeAtStartForgetsTheSubscribedPhones() {
        // The stored token is gone, so every phone is signed out. None of
        // them may go on getting notifications.
        XCTAssertEqual(push.subscribe(FakePhone().body).status, 200)
        XCTAssertNil(tokens.token)
        let link = link()
        link.turnOn()
        settle(link)
        guard case .on = link.state else { return XCTFail("\(link.state)") }
        XCTAssertNotNil(tokens.token)
        XCTAssertEqual(push.count, 0)
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

    // MARK: dev-server mappings

    /// A link that is on, with a serve status that follows the serve calls.
    /// Returns it with the port its own server is published on.
    private func linkOn() throws -> (PhoneLink, Int) {
        tailscale.live = true
        let link = link()
        link.turnOn()
        settle(link)
        guard case .on(let url, _) = link.state else {
            XCTFail("\(link.state)")
            throw CancellationError()
        }
        return (link, try XCTUnwrap(URL(string: url)?.port))
    }

    private func open(_ link: PhoneLink, _ port: Int, https: Bool = false) -> MobileServing.Opened {
        link.openMapping(port: port, https: https, thread: "localhost:12", label: "acme-app")
    }

    /// The serve calls that publish or unpublish a dev server (not the status reads).
    private func serves(own: Int) -> [[String]] {
        tailscale.calls.filter { $0.first == "serve" && $0[1] != "status" && $0[1] != "--https=\(own)"
            && !($0.count == 4 && $0[2] == "--https=\(own)") }
    }

    func testOpeningAMappingRunsTheExactServeCommandAndClosingTakesItAway() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(open(link, 5173), .ok)
        XCTAssertEqual(open(link, 6006, https: true), .ok)
        XCTAssertEqual(serves(own: own), [
            ["serve", "--bg", "--https=5173", "http://localhost:5173"],
            ["serve", "--bg", "--https=6006", "https+insecure://localhost:6006"],
        ])
        XCTAssertEqual(link.mappings.map(\.port), [5173, 6006])
        XCTAssertEqual(link.mappings.first?.thread, "localhost:12")
        XCTAssertEqual(link.mappings.first?.label, "acme-app")
        XCTAssertEqual(ports.stored, [
            5173: "http://localhost:5173", 6006: "https+insecure://localhost:6006",
        ])
        XCTAssertEqual(published, [[5173], [5173, 6006]])
        XCTAssertFalse(tailscale.calls.contains { $0.contains { $0.contains("funnel") } })

        XCTAssertTrue(link.closeMapping(port: 5173))
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=5173", "off"])
        XCTAssertEqual(link.mappings.map(\.port), [6006])
        XCTAssertEqual(ports.stored, [6006: "https+insecure://localhost:6006"])
        // Not a mapping of ours: nothing runs.
        let before = tailscale.calls.count
        XCTAssertFalse(link.closeMapping(port: 5173))
        XCTAssertFalse(link.closeMapping(port: 3000))
        XCTAssertFalse(link.closeMapping(port: own))
        XCTAssertEqual(tailscale.calls.count, before)
        link.shutdown()
    }

    func testOpeningTheSamePortAgainRenewsItWithoutASecondServe() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(open(link, 5173), .ok)
        clock.addTimeInterval(600)
        XCTAssertEqual(open(link, 5173), .ok)
        XCTAssertEqual(serves(own: own).count, 1)
        XCTAssertEqual(link.mappings.first?.openedAt, clock)
        link.shutdown()
    }

    func testTheOwnPortAndAPrivilegedPortAreRefusedBeforeAnythingRuns() throws {
        let (link, own) = try linkOn()
        let before = tailscale.calls.count
        for port in [own, 22, 80, 443, 1023, 0, -5, 65536] {
            XCTAssertEqual(open(link, port), .refused, "\(port)")
        }
        XCTAssertEqual(tailscale.calls.count, before)
        XCTAssertEqual(link.mappings, [])
        link.shutdown()
    }

    func testAPortSomethingElseAlreadyPublishesIsLeftAlone() throws {
        let (link, own) = try linkOn()
        tailscale.live = false
        for serving in [
            // Another project's mapping.
            #"{"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#,
            // A raw TCP forward.
            #"{"TCP":{"5173":{"TCPForward":"127.0.0.1:22"}}}"#,
            // Open to the internet.
            #"{"AllowFunnel":{"devmac.example.ts.net:5173":true},"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":"http://localhost:5173"}}}}}"#,
            // The same target, and not one this app made.
            #"{"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":"http://localhost:5173"}}}}}"#,
        ] {
            tailscale.serving = serving
            XCTAssertEqual(open(link, 5173), .taken, serving)
        }
        // No answer from Tailscale proves nothing: nothing is published.
        tailscale.serving = nil
        XCTAssertEqual(open(link, 5173), .unavailable("Tailscale did not answer"))
        XCTAssertEqual(serves(own: own), [])
        XCTAssertEqual(link.mappings, [])
        XCTAssertEqual(ports.stored, [:])
        tailscale.serving = "{}"
        link.shutdown()
    }

    func testNoMoreThanFiveMappingsAreOpenAtOnce() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(MobileServing.maxMappings, 5)
        for port in 3001...3005 { XCTAssertEqual(open(link, port), .ok) }
        XCTAssertEqual(open(link, 3006), .limit)
        // One of the five again is not a sixth.
        XCTAssertEqual(open(link, 3003), .ok)
        XCTAssertEqual(serves(own: own).count, 5)
        XCTAssertTrue(link.closeMapping(port: 3001))
        XCTAssertEqual(open(link, 3006), .ok)
        XCTAssertEqual(link.mappings.map(\.port), [3002, 3003, 3004, 3005, 3006])
        link.shutdown()
    }

    func testAFailedServeOrALinkThatIsOffPublishesNothing() throws {
        let off = link()
        XCTAssertEqual(open(off, 5173), .unavailable("Phone access is off"))
        XCTAssertEqual(tailscale.calls, [])

        let (link, _) = try linkOn()
        tailscale.serveFails = true
        XCTAssertEqual(open(link, 5173), .unavailable("tailscale serve failed"))
        XCTAssertEqual(link.mappings, [])
        XCTAssertEqual(ports.stored, [:])
        tailscale.serveFails = false
        link.shutdown()
    }

    func testTurningThePhoneOffOrQuittingRemovesEveryMapping() throws {
        for quit in [false, true] {
            let (link, own) = try linkOn()
            XCTAssertEqual(open(link, 5173), .ok)
            XCTAssertEqual(open(link, 6006), .ok)
            if quit {
                link.shutdown()
            } else {
                link.turnOff()
                while link.state != .off { usleep(10_000) }
            }
            XCTAssertEqual(Array(tailscale.calls.suffix(3)), [
                ["serve", "--https=5173", "off"], ["serve", "--https=6006", "off"],
                ["serve", "--https=\(own)", "off"],
            ])
            XCTAssertEqual(link.mappings, [])
            XCTAssertEqual(ports.stored, [:])
            XCTAssertEqual(published.last, [])
        }
    }

    /// What the app does with each new tree: one call with the tree and a way
    /// to ask what a pane runs. No port list is worked out by the caller.
    func testTheSweepWithATreeClosesAStoppedServerAndAThreadThatLeft() throws {
        let (link, own) = try linkOn()
        let drain = { _ = link.isKeepingAwake }
        XCTAssertEqual(open(link, 5173), .ok)
        XCTAssertEqual(open(link, 6006), .ok)
        func tree(_ panes: [String]) -> MobileSnapshot {
            MobileSnapshot.build([MobileHostInput(
                host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
                sessions: [TmuxSession(name: "acme-app", attached: true, windows: panes.enumerated().map {
                    TmuxWindow(index: $0.offset + 1, name: "w", active: true, panes: [
                        TmuxPane(id: $0.element, index: 0, command: "zsh", title: "", active: true),
                    ])
                })])])
        }
        func runs(_ ports: [Int], known: Bool = true) -> RunningSet {
            RunningSet(
                known: known,
                resources: ports.map {
                    RunningResource(
                        kind: .server(port: $0), host: Running.localHostName, paneID: "%12",
                        label: "acme-app", tooltip: "", url: "http://localhost:\($0)", pid: 4242)
                },
                unknowns: known ? [] : ["ports not checked yet on localhost"])
        }

        // Both servers run: nothing closes. The same when the scan has no answer yet.
        link.sweep(snapshot: tree(["%12"])) { _ in runs([5173, 6006]) }
        link.sweep(snapshot: tree(["%12"])) { _ in runs([], known: false) }
        drain()
        XCTAssertEqual(link.mappings.map(\.port), [5173, 6006])

        // The server on 6006 stopped.
        link.sweep(snapshot: tree(["%12"])) { _ in runs([5173]) }
        drain()
        XCTAssertEqual(link.mappings.map(\.port), [5173])
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=6006", "off"])

        // The phone server's own port among a thread's servers changes nothing.
        link.sweep(snapshot: tree(["%12"])) { _ in runs([5173, own]) }
        drain()
        XCTAssertEqual(link.mappings.map(\.port), [5173])

        // The thread left the tree: its mapping goes, and its pane is not asked.
        var asked = 0
        link.sweep(snapshot: tree(["%13"])) { _ in
            asked += 1
            return runs([5173])
        }
        drain()
        XCTAssertEqual(link.mappings, [])
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=5173", "off"])
        XCTAssertEqual(asked, 0)
    }

    func testTheSwitchGoingOffAStoppedServerAndHalfAnHourEachCloseAMapping() throws {
        let (link, own) = try linkOn()
        // Read through the link's queue, so what was asked before has run.
        let drain = { _ = link.isKeepingAwake }
        XCTAssertEqual(open(link, 5173), .ok)
        XCTAssertEqual(open(link, 6006), .ok)
        XCTAssertEqual(open(link, 8080), .ok)

        // Nothing is stale yet.
        link.sweepMappings(gone: [])
        drain()
        XCTAssertEqual(link.mappings.map(\.port), [5173, 6006, 8080])
        XCTAssertEqual(serves(own: own).count, 3)

        // The server on 6006 stopped.
        link.sweepMappings(gone: [6006, 9999])
        drain()
        XCTAssertEqual(link.mappings.map(\.port), [5173, 8080])
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=6006", "off"])

        // 8080 was opened again 20 minutes in; 5173 was not.
        clock.addTimeInterval(1200)
        XCTAssertEqual(open(link, 8080), .ok)
        clock.addTimeInterval(600)
        link.sweepMappings()
        drain()
        XCTAssertEqual(link.mappings.map(\.port), [8080])
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=5173", "off"])

        // The "Local servers" switch was turned off.
        link.closeAllMappings()
        drain()
        XCTAssertEqual(link.mappings, [])
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=8080", "off"])
        XCTAssertEqual(ports.stored, [:])
        XCTAssertTrue(link.isOn)
        link.shutdown()
    }

    func testAMappingSomeoneReplacedIsNotRemoved() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(open(link, 5173), .ok)
        tailscale.live = false
        tailscale.serving = """
            {"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}
            """
        XCTAssertTrue(link.closeMapping(port: 5173))
        XCTAssertFalse(serves(own: own).contains(["serve", "--https=5173", "off"]))
        XCTAssertEqual(link.mappings, [])
        link.shutdown()
    }

    func testLeftoverMappingsOfOursAreRemovedAtStartAndAnotherProjectsAreNot() {
        // 5173 and 6006 are still as this app made them. 7000 has the same
        // port and a `localhost` target, but not the one this app set. 8080 is
        // now another project's; 9000 is gone; 4000 was never stored.
        let serving = """
            {"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":"http://localhost:5173"}}},
            "devmac.example.ts.net:6006":{"Handlers":{"/":{"Proxy":"https+insecure://localhost:6006"}}},
            "devmac.example.ts.net:7000":{"Handlers":{"/":{"Proxy":"https+insecure://localhost:7000"}}},
            "devmac.example.ts.net:8080":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}},
            "devmac.example.ts.net:4000":{"Handlers":{"/":{"Proxy":"http://localhost:4000"}}}}}
            """
        let stored = [
            5173: "http://localhost:5173", 6006: "https+insecure://localhost:6006",
            7000: "http://localhost:7000", 8080: "http://localhost:8080", 9000: "http://localhost:9000",
        ]
        // With the switch off, at launch.
        tailscale.serving = serving
        ports.stored = stored
        let off = link(port: 7433)
        off.removeLeftoverMapping()
        off.shutdown()  // drains the link's queue
        XCTAssertEqual(tailscale.calls, [
            ["serve", "status", "--json"],
            ["serve", "--https=5173", "off"], ["serve", "--https=6006", "off"],
        ])
        XCTAssertEqual(ports.stored, [:])

        // With the switch on, before the listener starts.
        ports.stored = stored
        let on = link()
        on.turnOn()
        settle(on)
        XCTAssertTrue(on.isOn)
        let offs = tailscale.calls.filter { $0.last == "off" }
        XCTAssertEqual(offs, [
            ["serve", "--https=5173", "off"], ["serve", "--https=6006", "off"],
            ["serve", "--https=5173", "off"], ["serve", "--https=6006", "off"],
        ])
        // 4000 has our target form and was never stored: not ours to remove.
        XCTAssertFalse(tailscale.calls.contains(["serve", "--https=4000", "off"]))
        XCTAssertEqual(ports.stored, [:])
        XCTAssertEqual(on.mappings, [])
        tailscale.serving = "{}"
        on.shutdown()
    }

    /// A mapping on a port of ours that now proxies to the other `localhost`
    /// form is someone's own: it is not closed, renewed or removed as ours.
    func testAMappingWithAnotherTargetOnOurPortIsNotOurs() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(open(link, 5173), .ok)
        tailscale.live = false
        tailscale.serving = """
            {"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":"https+insecure://localhost:5173"}}}}}
            """
        // A second tap does not count it as open already.
        XCTAssertEqual(open(link, 5173), .taken)
        XCTAssertTrue(link.closeMapping(port: 5173))
        XCTAssertFalse(serves(own: own).contains(["serve", "--https=5173", "off"]))
        tailscale.serving = "{}"
        link.shutdown()
    }

    func testAnOlderStoredListOfBarePortsIsReadAsEmpty() throws {
        let suite = "phone-ports-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsPortStore(defaults: defaults)
        defaults.set([5173, 6006], forKey: store.key)
        XCTAssertEqual(store.load(), [:])
        store.save([5173: "http://localhost:5173"])
        XCTAssertEqual(store.load(), [5173: "http://localhost:5173"])
        store.save([:])
        XCTAssertEqual(store.load(), [:])
    }

    /// The whole path of one tap: the phone's request, the server's checks,
    /// the link, and the command Tailscale gets. Whatever else the body says,
    /// the command holds the port and the constant `localhost`.
    func testAnOpenRequestPutsNothingOfItsBodyButThePortIntoTheServeCommand() throws {
        tailscale.live = true
        final class Box { var link: PhoneLink? }
        let box = Box()
        let running = RunningSet(
            known: true,
            resources: [RunningResource(
                kind: .server(port: 5173), host: Running.localHostName, paneID: "%12",
                label: "acme-app", tooltip: "", url: "http://localhost:5173", pid: 4242)],
            unknowns: [])
        server = MobileServer(
            staticRoot: nil,
            sources: MobileServer.Sources(
                screen: { _, _ in nil }, transcript: { _ in nil }, running: { _ in running }),
            serving: MobileServer.Serving(
                open: { port, https, thread, label in
                    box.link?.openMapping(port: port, https: https, thread: thread, label: label)
                        ?? .unavailable("off")
                },
                close: { box.link?.closeMapping(port: $0) ?? false },
                list: { box.link?.mappings ?? [] }))
        let link = link()
        box.link = link
        link.turnOn()
        settle(link)
        guard case .on(let url, _) = link.state else { return XCTFail("\(link.state)") }
        let own = try XCTUnwrap(URL(string: url)?.port)
        server.configure(MobileConfig(capabilities: [.localServers]))
        var agent = TmuxPane(id: "%12", index: 0, command: "claude", title: "", active: true)
        agent.claudeSessionId = "c1"
        server.update(MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: "acme-app", attached: true, windows: [
                TmuxWindow(index: 1, name: "checkout-fix", active: true, panes: [agent]),
            ])])]))

        func post(_ path: String, _ json: String) -> String {
            let raw = "POST \(path) HTTP/1.1\r\nHost: devmac.example.ts.net:\(own)\r\n"
                + "Tailscale-User-Login: me@example.com\r\nOrigin: https://devmac.example.ts.net:\(own)\r\n"
                + "X-MuxMaestro: 1\r\nX-MuxMaestro-Token: \(tokens.token ?? "")\r\n"
                + "Content-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n" + json
            let connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(own))!, using: .tcp)
            let queue = DispatchQueue(label: "phone-link-tests")
            let finished = DispatchSemaphore(value: 0)
            var received = Data()
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let data { received.append(data) }
                    let text = String(decoding: received, as: UTF8.self)
                    if complete || error != nil || text.hasSuffix("}") { finished.signal() } else { read() }
                }
            }
            connection.start(queue: queue)
            connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
            read()
            _ = finished.wait(timeout: .now() + 5)
            connection.cancel()
            return queue.sync { String(decoding: received, as: UTF8.self) }
        }

        let opened = post("/api/servers/open", """
            {"thread":"localhost:12","port":5173,"host":"evil.example","url":"http://evil.example:80/",
            "target":"http://169.254.169.254:80","scheme":"https+insecure","funnel":true}
            """)
        XCTAssertTrue(opened.hasPrefix("HTTP/1.1 200"), opened)
        XCTAssertTrue(opened.hasSuffix(#"{"port":5173,"url":"https:\/\/devmac.example.ts.net:5173\/"}"#), opened)
        XCTAssertEqual(serves(own: own), [["serve", "--bg", "--https=5173", "http://localhost:5173"]])
        XCTAssertFalse(tailscale.calls.contains { $0.contains { $0.contains("evil") || $0.contains("169.254") || $0.contains("funnel") } })

        // The link's own port is refused by the server and never reaches Tailscale.
        let before = tailscale.calls.count
        XCTAssertTrue(post("/api/servers/open", #"{"thread":"localhost:12","port":\#(own)}"#).hasPrefix("HTTP/1.1 403"))
        // A port that runs, but not for this thread.
        XCTAssertTrue(post("/api/servers/open", #"{"thread":"localhost:12","port":6006}"#).hasPrefix("HTTP/1.1 404"))
        XCTAssertEqual(tailscale.calls.count, before)

        XCTAssertTrue(post("/api/servers/close", #"{"port":5173}"#).hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=5173", "off"])
        XCTAssertEqual(link.mappings, [])
        link.shutdown()
    }
}
