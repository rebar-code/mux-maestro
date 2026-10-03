import Foundation

/// Pure fuzzy subsequence matching + ranking for the ⌘P quick-open palette.
/// No AppKit so it's unit-testable. Modeled on how Zed / VS Code rank files:
/// a candidate matches when the query's characters appear in order (case-
/// insensitive); the score rewards matches at word boundaries, contiguous runs,
/// and the basename (filename) over the directory prefix, so typing a filename
/// floats that file to the top.
enum FuzzyMatch {
    /// A successful match: a score (higher is better) and the character indices in
    /// the candidate that matched the query, for highlighting.
    struct Result: Equatable {
        let score: Int
        let indices: [Int]
    }

    /// Match `query` against `candidate`. Returns nil when `query` isn't an
    /// (in-order, case-insensitive) subsequence of `candidate`. An empty query
    /// matches everything with score 0 and no indices.
    static func match(query: String, candidate: String) -> Result? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return Result(score: 0, indices: []) }
        let c = Array(candidate)
        guard c.count >= q.count else { return nil }
        let lastSlash = c.lastIndex(of: "/") ?? -1

        var qi = 0
        var indices: [Int] = []
        var score = 0
        var prev = -2
        for ci in 0..<c.count {
            guard qi < q.count else { break }
            guard lower(c[ci]) == q[qi] else { continue }
            if ci == prev + 1 {
                score += 18                          // contiguous run — the strongest signal
            } else if ci == 0 || isBoundary(c[ci - 1]) {
                score += 12                          // word boundary (path sep, _, -, ., space)
            } else if c[ci].isUppercase {
                score += 8                           // camelCase boundary
            } else {
                score += 1                           // mid-word
            }
            if ci > lastSlash { score += 4 }         // inside the basename
            if prev >= 0 { score -= (ci - prev - 1) }  // penalize gaps between matches
            indices.append(ci)
            prev = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer tighter matches in shorter candidates.
        score += max(0, 12 - (c.count - q.count) / 4)
        return Result(score: score, indices: indices)
    }

    /// Rank `candidates` against `query`, best first, capped to `limit`. An empty
    /// query returns the first `limit` candidates unscored (their natural order).
    /// Ties break toward shorter paths, then lexicographically — stable + testable.
    static func rank(
        query: String, candidates: [String], limit: Int
    ) -> [(path: String, indices: [Int])] {
        guard !query.isEmpty else {
            return candidates.prefix(limit).map { ($0, []) }
        }
        var scored: [(path: String, score: Int, indices: [Int])] = []
        for cand in candidates {
            if let r = match(query: query, candidate: cand) {
                scored.append((cand, r.score, r.indices))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        return scored.prefix(limit).map { ($0.path, $0.indices) }
    }

    private static func lower(_ ch: Character) -> Character { ch.lowercased().first ?? ch }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == "/" || ch == "_" || ch == "-" || ch == "." || ch == " "
    }
}
