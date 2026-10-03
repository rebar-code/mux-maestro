import Foundation

/// One row the ⌘K switcher can jump to: a session, one of its windows, or a
/// pane inside a split window.
struct SwitcherEntry: Equatable {
    enum Target: Equatable {
        case session
        case window(Int)
        /// A pane in a split window. A single-pane window gets no pane entry —
        /// its window row already is that pane, as in the sidebar.
        case pane(window: Int, pane: TmuxPane)
    }

    let session: String
    let host: Host
    let target: Target
    /// The path-like string the fuzzy matcher and the row renderer both use:
    /// "session", "session/window" or "session/window/%3 zsh", with a "host/"
    /// prefix for a remote. The row's own name is the last segment, so
    /// `FuzzyMatch`'s basename bonus ranks a direct name hit first.
    let candidate: String
    /// Where the row's own name starts in `candidate` (in characters) — the
    /// prefix before it renders dimmed.
    let nameStart: Int
}

/// Pure candidate building + ranking for the ⌘K switcher. No AppKit, so it is
/// unit-testable against a hand-built tree.
enum SessionSwitcher {
    /// Every session, window and split-window pane, in tree order: each session
    /// followed by its windows, each window followed by its panes.
    static func entries(_ tree: [(host: Host, sessions: [TmuxSession])]) -> [SwitcherEntry] {
        var out: [SwitcherEntry] = []
        for (host, sessions) in tree {
            let hostPrefix = host.isLocal ? "" : "\(host.name)/"
            for s in sessions {
                let sessionPath = hostPrefix + s.name
                out.append(SwitcherEntry(
                    session: s.name, host: host, target: .session,
                    candidate: sessionPath, nameStart: hostPrefix.count))
                for w in s.windows {
                    let windowPath = "\(sessionPath)/\(w.name)"
                    out.append(SwitcherEntry(
                        session: s.name, host: host, target: .window(w.index),
                        candidate: windowPath, nameStart: sessionPath.count + 1))
                    guard w.panes.count > 1 else { continue }
                    for p in w.panes {
                        out.append(SwitcherEntry(
                            session: s.name, host: host, target: .pane(window: w.index, pane: p),
                            candidate: "\(windowPath)/\(p.id) \(p.command)",
                            nameStart: windowPath.count + 1))
                    }
                }
            }
        }
        return out
    }

    /// Rank `items` against `query`, best first, capped to `limit`. An empty query
    /// lists sessions only, in their given order — windows and panes appear once
    /// you type. Ties break toward shorter candidates (a session before its
    /// windows), then lexicographically.
    static func rank<T>(
        _ items: [T], query: String, limit: Int, entry: KeyPath<T, SwitcherEntry>
    ) -> [(item: T, indices: [Int])] {
        guard !query.isEmpty else {
            return items.lazy.filter { $0[keyPath: entry].target == .session }
                .prefix(limit).map { ($0, []) }
        }
        var scored: [(item: T, candidate: String, score: Int, indices: [Int])] = []
        for it in items {
            let candidate = it[keyPath: entry].candidate
            if let r = FuzzyMatch.match(query: query, candidate: candidate) {
                scored.append((it, candidate, r.score, r.indices))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.candidate.count != b.candidate.count { return a.candidate.count < b.candidate.count }
            return a.candidate < b.candidate
        }
        return scored.prefix(limit).map { ($0.item, $0.indices) }
    }

    /// Shortest query that searches scrollback. One or two characters appear in
    /// nearly every pane, so every pane would show up as a hit.
    static let minScrollbackQuery = 3

    /// The newest line in each pane's captured scrollback that contains `query`:
    /// one hit per pane, in `panes` order. Literal and smart-case, the same rules
    /// as ⇧⌘F's pane search. Empty below `minScrollbackQuery` characters.
    static func scrollbackHits(
        query: String, captures: [String: [String]], panes: [PaneSearchTarget]
    ) -> [PaneMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= minScrollbackQuery else { return [] }
        let options: String.CompareOptions =
            needle.contains(where: \.isUppercase) ? [.literal] : [.literal, .caseInsensitive]
        return panes.compactMap { pane in
            guard let lines = captures[pane.paneId] else { return nil }
            for index in lines.indices.reversed() {
                let ranges = PaneSearch.highlights(of: needle, in: lines[index], options: options)
                guard !ranges.isEmpty else { continue }
                let (text, kept) = PaneSearch.clamp(line: lines[index], highlights: ranges)
                return PaneMatch(pane: pane, lineNumber: index + 1, lineText: text, highlights: kept)
            }
            return nil
        }
    }
}
