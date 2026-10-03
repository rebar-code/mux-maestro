import XCTest

final class TailscaleStatusParsingTests: XCTestCase {

    /// Trimmed from real `tailscale status --json` on this Mac. Keeps the shapes
    /// that matter: `Self` and `Peer` carrying the same node fields, `DNSName`
    /// arriving WITH a trailing dot, and both address families in `TailscaleIPs`.
    private let realStatus = """
    {
      "Version": "1.102.3-t9329c3677-ga522f65e9",
      "BackendState": "Running",
      "TailscaleIPs": ["100.64.0.5", "fd7a:115c:a1e0::5"],
      "Self": {
        "ID": "ndgkWGtCVJ11CNTRL",
        "HostName": "My MacBook Pro",
        "DNSName": "my-mac.example.ts.net.",
        "TailscaleIPs": ["100.64.0.5", "fd7a:115c:a1e0::5"]
      },
      "MagicDNSSuffix": "example.ts.net",
      "CurrentTailnet": {
        "Name": "example.com",
        "MagicDNSSuffix": "example.ts.net",
        "MagicDNSEnabled": true
      },
      "Peer": {
        "nodekey:aaa": {
          "HostName": "devbox1",
          "DNSName": "devbox1.example.ts.net.",
          "TailscaleIPs": ["100.64.0.4", "fd7a:115c:a1e0::4"],
          "Online": true
        },
        "nodekey:bbb": {
          "HostName": "buildbox1",
          "DNSName": "buildbox1.example.ts.net.",
          "TailscaleIPs": ["100.64.0.6"],
          "Online": true
        }
      }
    }
    """

    func testReadsSelfAndEveryPeerWithTheTrailingDotStripped() {
        let status = HostAddress.parseTailscaleStatus(realStatus)
        XCTAssertEqual(status?.nodes.map(\.dnsName), [
            "my-mac.example.ts.net",
            "devbox1.example.ts.net",
            "buildbox1.example.ts.net",
        ])
        XCTAssertEqual(
            status?.nodes[1].ips, ["100.64.0.4", "fd7a:115c:a1e0::4"])
    }

    func testMagicDNSIsReadFromTheCurrentTailnet() {
        XCTAssertEqual(HostAddress.parseTailscaleStatus(realStatus)?.magicDNSEnabled, true)
        let off = realStatus.replacingOccurrences(
            of: "\"MagicDNSEnabled\": true", with: "\"MagicDNSEnabled\": false")
        XCTAssertEqual(HostAddress.parseTailscaleStatus(off)?.magicDNSEnabled, false)
    }

    /// No `CurrentTailnet` at all (an older daemon, a logged-out client) is not a
    /// parse failure — it just means MagicDNS cannot be assumed.
    func testMissingTailnetBlockIsMagicDNSOff() {
        let status = HostAddress.parseTailscaleStatus(
            "{\"Self\": {\"DNSName\": \"mac.example.ts.net.\"}}")
        XCTAssertEqual(status?.magicDNSEnabled, false)
        XCTAssertEqual(status?.nodes.map(\.dnsName), ["mac.example.ts.net"])
    }

    func testNodeWithoutADNSNameIsSkipped() {
        let status = HostAddress.parseTailscaleStatus(
            "{\"Self\": {\"HostName\": \"nameless\"}, \"Peer\": {\"k\": {\"DNSName\": \"\"}}}")
        XCTAssertEqual(status?.nodes, [])
    }

    /// Tailscale absent or wedged prints something that is not JSON.
    func testNonJSONIsNoStatusAtAll() {
        XCTAssertNil(HostAddress.parseTailscaleStatus(""))
        XCTAssertNil(HostAddress.parseTailscaleStatus("failed to connect to local tailscaled"))
    }

    func testShortNameIsTheLabelBeforeTheFirstDot() {
        XCTAssertEqual(
            TailnetNode(dnsName: "devbox1.example.ts.net", ips: []).shortName,
            "devbox1")
    }
}

final class SshHostnameParsingTests: XCTestCase {

    /// Verbatim shape of `ssh -G devbox` on this Mac, which prints the effective
    /// value first and then a long tail of defaults.
    func testTakesTheFirstHostnameLine() {
        let output = """
        user dev
        hostname 100.64.0.4
        port 22
        hostname ignored-second-value
        """
        XCTAssertEqual(HostAddress.sshHostname(output), "100.64.0.4")
    }

    func testNoHostnameLineIsNil() {
        XCTAssertNil(HostAddress.sshHostname("user dev\nport 22\n"))
        XCTAssertNil(HostAddress.sshHostname(""))
        XCTAssertNil(HostAddress.sshHostname("hostname \n"))
    }
}

final class BrowserHostDecisionTests: XCTestCase {

    private let tailnet = TailnetStatus(magicDNSEnabled: true, nodes: [
        TailnetNode(
            dnsName: "devbox1.example.ts.net",
            ips: ["100.64.0.4", "fd7a:115c:a1e0::4"]),
    ])

    private func host(_ hostname: String?, tailnet: TailnetStatus?, resolves: Bool = true) -> String {
        HostAddress.browserHost(
            alias: "devbox", sshHostname: hostname, tailnet: tailnet, resolves: { _ in resolves })
    }

    /// Step 1. ssh told us nothing, so we are no worse off than before.
    func testNoSshHostnameFallsBackToTheAlias() {
        XCTAssertEqual(host(nil, tailnet: tailnet), "devbox")
        XCTAssertEqual(host("", tailnet: tailnet), "devbox")
    }

    /// Step 2, the case this feature exists for: `ssh -G devbox` prints a tailnet
    /// IP, and the MagicDNS name for it is what a person wants in the URL bar.
    func testTailnetIPBecomesItsMagicDNSName() {
        XCTAssertEqual(host("100.64.0.4", tailnet: tailnet), "devbox1.example.ts.net")
    }

    func testTailnetNodeIsAlsoFoundByItsDNSNameOrShortName() {
        XCTAssertEqual(
            host("devbox1.example.ts.net", tailnet: tailnet),
            "devbox1.example.ts.net")
        XCTAssertEqual(host("devbox1", tailnet: tailnet), "devbox1.example.ts.net")
    }

    /// The MagicDNS name only goes to the browser once this Mac's resolver
    /// answers for it. When it does not, the tailnet IPv4 always works.
    func testUnresolvableMagicDNSNameFallsBackToTheTailnetIPv4() {
        XCTAssertEqual(host("100.64.0.4", tailnet: tailnet, resolves: false), "100.64.0.4")
    }

    /// MagicDNS off means the name in the status output resolves nowhere, so it
    /// is never offered — and `resolves` is not even consulted.
    func testMagicDNSOffUsesTheTailnetIPv4WithoutALookup() {
        var asked = false
        let off = TailnetStatus(magicDNSEnabled: false, nodes: tailnet.nodes)
        let address = HostAddress.browserHost(
            alias: "devbox", sshHostname: "100.64.0.4", tailnet: off,
            resolves: { _ in asked = true; return true })
        XCTAssertEqual(address, "100.64.0.4")
        XCTAssertFalse(asked)
    }

    /// An IPv6-only node still yields something openable, once bracketed.
    func testIPv6OnlyNodeYieldsItsIPv6() {
        let v6 = TailnetStatus(magicDNSEnabled: true, nodes: [
            TailnetNode(dnsName: "v6.example.ts.net", ips: ["fd7a:115c:a1e0::1"]),
        ])
        XCTAssertEqual(host("fd7a:115c:a1e0::1", tailnet: v6, resolves: false), "fd7a:115c:a1e0::1")
    }

    /// Step 3. A real DNS name already resolves here; the tailnet has no opinion.
    func testHostnameOutsideTheTailnetIsUsedVerbatim() {
        XCTAssertEqual(
            HostAddress.browserHost(
                alias: "nas", sshHostname: "nas.example.com", tailnet: tailnet, resolves: { _ in true }),
            "nas.example.com")
        XCTAssertEqual(
            HostAddress.browserHost(
                alias: "pi", sshHostname: "192.168.1.40", tailnet: nil, resolves: { _ in true }),
            "192.168.1.40")
    }

    /// No Tailscale on this Mac at all.
    func testNoTailnetIsTheSshHostname() {
        XCTAssertEqual(host("100.64.0.4", tailnet: nil), "100.64.0.4")
    }
}

final class URLHostBracketingTests: XCTestCase {

    func testIPv6LiteralIsBracketedSoTheURLParses() {
        XCTAssertEqual(HostAddress.urlHost("fd7a:115c:a1e0::1"), "[fd7a:115c:a1e0::1]")
        XCTAssertNotNil(URL(string: "http://\(HostAddress.urlHost("fd7a:115c:a1e0::1")):54321"))
        XCTAssertEqual(
            URL(string: "http://\(HostAddress.urlHost("fd7a:115c:a1e0::1")):54321")?.port, 54321)
    }

    func testAlreadyBracketedIsLeftAlone() {
        XCTAssertEqual(HostAddress.urlHost("[fd7a:115c:a1e0::1]"), "[fd7a:115c:a1e0::1]")
    }

    func testNamesAndIPv4AreUntouched() {
        XCTAssertEqual(HostAddress.urlHost("localhost"), "localhost")
        XCTAssertEqual(HostAddress.urlHost("100.64.0.4"), "100.64.0.4")
        XCTAssertEqual(
            HostAddress.urlHost("devbox1.example.ts.net"),
            "devbox1.example.ts.net")
    }
}

final class HostAddressResolveTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HostAddress.resetCacheForTesting()
    }

    override func tearDown() {
        HostAddress.resetCacheForTesting()
        super.tearDown()
    }

    func testLocalHostNeedsNoResolution() {
        var runs = 0
        let runner = CountingRunner(onRun: { _, _ in runs += 1; return nil })
        XCTAssertEqual(HostAddress.resolve(.local, runner: runner), "localhost")
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(HostAddress.cached(.local), "localhost")
    }

    /// One `ssh -G` per alias for the life of the process, the same discipline
    /// `SshIdentity` keeps — the rail sweeps every few seconds.
    func testAliasIsResolvedOnceAndThenCached() {
        var sshRuns = 0
        let runner = CountingRunner(onRun: { path, _ in
            if path.hasSuffix("ssh") { sshRuns += 1; return "hostname 192.168.1.40\n" }
            return nil
        })
        let host = Host(name: "pi", sshAlias: "pi")
        XCTAssertNil(HostAddress.cached(host))
        XCTAssertEqual(HostAddress.resolve(host, runner: runner), "192.168.1.40")
        XCTAssertEqual(HostAddress.resolve(host, runner: runner), "192.168.1.40")
        XCTAssertEqual(sshRuns, 1)
        XCTAssertEqual(HostAddress.cached(host), "192.168.1.40")
    }

    /// An alias ssh cannot resolve degrades to the alias, which is exactly what
    /// the rail built before this change — never a crash, never an empty URL.
    func testUnresolvableAliasDegradesToTheAlias() {
        let runner = CountingRunner(onRun: { _, _ in nil })
        XCTAssertEqual(
            HostAddress.resolve(Host(name: "gone", sshAlias: "gone"), runner: runner), "gone")
    }
}

/// A `CommandRunner` that answers from a closure and counts nothing else.
private struct CountingRunner: CommandRunner {
    let onRun: (String, [String]) -> String?

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? { onRun(path, args) }

    func runCapturing(_ path: String, _ args: [String]) -> (ok: Bool, text: String) {
        (onRun(path, args) != nil, onRun(path, args) ?? "")
    }
}
