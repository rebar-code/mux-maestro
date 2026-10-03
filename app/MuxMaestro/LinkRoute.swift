import Foundation

/// Where a Cmd-clicked terminal link goes. Ghostty hands the app the matched
/// text (a URL, an absolute path, or a raw relative path — under tmux it has no
/// pwd to resolve against), and this decides what opens it.
enum LinkRoute: Equatable {
    /// `http(s)` — the default browser.
    case browser(URL)
    /// `muxmaestro://` — the app's own pane/thread jump.
    case thread(ThreadLink)
    /// A `muxmaestro://` link that does not parse. Must be reported, not dropped.
    case badLink(String)
    /// A path on the pane's host, with an optional `:line` suffix split off.
    case file(path: String, line: Int?)
    /// Any other scheme (`mailto:`, `ssh://`, …) — whatever the system maps it to.
    case system(URL)
    /// A relative path with no cwd to resolve it against, or nothing usable.
    case unresolved(String)

    /// Route `url` as Ghostty reported it. `cwd` is the pane's working directory
    /// (for relative paths); `home` expands a leading `~/`.
    static func route(_ url: String, cwd: String?, home: String) -> LinkRoute {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unresolved(text) }

        if let scheme = Self.scheme(of: text) {
            switch scheme {
            case "http", "https":
                guard let u = URL(string: text) else { return .unresolved(text) }
                return .browser(u)
            case ThreadLinks.scheme:
                guard let link = ThreadLinks.parse(text) else { return .badLink(text) }
                return .thread(link)
            case "file":
                guard let path = URL(string: text)?.path, !path.isEmpty else { return .unresolved(text) }
                return file(path)
            default:
                guard let u = URL(string: text) else { return .unresolved(text) }
                return .system(u)
            }
        }

        if text.hasPrefix("/") { return file(text) }
        if text.hasPrefix("~/") { return file(join(home, String(text.dropFirst(2)))) }
        guard let cwd, !cwd.isEmpty else { return .unresolved(text) }
        return file(join(cwd, text))
    }

    /// The lowercased scheme of `text`, or nil for a path. A scheme is letters
    /// then `:` (`mailto:` has no `//`); `C:`-style or `a/b:3` paths are not one.
    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[..<colon]
        guard head.count >= 2, let first = head.first, first.isLetter,
              head.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) })
        else { return nil }
        return head.lowercased()
    }

    /// A `.file` route, splitting a trailing `:line` or `:line:col`.
    private static func file(_ path: String) -> LinkRoute {
        var parts = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let n = Int(parts.last!), n > 0 {
            numbers.insert(n, at: 0)
            parts.removeLast()
        }
        return .file(path: parts.joined(separator: ":"), line: numbers.first)
    }

    /// `base` + `relative`, with `.`/`..` collapsed.
    private static func join(_ base: String, _ relative: String) -> String {
        URL(fileURLWithPath: base).appendingPathComponent(relative).standardizedFileURL.path
    }
}

/// When a mouse event must carry a synthetic Shift so ⌘-click reaches a link.
/// With mouse reporting on (tmux `mouse on`), Ghostty looks for links only while
/// Shift is held, and strips that Shift before matching ⌘. Without reporting it
/// matches ⌘ alone, and an added Shift would break the match.
enum LinkGesture {
    /// A move with no button held.
    /// While ⌘ is held, Ghostty can find the link. Once ⌘ is released over a
    /// link, one more Shift move lets Ghostty clear the hover.
    static func hoverAddsShift(command: Bool, overLink: Bool, mouseCaptured: Bool) -> Bool {
        mouseCaptured && (command || overLink)
    }

    /// A left press, and its release.
    /// Only a ⌘-click on a link; every other click and drag stays tmux's.
    static func clickAddsShift(command: Bool, overLink: Bool, mouseCaptured: Bool) -> Bool {
        mouseCaptured && command && overLink
    }

    /// Whether to clear Ghostty's last-looked-up cell before this hover. Ghostty
    /// skips the lookup when the cell is unchanged, even if the mods changed, so
    /// ⌘ pressed (or released) over a cell it checked before would do nothing.
    static func hoverResetsLookup(addsShift: Bool, modsChanged: Bool) -> Bool {
        addsShift && modsChanged
    }
}
