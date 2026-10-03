import Foundation

/// What is running because of the thing you are looking at: the dev servers a
/// pane's own processes hold, and the containers its directory owns — on this Mac
/// and on every ssh host the sidebar knows about.
///
/// Pure: argv builders, output parsers, the two join rules, the scheme rule and
/// the aggregation. Foundation only, no AppKit, so the test target compiles it
/// and every join is asserted instead of eyeballed. The popover's view controller
/// renders what this returns and parses nothing.
///
/// **Unknown is never zero.** A nil listener list and a `.unavailable` Docker
/// snapshot both mean "we did not get an answer" — the reading that makes a live
/// stack look idle. So `RunningSet` carries `known` plus the `unknowns` to say so
/// on screen, rather than a silently shorter list of rows.

/// One listening TCP port and the process holding it.
struct ListeningPort: Equatable, Hashable {
    let port: Int
    let pid: Int
    /// True when every bind for this port is loopback (`127.0.0.1`, `[::1]`).
    /// On this Mac that changes nothing; on a remote host it means no browser
    /// here can reach it, whatever name we give it — see `Running.reachable`.
    let loopbackOnly: Bool

    init(port: Int, pid: Int, loopbackOnly: Bool = false) {
        self.port = port
        self.pid = pid
        self.loopbackOnly = loopbackOnly
    }
}

/// One address a row offers: the dev server's own URL, or one service of a
/// Supabase stack (`Studio`, `API`, `DB`, `Mail`). A database is not a web page,
/// so its connection string is copied rather than opened.
struct RunningLink: Equatable {
    enum Action: Equatable { case open, copy }
    /// Empty for a dev server — the URL is the whole story.
    let label: String
    let url: String
    let action: Action
}

/// One thing that is running.
struct RunningResource: Equatable {
    enum Kind: Equatable {
        /// A listening port held by a pane's own process tree.
        case server(port: Int)
        /// A container, or a whole Supabase stack, and the host ports it
        /// publishes. `count` is how many containers the row stands for.
        case container(name: String, ports: [Int], count: Int)
    }

    let kind: Kind
    /// `Host.name` this runs on — "localhost", or the ssh alias for a remote.
    let host: String
    /// The pane that owns it; nil when nothing claims it (the *unclaimed* group).
    let paneID: String?
    let label: String
    let tooltip: String
    /// Where ↗ goes, already resolved (see `serverURL`), so it opens verbatim.
    /// **nil means there is nothing to open** — a remote port bound only to that
    /// host's loopback, or a container publishing no port. The ↗ button and the
    /// Stop confirm both read this one field rather than rebuilding an address.
    let url: String?
    /// The process holding the port, for Stop. nil for a container, which is
    /// stopped by name through Docker rather than by signal.
    let pid: Int?
    /// The checkout this row belongs to, which is where its favicon is loaded
    /// from. Empty for an unclaimed row — nothing owns it, so it has no icon.
    let dir: String
    /// What the row lists under its name. A server has one link (none when
    /// unreachable); a Supabase stack one per service; a container one per port.
    let links: [RunningLink]
    /// A whole Supabase stack rather than a plain container — which section the
    /// popover files it under.
    let isSupabaseStack: Bool

    init(kind: Kind, host: String, paneID: String?, label: String, tooltip: String,
         url: String? = nil, pid: Int? = nil, dir: String = "",
         links: [RunningLink]? = nil, isSupabaseStack: Bool = false) {
        self.kind = kind
        self.host = host
        self.paneID = paneID
        self.label = label
        self.tooltip = tooltip
        self.url = url
        self.pid = pid
        self.dir = dir
        self.links = links ?? url.map { [RunningLink(label: "", url: $0, action: .open)] } ?? []
        self.isSupabaseStack = isSupabaseStack
    }

    /// Identity for dedupe across panes.
    /// Host-qualified: `supabase_db_acme-app` on this Mac and the same name on
    /// `devbox` are two different containers.
    var key: String {
        switch kind {
        case .server(let port): return "\(host)|server|\(port)"
        case .container(let name, _, _): return "\(host)|container|\(name)"
        }
    }

    /// Servers before containers, then port / name ascending — a stable order so
    /// a refresh never reshuffles the rail under the pointer.
    var sortKey: String {
        switch kind {
        case .server(let port): return String(format: "0|%06d|%@", port, host)
        case .container(let name, _, _): return "1|\(name)|\(host)"
        }
    }
}

/// The answer for one selection.
struct RunningSet: Equatable {
    /// False when any input the rows depend on is unknown: a scan still in
    /// flight, a wedged Docker, a host that did not answer. The toolbar count
    /// dims on this rather than reading as zero.
    let known: Bool
    let resources: [RunningResource]
    /// One short line per thing we could not see ("Docker unavailable on devbox").
    /// Rendered as its own row so unknown never reads as zero.
    let unknowns: [String]

    static let unknown = RunningSet(known: false, resources: [], unknowns: [])

    var isEmpty: Bool { resources.isEmpty && unknowns.isEmpty }
    var keys: Set<String> { Set(resources.map(\.key)) }
}

/// One group of rows. A pane selection renders a single unnamed
/// group — a flat list — while a window or a session header names each one, and
/// the *unclaimed* group appears only at that top level.
struct RunningGroup: Equatable {
    let title: String?
    let set: RunningSet
}

/// What one host reported in the latest scan.
struct RunningHostScan: Equatable {
    /// `Host.name`.
    let host: String
    /// The name a browser on THIS Mac can open for that box — the ssh alias
    /// resolved through `HostAddress`. Defaults to `host`, which is what the
    /// rail built before and is still right for the local machine.
    let address: String
    /// `.unavailable` ⇒ not known, never "no containers".
    let docker: DockerSnapshot
    /// nil ⇒ the port scan has not answered yet, never "no servers".
    let listeners: [ListeningPort]?
    /// pid → ppid on that host, kept RAW rather than pre-joined: the sweep and
    /// the session tree move independently, so the pane a port belongs to is
    /// resolved at render time against the tree as it is now. A scan that landed
    /// before the tree loaded would otherwise attribute nothing and call every
    /// container a leak.
    let ppids: [Int: Int]
    /// pane id → the listeners that pane's own process tree holds. Filled by the
    /// renderer via `portsByPane(listeners:panePidToId:ppids:)`, not by the scan.
    let portsByPane: [String: [ListeningPort]]

    init(host: String, docker: DockerSnapshot, listeners: [ListeningPort]?,
         ppids: [Int: Int] = [:], portsByPane: [String: [ListeningPort]] = [:],
         address: String? = nil) {
        self.host = host
        self.address = address ?? host
        self.docker = docker
        self.listeners = listeners
        self.ppids = ppids
        self.portsByPane = portsByPane
    }

    /// The same scan with its ports attributed to `panePidToId`'s panes.
    func attributed(panePidToId: [Int: String]) -> RunningHostScan {
        RunningHostScan(
            host: host, docker: docker, listeners: listeners, ppids: ppids,
            portsByPane: listeners.map {
                Running.portsByPane(listeners: $0, panePidToId: panePidToId, ppids: ppids)
            } ?? [:],
            address: address)
    }
}

/// One tmux pane reduced to the keys that claim a resource: the process tree
/// (which holds the ports) and the directory (which owns the containers).
struct RunningPane: Equatable {
    let paneID: String
    /// `Host.name` the pane lives on.
    let host: String
    let cwd: String
    /// `project_id` from this checkout's `supabase/config.toml`, when it has one.
    let supabaseProjectID: String?
    /// This checkout's branch sanitized by `stackID(branch:)` — the key that joins
    /// a local pane to a stack the remote-stack script created on another host.
    let stackID: String?
    /// Already-resolved URLs, keyed by port (see `serverURL`). A port with no
    /// entry falls back to `http://`.
    let urls: [Int: String]

    init(paneID: String, host: String, cwd: String, supabaseProjectID: String? = nil,
         stackID: String? = nil, urls: [Int: String] = [:]) {
        self.paneID = paneID
        self.host = host
        self.cwd = cwd
        self.supabaseProjectID = supabaseProjectID
        self.stackID = stackID
        self.urls = urls
    }
}

enum Running {
    /// The local host's name, as `Host.local.name` spells it. Duplicated as a
    /// plain string so this file stays Foundation-only.
    static let localHostName = "localhost"

    // MARK: argv

    /// `lsof -nP -iTCP -sTCP:LISTEN -Fpn` — every listening TCP socket on a host
    /// with the pid holding it. `-n` and `-P` skip the DNS and service-name
    /// lookups, which are most of lsof's latency; `-F` is the machine-readable
    /// output `parseListeners` expects.
    ///
    /// ONE subprocess per host regardless of pane count — the same shape as the
    /// codex scan, and the reason this is not a per-pane probe (PR #67).
    static func lsofArgv() -> [String] { ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"] }

    // MARK: parsers

    /// Binds that a browser on that host can actually reach. A listener on one
    /// LAN interface (`192.168.1.5:7000`) is somebody else's business; the
    /// wildcard and loopback forms are the dev-server shapes.
    private static let localBinds: Set<String> =
        ["*", "0.0.0.0", "127.0.0.1", "localhost", "[::]", "[::1]", "::", "::1"]

    /// The subset of those that only the host's own browser can reach.
    private static let loopbackBinds: Set<String> =
        ["127.0.0.1", "localhost", "[::1]", "::1"]

    /// Parse `lsof -Fpn` output into (port, pid) pairs.
    ///
    /// `-F` prints one field per line: `p<pid>` opens a process block, then a
    /// `f<fd>`/`n<addr>` pair per socket — so the current pid has to be carried
    /// DOWN across the `f` lines, which macOS emits whether or not they were
    /// asked for. Malformed lines are skipped, never guessed at.
    ///
    /// IPv4 and IPv6 listeners on one port are two `n` lines with the same pid
    /// and must collapse to one row — but they can disagree about scope, and a
    /// `Set` of whole values would no longer fold them together now that scope
    /// is part of the value. So the merge is by `(port, pid)` and the scopes are
    /// ANDed: `127.0.0.1:7000` beside `[::]:7000` is ONE reachable row, because
    /// the wildcard bind is reachable and that is the truth about the port.
    static func parseListeners(_ lsof: String) -> [ListeningPort] {
        var loopback: [Pair: Bool] = [:]
        var current: Int?
        for line in lsof.split(separator: "\n", omittingEmptySubsequences: true) {
            let body = line.dropFirst()
            switch line.first {
            case "p":
                current = Int(body)
            case "n":
                guard let pid = current else { continue }
                let addr = String(body)
                guard let colon = addr.lastIndex(of: ":"),
                      let port = Int(addr[addr.index(after: colon)...])
                else { continue }
                let bind = String(addr[addr.startIndex..<colon])
                guard localBinds.contains(bind) else { continue }
                let key = Pair(port: port, pid: pid)
                loopback[key] = (loopback[key] ?? true) && loopbackBinds.contains(bind)
            default:
                continue
            }
        }
        return loopback
            .map { ListeningPort(port: $0.key.port, pid: $0.key.pid, loopbackOnly: $0.value) }
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// The merge key for `parseListeners` — the identity of a listener, without
    /// the bind scope that the merge is computing.
    private struct Pair: Hashable {
        let port: Int
        let pid: Int
    }

    /// Which pane each listening port belongs to, by walking the holding process
    /// up its parents until one of them is a pane's own shell pid — the same
    /// PID-ancestry join `TmuxModel.paneCodexIds` does for codex.
    ///
    /// `seen` is what makes the walk terminate: a malformed process table with a
    /// ppid cycle would otherwise spin forever on a background queue. A pid that
    /// reaches no pane is simply dropped — it is the machine's own listener
    /// (Chrome, Raycast, a Homebrew daemon), not this work's.
    static func portsByPane(
        listeners: [ListeningPort], panePidToId: [Int: String], ppids: [Int: Int]
    ) -> [String: [ListeningPort]] {
        var out: [String: Set<ListeningPort>] = [:]
        for listener in listeners {
            var current = listener.pid
            var seen = Set<Int>()
            while seen.insert(current).inserted {
                if let pane = panePidToId[current] {
                    out[pane, default: []].insert(listener)
                    break
                }
                guard let parent = ppids[current], parent > 1 else { break }
                current = parent
            }
        }
        // One port held by two pids in the same pane (a forked worker) is one
        // row; the lowest pid wins, which is the parent that owns the socket.
        return out.mapValues { listeners in
            Dictionary(grouping: listeners, by: \.port)
                .compactMap { $0.value.min { $0.pid < $1.pid } }
                .sorted { $0.port < $1.port }
        }
    }

    // MARK: the joins

    /// Longest `project_id` the Supabase CLI accepts, and the cap
    /// the remote-stack script applies before writing it.
    static let stackIDLimit = 60

    /// A branch name as the remote-stack script spells it when it creates that
    /// branch's stack on a remote host. Quoting the script verbatim, because this
    /// join silently degrades if the script changes and nothing else records the
    /// coupling (the remote-stack script):
    ///
    ///     # Supabase rejects a project_id with characters outside [a-zA-Z0-9_-].
    ///     safe = re.sub(r'[^a-zA-Z0-9_-]', '-', project)[:60]
    ///
    /// The failure mode is safe by construction: a missed join drops the container
    /// into *unclaimed*, it never lands on the wrong pane.
    static func stackID(branch: String) -> String {
        let safe = String(branch.map { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") ? ch : "-"
        })
        return String(safe.prefix(stackIDLimit))
    }

    /// Whether `pane` owns `container`.
    ///
    /// Two keys, and they are not interchangeable. The Supabase project id joins
    /// across hosts — that is what lets a local checkout claim the stack
    /// the remote-stack script built for its branch on `devbox` — and goes through
    /// `Docker.supabaseStackMatches`, which already handles the CLI's 40-character
    /// label truncation. The compose working dir is a path, and a path only means
    /// something on the machine it came from, so it joins on the pane's own host.
    static func claims(container: DockerContainer, pane: RunningPane, sameHost: Bool) -> Bool {
        for id in [pane.supabaseProjectID, pane.stackID].compactMap({ $0 }) {
            if Docker.supabaseStackMatches(label: container.supabaseProject, projectID: id) {
                return true
            }
        }
        guard sameHost, !container.composeWorkingDir.isEmpty, !pane.cwd.isEmpty else { return false }
        return Worktrees.isInside(path: container.composeWorkingDir, root: pane.cwd)
    }

    // MARK: the scheme rule

    /// The first `http(s)://<local-ish host>:<port>` URL in a pane's scrollback.
    ///
    /// Free and authoritative: the dev server printed the URL it is actually
    /// serving, so no probe can contradict it. `host` is matched too, because a
    /// remote pane prints its own hostname rather than localhost.
    static func urlFromScrollback(_ lines: [String], port: Int, host: String) -> String? {
        var hosts = ["localhost", "127\\.0\\.0\\.1", "0\\.0\\.0\\.0", "\\[::1\\]"]
        if host != localHostName, !host.isEmpty {
            hosts.append(NSRegularExpression.escapedPattern(for: host))
        }
        let pattern = "https?://(?:\(hosts.joined(separator: "|"))):\(port)(?![0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let found = Range(match.range, in: line) else { continue }
            return String(line[found])
        }
        return nil
    }

    /// Which scheme a port speaks. Neither default is safe here: SvelteKit on this
    /// Mac is HTTPS behind mkcert, while Supabase Studio is plain HTTP. So:
    /// (a) believe the URL the server printed, (b) on a miss ask the port once,
    /// (c) fall back to http. `probe` is injected and is the only step that does
    /// I/O, so the rule itself is asserted without a socket.
    static func scheme(scrollbackURL: String?, probe: () -> Bool) -> String {
        if let scrollbackURL { return scrollbackURL.hasPrefix("https://") ? "https" : "http" }
        return probe() ? "https" : "http"
    }

    /// The URL the ↗ button opens.
    ///
    /// A local pane's printed URL wins verbatim — the server said where it is.
    /// A remote pane's printed URL is used only for its SCHEME, because the name
    /// in it is that box's own idea of itself and means nothing here.
    ///
    /// `address` is what makes a remote row openable: an ssh alias is not a DNS
    /// name, so `http://devbox:54713` resolved nowhere. `HostAddress` turns the
    /// alias into a name this Mac can look up (`devbox1.example.ts.net`)
    /// or a tailnet IP, and that is what goes in the URL.
    static func serverURL(
        port: Int, host: String, address: String, scrollbackURL: String?, probe: () -> Bool
    ) -> String {
        if let scrollbackURL, host == localHostName { return scrollbackURL }
        let name = host == localHostName ? "localhost" : address
        let scheme = scheme(scrollbackURL: scrollbackURL, probe: probe)
        return "\(scheme)://\(HostAddress.urlHost(name)):\(port)"
    }

    /// Whether a browser on THIS Mac can reach that port at all.
    ///
    /// A port on this Mac always. A port on another box only when its bind is
    /// not loopback-only: `127.0.0.1:7000` on `devbox` answers `devbox`'s own
    /// browser and nothing else, so no name we could build would open it. Such a
    /// row says what it is (a `loopback` chip) and offers no ↗ — tunnelling it
    /// is a different feature.
    static func reachable(host: String, loopbackOnly: Bool) -> Bool {
        host == localHostName || !loopbackOnly
    }

    // MARK: aggregation

    /// Everything one pane owns: the ports its processes hold on its own host,
    /// plus the containers its directory owns on ANY host.
    static func resources(pane: RunningPane, scans: [RunningHostScan]) -> RunningSet {
        var out: [RunningResource] = []
        var unknowns: [String] = []

        if let scan = scans.first(where: { $0.host == pane.host }) {
            if scan.listeners == nil {
                unknowns.append(portsUnknownLine(host: pane.host))
            } else {
                for listener in scan.portsByPane[pane.paneID] ?? [] {
                    out.append(server(
                        listener, host: pane.host, address: scan.address, pane: pane))
                }
            }
        }

        for scan in scans.sorted(by: { $0.host < $1.host }) {
            guard case .containers(let all) = scan.docker else {
                unknowns.append(dockerUnknownLine(host: scan.host))
                continue
            }
            let mine = all.filter { claims(container: $0, pane: pane, sameHost: scan.host == pane.host) }
            for stack in stacks(mine) {
                out.append(container(
                    stack, host: scan.host, address: scan.address, paneID: pane.paneID,
                    dir: pane.cwd))
            }
        }
        return finish(out, unknowns: unknowns)
    }

    /// The union for a window or a session header: every child pane's own set,
    /// deduped. One container claimed by two panes of the same checkout is one
    /// row, attributed to the first pane in the list.
    static func resources(panes: [RunningPane], scans: [RunningHostScan]) -> RunningSet {
        var out: [RunningResource] = []
        var unknowns: [String] = []
        for pane in panes {
            let set = resources(pane: pane, scans: scans)
            out += set.resources
            unknowns += set.unknowns
        }
        return finish(out, unknowns: unknowns)
    }

    /// Containers no pane on any known host claims — the actual leak, and the
    /// thing the left WORKTREES section cannot catch, because a stack whose
    /// directory is gone has no worktree left to list.
    ///
    /// Containers only: a bare listening port never reaches this group. Once a
    /// dev server's pane dies its process is reparented to launchd, exactly like
    /// Chrome or ollama, so nothing separates a leak from the machine's own
    /// listeners except a name list. See the amendment to decision 4.
    static func unclaimed(scans: [RunningHostScan], panes: [RunningPane]) -> RunningSet {
        var out: [RunningResource] = []
        var unknowns: [String] = []
        for scan in scans.sorted(by: { $0.host < $1.host }) {
            guard case .containers(let all) = scan.docker else {
                unknowns.append(dockerUnknownLine(host: scan.host))
                continue
            }
            let loose = all.filter { c in
                !panes.contains { pane in
                    claims(container: c, pane: pane, sameHost: scan.host == pane.host)
                }
            }
            for stack in stacks(loose) {
                out.append(container(
                    stack, host: scan.host, address: scan.address, paneID: nil))
            }
        }
        return finish(out, unknowns: unknowns)
    }

    /// Dedupe by `key`, sort, and derive `known` — one place, so every entry
    /// point agrees on all three.
    private static func finish(
        _ resources: [RunningResource], unknowns: [String]
    ) -> RunningSet {
        var seen = Set<String>()
        let deduped = resources.filter { seen.insert($0.key).inserted }
        var seenLines = Set<String>()
        let lines = unknowns.filter { seenLines.insert($0).inserted }.sorted()
        return RunningSet(
            known: lines.isEmpty,
            resources: deduped.sorted { $0.sortKey < $1.sortKey },
            unknowns: lines)
    }

    private static func server(
        _ listener: ListeningPort, host: String, address: String, pane: RunningPane
    ) -> RunningResource {
        let port = listener.port
        let name = host == localHostName ? "localhost" : address
        let fallback = "http://\(HostAddress.urlHost(name)):\(port)"
        let url = reachable(host: host, loopbackOnly: listener.loopbackOnly)
            ? (pane.urls[port] ?? fallback)
            : nil
        let project = projectName(cwd: pane.cwd)
        return RunningResource(
            kind: .server(port: port),
            host: host,
            paneID: pane.paneID,
            label: project.isEmpty ? ":\(port)" : project,
            tooltip: "\(url ?? loopbackLine(host: host)) · \(pane.paneID) · pid \(listener.pid)",
            url: url,
            pid: listener.pid,
            dir: pane.cwd)
    }

    /// What a row says instead of a URL when nothing here can open it.
    static func loopbackLine(host: String) -> String { "bound to 127.0.0.1 on \(host)" }

    /// Containers grouped the way a person thinks about them: a Supabase stack is
    /// ONE thing — eight containers that only work together and share a port
    /// block — so it is one row named for the stack, not eight rows of
    /// `supabase_<service>_<stack>`. Anything without the label stands alone.
    ///
    /// Sorted by the name that will be shown, so the rail's order is stable.
    static func stacks(_ containers: [DockerContainer]) -> [(key: String, members: [DockerContainer])] {
        var order: [String] = []
        var grouped: [String: [DockerContainer]] = [:]
        for c in containers {
            let key = c.supabaseProject.isEmpty ? c.name : c.supabaseProject
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(c)
        }
        return order.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private static func container(
        _ stack: (key: String, members: [DockerContainer]), host: String, address: String,
        paneID: String?, dir: String = ""
    ) -> RunningResource {
        let allPorts = Set(stack.members.flatMap(\.ports)).sorted()
        let ports = allPorts.isEmpty ? "" : " · \(portsLabel(allPorts))"
        let age = stack.members.compactMap { $0.runningFor.isEmpty ? nil : $0.runningFor }.first
        let names = stack.members.count > 1
            ? "\(stack.members.count) containers"
            : stack.key
        let name = HostAddress.urlHost(host == localHostName ? "localhost" : address)
        let isStack = stack.members.contains { !$0.supabaseProject.isEmpty }
        let links = isStack
            ? supabaseLinks(stack.members, host: name)
            : allPorts.map { RunningLink(label: "", url: "http://\(name):\($0)", action: .open) }
        // What "Open in Browser" and the Stop confirm use: Studio for a stack,
        // never merely its lowest port — that is the API gateway or the database.
        let url = links.first { $0.action == .open }?.url
        return RunningResource(
            kind: .container(name: stack.key, ports: allPorts, count: stack.members.count),
            host: host,
            paneID: paneID,
            label: stack.key,
            tooltip: "\(names) on \(host)\(ports)" + (age.map { " · \($0)" } ?? ""),
            url: url,
            dir: dir,
            links: links,
            isSupabaseStack: isStack)
    }

    /// The services of a Supabase stack worth a link, in the order a person reaches
    /// for them. Keyed by the container-name prefix the CLI gives each service
    /// (`supabase_studio_<project>`); prefixes rather than splitting on `_`,
    /// because both service names (`pg_meta`) and project ids contain underscores.
    static let supabaseServices: [(prefix: String, label: String, action: RunningLink.Action)] = [
        ("supabase_studio_", "Studio", .open),
        ("supabase_kong_", "API", .open),
        ("supabase_db_", "DB", .copy),
        ("supabase_inbucket_", "Mail", .open),
        ("supabase_mailpit_", "Mail", .open),
    ]

    /// Which listed service `containerName` is, or nil for one not worth a link
    /// (`rest`, `auth`, `realtime`, …).
    static func supabaseService(containerName: String) -> (label: String, action: RunningLink.Action)? {
        supabaseServices.first { containerName.hasPrefix($0.prefix) }.map { ($0.label, $0.action) }
    }

    /// One link per listed service that publishes a port, each on ITS OWN port.
    /// A service publishing several (Mail: web, smtp, pop3) opens its lowest,
    /// which is the web UI. `host` is already URL-safe.
    static func supabaseLinks(_ members: [DockerContainer], host: String) -> [RunningLink] {
        var out: [RunningLink] = []
        for service in supabaseServices where !out.contains(where: { $0.label == service.label }) {
            guard let member = members.first(where: { $0.name.hasPrefix(service.prefix) }),
                  let port = member.ports.min() else { continue }
            let url = service.action == .copy
                ? "postgresql://postgres:postgres@\(host):\(port)/postgres"
                : "http://\(host):\(port)"
            out.append(RunningLink(label: service.label, url: url, action: service.action))
        }
        return out
    }

    /// The project a server belongs to — the checkout's own directory name, which
    /// is what the favicon is loaded from and what a reader recognizes.
    static func projectName(cwd: String) -> String {
        (Worktrees.normalize(cwd) as NSString).lastPathComponent
    }

    /// `:54321` for one port, `:54321–54329` for several. A Supabase stack
    /// publishes most of a block, and nine chips would crowd out the name.
    static func portsLabel(_ ports: [Int]) -> String {
        guard let low = ports.min(), let high = ports.max() else { return "" }
        return low == high ? ":\(low)" : ":\(low)–\(high)"
    }

    static func dockerUnknownLine(host: String) -> String { "Docker unavailable on \(host)" }
    static func portsUnknownLine(host: String) -> String { "ports not checked yet on \(host)" }

    /// One set for a whole popover's worth of groups, deduped. Unknown anywhere is
    /// unknown overall.
    static func combined(_ groups: [RunningGroup]) -> RunningSet {
        finish(groups.flatMap(\.set.resources), unknowns: groups.flatMap(\.set.unknowns))
    }

    /// The popover's sections, each only when non-empty: what the selection owns,
    /// split by what it IS, then what nothing owns. Unclaimed rows are the ones
    /// with no pane, whichever group they arrived in.
    static func sections(_ groups: [RunningGroup]) -> [(title: String, resources: [RunningResource])] {
        let all = combined(groups).resources
        let claimed = all.filter { $0.paneID != nil }
        let servers = claimed.filter { if case .server = $0.kind { return true } else { return false } }
        let containers = claimed.filter { if case .container = $0.kind { return true } else { return false } }
        let out: [(String, [RunningResource])] = [
            ("Dev servers", servers),
            ("Supabase", containers.filter(\.isSupabaseStack)),
            ("Docker", containers.filter { !$0.isSupabaseStack }),
            ("Unclaimed", all.filter { $0.paneID == nil }),
        ]
        return out.filter { !$0.1.isEmpty }.map { (title: $0.0, resources: $0.1) }
    }

    /// How many things the selection owns. Unclaimed rows do not count — a
    /// session header would otherwise read "18 running" on a machine whose
    /// sessions own nothing. Zero hides the drawer altogether.
    static func ownedCount(_ groups: [RunningGroup]) -> Int {
        combined(groups).resources.filter { $0.paneID != nil }.count
    }

    /// The drawer pill's title.
    static func toolbarTitle(_ groups: [RunningGroup]) -> String {
        let owned = ownedCount(groups)
        return owned == 0 ? "Running" : "\(owned) running"
    }

    // MARK: stop

    /// Everything `docker stop` must be given for a Stop on `resource`.
    ///
    /// A Supabase stack is eight containers that only work together, so stopping
    /// the one row you clicked would leave a half-stack that looks alive and
    /// answers nothing. The siblings are the containers sharing this one's
    /// project label on the same host — which is also why the confirm names every
    /// one of them rather than just the row.
    static func stopTargets(
        for resource: RunningResource, scans: [RunningHostScan]
    ) -> [DockerContainer] {
        guard case .container(let name, _, _) = resource.kind,
              let scan = scans.first(where: { $0.host == resource.host }),
              case .containers(let all) = scan.docker
        else { return [] }
        // The row IS the stack (see `stacks`), so its key names either a Supabase
        // project or a lone container.
        let members = all.filter { $0.supabaseProject == name || ($0.supabaseProject.isEmpty && $0.name == name) }
        return members.sorted { $0.name < $1.name }
    }

    /// The evidence the Stop confirm puts in front of a human.
    ///
    /// "Unclaimed" only means no tmux session MuxMaestro can see is sitting in
    /// that directory. A detached script or a cron job has no session anywhere and
    /// would read as unclaimed while being a live database — so this dialog does
    /// not decide anything. It lays out the host, every container it is about to
    /// stop, the port range, how long they have been up, and the fact that no
    /// session claims them, and lets the person judge.
    static func stopConfirm(
        for resource: RunningResource, targets: [DockerContainer], knownHosts: [String]
    ) -> (title: String, body: String) {
        var lines: [String] = ["Host: \(resource.host)"]
        switch resource.kind {
        case .server(let port):
            lines.append("Port: :\(port)")
            lines.append("URL: \(resource.url ?? loopbackLine(host: resource.host))")
            if let pid = resource.pid { lines.append("Process: pid \(pid)") }
        case .container(_, let ports, _):
            let names = targets.isEmpty ? [resource.label] : targets.map(\.name)
            lines.append("Containers: \(names.joined(separator: ", "))")
            let allPorts = targets.isEmpty ? ports : targets.flatMap(\.ports).sorted()
            if !allPorts.isEmpty { lines.append("Ports: \(portsLabel(allPorts))") }
            let age = targets.compactMap { $0.runningFor.isEmpty ? nil : $0.runningFor }.first
            if let age { lines.append("Up: \(age)") }
        }
        if resource.paneID == nil {
            let hosts = knownHosts.isEmpty ? [resource.host] : knownHosts
            lines.append("No session on \(hosts.joined(separator: ", ")) claims this.")
        }

        let title: String
        switch resource.kind {
        case .server(let port): title = "Stop the server on :\(port)?"
        case .container:
            title = targets.count > 1
                ? "Stop these \(targets.count) containers?"
                : "Stop \(resource.label)?"
        }
        return (title, lines.joined(separator: "\n"))
    }

    // MARK: chips

    /// The trailing pills on a row, reusing the worktree rows' chip type rather
    /// than inventing a second pill: the host when it is not this Mac. Ports are
    /// not chipped — every one is already spelled out in the row's links.
    static func chips(for resource: RunningResource) -> [WorktreeChip] {
        var out: [WorktreeChip] = []
        if resource.host != localHostName {
            out.append(WorktreeChip(
                text: resource.host, tooltip: "Runs on \(resource.host)", tone: .muted))
        }
        // A remote port bound to that box's own loopback. The row exists — the
        // server IS running — but ↗ is hidden, and this says why in one word.
        if case .server = resource.kind, resource.url == nil {
            out.append(WorktreeChip(
                text: "loopback", tooltip: loopbackLine(host: resource.host), tone: .muted))
        }
        return out
    }
}
