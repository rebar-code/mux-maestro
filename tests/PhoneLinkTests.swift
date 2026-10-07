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

/// The ssh forwards, faked: what was launched, and which ports of this Mac
/// something listens on. A launched forward listens at once unless told not to.
private final class FakeForwards {
    final class Child: PhoneForward {
        private let lock = NSLock()
        private var running = true
        private var stopCount = 0
        let onExit: () -> Void
        var onStop: (() -> Void)?

        init(onExit: @escaping () -> Void) {
            self.onExit = onExit
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }
        var stops: Int {
            lock.lock()
            defer { lock.unlock() }
            return stopCount
        }

        func stop() {
            lock.lock()
            running = false
            stopCount += 1
            lock.unlock()
            onStop?()
        }

        /// The ssh ended by itself: the host went away.
        func die() {
            lock.lock()
            running = false
            lock.unlock()
            onStop?()
            onExit()
        }
    }

    private let lock = NSLock()
    private var argvs: [[String]] = []
    private var made: [Child] = []
    private var used: Set<Int> = []
    /// The launch gives no child at all.
    var refuses = false
    /// The child is gone as soon as it starts: the forward failed.
    var deadOnArrival = false
    /// The child runs and never listens.
    var silent = false
    /// Called at each launch, before the child exists.
    var onLaunch: (() -> Void)?

    var launched: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return argvs
    }
    var children: [Child] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    func listen(_ port: Int) {
        lock.lock()
        used.insert(port)
        lock.unlock()
    }

    private func free(_ port: Int) {
        lock.lock()
        used.remove(port)
        lock.unlock()
    }

    func inUse(_ port: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return used.contains(port)
    }

    func launch(_ argv: [String], onExit: @escaping () -> Void) -> PhoneForward? {
        onLaunch?()
        lock.lock()
        defer { lock.unlock() }
        argvs.append(argv)
        guard !refuses else { return nil }
        // "127.0.0.1:3000:localhost:3000"
        let spec = argv.firstIndex(of: "-L").map { argv[$0 + 1] } ?? ""
        let port = Int(spec.split(separator: ":").last ?? "") ?? 0
        let child = Child(onExit: onExit)
        made.append(child)
        if deadOnArrival {
            child.stop()
        } else if !silent {
            used.insert(port)
        }
        child.onStop = { [weak self] in self?.free(port) }
        return child
    }
}

/// The stored mappings (port and target), in memory.
private final class MemoryPorts: PhonePortStore {
    var stored: [Int: String] = [:]

    func load() -> [Int: String] { stored }
    func save(_ ports: [Int: String]) { stored = ports }
}

/// The stored digest, in memory.
private final class MemoryDigests: PhoneDigestStore {
    var digest: String?

    func load() -> String? { digest }
    func save(_ digest: String) { self.digest = digest }
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
    private var forwards: FakeForwards!
    private var ports: MemoryPorts!
    private var digests: MemoryDigests!
    /// The clock the link reads; a test moves it.
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var published: [[Int]] = []
    private var server: MobileServer!
    private var push: MobilePushCenter!
    private var states: [PhoneLink.State] = []
    private let lock = NSLock()

    override func setUp() {
        tailscale = FakeTailscale()
        forwards = FakeForwards()
        tokens = MemoryTokens()
        ports = MemoryPorts()
        digests = MemoryDigests()
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
            digests: digests,
            now: { [unowned self] in self.clock }, keychainNotice: 0.05,
            forward: { [unowned self] in self.forwards.launch($0, onExit: $1) },
            portInUse: { [unowned self] in self.forwards.inUse($0) }, forwardWait: 0.3,
            notify: { $0() })
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

    /// Bug: every `make install` left the phone off. The new build's start
    /// waited in the Keychain read for a dialog nobody was there to answer,
    /// though the switch was on. A start after the first reads no Keychain.
    func testAStartAfterANewBuildDoesNotWaitForTheKeychain() {
        tokens.token = "stored-token"
        let before = link()
        before.turnOn()
        settle(before)
        XCTAssertTrue(before.isOn)
        before.shutdown()
        XCTAssertEqual(digests.digest, MobileAPI.tokenDigest("stored-token"))

        // The new build: macOS asks for the token again, and nobody answers.
        let dialog = DispatchSemaphore(value: 0)
        tokens.dialog = dialog
        let published = tailscale.calls.filter { $0.contains("--bg") }.count
        let after = link()
        after.turnOn()
        settle(after)
        XCTAssertTrue(after.isOn, "\(after.state)")
        XCTAssertFalse(states.contains(.waitingForKeychain))
        XCTAssertEqual(tailscale.calls.filter { $0.contains("--bg") }.count, published + 1)
        // The paired phone's token is still the one the server takes.
        XCTAssertTrue(MobileAPI.sameToken("stored-token", digest: digests.digest))

        // The pairing link is the one thing that needs the token. Asking for
        // it waits for the dialog; the link stays on meanwhile.
        guard case .on(let url, let pairing) = after.state else { return XCTFail("\(after.state)") }
        XCTAssertEqual(pairing, "")
        after.loadPairing()
        usleep(100_000)
        XCTAssertEqual(after.state, .on(url: url, pairing: ""))
        dialog.signal()  // the user clicked Allow
        tokens.dialog = nil
        let deadline = Date().addingTimeInterval(5)
        while after.state == .on(url: url, pairing: ""), Date() < deadline { usleep(10_000) }
        XCTAssertEqual(after.state, .on(url: url, pairing: url + "#pair=stored-token"))
        after.shutdown()
    }

    func testThePairingLinkTakesTheKeychainTokenOverAStaleDigest() {
        tokens.token = "stored-token"
        digests.digest = MobileAPI.tokenDigest("another-token")
        let link = link()
        link.turnOn()
        settle(link)
        guard case .on(let url, _) = link.state else { return XCTFail("\(link.state)") }
        link.loadPairing()
        let deadline = Date().addingTimeInterval(5)
        while link.state == .on(url: url, pairing: ""), Date() < deadline { usleep(10_000) }
        XCTAssertEqual(link.state, .on(url: url, pairing: url + "#pair=stored-token"))
        XCTAssertEqual(digests.digest, MobileAPI.tokenDigest("stored-token"))
        link.shutdown()
    }

    func testAPairingLinkWithNoStoredTokenMakesANewOne() {
        digests.digest = MobileAPI.tokenDigest("lost-token")
        let link = link()
        link.turnOn()
        settle(link)
        guard case .on(let url, _) = link.state else { return XCTFail("\(link.state)") }
        link.loadPairing()
        let deadline = Date().addingTimeInterval(5)
        while link.state == .on(url: url, pairing: ""), Date() < deadline { usleep(10_000) }
        let fresh = tokens.token ?? ""
        XCTAssertEqual(fresh.count, 43)
        XCTAssertEqual(link.state, .on(url: url, pairing: url + "#pair=" + fresh))
        XCTAssertEqual(digests.digest, MobileAPI.tokenDigest(fresh))
        link.shutdown()
    }

    func testASecondStartBehindTheKeychainStillSaysWhatHoldsIt() {
        tokens.token = "stored-token"
        let dialog = DispatchSemaphore(value: 0)
        tokens.dialog = dialog
        let link = link()
        link.turnOn()
        let deadline = Date().addingTimeInterval(5)
        while link.state != .waitingForKeychain, Date() < deadline { usleep(10_000) }
        // `mux phone on` meanwhile: not "Starting…", which hid the reason.
        link.turnOn()
        XCTAssertEqual(link.state, .waitingForKeychain)
        dialog.signal()
        tokens.dialog = nil
        settle(link)
        XCTAssertTrue(link.isOn)
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

    // MARK: a port on another host

    private func openRemote(_ link: PhoneLink, _ port: Int, https: Bool = false) -> MobileServing.Opened {
        link.openMapping(port: port, https: https, thread: "devbox:12", label: "acme-app", host: "devbox")
    }

    private static func forwardArgv(_ port: Int) -> [String] {
        [
            "/usr/bin/ssh", "-N", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(port):localhost:\(port)", "devbox",
        ]
    }

    /// Wait for what the link does on its own queue after a child ended.
    private func eventually(
        _ what: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(5)
        while !what(), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(what(), file: file, line: line)
    }

    func testARemotePortIsForwardedByADedicatedSshAndOnlyThenPublished() throws {
        let (link, own) = try linkOn()
        var servedAtLaunch: [[String]]?
        forwards.onLaunch = { [unowned self] in servedAtLaunch = self.serves(own: own) }
        XCTAssertEqual(openRemote(link, 3000), .ok)
        // One ssh of its own: no control master, this Mac's loopback, the same port.
        XCTAssertEqual(forwards.launched, [Self.forwardArgv(3000)])
        XCTAssertFalse(forwards.launched[0].contains { $0.contains("ControlMaster=auto") || $0 == "-O" })
        // Nothing was published before the forward was started.
        XCTAssertEqual(servedAtLaunch, [])
        // The proxy goes to the address the forward binds, never to `localhost`.
        XCTAssertEqual(serves(own: own), [["serve", "--bg", "--https=3000", "http://127.0.0.1:3000"]])
        XCTAssertEqual(link.mappings.map(\.port), [3000])
        XCTAssertEqual(link.mappings.first?.host, "devbox")
        XCTAssertEqual(link.mappings.first?.thread, "devbox:12")
        XCTAssertEqual(ports.stored, [3000: "http://127.0.0.1:3000"])

        forwards.onLaunch = nil
        XCTAssertEqual(openRemote(link, 3443, https: true), .ok)
        XCTAssertEqual(forwards.launched.last, Self.forwardArgv(3443))
        XCTAssertEqual(
            serves(own: own).last, ["serve", "--bg", "--https=3443", "https+insecure://127.0.0.1:3443"])

        // A local port still starts no ssh.
        XCTAssertEqual(open(link, 5173), .ok)
        XCTAssertEqual(forwards.launched.count, 2)
        link.shutdown()
    }

    func testAPortThisMacAlreadyUsesIsTakenAndNothingStarts() throws {
        let (link, own) = try linkOn()
        forwards.listen(3000)
        XCTAssertEqual(openRemote(link, 3000), .taken)
        // No ssh, no serve, and no other port in its place.
        XCTAssertEqual(forwards.launched, [])
        XCTAssertEqual(serves(own: own), [])
        XCTAssertEqual(link.mappings, [])
        XCTAssertEqual(ports.stored, [:])
        link.shutdown()
    }

    func testTheSamePortAgainRenewsItAndAnotherHostsSamePortIsTaken() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(openRemote(link, 3000), .ok)
        clock.addTimeInterval(600)
        XCTAssertEqual(openRemote(link, 3000), .ok)
        XCTAssertEqual(forwards.launched.count, 1)
        XCTAssertEqual(serves(own: own).count, 1)
        XCTAssertEqual(link.mappings.first?.openedAt, clock)
        // The port is that forward's: not this Mac's own server, not another host's.
        XCTAssertEqual(open(link, 3000), .taken)
        XCTAssertEqual(
            link.openMapping(port: 3000, https: false, thread: "buildbox:3", label: "x", host: "buildbox"),
            .taken)
        XCTAssertEqual(forwards.launched.count, 1)
        XCTAssertEqual(forwards.children[0].stops, 0)
        XCTAssertEqual(link.mappings.first?.host, "devbox")
        // And a port this Mac published for itself is not a remote thread's.
        XCTAssertEqual(open(link, 5173), .ok)
        XCTAssertEqual(openRemote(link, 5173), .taken)
        XCTAssertEqual(forwards.launched.count, 1)
        link.shutdown()
    }

    func testClosingAMappingEndsItsForward() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(openRemote(link, 3000), .ok)
        XCTAssertEqual(openRemote(link, 3001), .ok)
        XCTAssertTrue(link.closeMapping(port: 3000))
        XCTAssertEqual(forwards.children.map(\.stops), [1, 0])
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=3000", "off"])
        XCTAssertEqual(link.mappings.map(\.port), [3001])
        // The port is free again, and a new tap starts a new ssh.
        XCTAssertEqual(openRemote(link, 3000), .ok)
        XCTAssertEqual(forwards.launched.count, 3)

        // Its server stopped, or nobody opened it for half an hour.
        link.sweepMappings(gone: [3001])
        eventually(link.mappings.map(\.port) == [3000])
        XCTAssertEqual(forwards.children.map(\.stops), [1, 1, 0])
        clock.addTimeInterval(MobileServing.idleSeconds)
        link.sweepMappings()
        eventually(link.mappings.isEmpty)
        XCTAssertEqual(forwards.children.map(\.stops), [1, 1, 1])
        XCTAssertFalse(forwards.children.contains(where: \.isRunning))
        link.shutdown()
    }

    func testTurningOffQuittingAndTheSwitchGoingOffEndEveryForward() throws {
        for how in ["off", "quit", "switch"] {
            forwards = FakeForwards()
            let (link, _) = try linkOn()
            XCTAssertEqual(openRemote(link, 3000), .ok, how)
            XCTAssertEqual(openRemote(link, 3001), .ok, how)
            XCTAssertEqual(open(link, 5173), .ok, how)
            switch how {
            case "off":
                link.turnOff()
                while link.state != .off { usleep(10_000) }
            case "quit":
                link.shutdown()
            default:
                link.closeAllMappings()
                eventually(link.mappings.isEmpty)
            }
            XCTAssertEqual(forwards.children.map(\.stops), [1, 1], how)
            XCTAssertFalse(forwards.children.contains(where: \.isRunning), how)
            XCTAssertEqual(link.mappings, [], how)
            XCTAssertEqual(ports.stored, [:], how)
            link.shutdown()
        }
    }

    func testAForwardThatEndsByItselfEndsItsMapping() throws {
        let (link, own) = try linkOn()
        XCTAssertEqual(openRemote(link, 3000), .ok)
        XCTAssertEqual(openRemote(link, 3001), .ok)
        // The host went away.
        forwards.children[0].die()
        eventually(link.mappings.map(\.port) == [3001])
        XCTAssertEqual(serves(own: own).last, ["serve", "--https=3000", "off"])
        XCTAssertEqual(ports.stored, [3001: "http://127.0.0.1:3001"])
        XCTAssertEqual(published.last, [3001])
        XCTAssertTrue(forwards.children[1].isRunning)
        // The exit of a forward that was replaced ends nothing of the new one.
        XCTAssertEqual(openRemote(link, 3000), .ok)
        forwards.children[0].onExit()
        link.sweepMappings()
        usleep(100_000)
        XCTAssertEqual(link.mappings.map(\.port), [3000, 3001])
        XCTAssertTrue(forwards.children[2].isRunning)
        link.shutdown()
    }

    func testAForwardThatDoesNotComeUpPublishesNothing() throws {
        let (link, own) = try linkOn()
        let failed = MobileServing.Opened.unavailable("ssh did not forward port 3000")
        // ssh ended at once: the host is away, or it refused the forward.
        forwards.deadOnArrival = true
        XCTAssertEqual(openRemote(link, 3000), failed)
        forwards.deadOnArrival = false
        // ssh runs and the port never listens.
        forwards.silent = true
        XCTAssertEqual(openRemote(link, 3000), failed)
        XCTAssertEqual(forwards.children.last?.stops, 1)
        forwards.silent = false
        // ssh could not be started at all.
        forwards.refuses = true
        XCTAssertEqual(openRemote(link, 3000), failed)
        forwards.refuses = false
        XCTAssertEqual(serves(own: own), [])
        XCTAssertEqual(link.mappings, [])
        XCTAssertEqual(ports.stored, [:])
        XCTAssertFalse(forwards.children.contains(where: \.isRunning))
        // And the next tap works.
        XCTAssertEqual(openRemote(link, 3000), .ok)
        link.shutdown()
    }

    func testAFailedServeEndsTheForwardAndTheLimitComesBeforeAnySsh() throws {
        let (link, _) = try linkOn()
        tailscale.serveFails = true
        XCTAssertEqual(openRemote(link, 3000), .unavailable("tailscale serve failed"))
        XCTAssertEqual(forwards.children.map(\.stops), [1])
        XCTAssertEqual(link.mappings, [])
        XCTAssertEqual(ports.stored, [:])
        tailscale.serveFails = false
        for port in 4000..<4005 { XCTAssertEqual(open(link, port), .ok) }
        XCTAssertEqual(openRemote(link, 3000), .limit)
        XCTAssertEqual(forwards.launched.count, 1)
        link.shutdown()
    }

    /// The whole path of one tap for a thread on another host: the host in the
    /// ssh command is the one Running names, and the port is one it lists.
    func testAnOpenRequestForARemoteThreadForwardsOnlyAPortRunningLists() throws {
        tailscale.live = true
        final class Box { var link: PhoneLink? }
        let box = Box()
        let running = RunningSet(
            known: true,
            resources: [RunningResource(
                kind: .server(port: 3000), host: "devbox", paneID: "%12",
                label: "acme-app", tooltip: "", url: nil, pid: 4242)],
            unknowns: [])
        server = MobileServer(
            staticRoot: nil,
            sources: MobileServer.Sources(
                screen: { _, _ in nil }, transcript: { _ in nil }, running: { _ in running }),
            serving: MobileServer.Serving(
                open: { port, https, thread, label, host in
                    box.link?.openMapping(port: port, https: https, thread: thread, label: label, host: host)
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
            let reply = LoopbackClient.exchange(
                port: own, send: Data(raw.utf8), label: "phone-link-tests"
            ) { String(decoding: $0, as: UTF8.self).hasSuffix("}") }
            return String(decoding: reply, as: UTF8.self)
        }

        // Not in Running for this thread: no ssh, no serve.
        for port in [3001, 5173, 22, own] {
            let refused = post(
                "/api/servers/open", #"{"thread":"localhost:12","port":\#(port),"host":"devbox"}"#)
            XCTAssertTrue(refused.hasPrefix("HTTP/1.1 40"), refused)
        }
        XCTAssertEqual(forwards.launched, [])
        XCTAssertEqual(serves(own: own), [])

        let opened = post("/api/servers/open", """
            {"thread":"localhost:12","port":3000,"host":"evil.example","bind":"0.0.0.0",
            "target":"169.254.169.254:80","alias":"-oProxyCommand=id"}
            """)
        XCTAssertTrue(opened.hasPrefix("HTTP/1.1 200"), opened)
        XCTAssertEqual(forwards.launched, [Self.forwardArgv(3000)])
        XCTAssertEqual(serves(own: own), [["serve", "--bg", "--https=3000", "http://127.0.0.1:3000"]])

        // The Mac's port is in use: the phone is told so.
        XCTAssertTrue(post("/api/servers/close", #"{"port":3000}"#).hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(forwards.children.map(\.stops), [1])
        forwards.listen(3000)
        let taken = post("/api/servers/open", #"{"thread":"localhost:12","port":3000}"#)
        XCTAssertTrue(taken.hasPrefix("HTTP/1.1 409"), taken)
        XCTAssertTrue(taken.hasSuffix(#"{"error":"taken"}"#), taken)
        XCTAssertEqual(forwards.launched.count, 1)
        link.shutdown()
    }

    // MARK: the real child and the real port check

    /// Whether `pid` still runs. A child that ended and was not collected yet
    /// keeps its number, and does not count.
    private func alive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    func testASupervisedChildEndsWhenItIsStoppedOrLetGo() throws {
        var child = try XCTUnwrap(SupervisedChild.launch(["/bin/sleep", "300"]) {})
        var pid = try XCTUnwrap(child.pid)
        XCTAssertTrue(child.isRunning)
        XCTAssertTrue(alive(pid))
        child.stop()
        XCTAssertFalse(child.isRunning)
        eventually(!alive(pid))

        // Let go without `stop()`: the same end.
        child = try XCTUnwrap(SupervisedChild.launch(["/bin/sleep", "300"]) {})
        pid = try XCTUnwrap(child.pid)
        XCTAssertTrue(alive(pid))
        child = try XCTUnwrap(SupervisedChild.launch(["/bin/sleep", "300"]) {})
        eventually(!alive(pid))
        child.stop()
    }

    func testASupervisedChildThatEndsByItselfSaysSoOnce() throws {
        let ended = expectation(description: "exit")
        let child = try XCTUnwrap(SupervisedChild.launch(["/bin/sh", "-c", "sleep 0.2"]) { ended.fulfill() })
        wait(for: [ended], timeout: 5)
        XCTAssertFalse(child.isRunning)
        XCTAssertNil(child.pid)
        child.stop()

        // One that is stopped does not also report an exit.
        let silent = expectation(description: "no exit")
        silent.isInverted = true
        let stopped = try XCTUnwrap(SupervisedChild.launch(["/bin/sleep", "300"]) { silent.fulfill() })
        stopped.stop()
        wait(for: [silent], timeout: 0.5)
        // A program that does not exist gives no running child.
        let missing = SupervisedChild.launch(["/nonexistent/ssh", "-N"]) {}
        eventually(missing?.isRunning != true)
    }

    func testAPortOfThisMacIsInUseOnlyWhileSomethingListensOnItsLoopback() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                Darwin.bind(fd, pointer, length) == 0 && listen(fd, 4) == 0
                    && getsockname(fd, pointer, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertTrue(LoopbackPort.inUse(port))
        close(fd)
        XCTAssertFalse(LoopbackPort.inUse(port))
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
                open: { port, https, thread, label, host in
                    box.link?.openMapping(port: port, https: https, thread: thread, label: label, host: host)
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
            let reply = LoopbackClient.exchange(
                port: own, send: Data(raw.utf8), label: "phone-link-tests"
            ) { String(decoding: $0, as: UTF8.self).hasSuffix("}") }
            return String(decoding: reply, as: UTF8.self)
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
    // MARK: mux phone

    func testAPhoneRequestIsTakenOnceAndAnOldOneIsDropped() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(PhoneRequest.parse("on 1700000000\n", now: now), true)
        XCTAssertEqual(PhoneRequest.parse("off 1699999990\n", now: now), false)
        // Made while the app was not running: not done at a later launch.
        XCTAssertNil(PhoneRequest.parse("on 1699999000\n", now: now))
        XCTAssertNil(PhoneRequest.parse("toggle 1700000000\n", now: now))
        XCTAssertNil(PhoneRequest.parse("on\n", now: now))
        XCTAssertNil(PhoneRequest.parse("", now: now))

        let file = try scratch().appendingPathComponent("phone-request")
        XCTAssertNil(PhoneRequest.take(at: file, now: now))
        try "on 1700000000\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PhoneRequest.take(at: file, now: now), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(PhoneRequest.take(at: file, now: now))
        // A stale file is removed too, so it is not read every second.
        try "on 1699999000\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(PhoneRequest.take(at: file, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMuxPhoneOnLeavesARequestTheAppTakes() throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("support dir/phone-request")
        let on = mux(["phone", "on", "--no-wait"], dir: dir, request: file)
        XCTAssertEqual(on.status, 0, on.err)
        XCTAssertEqual(PhoneRequest.take(at: file), true)
        XCTAssertEqual(mux(["phone", "off", "--no-wait"], dir: dir, request: file).status, 0)
        XCTAssertEqual(PhoneRequest.take(at: file), false)

        // No app takes it: the command says so and leaves nothing behind
        // for the next launch to act on.
        let nobody = mux(["phone", "on"], dir: dir, request: file, wait: 1)
        XCTAssertEqual(nobody.status, 2)
        XCTAssertTrue(nobody.err.contains("did not take the request"), nobody.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        XCTAssertEqual(mux(["phone", "sideways"], dir: dir, request: file).status, 2)
        XCTAssertEqual(mux(["phone", "on", "now"], dir: dir, request: file).status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMuxPhoneStatusReportsTheServerAndTheRoute() throws {
        let dir = try scratch()
        // Nothing listens and nothing is published.
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        let port = Int(try XCTUnwrap(listener.port).rawValue)
        defer { listener.cancel() }

        let down = mux(["phone", "status"], dir: dir, port: port + 1, serving: "{}")
        XCTAssertEqual(down.status, 1)
        XCTAssertEqual(down.out, """
            switch: off
            server: not listening on 127.0.0.1:\(port + 1)
            route: none for \(port + 1)

            """)

        // The server listens, but the route is another project's.
        let other = #"{"Web":{"devmac.example.ts.net:\#(port)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9"}}}}}"#
        let unrouted = mux(["phone", "status"], dir: dir, port: port, serving: other)
        XCTAssertEqual(unrouted.status, 1)
        XCTAssertTrue(unrouted.out.contains("server: listening on 127.0.0.1:\(port)\n"), unrouted.out)
        XCTAssertTrue(unrouted.out.contains("route: none for \(port)\n"), unrouted.out)

        let ours = #"{"Web":{"devmac.example.ts.net:\#(port)":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:\#(port)"}}}}}"#
        // The app's last word on the switch comes from the phone log.
        let logs = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try """
            {"t":"2026-01-02T03:04:05.000Z","sev":"info","kind":"mac","msg":"phone link: starting"}
            {"t":"2026-01-02T03:04:06.000Z","sev":"info","kind":"mac","msg":"phone link: on"}

            """.write(to: logs.appendingPathComponent("phone.jsonl"), atomically: true, encoding: .utf8)
        let up = mux(["phone", "status"], dir: dir, port: port, serving: ours)
        XCTAssertEqual(up.status, 0, up.out + up.err)
        XCTAssertEqual(up.out, """
            switch: off
            server: listening on 127.0.0.1:\(port)
            route: tailscale serve publishes \(port)
            link: on (2026-01-02T03:04:06.000Z)

            """)

        // Tailscale that cannot be asked is not "no route".
        let silent = mux(["phone", "status"], dir: dir, port: port, serving: nil)
        XCTAssertEqual(silent.status, 1)
        XCTAssertTrue(silent.out.contains("route: unknown, tailscale did not answer\n"), silent.out)
    }

    func testTheLinkStateIsWrittenForTheLogWithNoSecret() {
        XCTAssertEqual(PhoneLink.State.off.logText, "off")
        XCTAssertEqual(PhoneLink.State.waitingForKeychain.logText, "waiting for Keychain")
        XCTAssertEqual(
            PhoneLink.State.on(url: "https://devmac.example.ts.net:7433/", pairing: "x#pair=secret").logText,
            "on")
        XCTAssertEqual(PhoneLink.State.failed("Port 7433 is in use").logText, "failed: Port 7433 is in use")
        XCTAssertTrue(PhoneLink.State.failed("x").isFailure)
        XCTAssertFalse(PhoneLink.State.starting.isFailure)
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux-phone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Run the bundled `mux` with every outside piece replaced: a preference
    /// domain nothing writes, a fake `tailscale` that prints `serving` (or
    /// fails when it is nil), and paths under `dir`.
    private func mux(
        _ args: [String], dir: URL, request: URL? = nil, port: Int = 1, serving: String? = "{}",
        wait: Int? = nil
    ) -> (status: Int32, out: String, err: String) {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../app/MuxMaestro/Resources/manager/mux").standardizedFileURL.path
        let tailscale = dir.appendingPathComponent("tailscale")
        let body = serving.map { "#!/bin/sh\ncat <<'EOF'\n\($0)\nEOF\n" } ?? "#!/bin/sh\nexit 1\n"
        try? body.write(to: tailscale, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tailscale.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["MUX_PHONE_DOMAIN"] = "com.example.mux-phone-test-\(UUID().uuidString)"
        env["MUX_PHONE_PORT"] = String(port)
        env["MUX_TAILSCALE"] = tailscale.path
        env["MUX_PHONE_LOG_DIR"] = dir.appendingPathComponent("logs").path
        env["MUX_PHONE_REQUEST"] = (request ?? dir.appendingPathComponent("phone-request")).path
        env["MUX_MANAGER_DB"] = dir.appendingPathComponent("manager.db").path
        if let wait { env["MUX_PHONE_WAIT"] = String(wait) }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }
}
