import XCTest

// Running.swift is Foundation-only, so the whole core — the lsof parser, the
// pid→pane walk, the branch sanitizer, both join rules and the aggregation —
// compiles into this target and is asserted without a process, a socket or a
// view. TmuxService.swift comes along too, so the new argv is asserted against a
// fake runner the same way the Docker argv already is.

/// Records every command and replies from a scripted table — same shape as the
/// FakeRunner in TmuxServiceTests/GitDiffTests (each is file-private, so this
/// target keeps its own copy).
private final class FakeRunner: CommandRunner {
    private let lock = NSLock()
    private var _calls: [(path: String, args: [String], hadStdin: Bool)] = []
    var calls: [(path: String, args: [String], hadStdin: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var responses: [String: String?] = [:]
    var defaultResponse: String? = ""

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        _calls.append((path, args, stdin != nil))
        lock.unlock()
        let key = args.joined(separator: " ")
        if let scripted = responses[key] { return scripted }
        return defaultResponse
    }

    var argSequences: [[String]] { calls.map(\.args) }
}

final class RunningListenerTests: XCTestCase {

    // MARK: parseListeners — real `lsof -Fpn` output

    /// Verbatim from `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpn` on this Mac,
    /// trimmed to the interesting cases: a v4+v6 pair on ONE port (pid 675), the
    /// `f<fd>` lines macOS emits between `p` and `n` whether or not they were
    /// asked for, a bracketed IPv6 loopback, and a wildcard bind.
    private let realLsof = """
    p616
    f10
    n*:60740
    f11
    n*:60740
    p675
    f10
    n127.0.0.1:7000
    f11
    n[::1]:7000
    p33261
    f27
    n[::1]:5173
    p17383
    f24
    n127.0.0.1:5180
    """

    func testParsesPidAndPortCarryingThePidAcrossFDLines() {
        XCTAssertEqual(Running.parseListeners(realLsof), [
            ListeningPort(port: 5173, pid: 33261, loopbackOnly: true),
            ListeningPort(port: 5180, pid: 17383, loopbackOnly: true),
            ListeningPort(port: 7000, pid: 675, loopbackOnly: true),
            ListeningPort(port: 60740, pid: 616, loopbackOnly: false),
        ])
    }

    /// IPv4 and IPv6 on the same port are one listener, not two — the same
    /// dedupe `Docker.parsePorts` applies to the published-port column.
    func testIPv4AndIPv6PairOnOnePortCollapsesToOne() {
        let both = "p675\nf10\nn127.0.0.1:7000\nf11\nn[::1]:7000\n"
        XCTAssertEqual(
            Running.parseListeners(both),
            [ListeningPort(port: 7000, pid: 675, loopbackOnly: true)])
    }

    /// The merge is by `(port, pid)` and ANDs the scopes, so a port that is
    /// loopback on one family and wildcard on the other is ONE row — and a
    /// reachable one, because the wildcard bind is the truth about the port.
    func testLoopbackAndWildcardOnOnePortIsOneReachableListener() {
        let mixed = "p675\nf10\nn127.0.0.1:7000\nf11\nn[::]:7000\n"
        XCTAssertEqual(
            Running.parseListeners(mixed),
            [ListeningPort(port: 7000, pid: 675, loopbackOnly: false)])
    }

    /// Two processes on one port stay two rows: the scope merge is per pid, not
    /// per port.
    func testTwoPidsOnOnePortKeepTheirOwnScopes() {
        let two = "p1\nn127.0.0.1:3000\np2\nn*:3000\n"
        XCTAssertEqual(Running.parseListeners(two), [
            ListeningPort(port: 3000, pid: 1, loopbackOnly: true),
            ListeningPort(port: 3000, pid: 2, loopbackOnly: false),
        ])
    }

    /// A listener bound to one LAN interface isn't reachable as localhost and
    /// isn't this work's dev server.
    func testNonLoopbackBindIsDropped() {
        let lan = "p900\nn192.168.1.5:8080\np901\nn[fe80::1]:8080\n"
        XCTAssertEqual(Running.parseListeners(lan), [])
    }

    func testWildcardAndAllZeroBindsAreKept() {
        XCTAssertEqual(Running.parseListeners("p1\nn*:3000\np2\nn0.0.0.0:3001\np3\nn[::]:3002\n"), [
            ListeningPort(port: 3000, pid: 1),
            ListeningPort(port: 3001, pid: 2),
            ListeningPort(port: 3002, pid: 3),
        ])
    }

    /// Malformed lines are skipped rather than guessed at, and never take the
    /// rest of the scan down with them.
    func testMalformedLinesAreSkipped() {
        let junk = """
        garbage without a field letter
        nnot-an-address
        p
        pnotanumber
        n127.0.0.1:notaport
        n127.0.0.1
        p42
        n127.0.0.1:5173
        """
        XCTAssertEqual(
            Running.parseListeners(junk),
            [ListeningPort(port: 5173, pid: 42, loopbackOnly: true)])
    }

    /// An `n` line before any `p` line has no pid to belong to.
    func testAddressBeforeAnyPidIsDropped() {
        XCTAssertEqual(Running.parseListeners("n127.0.0.1:5173\n"), [])
    }

    func testEmptyOutputIsNoListeners() {
        XCTAssertEqual(Running.parseListeners(""), [])
    }

    func testLsofArgvSkipsDNSAndServiceNameLookups() {
        XCTAssertEqual(Running.lsofArgv(), ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
    }
}

final class RunningPortAttributionTests: XCTestCase {

    /// pane %12's shell is pid 100; the server is three levels below it
    /// (`zsh 100 → pnpm 200 → node 300`), which is the normal shape.
    func testWalksAThreeDeepChainToThePane() {
        let ports = Running.portsByPane(
            listeners: [ListeningPort(port: 5173, pid: 300)],
            panePidToId: [100: "%12"],
            ppids: [300: 200, 200: 100, 100: 1])
        XCTAssertEqual(ports, ["%12": [ListeningPort(port: 5173, pid: 300)]])
    }

    /// Chrome, Raycast, ollama: the listener is real, it just belongs to the
    /// machine rather than to any pane. Dropped, never rendered.
    func testPidThatReachesNoPaneIsDropped() {
        let ports = Running.portsByPane(
            listeners: [ListeningPort(port: 9222, pid: 800)],
            panePidToId: [100: "%12"],
            ppids: [800: 1])
        XCTAssertEqual(ports, [:])
    }

    /// A ppid cycle must terminate. Without the `seen` set this spins forever on
    /// a background queue — the same guard `TmuxModel.paneCodexIds` carries.
    func testPpidCycleTerminates() {
        let ports = Running.portsByPane(
            listeners: [ListeningPort(port: 5173, pid: 10)],
            panePidToId: [999: "%1"],
            ppids: [10: 11, 11: 12, 12: 10])
        XCTAssertEqual(ports, [:])
    }

    func testSeveralPortsOnOnePaneAreSortedAndDeduped() {
        let ports = Running.portsByPane(
            listeners: [
                ListeningPort(port: 5180, pid: 300),
                ListeningPort(port: 5173, pid: 301),
                ListeningPort(port: 5173, pid: 300),
            ],
            panePidToId: [100: "%12"],
            ppids: [300: 100, 301: 100, 100: 1])
        // 5173 is held by two pids in the same pane (a forked worker); the
        // parent that owns the socket wins, and it stays one row.
        XCTAssertEqual(ports, ["%12": [
            ListeningPort(port: 5173, pid: 300), ListeningPort(port: 5180, pid: 300),
        ]])
    }

    /// The pane's own shell holding the port (a `python -m http.server` run in
    /// the foreground) resolves without any walk at all.
    func testPanePidItselfCounts() {
        let ports = Running.portsByPane(
            listeners: [ListeningPort(port: 8000, pid: 100)],
            panePidToId: [100: "%7"], ppids: [:])
        XCTAssertEqual(ports, ["%7": [ListeningPort(port: 8000, pid: 100)]])
    }
}

final class RunningStackIDTests: XCTestCase {

    /// The sanitizer the remote-stack script applies before writing project_id.
    func testSlashesBecomeDashes() {
        XCTAssertEqual(Running.stackID(branch: "db/feat/access-model"), "db-feat-access-model")
    }

    func testUnderscoresAndDigitsSurvive() {
        XCTAssertEqual(Running.stackID(branch: "fix_123-abc"), "fix_123-abc")
    }

    func testEveryOtherCharacterBecomesADash() {
        XCTAssertEqual(Running.stackID(branch: "feat/a b.c@d"), "feat-a-b-c-d")
    }

    func testCappedAtSixtyLikeTheScript() {
        let branch = String(repeating: "a", count: 80)
        XCTAssertEqual(Running.stackID(branch: branch).count, 60)
    }

    /// The reason this join is worth having: a long branch's stack id is written
    /// to the container label TRUNCATED AT 40, so plain equality misses it and
    /// `Docker.supabaseStackMatches` is what closes the gap.
    func testLongBranchJoinsThroughTheTruncatedLabel() {
        let id = Running.stackID(branch: "admin/fix/people-edits-profiles-join-and-more")
        XCTAssertEqual(id, "admin-fix-people-edits-profiles-join-and-more")
        XCTAssertGreaterThan(id.count, Docker.supabaseLabelLimit)
        let label = String(id.prefix(Docker.supabaseLabelLimit))
        XCTAssertTrue(Docker.supabaseStackMatches(label: label, projectID: id))
    }

    /// The other half of that rule, which this join inherits: a SHORT label that
    /// merely prefixes the id is a different stack, not a truncation.
    func testShortPrefixIsNotAMatch() {
        XCTAssertFalse(Docker.supabaseStackMatches(
            label: "acme-app-portal", projectID: "acme-app-portal-spin-feat-x"))
    }
}

final class RunningSchemeTests: XCTestCase {

    private let scrollback = [
        "  VITE v5.4.2  ready in 412 ms",
        "  ➜  Local:   https://localhost:5173/",
        "  ➜  Network: use --host to expose",
        "  Studio: http://127.0.0.1:54723",
    ]

    func testFindsTheHttpsURLThePaneActuallyPrinted() {
        XCTAssertEqual(
            Running.urlFromScrollback(scrollback, port: 5173, host: "localhost"),
            "https://localhost:5173")
    }

    func testFindsAPlainHTTPURLOnAnotherPort() {
        XCTAssertEqual(
            Running.urlFromScrollback(scrollback, port: 54723, host: "localhost"),
            "http://127.0.0.1:54723")
    }

    /// `:5173` must not match a line advertising `:51730`.
    func testDoesNotMatchALongerPortWithTheSamePrefix() {
        XCTAssertNil(Running.urlFromScrollback(
            ["ready on http://localhost:51730"], port: 5173, host: "localhost"))
    }

    /// A remote pane prints its own hostname, not localhost.
    func testMatchesTheRemoteHostsOwnName() {
        XCTAssertEqual(
            Running.urlFromScrollback(["listening on http://devbox:54713"], port: 54713, host: "devbox"),
            "http://devbox:54713")
    }

    func testMissingURLIsNil() {
        XCTAssertNil(Running.urlFromScrollback(scrollback, port: 9999, host: "localhost"))
    }

    // MARK: the three-step rule

    func testScrollbackWins_HTTPS() {
        XCTAssertEqual(
            Running.scheme(scrollbackURL: "https://localhost:5173", probe: { false }), "https")
    }

    /// Supabase Studio is plain HTTP — the printed URL beats the probe, which is
    /// the whole point of asking the scrollback first.
    func testScrollbackWins_HTTP() {
        XCTAssertEqual(
            Running.scheme(scrollbackURL: "http://127.0.0.1:54723", probe: { true }), "http")
    }

    func testProbeDecidesOnAScrollbackMiss() {
        XCTAssertEqual(Running.scheme(scrollbackURL: nil, probe: { true }), "https")
        XCTAssertEqual(Running.scheme(scrollbackURL: nil, probe: { false }), "http")
    }

    func testProbeIsNotCalledWhenTheScrollbackAnswered() {
        var probed = false
        _ = Running.scheme(scrollbackURL: "https://localhost:5173", probe: { probed = true; return true })
        XCTAssertFalse(probed)
    }

    /// The bug this part fixes: `devbox` is an ssh alias, and `ping devbox` says
    /// "Unknown host". The URL must carry the address `HostAddress` resolved.
    func testRemotePortIsAddressedByTheResolvedAddressNotTheAlias() {
        XCTAssertEqual(
            Running.serverURL(
                port: 54713, host: "devbox", address: "devbox1.example.ts.net",
                scrollbackURL: nil, probe: { false }),
            "http://devbox1.example.ts.net:54713")
    }

    /// A remote pane prints its own hostname, which means nothing here — so the
    /// printed URL is read for its scheme and the address supplies the name.
    func testRemoteScrollbackURLContributesOnlyItsScheme() {
        XCTAssertEqual(
            Running.serverURL(
                port: 54713, host: "devbox", address: "100.64.0.4",
                scrollbackURL: "https://devbox1:54713/", probe: { false }),
            "https://100.64.0.4:54713")
    }

    func testLocalURLKeepsWhateverThePanePrinted() {
        XCTAssertEqual(
            Running.serverURL(
                port: 5173, host: "localhost", address: "localhost",
                scrollbackURL: "https://localhost:5173/", probe: { false }),
            "https://localhost:5173/")
    }

    /// An address that resolved to a tailnet IPv6 literal still has to parse as
    /// a URL, which means brackets.
    func testIPv6AddressIsBracketedInTheURL() {
        XCTAssertEqual(
            Running.serverURL(
                port: 54713, host: "devbox", address: "fd7a:115c:a1e0::4",
                scrollbackURL: nil, probe: { false }),
            "http://[fd7a:115c:a1e0::4]:54713")
    }

    // MARK: reachable — a remote loopback bind has nothing to open

    func testLoopbackOnlyIsReachableOnThisMacAndNowhereElse() {
        XCTAssertTrue(Running.reachable(host: "localhost", loopbackOnly: true))
        XCTAssertFalse(Running.reachable(host: "devbox", loopbackOnly: true))
        XCTAssertTrue(Running.reachable(host: "devbox", loopbackOnly: false))
    }
}

final class RunningAggregationTests: XCTestCase {

    private func supabase(_ project: String, _ ports: [Int] = []) -> DockerContainer {
        DockerContainer(
            name: "supabase_db_\(project)", supabaseProject: project,
            composeWorkingDir: "", ports: ports)
    }

    private func compose(_ name: String, dir: String, ports: [Int] = []) -> DockerContainer {
        DockerContainer(
            name: name, supabaseProject: "", composeWorkingDir: dir, ports: ports)
    }

    private let pane = RunningPane(
        paneID: "%12", host: "localhost", cwd: "/Users/me/code/acme-app",
        supabaseProjectID: "acme-app", stackID: "feat-rates", urls: [:])

    func testPaneOwnsItsPortsAndItsContainers() {
        let scan = RunningHostScan(
            host: "localhost",
            docker: .containers([supabase("acme-app", [54321]), supabase("other")]),
            listeners: [],
            portsByPane: ["%12": [ListeningPort(port: 5173, pid: 300)]])
        let set = Running.resources(pane: pane, scans: [scan])

        XCTAssertTrue(set.known)
        XCTAssertEqual(set.resources.count, 2)
        XCTAssertEqual(set.resources[0].kind, .server(port: 5173))
        XCTAssertEqual(set.resources[0].url, "http://localhost:5173")
        XCTAssertEqual(set.resources[1].kind, .container(name: "acme-app", ports: [54321], count: 1))
        XCTAssertEqual(set.resources.map(\.paneID), ["%12", "%12"])
    }

    /// A remote row's ↗ is built from the scan's resolved address, not from the
    /// ssh alias — `http://devbox:5173` resolves nowhere on this Mac.
    func testRemoteServerRowOpensTheResolvedAddress() {
        let remotePane = RunningPane(paneID: "%20", host: "devbox", cwd: "/home/dev/acme-app")
        let scan = RunningHostScan(
            host: "devbox", docker: .containers([]), listeners: [],
            portsByPane: ["%20": [ListeningPort(port: 5173, pid: 300, loopbackOnly: false)]],
            address: "devbox1.example.ts.net")
        let set = Running.resources(pane: remotePane, scans: [scan])
        XCTAssertEqual(set.resources.count, 1)
        XCTAssertEqual(set.resources[0].url, "http://devbox1.example.ts.net:5173")
    }

    /// A port bound to 127.0.0.1 on another box answers that box's browser and
    /// nothing else. The row stays — the server IS running — but it offers no
    /// link, and the chip says why.
    func testRemoteLoopbackOnlyPortHasNoURLAndSaysSo() {
        let remotePane = RunningPane(paneID: "%20", host: "devbox", cwd: "/home/dev/acme-app")
        let scan = RunningHostScan(
            host: "devbox", docker: .containers([]), listeners: [],
            portsByPane: ["%20": [ListeningPort(port: 5173, pid: 300, loopbackOnly: true)]],
            address: "devbox1.example.ts.net")
        let set = Running.resources(pane: remotePane, scans: [scan])
        XCTAssertEqual(set.resources.count, 1)
        XCTAssertNil(set.resources[0].url)
        XCTAssertEqual(Running.chips(for: set.resources[0]).map(\.text), ["devbox", "loopback"])
    }

    /// The same bind on THIS Mac is perfectly openable.
    func testLocalLoopbackOnlyPortStillOpens() {
        let scan = RunningHostScan(
            host: "localhost", docker: .containers([]), listeners: [],
            portsByPane: ["%12": [ListeningPort(port: 5173, pid: 300, loopbackOnly: true)]])
        let set = Running.resources(pane: pane, scans: [scan])
        XCTAssertEqual(set.resources[0].url, "http://localhost:5173")
    }

    /// A plain container gets one link per published port, built from the same
    /// address the server rows use; the row's own URL is the lowest.
    func testRemotePlainContainerLinksEveryPublishedPort() {
        let scan = RunningHostScan(
            host: "devbox",
            docker: .containers([compose("redis", dir: "/srv/x", ports: [6380, 6379])]),
            listeners: nil, address: "devbox1.example.ts.net")
        let row = Running.unclaimed(scans: [scan], panes: []).resources[0]
        XCTAssertEqual(row.links.map(\.url), [
            "http://devbox1.example.ts.net:6379",
            "http://devbox1.example.ts.net:6380",
        ])
        XCTAssertEqual(row.url, "http://devbox1.example.ts.net:6379")
        XCTAssertFalse(row.isSupabaseStack)
    }

    /// Nothing published, nothing to open.
    func testContainerWithNoPublishedPortHasNoURL() {
        let scan = RunningHostScan(
            host: "devbox", docker: .containers([supabase("feat-rates")]), listeners: nil,
            address: "devbox1.example.ts.net")
        XCTAssertNil(Running.resources(pane: pane, scans: [scan]).resources[0].url)
    }

    /// Decision 5: a local pane claims the stack the remote-stack script built for
    /// its branch on another machine, joined by the sanitized branch alone.
    func testLocalPaneClaimsARemoteStackByBranch() {
        let remote = RunningHostScan(
            host: "devbox", docker: .containers([supabase("feat-rates", [54720])]), listeners: nil)
        let set = Running.resources(pane: pane, scans: [remote])
        XCTAssertEqual(set.resources.count, 1)
        XCTAssertEqual(set.resources[0].host, "devbox")
        XCTAssertEqual(set.resources[0].paneID, "%12")
    }

    /// A compose working dir is a path, and a path only means something on the
    /// machine it came from.
    func testComposeDirJoinsOnlyOnThePanesOwnHost() {
        let sameDir = compose("web", dir: "/Users/me/code/acme-app/apps/web")
        let local = RunningHostScan(
            host: "localhost", docker: .containers([sameDir]), listeners: [])
        let remote = RunningHostScan(
            host: "devbox", docker: .containers([sameDir]), listeners: nil)

        XCTAssertEqual(Running.resources(pane: pane, scans: [local]).resources.count, 1)
        XCTAssertEqual(Running.resources(pane: pane, scans: [remote]).resources.count, 0)
    }

    /// The gate on auto-open, and the row that must never read as zero.
    func testUnavailableDockerIsUnknownNotEmpty() {
        let scan = RunningHostScan(host: "localhost", docker: .unavailable, listeners: [])
        let set = Running.resources(pane: pane, scans: [scan])
        XCTAssertFalse(set.known)
        XCTAssertEqual(set.unknowns, ["Docker unavailable on localhost"])
        XCTAssertTrue(set.resources.isEmpty)
    }

    func testNilListenersIsUnknownNotEmpty() {
        let scan = RunningHostScan(
            host: "localhost", docker: .containers([]), listeners: nil)
        let set = Running.resources(pane: pane, scans: [scan])
        XCTAssertFalse(set.known)
        XCTAssertEqual(set.unknowns, ["ports not checked yet on localhost"])
    }

    /// A known, genuinely empty set is a good state, and a different one from
    /// unknown.
    func testNothingRunningIsKnownAndEmpty() {
        let scan = RunningHostScan(
            host: "localhost", docker: .containers([]), listeners: [], portsByPane: [:])
        let set = Running.resources(pane: pane, scans: [scan])
        XCTAssertTrue(set.known)
        XCTAssertTrue(set.isEmpty)
    }

    /// One stack shared by two panes of the same checkout is one row, attributed
    /// to the first pane, and the ports stay sorted ahead of the containers.
    func testWindowUnionDedupesAndSorts() {
        let other = RunningPane(
            paneID: "%13", host: "localhost", cwd: "/Users/me/code/acme-app",
            supabaseProjectID: "acme-app")
        let scan = RunningHostScan(
            host: "localhost",
            docker: .containers([supabase("acme-app", [54321])]),
            listeners: [],
            portsByPane: [
                "%12": [ListeningPort(port: 5180, pid: 300)],
                "%13": [ListeningPort(port: 5173, pid: 301)],
            ])

        let set = Running.resources(panes: [pane, other], scans: [scan])
        XCTAssertEqual(set.resources.map(\.key), [
            "localhost|server|5173", "localhost|server|5180", "localhost|container|acme-app",
        ])
        XCTAssertEqual(set.resources.last?.paneID, "%12")
    }

    /// A Supabase stack is eight containers that share a port block and only work
    /// together. Eight rows of `supabase_<service>_<stack>` is the same fact
    /// written eight times — one row, named for the stack.
    func testSupabaseStackCollapsesToOneRow() {
        let stack = (1...8).map { i in
            DockerContainer(name: "supabase_svc\(i)_feat-rates", supabaseProject: "feat-rates",
                            composeWorkingDir: "", ports: [54720 + i])
        }
        let scan = RunningHostScan(host: "devbox", docker: .containers(stack), listeners: nil)
        let set = Running.resources(pane: pane, scans: [scan])

        XCTAssertEqual(set.resources.count, 1)
        XCTAssertEqual(set.resources[0].label, "feat-rates")
        XCTAssertEqual(
            set.resources[0].kind,
            .container(name: "feat-rates", ports: Array(54721...54728), count: 8))
    }

    /// A container with no stack label is its own row, under its own name.
    func testPlainContainerKeepsItsName() {
        let scan = RunningHostScan(
            host: "localhost",
            docker: .containers([compose("redis", dir: "/Users/me/code/acme-app", ports: [6379])]),
            listeners: [])
        let set = Running.resources(pane: pane, scans: [scan])
        XCTAssertEqual(set.resources.map(\.label), ["redis"])
        XCTAssertEqual(set.resources[0].kind, .container(name: "redis", ports: [6379], count: 1))
    }

    /// The sweep and the session tree move independently, so a scan is attributed
    /// when it is rendered, against the tree as it is then. Binding the two at
    /// scan time left every port unclaimed on the first sweep after launch, before
    /// the tree had loaded.
    func testAttributedJoinsAgainstTheTreeItIsGiven() {
        let scan = RunningHostScan(
            host: "localhost", docker: .containers([]),
            listeners: [ListeningPort(port: 5173, pid: 300)],
            ppids: [300: 200, 200: 100, 100: 1])
        XCTAssertTrue(scan.portsByPane.isEmpty)

        let joined = scan.attributed(panePidToId: [100: "%12"])
        XCTAssertEqual(joined.portsByPane, ["%12": [ListeningPort(port: 5173, pid: 300)]])
        // …and an empty tree attributes nothing, rather than crashing or guessing.
        XCTAssertTrue(scan.attributed(panePidToId: [:]).portsByPane.isEmpty)
    }

    // MARK: unclaimed

    func testUnclaimedListsWhatNoPaneOwns() {
        let scan = RunningHostScan(
            host: "devbox",
            docker: .containers([supabase("acme-app"), supabase("long-dead-branch", [54990])]),
            listeners: nil)
        let set = Running.unclaimed(scans: [scan], panes: [pane])
        XCTAssertEqual(set.resources.map(\.label), ["long-dead-branch"])
        XCTAssertNil(set.resources[0].paneID)
        XCTAssertEqual(set.resources[0].host, "devbox")
    }

    /// The fixture decision 5 exists for: the container runs on `devbox`, the pane
    /// that owns it is on this Mac, and it must NOT be called a leak.
    func testContainerClaimedByAPaneOnAnotherHostIsNotUnclaimed() {
        let scan = RunningHostScan(
            host: "devbox", docker: .containers([supabase("feat-rates", [54720])]), listeners: nil)
        XCTAssertTrue(Running.unclaimed(scans: [scan], panes: [pane]).resources.isEmpty)
    }

    /// The decision-4 amendment: a listening port never reaches unclaimed on its
    /// own, so Chrome, ollama and a Homebrew daemon can't appear there.
    func testUnclaimedNeverListsABarePort() {
        let scan = RunningHostScan(
            host: "localhost",
            docker: .containers([]),
            listeners: [ListeningPort(port: 9222, pid: 800), ListeningPort(port: 11434, pid: 5848)],
            portsByPane: [:])
        let set = Running.unclaimed(scans: [scan], panes: [])
        XCTAssertTrue(set.resources.isEmpty)
        XCTAssertTrue(set.known)
    }

    func testUnclaimedReportsAnUnavailableHostRatherThanCallingItEmpty() {
        let set = Running.unclaimed(
            scans: [RunningHostScan(host: "localhost", docker: .unavailable, listeners: nil)],
            panes: [])
        XCTAssertFalse(set.known)
        XCTAssertEqual(set.unknowns, ["Docker unavailable on localhost"])
    }

    // MARK: chips + labels

    /// The host, and no port range: the links under the name list every port.
    func testChipsCarryTheRemoteHostOnly() {
        let remote = RunningResource(
            kind: .container(name: "x", ports: [54720, 54721, 54729], count: 8),
            host: "devbox", paneID: "%1", label: "x", tooltip: "")
        XCTAssertEqual(Running.chips(for: remote).map(\.text), ["devbox"])
    }

    /// No host chip for this Mac — every row would carry it, which is noise on
    /// every row for ever.
    func testLocalServerRowHasNoChips() {
        let local = RunningResource(
            kind: .server(port: 5173), host: "localhost", paneID: "%1", label: "acme-app",
            tooltip: "", url: "http://localhost:5173")
        XCTAssertTrue(Running.chips(for: local).isEmpty)
    }

    func testPortsLabelCollapsesABlockToARange() {
        XCTAssertEqual(Running.portsLabel([54321]), ":54321")
        XCTAssertEqual(Running.portsLabel([54329, 54321, 54325]), ":54321–54329")
        XCTAssertEqual(Running.portsLabel([]), "")
    }

    func testServerRowIsNamedForTheProjectNotThePath() {
        XCTAssertEqual(Running.projectName(cwd: "/Users/me/code/acme-app/"), "acme-app")
        XCTAssertEqual(Running.projectName(cwd: ""), "")
    }
}

final class RunningServiceArgvTests: XCTestCase {
    private func localService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(
            host: .local, transport: LocalTmuxTransport(tmuxPath: "/opt/homebrew/bin/tmux"),
            runner: runner, statusProvider: nil)
    }

    private func remoteService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(
            host: Host(name: "devbox", sshAlias: "devbox"),
            transport: SshTmuxTransport(host: "devbox"),
            runner: runner, statusProvider: nil)
    }

    func testListeningPortsArgv() {
        let runner = FakeRunner()
        runner.defaultResponse = "p42\nf3\nn127.0.0.1:5173\n"
        let ports = localService(runner).listeningPorts()
        XCTAssertEqual(runner.argSequences, [["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]])
        XCTAssertEqual(runner.calls.first?.path, "/usr/sbin/lsof")
        XCTAssertEqual(ports, [ListeningPort(port: 5173, pid: 42, loopbackOnly: true)])
    }

    /// nil is "unknown", never an empty list — lsof also exits non-zero when it
    /// matches nothing, and rendering that as "no servers" is the reading that
    /// makes a live dev server look stopped.
    func testListeningPortsFailureIsNilNotEmpty() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertNil(localService(runner).listeningPorts())
    }

    /// Decision 5: the remote path is no longer gated off. Every token is
    /// single-quoted for the remote login shell, like the tmux transport.
    func testRemoteDockerSnapshotGoesOverSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = "supabase_db_x\tx\t\t0.0.0.0:54321->5432/tcp"
        let snapshot = remoteService(runner).dockerSnapshot()

        XCTAssertEqual(runner.calls.first?.path, "/usr/bin/ssh")
        let argv = runner.argSequences.first ?? []
        XCTAssertEqual(argv.last(where: { $0 == "'ps'" }), "'ps'")
        XCTAssertTrue(argv.contains("'docker'"))
        XCTAssertTrue(argv.contains("devbox"))
        XCTAssertEqual(snapshot, .containers([
            DockerContainer(name: "supabase_db_x", supabaseProject: "x",
                            composeWorkingDir: "", ports: [54321]),
        ]))
    }

    func testRemoteListeningPortsGoOverSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = "p42\nn127.0.0.1:54713\n"
        XCTAssertEqual(
            remoteService(runner).listeningPorts(),
            [ListeningPort(port: 54713, pid: 42, loopbackOnly: true)])
        let argv = runner.argSequences.first ?? []
        XCTAssertTrue(argv.contains("'lsof'"))
        XCTAssertTrue(argv.contains("'-sTCP:LISTEN'"))
    }

    /// Two callers want this now (the worktree sweep and the rail). The second
    /// one inside the TTL must NOT start a second `docker ps`.
    func testDockerSnapshotIsSharedWithinItsTTL() {
        let runner = FakeRunner()
        runner.defaultResponse = "supabase_db_x\tx\t\t"
        let service = localService(runner)
        let start = Date()

        _ = service.dockerSnapshot(now: start)
        _ = service.dockerSnapshot(now: start.addingTimeInterval(5))
        XCTAssertEqual(runner.calls.count, 1)

        _ = service.dockerSnapshot(now: start.addingTimeInterval(TmuxService.dockerSnapshotTTL + 1))
        XCTAssertEqual(runner.calls.count, 2)
    }

    /// A wedged daemon is cached too, or every caller pays the full 30s timeout
    /// again and one stall becomes a permanent one.
    func testUnavailableIsCachedToo() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        let service = localService(runner)
        let start = Date()

        XCTAssertEqual(service.dockerSnapshot(now: start), .unavailable)
        XCTAssertEqual(service.dockerSnapshot(now: start.addingTimeInterval(1)), .unavailable)
        XCTAssertEqual(runner.calls.count, 1)
    }
}

final class RunningStopTests: XCTestCase {

    private let stack = [
        DockerContainer(name: "supabase_db_acme-app", supabaseProject: "acme-app",
                        composeWorkingDir: "", ports: [54322], runningFor: "2 days ago"),
        DockerContainer(name: "supabase_kong_acme-app", supabaseProject: "acme-app",
                        composeWorkingDir: "", ports: [54321], runningFor: "2 days ago"),
        DockerContainer(name: "redis", supabaseProject: "",
                        composeWorkingDir: "/srv/app", ports: [6379], runningFor: "3 hours ago"),
    ]

    private func scan(_ host: String) -> RunningHostScan {
        RunningHostScan(host: host, docker: .containers(stack), listeners: nil)
    }

    private func row(_ name: String, host: String = "devbox", pane: String? = nil) -> RunningResource {
        RunningResource(
            kind: .container(name: name, ports: [], count: 1), host: host, paneID: pane,
            label: name, tooltip: "")
    }

    /// Stopping one container of a Supabase stack leaves a half-stack that looks
    /// alive and answers nothing, so Stop takes the whole stack.
    func testStopTakesTheWholeStack() {
        let targets = Running.stopTargets(for: row("acme-app"), scans: [scan("devbox")])
        XCTAssertEqual(targets.map(\.name), ["supabase_db_acme-app", "supabase_kong_acme-app"])
    }

    /// A container with no Supabase label is its own business — no siblings.
    func testPlainContainerStopsAlone() {
        XCTAssertEqual(
            Running.stopTargets(for: row("redis"), scans: [scan("devbox")]).map(\.name), ["redis"])
    }

    /// The stack on THIS Mac is not a sibling of the one on devbox.
    func testSiblingsAreLookedUpOnTheRowsOwnHost() {
        XCTAssertTrue(
            Running.stopTargets(for: row("acme-app", host: "localhost"),
                                scans: [scan("devbox")]).isEmpty)
    }

    func testAServerHasNoContainerTargets() {
        let server = RunningResource(
            kind: .server(port: 5173), host: "localhost", paneID: "%12", label: "acme-app",
            tooltip: "", url: "http://localhost:5173", pid: 300)
        XCTAssertTrue(Running.stopTargets(for: server, scans: [scan("localhost")]).isEmpty)
    }

    // MARK: the confirm — decision 8's evidence, not a verdict

    func testContainerConfirmNamesEveryContainerItsPortsAndItsAge() {
        let resource = row("acme-app")
        let targets = Running.stopTargets(for: resource, scans: [scan("devbox")])
        let confirm = Running.stopConfirm(
            for: resource, targets: targets, knownHosts: ["localhost", "devbox"])

        XCTAssertEqual(confirm.title, "Stop these 2 containers?")
        XCTAssertEqual(confirm.body, """
        Host: devbox
        Containers: supabase_db_acme-app, supabase_kong_acme-app
        Ports: :54321–54322
        Up: 2 days ago
        No session on localhost, devbox claims this.
        """)
    }

    /// A row a pane DOES claim is not described as unclaimed — that line is the
    /// one a human weighs hardest, so it must never be wrong.
    func testClaimedRowDoesNotClaimNobodyOwnsIt() {
        let resource = row("redis", pane: "%12")
        let confirm = Running.stopConfirm(
            for: resource, targets: Running.stopTargets(for: resource, scans: [scan("devbox")]),
            knownHosts: ["localhost", "devbox"])
        XCTAssertFalse(confirm.body.contains("No session"))
    }

    func testServerConfirmNamesThePortURLAndPid() {
        let server = RunningResource(
            kind: .server(port: 5173), host: "localhost", paneID: "%12", label: "acme-app",
            tooltip: "", url: "https://localhost:5173", pid: 300)
        let confirm = Running.stopConfirm(for: server, targets: [], knownHosts: ["localhost"])
        XCTAssertEqual(confirm.title, "Stop the server on :5173?")
        XCTAssertEqual(confirm.body, """
        Host: localhost
        Port: :5173
        URL: https://localhost:5173
        Process: pid 300
        """)
    }
}

// MARK: - Links, sections and the toolbar title (the popover)

final class RunningLinkTests: XCTestCase {

    private func member(_ service: String, _ ports: [Int], stack: String = "feat-rates")
        -> DockerContainer {
        DockerContainer(
            name: "supabase_\(service)_\(stack)", supabaseProject: stack,
            composeWorkingDir: "", ports: ports)
    }

    private var stack: [DockerContainer] {
        [
            member("db", [54722]),
            member("kong", [54721]),
            member("studio", [54723]),
            member("inbucket", [54724, 54725, 54726]),
            member("rest", []),
            member("pg_meta", []),
        ]
    }

    func testServiceIsReadFromTheContainerNamePrefix() {
        XCTAssertEqual(Running.supabaseService(containerName: "supabase_studio_acme-app")?.label, "Studio")
        XCTAssertEqual(Running.supabaseService(containerName: "supabase_kong_x")?.label, "API")
        XCTAssertEqual(Running.supabaseService(containerName: "supabase_db_x")?.label, "DB")
        XCTAssertEqual(Running.supabaseService(containerName: "supabase_db_x")?.action, .copy)
        XCTAssertEqual(Running.supabaseService(containerName: "supabase_inbucket_x")?.label, "Mail")
        XCTAssertEqual(Running.supabaseService(containerName: "supabase_mailpit_x")?.label, "Mail")
        XCTAssertNil(Running.supabaseService(containerName: "supabase_rest_x"))
        XCTAssertNil(Running.supabaseService(containerName: "redis"))
    }

    /// A project id past the CLI's 40-character label cap still maps: the service
    /// comes from the name's prefix, never from the (truncated) project label.
    func testServiceMapsForATruncatedStackName() {
        let long = "admin-fix-people-edits-profiles-join-and-more"
        XCTAssertEqual(Running.supabaseService(containerName: "supabase_studio_\(long)")?.label, "Studio")
    }

    /// The bug this replaces: the row opened its LOWEST port, which is the API
    /// gateway (or the database), never Studio.
    func testEachServiceLinksItsOwnPortInReachOrder() {
        let links = Running.supabaseLinks(stack, host: "localhost")
        XCTAssertEqual(links.map(\.label), ["Studio", "API", "DB", "Mail"])
        XCTAssertEqual(links[0].url, "http://localhost:54723")
        XCTAssertEqual(links[1].url, "http://localhost:54721")
        XCTAssertEqual(links[3].url, "http://localhost:54724")
    }

    func testDatabaseIsACopiedConnectionString() {
        let db = Running.supabaseLinks(stack, host: "devbox1.example.ts.net")[2]
        XCTAssertEqual(db.action, .copy)
        XCTAssertEqual(
            db.url, "postgresql://postgres:postgres@devbox1.example.ts.net:54722/postgres")
    }

    /// A service publishing nothing gets no link rather than a dead one.
    func testUnpublishedServiceHasNoLink() {
        let links = Running.supabaseLinks([member("studio", []), member("kong", [54321])], host: "localhost")
        XCTAssertEqual(links.map(\.label), ["API"])
    }

    func testStackRowOpensStudioNotItsLowestPort() {
        let scan = RunningHostScan(host: "localhost", docker: .containers(stack), listeners: [])
        let row = Running.unclaimed(scans: [scan], panes: []).resources[0]
        XCTAssertTrue(row.isSupabaseStack)
        XCTAssertEqual(row.url, "http://localhost:54723")
    }

    /// A server row's link is its URL; an unreachable one (remote loopback) has
    /// none — the behaviour #133 established, kept.
    func testServerLinkFollowsItsURL() {
        let open = RunningResource(
            kind: .server(port: 5173), host: "localhost", paneID: "%1", label: "p",
            tooltip: "", url: "https://localhost:5173/")
        XCTAssertEqual(open.links, [RunningLink(label: "", url: "https://localhost:5173/", action: .open)])
        let loopback = RunningResource(
            kind: .server(port: 7000), host: "devbox", paneID: "%1", label: "p", tooltip: "")
        XCTAssertTrue(loopback.links.isEmpty)
    }

    // MARK: sections + title

    private func server(_ port: Int, pane: String? = "%1") -> RunningResource {
        RunningResource(kind: .server(port: port), host: "localhost", paneID: pane,
                        label: "p", tooltip: "")
    }

    private func container(_ name: String, pane: String?, supabase: Bool) -> RunningResource {
        RunningResource(kind: .container(name: name, ports: [], count: 1), host: "localhost",
                        paneID: pane, label: name, tooltip: "", isSupabaseStack: supabase)
    }

    private func group(_ resources: [RunningResource], title: String? = nil) -> RunningGroup {
        RunningGroup(title: title, set: RunningSet(known: true, resources: resources, unknowns: []))
    }

    func testSectionsSplitByKindAndPutUnclaimedLast() {
        let groups = [
            group([server(5173), container("acme-app", pane: "%1", supabase: true),
                   container("redis", pane: "%1", supabase: false)], title: "0: web"),
            group([container("orphan", pane: nil, supabase: true)], title: "unclaimed"),
        ]
        XCTAssertEqual(Running.sections(groups).map(\.title),
                       ["Dev servers", "Supabase", "Docker", "Unclaimed"])
        XCTAssertEqual(Running.sections(groups)[3].resources.map(\.label), ["orphan"])
    }

    func testEmptySectionsAreLeftOut() {
        XCTAssertEqual(Running.sections([group([server(5173)])]).map(\.title), ["Dev servers"])
        XCTAssertTrue(Running.sections([]).isEmpty)
    }

    /// Two windows of one checkout claim the same server: one row, one count.
    func testSectionsDedupeAcrossGroups() {
        let groups = [group([server(5173)], title: "0: a"), group([server(5173)], title: "1: b")]
        XCTAssertEqual(Running.sections(groups)[0].resources.count, 1)
        XCTAssertEqual(Running.toolbarTitle(groups), "1 running")
    }

    /// Zero hides the drawer: nothing the selection owns, even with unclaimed
    /// stacks elsewhere, and nothing at all while unknown.
    func testOwnedCountIgnoresUnclaimedAndUnknown() {
        XCTAssertEqual(Running.ownedCount([]), 0)
        XCTAssertEqual(Running.ownedCount([group([container("o", pane: nil, supabase: true)])]), 0)
        XCTAssertEqual(Running.ownedCount([RunningGroup(title: nil, set: .unknown)]), 0)
        XCTAssertEqual(Running.ownedCount([group([server(5173), container("o", pane: nil, supabase: true)])]), 1)
    }

    /// Unclaimed rows never count: a session header would otherwise read
    /// "18 running" on a machine whose sessions own nothing.
    func testToolbarTitleCountsOnlyWhatTheSelectionOwns() {
        XCTAssertEqual(Running.toolbarTitle([]), "Running")
        XCTAssertEqual(Running.toolbarTitle([group([container("o", pane: nil, supabase: true)])]), "Running")
        XCTAssertEqual(Running.toolbarTitle([group([
            server(5173), server(5180), container("acme-app", pane: "%1", supabase: true),
        ])]), "3 running")
    }
}
