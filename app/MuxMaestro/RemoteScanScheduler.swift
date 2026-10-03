import Foundation

/// Decides *when* a collapsed, unwatched remote host gets a cold discovery scan.
///
/// The sidebar polls "hot" hosts — local, expanded, watched, or already holding
/// sessions — every `Settings.pollInterval()` (~1.5s). Everything else is swept
/// on a slow cadence so remote sessions surface on their own instead of only
/// after the user expands the row or flips Watch.
///
/// A host that answers is rescanned at `baseInterval`. A host that fails (offline,
/// or reachable but tmux-less) backs off geometrically to `maxInterval`, so a
/// permanently-dead alias in `~/.ssh/config` — an SFTP-only endpoint, a NAS with
/// no tmux — costs one connect timeout an hour instead of one every five minutes.
///
/// Pure and clock-injected: no timers, no I/O, `now` is supplied by the caller.
/// Not thread-safe; the sidebar drives it from the main thread only.
final class RemoteScanScheduler {
    struct Policy {
        /// Cadence for a host that answered last time.
        var baseInterval: TimeInterval = 300
        /// Ceiling the geometric backoff clamps to.
        var maxInterval: TimeInterval = 3600
        var backoffFactor: Double = 2
    }

    private struct Entry {
        var nextDue: Date
        /// Consecutive failures; 0 after any success. Drives the backoff exponent.
        var failures: Int
    }

    /// Exponent cap — `pow` past this is pointless (already clamped to
    /// `maxInterval`) and guards against a silly `Double` blowup.
    private static let maxExponent = 16

    private let policy: Policy
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    init(policy: Policy = Policy()) { self.policy = policy }

    /// Whether `host` should be scanned now. A never-seen host is due immediately,
    /// so the first poll after launch discovers every remote. A scan already in
    /// flight is never re-issued.
    func isDue(_ host: String, now: Date) -> Bool {
        guard !inFlight.contains(host) else { return false }
        guard let entry = entries[host] else { return true }
        return now >= entry.nextDue
    }

    func begin(_ host: String) { inFlight.insert(host) }

    func isInFlight(_ host: String) -> Bool { inFlight.contains(host) }

    /// Host answered: reset backoff, next sweep one `baseInterval` out.
    func recordSuccess(_ host: String, now: Date) {
        inFlight.remove(host)
        entries[host] = Entry(nextDue: now.addingTimeInterval(policy.baseInterval), failures: 0)
    }

    /// Host was unreachable or had no tmux: back off. The first failure still waits
    /// only `baseInterval` — a box that's merely rebooting shouldn't be punished.
    func recordFailure(_ host: String, now: Date) {
        inFlight.remove(host)
        let failures = (entries[host]?.failures ?? 0) + 1
        let exponent = Double(min(failures - 1, Self.maxExponent))
        let delay = min(policy.baseInterval * pow(policy.backoffFactor, exponent), policy.maxInterval)
        entries[host] = Entry(nextDue: now.addingTimeInterval(delay), failures: failures)
    }

    /// Make every host due immediately and clear all backoff — the SERVERS refresh
    /// button. In-flight scans are left alone; their completion re-arms them.
    func forceAll() {
        entries.removeAll()
    }

    /// Drop bookkeeping for hosts no longer in `~/.ssh/config` so a long-lived
    /// process doesn't accumulate entries for deleted aliases.
    func retain(_ hosts: Set<String>) {
        entries = entries.filter { hosts.contains($0.key) }
        inFlight = inFlight.filter { hosts.contains($0) }
    }

    /// Test/diagnostic seam: when `host` is next eligible, or nil if never scanned.
    func nextDue(_ host: String) -> Date? { entries[host]?.nextDue }
}

/// Which remotes the sidebar shows, and how often it polls them.
///
/// Pure policy, kept out of `SidebarViewController` (an AppKit type the test target
/// doesn't compile) so the tiering and the alias-dedupe can be asserted directly.
enum RemoteTier {
    /// Whether `host` belongs in the fast (~1.5s) poll tier: the user is looking at
    /// it (expanded), asked for it (watched), or it already holds sessions — in which
    /// case its attention dots must stay live, since a remote Claude waiting on the
    /// user is exactly what this app exists to surface. Everything else is cold, and
    /// swept by `RemoteScanScheduler`'s cadence.
    static func isHot(watched: Bool, expanded: Bool, hasSessions: Bool) -> Bool {
        watched || expanded || hasSessions
    }

    /// Hot remotes reload every Nth tick, not every tick. Being hot means "keep
    /// this host live", not "hit it as hard as the local one": a local tree is
    /// three ~8ms `list-*` calls, while the same three over ssh cost a round-trip
    /// apiece and were the largest share of the app's background work. Remote
    /// sessions also change far more slowly than local ones — nobody is typing in
    /// them on this machine.
    static let remotePollTicks = 3

    /// Whether a host last polled at `last` is due again at `now`.
    ///
    /// The slack absorbs timer jitter: a 4.5s interval sampled by a 1.5s timer
    /// lands a hair early on the third tick, and without slack it would miss and
    /// silently become a 6s interval.
    static func isDue(
        last: Date?, now: Date, interval: TimeInterval, slack: TimeInterval = 0.25
    ) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval - slack
    }

    /// The remotes whose sessions belong in ACTIVE: watched, or holding sessions the
    /// cold sweep discovered — the latter is what makes a remote session appear
    /// without the user first expanding the row or flipping Watch.
    ///
    /// Aliases reaching the same machine collapse to the first declared. `~/.ssh/config`
    /// is an alias table, not a server list: with `Host buildbox buildbox1` both
    /// watched, every tmux session on that one box was rendered twice.
    static func active(
        _ remotes: [Host],
        watched: (Host) -> Bool,
        hasSessions: (Host) -> Bool,
        identity: (Host) -> String?
    ) -> [Host] {
        SshIdentity.dedupe(remotes.filter { watched($0) || hasSessions($0) }, identity: identity)
    }

    /// The remotes listed in SERVERS: one row per machine and user, the first alias
    /// declared. `Host devbox devbox1` is one server, not two rows.
    static func servers(_ remotes: [Host], identity: (Host) -> String?) -> [Host] {
        SshIdentity.dedupe(remotes, identity: identity)
    }
}
