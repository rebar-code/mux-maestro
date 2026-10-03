import Foundation

/// A `muxmaestro://` link — how the manager agent (and anything else that can
/// print a URL) points at a pane. `mux link` prints them; the app opens them from
/// LaunchServices, the manager rail and its toasts.
enum ThreadLink: Equatable {
    /// `muxmaestro://open?session=<name>&window=<n>&pane=<id>&host=<host>` —
    /// a fixed tmux address. Only `session` is required; `host` defaults to local.
    case open(session: String, window: Int?, pane: String?, host: String)
    /// `muxmaestro://thread/<claude-or-codex-session-id>` — whichever pane runs
    /// that conversation *now*, so the link survives the thread moving.
    case thread(id: String)
}

enum ThreadLinks {
    static let scheme = "muxmaestro"

    /// Where a link lands once resolved against the session tree.
    struct Target: Equatable {
        let host: String
        let session: String
        let window: Int?
        let pane: String?
    }

    /// Why a link could not be opened. Every case names what was asked for — a
    /// link that goes nowhere must say so, never do nothing.
    enum LinkError: Error, Equatable {
        case malformed(String)
        case unknownThread(String)
        case unknownSession(String, host: String)
        case unknownWindow(session: String, window: Int, host: String)
        case unknownPane(String, host: String)

        var message: String {
            switch self {
            case .malformed(let url):
                return "Not a MuxMaestro link: \(url)"
            case .unknownThread(let id):
                return "No pane is running thread \(id)"
            case .unknownSession(let session, let host):
                return "No session “\(session)”\(ThreadLinks.onHost(host))"
            case .unknownWindow(let session, let window, let host):
                return "No window \(session):\(window)\(ThreadLinks.onHost(host))"
            case .unknownPane(let pane, let host):
                return "No pane \(pane)\(ThreadLinks.onHost(host))"
            }
        }
    }

    // MARK: Build

    /// The one place link text is written. `mux link` builds the same shape in sh;
    /// `ThreadLinksTests` pins the two together.
    static func url(for link: ThreadLink) -> String {
        switch link {
        case .thread(let id):
            return "\(scheme)://thread/\(encode(id))"
        case .open(let session, let window, let pane, let host):
            var query = ["session=\(encode(session))"]
            if let window { query.append("window=\(window)") }
            if let pane { query.append("pane=\(encode(pane))") }
            if host != Host.local.name { query.append("host=\(encode(host))") }
            return "\(scheme)://open?" + query.joined(separator: "&")
        }
    }

    /// Link to the pane running a Claude or Codex conversation.
    static func thread(_ sessionId: String) -> String {
        url(for: .thread(id: sessionId))
    }

    // MARK: Parse

    /// Parse a `muxmaestro://` URL. Nil for another scheme, an unknown action, a
    /// missing session, a non-numeric window, or a thread id that isn't one.
    static func parse(_ string: String) -> ThreadLink? {
        guard let parts = URLComponents(string: string),
              parts.scheme?.lowercased() == scheme else { return nil }
        switch parts.host?.lowercased() {
        case "open":
            let items = parts.queryItems ?? []
            func value(_ name: String) -> String? {
                guard let v = items.first(where: { $0.name == name })?.value, !v.isEmpty
                else { return nil }
                return v
            }
            guard let session = value("session") else { return nil }
            var window: Int?
            if let raw = value("window") {
                guard let n = Int(raw), n >= 0 else { return nil }
                window = n
            }
            return .open(session: session, window: window, pane: value("pane"),
                         host: value("host") ?? Host.local.name)
        case "thread":
            let path = parts.path.split(separator: "/")
            guard path.count == 1, isSessionId(path[0]) else { return nil }
            return .thread(id: String(path[0]))
        default:
            return nil
        }
    }

    /// Claude and Codex ids are UUIDs; accept letters, digits and dashes only.
    static func isSessionId<S: StringProtocol>(_ s: S) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: Resolve

    /// Resolve `link` against the tree, keyed by host name as the sidebar holds it.
    /// A thread resolves to the first pane whose Claude or Codex id matches —
    /// local host first, then remotes by name, so the answer is stable.
    static func resolve(
        _ link: ThreadLink, in tree: [String: [TmuxSession]]
    ) -> Result<Target, LinkError> {
        switch link {
        case .thread(let id):
            let hosts = tree.keys.sorted { a, b in
                let aLocal = a == Host.local.name, bLocal = b == Host.local.name
                return aLocal != bLocal ? aLocal : a < b
            }
            for host in hosts {
                for session in tree[host] ?? [] {
                    for window in session.windows {
                        for pane in window.panes where matches(pane, id) {
                            return .success(Target(host: host, session: session.name,
                                                   window: window.index, pane: pane.id))
                        }
                    }
                }
            }
            return .failure(.unknownThread(id))

        case .open(let name, let window, let pane, let host):
            guard let session = (tree[host] ?? []).first(where: { $0.name == name }) else {
                return .failure(.unknownSession(name, host: host))
            }
            if let pane {
                guard let owner = session.windows.first(where: { w in
                    w.panes.contains { $0.id == pane }
                }), window == nil || window == owner.index else {
                    return .failure(.unknownPane(pane, host: host))
                }
                return .success(Target(host: host, session: name, window: owner.index, pane: pane))
            }
            if let window, !session.windows.contains(where: { $0.index == window }) {
                return .failure(.unknownWindow(session: name, window: window, host: host))
            }
            return .success(Target(host: host, session: name, window: window, pane: nil))
        }
    }

    // MARK: Render

    /// Every parseable `muxmaestro://` link in `text`, in order, with its UTF-16
    /// range (the unit `NSAttributedString` counts in). A link runs to the next
    /// whitespace; trailing sentence punctuation is left out of it.
    static func matches(in text: String) -> [(range: NSRange, link: ThreadLink)] {
        let ns = text as NSString
        return linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                var range = match.range
                while range.length > 0,
                      let last = ns.substring(with: NSRange(location: range.upperBound - 1, length: 1)).first,
                      trailingPunctuation.contains(last) {
                    range.length -= 1
                }
                guard let link = parse(ns.substring(with: range)) else { return nil }
                return (range, link)
            }
    }

    /// The short text a link renders as: `session:window` (prefixed `host/` for a
    /// remote), or `thread 3f2c9a1e…a0b1c2` joined by a no-break space so the
    /// label never wraps in the middle.
    static func label(for link: ThreadLink) -> String {
        switch link {
        case .thread(let id):
            return "thread\u{00A0}\(TmuxCommands.abbreviatedSessionId(id))"
        case .open(let session, let window, _, let host):
            let address = window.map { "\(session):\($0)" } ?? session
            return host == Host.local.name ? address : "\(host)/\(address)"
        }
    }

    // MARK: Internals

    private static let linkPattern = try! NSRegularExpression(
        pattern: "\(scheme)://[^\\s<>\"']+", options: [.caseInsensitive])

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]

    /// RFC 3986 unreserved characters — everything else in a value is escaped,
    /// including `&`, `=` and `+`, which `URLComponents` would leave alone.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func matches(_ pane: TmuxPane, _ id: String) -> Bool {
        [pane.claudeSessionId, pane.codexSessionId].contains {
            $0?.caseInsensitiveCompare(id) == .orderedSame
        }
    }

    fileprivate static func onHost(_ host: String) -> String {
        host == Host.local.name ? "" : " on \(host)"
    }
}
