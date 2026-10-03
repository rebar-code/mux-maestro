import Foundation

/// The name a browser on THIS Mac can open for a host the sidebar knows only by
/// ssh alias.
///
/// An ssh alias is not a DNS name. `~/.ssh/config` maps `devbox` to a tailnet
/// address and nothing outside ssh knows that, so `ping devbox` answers "Unknown
/// host" and the `http://devbox:54713` the Running popover used to build never
/// opened. Three cheap steps fix it, and only the last one is a lookup:
/// `ssh -G` for the hostname the alias really means, `tailscale status --json`
/// for the MagicDNS name that hostname belongs to, and one local resolver call
/// to decide whether this Mac can use that name or must use the tailnet IP.
///
/// Pure parsers plus a process-lifetime cache, the same shape as `SshIdentity`.
/// Foundation only, so the test target compiles it and each step of the decision
/// is asserted rather than eyeballed.

/// One machine on the tailnet, as `tailscale status --json` describes it.
struct TailnetNode: Equatable {
    /// MagicDNS name with the trailing dot stripped
    /// ("devbox1.example.ts.net").
    let dnsName: String
    /// Its tailnet addresses, in the order Tailscale prints them (IPv4 first).
    let ips: [String]

    /// The label before the first dot — the short name MagicDNS also answers to.
    var shortName: String { String(dnsName.prefix { $0 != "." }) }
}

/// What `tailscale status --json` says about this tailnet.
struct TailnetStatus: Equatable {
    /// False when MagicDNS is off. The DNS names are still in the output, but
    /// nothing on this Mac resolves them, so they must not reach a browser.
    let magicDNSEnabled: Bool
    let nodes: [TailnetNode]
}

enum HostAddress {
    // MARK: parsers

    /// Read the nodes out of `tailscale status --json`.
    ///
    /// `Self` is this Mac and `Peer` is a dictionary of every other machine; both
    /// carry the same node shape. `DNSName` arrives fully qualified WITH a
    /// trailing dot ("devbox1.example.ts.net."), which no URL wants, so
    /// it is stripped here once. Returns nil when the output is not JSON at all —
    /// Tailscale absent or wedged — which the caller treats as "no tailnet".
    static func parseTailscaleStatus(_ json: String) -> TailnetStatus? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        var nodes: [TailnetNode] = []
        if let mine = node(root["Self"]) { nodes.append(mine) }
        if let peers = root["Peer"] as? [String: Any] {
            nodes += peers.keys.sorted().compactMap { node(peers[$0]) }
        }
        let tailnet = root["CurrentTailnet"] as? [String: Any]
        return TailnetStatus(
            magicDNSEnabled: (tailnet?["MagicDNSEnabled"] as? Bool) ?? false,
            nodes: nodes)
    }

    private static func node(_ raw: Any?) -> TailnetNode? {
        guard let fields = raw as? [String: Any],
              let name = fields["DNSName"] as? String else { return nil }
        let dns = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard !dns.isEmpty else { return nil }
        return TailnetNode(dnsName: dns, ips: (fields["TailscaleIPs"] as? [String]) ?? [])
    }

    /// The `hostname` an alias resolves to, out of `ssh -G` output. First wins —
    /// ssh prints the effective value first, the rule `SshIdentity.parse` uses.
    static func sshHostname(_ sshDashG: String) -> String? {
        for line in sshDashG.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "hostname" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: the decision

    /// The host part of a URL this Mac's browser can open for `alias`.
    ///
    /// 1. No ssh hostname — ssh could not resolve the alias, or ssh is not there.
    ///    Fall back to the alias, which is exactly today's behaviour.
    /// 2. The hostname names a tailnet node. Prefer that node's MagicDNS name,
    ///    which is stable and readable — but only once `resolves` confirms this
    ///    Mac's resolver answers for it, because MagicDNS can be off or the
    ///    tailnet DNS not installed. Otherwise use the node's tailnet IPv4, which
    ///    always works while the tailnet is up.
    /// 3. Anything else — the ssh hostname verbatim. A real DNS name
    ///    (`nas.example.com`) and a LAN IP already resolve here.
    ///
    /// `resolves` is injected, so the whole table is asserted with no lookup.
    static func browserHost(
        alias: String, sshHostname: String?, tailnet: TailnetStatus?,
        resolves: (String) -> Bool
    ) -> String {
        guard let hostname = sshHostname, !hostname.isEmpty else { return alias }
        guard let tailnet, let node = tailnet.nodes.first(where: { matches($0, hostname) })
        else { return hostname }
        if tailnet.magicDNSEnabled, resolves(node.dnsName) { return node.dnsName }
        return node.ips.first { !$0.contains(":") } ?? node.ips.first ?? hostname
    }

    /// Whether `hostname` names this node — by tailnet IP (what `ssh -G` prints
    /// for a `HostName 100.x` entry), by full MagicDNS name, or by short name.
    private static func matches(_ node: TailnetNode, _ hostname: String) -> Bool {
        let needle = hostname.lowercased()
        if node.ips.contains(where: { $0.lowercased() == needle }) { return true }
        let dns = node.dnsName.lowercased()
        return dns == needle || String(dns.prefix { $0 != "." }) == needle
    }

    /// A host as it goes into a URL. An IPv6 literal has to be bracketed or the
    /// URL does not parse — `http://fd7a::1:54321` has no port in it.
    static func urlHost(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    // MARK: resolution

    private static var cache: [String: String] = [:]
    /// Double optional on purpose: nil means "not asked yet", `.some(nil)` means
    /// "asked, and there is no tailnet here" — so a box without Tailscale spawns
    /// one process, not one per host per sweep.
    private static var tailnetCache: TailnetStatus??
    private static let lock = NSLock()

    /// The browser-reachable address for `host`, blocking on `ssh -G` and (once
    /// per process) `tailscale status --json` for a cache miss. Call OFF the main
    /// thread. The local host is always "localhost".
    static func resolve(
        _ host: Host, runner: CommandRunner = ProcessCommandRunner(timeout: 4.0),
        resolves: (String) -> Bool = dnsResolves
    ) -> String {
        guard let alias = host.sshAlias else { return host.name }
        lock.lock()
        if let hit = cache[alias] { lock.unlock(); return hit }
        lock.unlock()

        let hostname = runner.run(Ssh.sshPath, ["-G", alias]).flatMap(sshHostname)
        let address = browserHost(
            alias: alias, sshHostname: hostname, tailnet: tailnetStatus(runner: runner),
            resolves: resolves)

        lock.lock()
        cache[alias] = address
        lock.unlock()
        return address
    }

    /// Non-blocking read for the main thread: the cached address, or nil when this
    /// alias has not been resolved yet. A miss degrades to the alias for one
    /// refresh rather than spawning a subprocess during layout.
    static func cached(_ host: Host) -> String? {
        guard let alias = host.sshAlias else { return host.name }
        lock.lock()
        defer { lock.unlock() }
        return cache[alias]
    }

    /// Resolve every host off-main so `cached(_:)` hits on the next render.
    static func prewarm(_ hosts: [Host], runner: CommandRunner = ProcessCommandRunner(timeout: 4.0)) {
        for host in hosts { _ = resolve(host, runner: runner) }
    }

    private static func tailnetStatus(runner: CommandRunner) -> TailnetStatus? {
        lock.lock()
        if let hit = tailnetCache { lock.unlock(); return hit }
        lock.unlock()

        let status = tailscalePath()
            .flatMap { runner.run($0, ["status", "--json"]) }
            .flatMap(parseTailscaleStatus)

        lock.lock()
        tailnetCache = .some(status)
        lock.unlock()
        return status
    }

    /// Best-effort local path to the Tailscale CLI, the same first-existing idiom
    /// `dockerPath` uses. No Tailscale means step 3 of `browserHost`, never a crash.
    static func tailscalePath() -> String? {
        ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
         "/Applications/Tailscale.app/Contents/MacOS/Tailscale"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// Whether this Mac's resolver answers for `host` — one `getaddrinfo`, the
    /// same lookup the browser is about to do. No connection is opened.
    static func dnsResolves(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let ok = getaddrinfo(host, nil, &hints, &result) == 0
        if let result { freeaddrinfo(result) }
        return ok
    }

    /// Test seam: drop the memoized address and tailnet answers.
    static func resetCacheForTesting() {
        lock.lock()
        cache.removeAll()
        tailnetCache = nil
        lock.unlock()
    }
}
