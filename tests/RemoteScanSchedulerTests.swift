import XCTest

// RemoteScanScheduler.swift + the SshIdentity half of SshConfig.swift are
// Foundation-only and compiled into this test target, so the cold-scan cadence,
// its backoff, and alias canonicalization are asserted without timers or ssh.

final class RemoteScanSchedulerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func scheduler(
        base: TimeInterval = 300, max: TimeInterval = 3600, factor: Double = 2
    ) -> RemoteScanScheduler {
        RemoteScanScheduler(policy: .init(
            baseInterval: base, maxInterval: max, backoffFactor: factor))
    }

    // MARK: Cadence

    func testNeverScannedHostIsDueImmediately() {
        // First poll after launch must discover every remote, not wait 5 minutes.
        XCTAssertTrue(scheduler().isDue("buildbox", now: t0))
    }

    func testSuccessDefersByBaseInterval() {
        let s = scheduler()
        s.recordSuccess("buildbox", now: t0)
        XCTAssertFalse(s.isDue("buildbox", now: t0.addingTimeInterval(299)))
        XCTAssertTrue(s.isDue("buildbox", now: t0.addingTimeInterval(300)))
    }

    func testInFlightHostIsNotRescanned() {
        // A slow ssh must not have a second scan stacked on it by the 1.5s poll.
        let s = scheduler()
        s.begin("buildbox")
        XCTAssertFalse(s.isDue("buildbox", now: t0))
        XCTAssertTrue(s.isInFlight("buildbox"))
        s.recordSuccess("buildbox", now: t0)
        XCTAssertFalse(s.isInFlight("buildbox"))
    }

    // MARK: Backoff

    func testFirstFailureStillWaitsOnlyBaseInterval() {
        // A rebooting box shouldn't be punished on its first miss.
        let s = scheduler()
        s.recordFailure("nas", now: t0)
        XCTAssertTrue(s.isDue("nas", now: t0.addingTimeInterval(300)))
    }

    func testConsecutiveFailuresBackOffGeometrically() {
        let s = scheduler()
        var now = t0
        // 1st failure → 300s, 2nd → 600s, 3rd → 1200s.
        for expected in [300.0, 600.0, 1200.0] {
            s.recordFailure("sftp.example.com", now: now)
            XCTAssertFalse(s.isDue("sftp.example.com", now: now.addingTimeInterval(expected - 1)))
            XCTAssertTrue(s.isDue("sftp.example.com", now: now.addingTimeInterval(expected)))
            now = now.addingTimeInterval(expected)
        }
    }

    func testBackoffClampsToMaxInterval() {
        // A permanently-dead alias costs one connect timeout an hour, not one per 5 min.
        let s = scheduler()
        var now = t0
        for _ in 0..<50 {
            s.recordFailure("sftp.example.com", now: now)
            now = now.addingTimeInterval(3600)
        }
        s.recordFailure("sftp.example.com", now: t0)
        XCTAssertEqual(s.nextDue("sftp.example.com"), t0.addingTimeInterval(3600))
    }

    func testSuccessResetsBackoff() {
        let s = scheduler()
        s.recordFailure("host3", now: t0)
        s.recordFailure("host3", now: t0)  // now at 600s
        s.recordSuccess("host3", now: t0)
        XCTAssertEqual(s.nextDue("host3"), t0.addingTimeInterval(300))
    }

    func testForceAllMakesEveryHostDue() {
        let s = scheduler()
        s.recordFailure("nas", now: t0)
        s.recordSuccess("buildbox", now: t0)
        s.forceAll()
        XCTAssertTrue(s.isDue("nas", now: t0))
        XCTAssertTrue(s.isDue("buildbox", now: t0))
    }

    func testRetainDropsRemovedAliases() {
        let s = scheduler()
        s.recordSuccess("buildbox", now: t0)
        s.recordSuccess("gone", now: t0)
        s.retain(["buildbox"])
        XCTAssertNotNil(s.nextDue("buildbox"))
        XCTAssertNil(s.nextDue("gone"))
    }
}

final class SshIdentityTests: XCTestCase {
    // MARK: ssh -G parsing

    func testParsesUserHostnamePort() {
        let out = "user dev\nhostname 100.64.0.1\nport 22\nforwardagent no\n"
        XCTAssertEqual(SshIdentity.parse(sshDashG: out), "dev@100.64.0.1:22")
    }

    func testParseTakesFirstOccurrenceOfEachKey() {
        let out = "hostname 10.0.0.1\nhostname 10.0.0.2\nuser a\nport 22\n"
        XCTAssertEqual(SshIdentity.parse(sshDashG: out), "a@10.0.0.1:22")
    }

    func testParseDefaultsPortWhenAbsent() {
        XCTAssertEqual(SshIdentity.parse(sshDashG: "user a\nhostname h\n"), "a@h:22")
    }

    func testParseReturnsNilWithoutHostname() {
        XCTAssertNil(SshIdentity.parse(sshDashG: "user dev\nport 22\n"))
    }

    // MARK: Dedupe — the reported duplicate-sessions bug

    func testAliasesForSameMachineCollapseToFirst() {
        // `Host buildbox buildbox1` is ONE box. With both watched, the sidebar
        // listed its tmux sessions twice. First alias declared wins.
        let hosts = [
            Host(name: "buildbox", sshAlias: "buildbox"),
            Host(name: "buildbox1", sshAlias: "buildbox1"),
            Host(name: "host3", sshAlias: "host3"),
        ]
        let identities = [
            "buildbox": "dev@100.64.0.1:22",
            "buildbox1": "dev@100.64.0.1:22",
            "host3": "dev@100.64.0.2:22",
        ]
        let kept = SshIdentity.dedupe(hosts) { identities[$0.name] }
        XCTAssertEqual(kept.map(\.name), ["buildbox", "host3"])
    }

    func testServersListOneRowPerMachineAndUser() {
        // A typical ~/.ssh/config: `Host buildbox buildbox1`, `Host buildbox-hermes
        // hermes-buildbox` (same box, user hermes), `Host devbox devbox1`. SERVERS
        // showed all six aliases. One row per account, first alias declared.
        let names = ["buildbox", "buildbox1", "buildbox-hermes", "hermes-buildbox",
                     "devbox", "devbox1"]
        let hosts = names.map { Host(name: $0, sshAlias: $0) }
        let identities = [
            "buildbox": "dev@100.64.0.3:22",
            "buildbox1": "dev@100.64.0.3:22",
            "buildbox-hermes": "hermes@100.64.0.3:22",
            "hermes-buildbox": "hermes@100.64.0.3:22",
            "devbox": "dev@100.64.0.4:22",
            "devbox1": "dev@100.64.0.4:22",
        ]
        let kept = RemoteTier.servers(hosts) { identities[$0.name] }
        XCTAssertEqual(kept.map(\.name), ["buildbox", "buildbox-hermes", "devbox"])
    }

    func testUnresolvedAliasesAreNeverCollapsed() {
        // nil identity = "not resolved yet". Two unknowns must not be assumed equal.
        let hosts = [
            Host(name: "a", sshAlias: "a"),
            Host(name: "b", sshAlias: "b"),
        ]
        XCTAssertEqual(SshIdentity.dedupe(hosts) { _ in nil }.map(\.name), ["a", "b"])
    }

    func testLocalHostHasItsOwnIdentity() {
        XCTAssertEqual(SshIdentity.cached(.local), SshIdentity.localIdentity)
    }

    func testCanonicalFallsBackToAliasWhenSshFails() {
        // An unresolvable alias gets a unique identity (itself), so it never
        // collapses into another host.
        SshIdentity.resetCacheForTesting()
        let host = Host(name: "ghost", sshAlias: "ghost")
        let resolved = SshIdentity.canonical(host, runner: FailingRunner())
        XCTAssertEqual(resolved, "ghost")
    }

    func testCanonicalMemoizesSoSshRunsOncePerAlias() {
        SshIdentity.resetCacheForTesting()
        let runner = CountingRunner(output: "user j\nhostname h\nport 22\n")
        let host = Host(name: "buildbox", sshAlias: "buildbox")
        XCTAssertEqual(SshIdentity.canonical(host, runner: runner), "j@h:22")
        XCTAssertEqual(SshIdentity.canonical(host, runner: runner), "j@h:22")
        XCTAssertEqual(runner.calls, 1)
        SshIdentity.resetCacheForTesting()
    }
}

/// `RemoteTier.active` is the exact function `buildHostNodes` uses to decide which
/// remotes contribute session rows to ACTIVE.
final class RemoteTierTests: XCTestCase {
    private let buildbox = Host(name: "buildbox", sshAlias: "buildbox")
    private let buildboxAlias = Host(name: "buildbox1", sshAlias: "buildbox1")
    private let host3 = Host(name: "host3", sshAlias: "host3")
    private let nas = Host(name: "nas", sshAlias: "nas")

    private func identity(_ host: Host) -> String? {
        [
            "buildbox": "dev@100.64.0.1:22",
            "buildbox1": "dev@100.64.0.1:22",
            "host3": "dev@100.64.0.2:22",
            "nas": "dev@nas.example.com:22",
        ][host.name]
    }

    /// Regression: with `watch.buildbox` and `watch.buildbox1` both set, every
    /// tmux session on that one box was rendered twice in ACTIVE.
    func testTwoWatchedAliasesForOneBoxYieldOneEntry() {
        let kept = RemoteTier.active(
            [buildbox, buildboxAlias, host3],
            watched: { _ in true },
            hasSessions: { _ in true },
            identity: identity)
        XCTAssertEqual(kept.map(\.name), ["buildbox", "host3"])
    }

    /// The cold sweep's payoff: an unwatched remote earns a place in ACTIVE purely by
    /// having had sessions discovered on it.
    func testUnwatchedRemoteWithDiscoveredSessionsIsActive() {
        let kept = RemoteTier.active(
            [host3],
            watched: { _ in false },
            hasSessions: { $0.name == "host3" },
            identity: identity)
        XCTAssertEqual(kept.map(\.name), ["host3"])
    }

    func testUnwatchedRemoteWithNoSessionsIsExcluded() {
        let kept = RemoteTier.active(
            [nas],
            watched: { _ in false },
            hasSessions: { _ in false },
            identity: identity)
        XCTAssertTrue(kept.isEmpty)
    }

    /// A watched host still shows even before its first successful load, so toggling
    /// Watch gives immediate feedback.
    func testWatchedRemoteWithoutSessionsStillActive() {
        let kept = RemoteTier.active(
            [nas],
            watched: { $0.name == "nas" },
            hasSessions: { _ in false },
            identity: identity)
        XCTAssertEqual(kept.map(\.name), ["nas"])
    }

    /// Dedupe must not drop a real second machine that merely sorts adjacent.
    func testDistinctMachinesAllSurvive() {
        let kept = RemoteTier.active(
            [buildbox, host3, nas],
            watched: { _ in true },
            hasSessions: { _ in false },
            identity: identity)
        XCTAssertEqual(kept.map(\.name), ["buildbox", "host3", "nas"])
    }

    /// Before the first `ssh -G` prewarm lands, identities are nil. Two unresolved
    /// aliases must not be merged — better a transient duplicate than a lost host.
    func testUnresolvedIdentitiesAreNotMerged() {
        let kept = RemoteTier.active(
            [buildbox, buildboxAlias],
            watched: { _ in true },
            hasSessions: { _ in false },
            identity: { _ in nil })
        XCTAssertEqual(kept.map(\.name), ["buildbox", "buildbox1"])
    }
}

private struct FailingRunner: CommandRunner {
    func run(_ path: String, _ args: [String], stdin: Data?) -> String? { nil }
}

private final class CountingRunner: CommandRunner {
    let output: String
    private(set) var calls = 0
    init(output: String) { self.output = output }
    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        calls += 1
        return output
    }
}

extension RemoteTierTests {
    // MARK: Poll tiers

    func testExpandedOrWatchedOrSessionfulHostIsHot() {
        XCTAssertTrue(RemoteTier.isHot(watched: true, expanded: false, hasSessions: false))
        XCTAssertTrue(RemoteTier.isHot(watched: false, expanded: true, hasSessions: false))
        // The payoff of auto-promotion: a discovered remote joins the fast poll, so
        // its attention dots don't sit up to 5 minutes stale.
        XCTAssertTrue(RemoteTier.isHot(watched: false, expanded: false, hasSessions: true))
    }

    func testIdleCollapsedUnwatchedHostIsCold() {
        XCTAssertFalse(RemoteTier.isHot(watched: false, expanded: false, hasSessions: false))
    }

    // MARK: Hot-remote cadence (every Nth tick, not every tick)

    func testNeverPolledHostIsDue() {
        XCTAssertTrue(RemoteTier.isDue(last: nil, now: Date(), interval: 4.5))
    }

    func testHostPolledWithinTheIntervalIsNotDue() {
        let now = Date()
        // One tick ago (1.5s) — still inside the 4.5s remote interval.
        XCTAssertFalse(RemoteTier.isDue(last: now.addingTimeInterval(-1.5), now: now, interval: 4.5))
        XCTAssertFalse(RemoteTier.isDue(last: now.addingTimeInterval(-3.0), now: now, interval: 4.5))
    }

    func testThirdTickIsDueDespiteTimerJitter() {
        let now = Date()
        // The third 1.5s tick lands a hair under 4.5s in practice. Without the
        // slack this misses and the remote silently polls at 6s instead.
        XCTAssertTrue(RemoteTier.isDue(last: now.addingTimeInterval(-4.4), now: now, interval: 4.5))
        XCTAssertTrue(RemoteTier.isDue(last: now.addingTimeInterval(-4.5), now: now, interval: 4.5))
    }

    func testSlackDoesNotSwallowAWholeTick() {
        let now = Date()
        // Slack absorbs jitter, not an entire tick: 3.0s elapsed must stay not-due,
        // otherwise the "every third tick" cadence collapses back toward every other.
        XCTAssertFalse(RemoteTier.isDue(last: now.addingTimeInterval(-3.1), now: now, interval: 4.5))
    }
}
