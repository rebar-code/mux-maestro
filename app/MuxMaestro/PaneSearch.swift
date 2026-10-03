import Foundation

/// Which corpus ⇧⌘F searches. ⇧⌘F always opens on `.repo` — ⌘K covers pane
/// scrollback — and the panel's switch flips to `.panes` for one search.
enum TreeSearchScope: String {
    /// Every pane's tmux scrollback, on every host.
    case panes
    /// The selected session's repo, via ripgrep.
    case repo
}

/// One pane in a scrollback sweep: its tmux identity plus the labels a result
/// row shows. Built from `list-panes -a`, so it spans every session on a host.
struct PaneSearchTarget: Equatable {
    /// tmux pane id, e.g. "%12" — stable across window/pane renumbering, which is
    /// why the capture and the jump both address the pane by id.
    let paneId: String
    let session: String
    let window: Int
    let windowName: String
    /// The pane's foreground command ("claude", "nvim", "zsh") — the fastest way
    /// to recognize a pane in a result list.
    let command: String
    let host: Host
}

/// One matching line inside a pane's captured scrollback.
struct PaneMatch: Equatable {
    let pane: PaneSearchTarget
    /// 1-based line number within the *captured* buffer (oldest captured line is
    /// 1). Not shown in the UI — scrollback offsets mean nothing to a reader —
    /// but it keeps matches ordered and makes the matcher testable.
    let lineNumber: Int
    let lineText: String
    /// Half-open ranges of UTF-8 byte offsets into `lineText` that matched, for
    /// highlighting. Byte offsets so pane hits and ripgrep hits render through
    /// the same code path.
    let highlights: [Range<Int>]
}

/// Matches for one pane, in match order — the unit the panel renders as a header
/// row followed by its match rows. Mirrors `SearchFileGroup`.
struct PaneMatchGroup: Equatable {
    let pane: PaneSearchTarget
    let matches: [PaneMatch]
}

/// The result of a pane sweep: the (capped) matches and whether the cap was hit.
struct PaneSearchResult: Equatable {
    let matches: [PaneMatch]
    /// True when more than `PaneSearch.maxMatches` matches were found and the
    /// rest were dropped — surfaced so a huge result set never silently
    /// truncates. Same discipline as `CodeSearchResult.truncated`.
    let truncated: Bool
}

/// Pure construction of the tmux argv + parsing/matching for the "All panes"
/// scope of the ⇧⌘F search. No process spawning here, so every piece is
/// unit-testable against canned tmux output — like `CodeSearch` for the repo
/// scope.
///
/// tmux has no server-wide grep, so the sweep is capture-then-match in Swift.
/// The cost that matters is round trips, not CPU: the whole capture is ONE tmux
/// invocation with a `display-message` marker before each `capture-pane`, so a
/// remote host costs two ssh hops (list + capture) no matter how many panes it
/// has.
enum PaneSearch {
    /// How far back in each pane's scrollback to look. 2000 lines is deep enough
    /// to hold the output you're trying to find again and shallow enough that a
    /// 40-pane server stays under a megabyte of capture.
    static let captureLines = 2000

    /// Per-pane match cap, so one pane looping the same error can't crowd out
    /// every other pane.
    static let perPaneCap = 20

    /// Total match cap across all panes on one host. Anything past this is
    /// dropped and `truncated` is set.
    static let maxMatches = 300

    /// Longest line kept for display, in characters. A terminal line is normally
    /// narrower than this; the cap only bites on a pane that printed a minified
    /// blob, where the rest could never be read in a one-line row anyway. Mirrors
    /// ripgrep's `--max-columns` for the repo scope.
    static let maxLineLength = 500

    /// Printed before each pane's capture so one blob of output can be split back
    /// into per-pane buffers. Two control characters — they carry no meaning to a
    /// shell or a program, so a pane printing this by accident is not a real
    /// concern, and `capture-pane -p` has already stripped escape sequences.
    ///
    /// It deliberately contains no `%`: tmux runs a display-message string
    /// through **strftime** before printing it, so a literal `%12` in the marker
    /// would be eaten as a time conversion. The pane id is appended by tmux
    /// itself, via `#{pane_id}` against the message's own `-t` target.
    static let marker = "\u{1}\u{2}mmpane:"

    /// argv listing every pane on the server, one per line, tab-separated:
    /// `pane_id`, session, window index, window name, foreground command.
    static func listPanesArgv() -> [String] {
        ["list-panes", "-a", "-F",
         "#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{pane_current_command}"]
    }

    /// Parse `list-panes -a` output into targets. Malformed lines are skipped
    /// rather than failing the sweep — one odd pane must not lose the rest.
    static func parsePanes(_ text: String, host: Host) -> [PaneSearchTarget] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 5, let window = Int(f[2]) else { return nil }
            return PaneSearchTarget(
                paneId: String(f[0]), session: String(f[1]), window: window,
                windowName: String(f[3]), command: String(f[4]), host: host)
        }
    }

    /// argv capturing every pane's last `lines` lines in ONE tmux invocation:
    /// `display-message -p -t <id> <marker>#{pane_id} ; capture-pane -p -S
    /// -<lines> -t <id>`, repeated. tmux runs the chained commands in order and
    /// concatenates their output, so the markers make the blob splittable.
    ///
    /// One failing command aborts the rest of a tmux command list, so a pane that
    /// dies between the listing and the capture costs every pane after it — see
    /// `TmuxService.searchPanes`, which re-lists and retries once.
    static func captureArgv(panes: [String], lines: Int = captureLines) -> [String] {
        var argv: [String] = []
        for id in panes {
            if !argv.isEmpty { argv.append(";") }
            argv += ["display-message", "-p", "-t", id, "\(marker)#{pane_id}"]
            argv += [";", "capture-pane", "-p", "-S", "-\(lines)", "-t", id]
        }
        return argv
    }

    /// Split a marked capture blob back into `pane id → lines`. Output before the
    /// first marker (a tmux warning, say) is discarded.
    static func parseCaptures(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        var buffer: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(marker) {
                if let current { out[current] = buffer }
                current = String(line.dropFirst(marker.count))
                buffer = []
            } else if current != nil {
                buffer.append(String(line))
            }
        }
        if let current { out[current] = buffer }
        return out
    }

    /// Match `query` against the captured buffers, in `panes` order. Literal and
    /// smart-case (an uppercase letter in the query makes it case-sensitive) —
    /// the same rules ripgrep applies to the repo scope, so one search field
    /// behaves the same either way. The caps default to the sweep's; a search
    /// of one pane passes its own.
    static func match(
        query: String, captures: [String: [String]], panes: [PaneSearchTarget],
        perPaneCap: Int = PaneSearch.perPaneCap, maxMatches: Int = PaneSearch.maxMatches
    ) -> PaneSearchResult {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return PaneSearchResult(matches: [], truncated: false) }
        let options: String.CompareOptions =
            needle.contains(where: \.isUppercase) ? [.literal] : [.literal, .caseInsensitive]

        var out: [PaneMatch] = []
        var truncated = false
        for pane in panes {
            guard let lines = captures[pane.paneId] else { continue }
            var perPane = 0
            for (index, line) in lines.enumerated() {
                guard perPane < perPaneCap else { break }
                let ranges = highlights(of: needle, in: line, options: options)
                guard !ranges.isEmpty else { continue }
                guard out.count < maxMatches else {
                    return PaneSearchResult(matches: out, truncated: true)
                }
                let (text, kept) = clamp(line: line, highlights: ranges)
                out.append(PaneMatch(
                    pane: pane, lineNumber: index + 1, lineText: text, highlights: kept))
                perPane += 1
            }
            if perPane >= perPaneCap { truncated = true }
        }
        return PaneSearchResult(matches: out, truncated: truncated)
    }

    /// Trim an over-long line to `maxLineLength` characters, dropping highlights
    /// that fall past the cut so no range can point outside the stored text.
    static func clamp(
        line: String, highlights: [Range<Int>]
    ) -> (String, [Range<Int>]) {
        guard line.count > maxLineLength else { return (line, highlights) }
        let text = String(line.prefix(maxLineLength))
        let bytes = text.utf8.count
        return (text, highlights.filter { $0.upperBound <= bytes })
    }

    /// Every occurrence of `needle` in `line`, as UTF-8 byte ranges.
    static func highlights(
        of needle: String, in line: String, options: String.CompareOptions
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var from = line.startIndex
        while let found = line.range(of: needle, options: options, range: from..<line.endIndex) {
            let lower = line.utf8.distance(from: line.utf8.startIndex, to: found.lowerBound)
            let upper = line.utf8.distance(from: line.utf8.startIndex, to: found.upperBound)
            ranges.append(lower..<upper)
            guard found.upperBound > from, found.upperBound < line.endIndex else { break }
            from = found.upperBound
        }
        return ranges
    }

    /// Group matches by pane, preserving first-appearance order. Mirrors
    /// `CodeSearch.group`.
    static func group(_ matches: [PaneMatch]) -> [PaneMatchGroup] {
        var order: [String] = []
        var byPane: [String: [PaneMatch]] = [:]
        for m in matches {
            if byPane[m.pane.paneId] == nil { order.append(m.pane.paneId) }
            byPane[m.pane.paneId, default: []].append(m)
        }
        return order.compactMap { id in
            guard let ms = byPane[id], let first = ms.first else { return nil }
            return PaneMatchGroup(pane: first.pane, matches: ms)
        }
    }
}
