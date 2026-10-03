import Foundation

/// One ripgrep hit for the Search palette (⌘⇧F): the absolute file path, the
/// 1-based line number, the matched line's text, and the byte ranges within that
/// text that matched (for highlighting). Pure data — no AppKit — so the service
/// can hand it back across threads and the core stays testable, the same shape
/// `GitDiffResult` takes for the Diff pane.
struct SearchMatch: Equatable {
    /// Absolute path to the file containing the match. rg is given the absolute
    /// `cwd` as its search root, so `data.path.text` comes back absolute already.
    let path: String
    /// 1-based line number of the match within the file.
    let lineNumber: Int
    /// The full text of the matched line (trailing newline stripped), already
    /// bounded by rg's `--max-columns` so one giant minified line can't blow up
    /// the UI. Empty when rg omitted the text (an over-long line).
    let lineText: String
    /// Half-open ranges of **UTF-8 byte offsets** into `lineText` that the query
    /// matched, for highlighting. Byte offsets (not character offsets) because
    /// that's what rg's submatch `start`/`end` are; the UI converts.
    let highlights: [Range<Int>]
}

/// The result of a repo search: the (capped) matches and whether the cap was hit,
/// plus whether ripgrep itself could run — false lets the palette show a friendly
/// "ripgrep not found" note instead of an ambiguous "no results".
struct CodeSearchResult: Equatable {
    let matches: [SearchMatch]
    /// True when more than `CodeSearch.maxMatches` matches were found and the rest
    /// were dropped — surfaced so a huge result set never silently truncates.
    let truncated: Bool
    /// False only when rg couldn't run at all (not installed / host unreachable).
    /// The pure `parse` always reports true; the service flips it on a probe.
    var rgAvailable: Bool = true
}

/// Matches for one file, in match order — the unit the palette renders as a
/// header row followed by its match rows.
struct SearchFileGroup: Equatable {
    let path: String
    let matches: [SearchMatch]
}

/// Pure construction of the ripgrep argv + parsing of its line-delimited JSON for
/// the Search palette. No process spawning here so every piece is unit-testable
/// against canned rg output (like `GitDiff` for the Diff pane). The backend is
/// isolated behind this enum so swapping ripgrep for a warm-index tool later is a
/// localized change.
enum CodeSearch {
    /// Per-file match cap (`rg --max-count`), so one file with thousands of hits
    /// can't crowd out every other file in the results.
    static let perFileCap = 50

    /// Total match cap across all files. Anything past this is dropped and
    /// `CodeSearchResult.truncated` is set — same discipline as
    /// `GitDiff.maxUntrackedFiles`.
    static let maxMatches = 500

    /// ripgrep argv for a literal, smart-case search rooted at `cwd`:
    ///  - `--json` — line-delimited JSON with submatch offsets (delimiter-proof
    ///    parsing + highlight ranges).
    ///  - `--smart-case` — case-insensitive unless the query has an uppercase char.
    ///  - `-F` — fixed-string (literal) so typed regex metacharacters are safe.
    ///  - `--max-count` — the per-file cap.
    ///  - `--max-columns 300` — don't return enormous (minified) lines verbatim.
    ///  - `--` — end of flags, so a query starting with `-` isn't read as one.
    static func searchArgv(cwd: String, query: String) -> [String] {
        ["--json", "--smart-case", "-F", "--max-count", "\(perFileCap)",
         "--max-columns", "300", "--", query, cwd]
    }

    /// Parse rg's line-delimited `--json` output into matches. Only `type:"match"`
    /// objects contribute; `begin`/`end`/`summary`/`context` lines and any
    /// unparseable line are skipped. Capped to `maxMatches` with a `truncated`
    /// flag. Always reports `rgAvailable: true` — the service decides otherwise.
    static func parse(_ jsonLines: String) -> CodeSearchResult {
        var matches: [SearchMatch] = []
        var truncated = false
        for raw in jsonLines.split(separator: "\n", omittingEmptySubsequences: true) {
            if matches.count >= maxMatches { truncated = true; break }
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "match",
                  let d = obj["data"] as? [String: Any],
                  let path = (d["path"] as? [String: Any])?["text"] as? String,
                  let lineNumber = d["line_number"] as? Int
            else { continue }

            let rawLine = (d["lines"] as? [String: Any])?["text"] as? String ?? ""
            let lineText = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine

            let subs = d["submatches"] as? [[String: Any]] ?? []
            let highlights: [Range<Int>] = subs.compactMap { sub in
                guard let start = sub["start"] as? Int, let end = sub["end"] as? Int,
                      start >= 0, start < end else { return nil }
                return start..<end
            }

            matches.append(SearchMatch(
                path: path, lineNumber: lineNumber, lineText: lineText, highlights: highlights))
        }
        return CodeSearchResult(matches: matches, truncated: truncated)
    }

    /// Bucket matches by file, preserving first-seen file order and match order
    /// within each file — what the palette renders (file header + its rows).
    static func group(_ matches: [SearchMatch]) -> [SearchFileGroup] {
        var order: [String] = []
        var byPath: [String: [SearchMatch]] = [:]
        for m in matches {
            if byPath[m.path] == nil { order.append(m.path) }
            byPath[m.path, default: []].append(m)
        }
        return order.map { SearchFileGroup(path: $0, matches: byPath[$0] ?? []) }
    }
}
