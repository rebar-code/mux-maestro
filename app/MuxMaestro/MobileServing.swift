import Foundation

// A thread's dev servers on the phone: the Running list as JSON, and the rules
// for publishing one local port on the tailnet with `tailscale serve`. A port
// on another host is first brought to this Mac by an ssh forward. Pure:
// `PhoneLink` owns the mappings and runs the commands. Foundation only, so the
// test target compiles it.

/// One local port this app published on the tailnet.
struct MobilePortMapping: Equatable {
    let port: Int
    /// The thread it was opened from.
    let thread: String
    let label: String
    /// The local server speaks https (a `mkcert` certificate).
    let https: Bool
    /// When the phone last asked for it. It closes `idleSeconds` after.
    var openedAt: Date
    /// The ssh alias of the host the server runs on, which an ssh forward
    /// brings to this Mac's loopback. nil when it runs on this Mac.
    var host: String?

    /// What `tailscale serve` was told to proxy to: how the mapping is known again.
    var target: String { MobileServing.target(port: port, https: https, forwarded: host != nil) }
}

enum MobileServing {
    /// Open mappings at once. Each one is a port every device on the tailnet
    /// can reach, so the number stays small.
    static let maxMappings = 5
    /// A mapping closes this long after the phone last opened it.
    static let idleSeconds: TimeInterval = 30 * 60

    enum Opened: Equatable {
        case ok
        /// The phone server's own port, or a privileged one.
        case refused
        /// `tailscale serve` already publishes the port for something else,
        /// or a remote port's number is in use on this Mac.
        case taken
        case limit
        case unavailable(String)
    }

    /// Who `tailscale serve` publishes a port for.
    enum Holder: Equatable { case nobody, ours, other }

    /// A port this app may publish at all, whatever runs on it: never a
    /// privileged port, never the phone server's own.
    static func allowed(port: Int, ownPort: Int?) -> Bool {
        (1024...65535).contains(port) && port != ownPort
    }

    /// Where a mapping sends its requests. The host is this constant and the
    /// port is the one Running reported: nothing the phone sent is in it.
    /// `localhost`, not `127.0.0.1`: a dev server often listens on `::1` only.
    /// A forwarded port is the other way round: the forward binds `127.0.0.1`
    /// and nothing else, so `localhost` could reach another server on `::1`.
    static func target(port: Int, https: Bool, forwarded: Bool = false) -> String {
        "\(https ? "https+insecure" : "http")://\(forwarded ? "127.0.0.1" : "localhost"):\(port)"
    }

    /// Publish `port` on the tailnet, HTTPS, on the same port. Tailnet only.
    static func serveOnArgv(port: Int, https: Bool, forwarded: Bool = false) -> [String] {
        ["serve", "--bg", "--https=\(port)", target(port: port, https: https, forwarded: forwarded)]
    }

    /// The ssh arguments that bring `port` of `host` to the same port of this
    /// Mac's loopback, and run nothing there. An ssh of its own: the app's
    /// control master goes away a minute after its last command, and a
    /// forward on it would go with it. `ExitOnForwardFailure` ends the ssh
    /// when the port cannot be bound; the keepalives end it when the host is
    /// away. `host` and `port` come from Running, never from the phone.
    static func forwardArgv(port: Int, host: String) -> [String] {
        [
            "-N", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(port):localhost:\(port)", host,
        ]
    }

    /// Where `tailscale serve` proxies `port`, when that is all it does with
    /// it: one handler, a proxy, tailnet only. nil for anything else. A mapping
    /// is this app's only when this is the exact target the app set.
    static func proxy(serveStatusJSON json: String, port: Int) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        let suffix = ":\(port)"
        for (name, on) in root["AllowFunnel"] as? [String: Any] ?? [:]
        where name.hasSuffix(suffix) && on as? Bool == true {
            return nil
        }
        var handlers: [Any] = []
        for (name, value) in root["Web"] as? [String: Any] ?? [:] where name.hasSuffix(suffix) {
            handlers += Array(((value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]).values)
        }
        guard handlers.count == 1 else { return nil }
        return (handlers[0] as? [String: Any])?["Proxy"] as? String
    }

    static func holder(serveStatusJSON json: String, port: Int) -> Holder {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return .other }
        let suffix = ":\(port)"
        // A port open to the internet is not a mapping of ours, whatever it proxies.
        for (name, on) in root["AllowFunnel"] as? [String: Any] ?? [:]
        where name.hasSuffix(suffix) && on as? Bool == true {
            return .other
        }
        var proxies: [String?] = []
        for (name, value) in root["Web"] as? [String: Any] ?? [:] where name.hasSuffix(suffix) {
            let entries = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            proxies += entries.values.map { ($0 as? [String: Any])?["Proxy"] as? String }
        }
        if proxies.isEmpty {
            // A raw TCP forward on the port has no web handler to compare.
            return (root["TCP"] as? [String: Any])?["\(port)"] == nil ? .nobody : .other
        }
        let mine = [target(port: port, https: false), target(port: port, https: true)]
        return proxies.allSatisfy { $0.map(mine.contains) ?? false } ? .ours : .other
    }

    /// The mappings a sweep closes: older than `idleSeconds`, or on a port
    /// that nothing runs on any more.
    static func stale(_ mappings: [MobilePortMapping], gone: Set<Int>, now: Date) -> [Int] {
        mappings.filter { gone.contains($0.port) || now.timeIntervalSince($0.openedAt) >= idleSeconds }
            .map(\.port).sorted()
    }

    /// The mappings whose server is gone, for the sweep: the thread left the
    /// tree, or what it runs is known and no longer has the port. A list that
    /// is not known yet, or a pane the scan could not find, proves nothing
    /// and closes nothing; the idle time still ends such a mapping.
    static func gone(
        _ mappings: [MobilePortMapping], snapshot: MobileSnapshot,
        running: (MobileThread) -> RunningSet?, ownPort: Int?
    ) -> Set<Int> {
        Set(mappings.filter { mapping in
            guard let thread = snapshot.thread(id: mapping.thread) else { return true }
            guard let set = running(thread), set.known else { return false }
            return mappable(in: set, ownPort: ownPort)[mapping.port] == nil
        }.map(\.port))
    }

    // MARK: Requests

    /// A JSON integer and nothing else: not a string, a bool or a fraction.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number)
        else { return nil }
        return (0...65535).contains(number.int64Value) ? number.intValue : nil
    }

    /// The `{"thread", "port"}` of an open request. No other field is read.
    static func openRequest(_ body: Data) -> (thread: String, port: Int)? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let thread = object["thread"] as? String, let port = integer(object["port"])
        else { return nil }
        return (thread, port)
    }

    static func closeRequest(_ body: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { integer($0["port"]) }
    }

    static func response(_ opened: Opened, port: Int, identity: MobileIdentity) -> MobileResponse {
        switch opened {
        case .ok: return .json(["port": port, "url": MobileTailnet.url(identity: identity, port: port)])
        case .refused: return .error(403, "refused")
        case .taken: return .error(409, "taken")
        case .limit: return .error(409, "limit")
        case .unavailable(let message): return .error(503, "unavailable", message: message)
        }
    }

    static func listJSON(_ mappings: [MobilePortMapping], identity: MobileIdentity) -> [String: Any] {
        [
            "mappings": mappings.sorted { $0.port < $1.port }.map { mapping -> [String: Any] in
                [
                    "port": mapping.port, "thread": mapping.thread, "label": mapping.label,
                    "url": MobileTailnet.url(identity: identity, port: mapping.port),
                ]
            },
            "max": maxMappings,
        ]
    }

    // MARK: Running

    /// One address of a running thing, as the phone lists it.
    struct Link: Equatable {
        let label: String
        let port: Int
        /// It is a web page. A database is not, and its address is never sent:
        /// that one is a connection string with a password in it.
        let open: Bool
        let https: Bool
        let mappable: Bool
    }

    /// Where a running thing is, for publishing it.
    enum Place: Equatable {
        case here
        /// On the host with this ssh alias: an ssh forward reaches it.
        case remote(String)
        /// A host name ssh would read as an option, or none at all.
        case nowhere

        /// The ssh alias, when there is one.
        var host: String? {
            if case .remote(let host) = self { return host }
            return nil
        }
    }

    static func place(of resource: RunningResource) -> Place {
        if resource.host == Running.localHostName { return .here }
        return resource.host.isEmpty || resource.host.hasPrefix("-") ? .nowhere : .remote(resource.host)
    }

    /// The addresses of `resource`. One is mappable only when it is a web page
    /// on a port this app may publish, on this Mac or on a host ssh reaches.
    static func links(of resource: RunningResource, ownPort: Int?) -> [Link] {
        let place = place(of: resource)
        var out: [Link] = resource.links.compactMap { link in
            guard let parts = URLComponents(string: link.url), let port = parts.port else { return nil }
            let scheme = parts.scheme?.lowercased() ?? ""
            let open = link.action == .open && (scheme == "http" || scheme == "https")
            return Link(
                label: link.label, port: port, open: open, https: scheme == "https",
                mappable: place != .nowhere && open && allowed(port: port, ownPort: ownPort))
        }
        // A server bound to another host's loopback has no address this Mac
        // can open, so Running gives it no link. The forward reaches it.
        if case .remote = place, case .server(let port) = resource.kind,
           !out.contains(where: { $0.port == port }) {
            out.append(Link(
                label: "", port: port, open: true, https: false,
                mappable: allowed(port: port, ownPort: ownPort)))
        }
        return out
    }

    /// The ports of `set` the phone may ask to publish, with what each is.
    /// `host` is nil for this Mac, or the ssh alias of the host it runs on.
    static func mappable(
        in set: RunningSet, ownPort: Int?
    ) -> [Int: (https: Bool, label: String, host: String?)] {
        var out: [Int: (https: Bool, label: String, host: String?)] = [:]
        for resource in set.resources {
            let host = place(of: resource).host
            for link in links(of: resource, ownPort: ownPort) where link.mappable && out[link.port] == nil {
                let label = link.label.isEmpty ? resource.label : "\(resource.label) \(link.label)"
                out[link.port] = (link.https, label, host)
            }
        }
        return out
    }

    /// The `/running` body: the Mac's Running drawer for one thread.
    static func runningJSON(_ set: RunningSet, ownPort: Int?) -> [String: Any] {
        var servers: [[String: Any]] = [], stacks: [[String: Any]] = [], containers: [[String: Any]] = []
        for resource in set.resources {
            let links = links(of: resource, ownPort: ownPort)
            var row: [String: Any] = [
                "key": resource.key, "label": resource.label, "host": resource.host,
                "local": resource.host == Running.localHostName,
            ]
            switch resource.kind {
            case .server(let port):
                // A port nothing here can open has no link, and is still listed.
                let link = links.first { $0.port == port }
                row["port"] = port
                row["https"] = link?.https ?? false
                row["mappable"] = link?.mappable ?? false
                servers.append(row)
            case .container(_, _, let count):
                row["count"] = count
                row["links"] = links.map { link -> [String: Any] in
                    ["label": link.label, "port": link.port, "open": link.open, "mappable": link.mappable]
                }
                if resource.isSupabaseStack { stacks.append(row) } else { containers.append(row) }
            }
        }
        return [
            "known": set.known, "unknowns": set.unknowns,
            "servers": servers, "stacks": stacks, "containers": containers,
        ]
    }
}
