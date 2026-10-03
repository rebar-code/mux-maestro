import Foundation

/// A file with uncommitted changes, shown as a row in the commit panel. `staged`
/// reflects the git index (the X column of porcelain status); toggling the row's
/// checkbox stages/unstages it.
struct ChangedFile: Equatable {
    let path: String
    /// The two-character porcelain code, e.g. "M ", " M", "??", "A ", "MM", "D ".
    let code: String
    var staged: Bool

    var isUntracked: Bool { code == "??" }

    /// A single letter summarizing the change, for the row glyph.
    var glyph: String {
        if isUntracked { return "A" }  // untracked reads as an addition
        let x = code.first ?? " "
        let y = code.dropFirst().first ?? " "
        let c = x != " " ? x : y
        switch c {
        case "M": return "M"
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "C": return "C"
        default: return "?"
        }
    }
}

/// Pure git plumbing for the commit panel: `git status --porcelain` parsing plus
/// argv builders for the write operations (add / unstage / commit / push). No
/// process spawning here so it is fully unit-testable (see GitCommitTests).
enum GitCommit {
    /// Parse `git status --porcelain=v1 -z` into changed files. The `-z` format is
    /// NUL-separated records, each "XY <path>"; a rename/copy (X is R/C) appends a
    /// second NUL-separated record with the origin path, which we skip.
    static func parseStatus(_ z: String) -> [ChangedFile] {
        let records = z.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        var out: [ChangedFile] = []
        var i = 0
        while i < records.count {
            let rec = records[i]
            // Minimum meaningful record is "XY p" (2 status chars + space + path).
            guard rec.count >= 4 else { i += 1; continue }
            let code = String(rec.prefix(2))
            let path = String(rec.dropFirst(3))
            // A rename/copy consumes the following record (the origin path).
            if let x = code.first, x == "R" || x == "C" { i += 1 }
            let first = code.first ?? " "
            let staged = first != " " && first != "?"
            out.append(ChangedFile(path: path, code: code, staged: staged))
            i += 1
        }
        return out
    }

    static func statusArgv(cwd: String) -> [String] {
        ["-C", cwd, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
    }
    static func addArgv(cwd: String, path: String) -> [String] {
        ["-C", cwd, "add", "--", path]
    }
    static func unstageArgv(cwd: String, path: String) -> [String] {
        ["-C", cwd, "reset", "-q", "HEAD", "--", path]
    }
    /// `git commit -m <subject>` plus a second `-m <body>` paragraph when a body is
    /// given. Commits only what is staged in the index.
    static func commitArgv(cwd: String, subject: String, body: String) -> [String] {
        var a = ["-C", cwd, "commit", "-m", subject]
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { a += ["-m", b] }
        return a
    }
    /// Resolves the tracking branch; fails (non-zero) when the branch has no
    /// upstream yet, which is how the panel decides whether to push with `-u`.
    static func upstreamArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
    }
    static func pushArgv(cwd: String, branch: String, setUpstream: Bool) -> [String] {
        setUpstream ? ["-C", cwd, "push", "-u", "origin", branch] : ["-C", cwd, "push"]
    }
}
