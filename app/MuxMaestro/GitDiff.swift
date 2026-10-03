import Foundation

/// The structured result of computing a working directory's diff (M14): the
/// combined unified-diff patch the renderer consumes, plus the context the pane's
/// header + empty/error states need. Pure data — no AppKit — so the service can
/// hand it back across threads and the pure core stays testable.
struct GitDiffResult: Equatable {
    /// The combined unified patch (tracked `git diff HEAD` + synthesized
    /// untracked-file additions), ready to feed the renderer. Empty for a clean
    /// repo or a non-repo cwd.
    let patch: String
    /// The current branch (`rev-parse --abbrev-ref HEAD`), e.g. `main`. Empty for
    /// an empty repo (no HEAD) or a non-repo cwd.
    let branch: String
    /// False when `cwd` isn't inside a git work tree — the pane shows a friendly
    /// "not a git repository" instead of an empty diff.
    let isRepo: Bool
    /// True for a repo with no commits yet (no HEAD): the tracked diff is taken
    /// against the empty tree form rather than `HEAD`.
    let isEmptyRepo: Bool
    /// How many untracked files were dropped past `GitDiff.maxUntrackedFiles`
    /// (0 normally) — surfaced so a huge untracked tree can't silently truncate.
    let untrackedDropped: Int
}

/// Pure construction of the git argv + synthesis of untracked-file patches for
/// the M14 Diff pane. No process spawning here so every piece is unit-testable
/// against a `FakeRunner` (like `BrowserPorts` / `FileTransfer`): the argv
/// builders return the exact command, and `untrackedFilePatch` / `combine`
/// produce the patch string from canned contents.
///
/// Scope: **all uncommitted changes vs HEAD** (`git diff HEAD` — staged +
/// unstaged tracked changes) **plus untracked files rendered as additions**, in
/// one refreshable patch. Untracked patches are built in Swift (not
/// `git diff --no-index`) so we never hit the runner's non-zero-exit limitation
/// and never mutate the index (no `git add -N`).
enum GitDiff {
    /// Cap on how many untracked files are synthesized into the patch, so a repo
    /// with thousands of untracked files (a fresh `node_modules` slip-through,
    /// build output) can't wedge the pane. Anything past this is dropped and the
    /// count is surfaced via `GitDiffResult.untrackedDropped`.
    static let maxUntrackedFiles = 100

    /// Cap on a single untracked file's contents (bytes) before it's truncated in
    /// the synthesized patch, so one huge blob can't blow up the renderer.
    static let maxUntrackedFileBytes = 256 * 1024

    // MARK: Repo probes

    /// argv to test whether `cwd` is inside a git work tree:
    /// `git -C <cwd> rev-parse --is-inside-work-tree`. Prints `true` and exits 0
    /// inside a work tree; exits non-zero (→ nil from the runner) when `cwd` is
    /// not a repo at all.
    static func isRepoArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--is-inside-work-tree"]
    }

    /// argv that succeeds (exit 0) only when the repo has at least one commit
    /// (a resolvable HEAD): `git -C <cwd> rev-parse --verify -q HEAD`. `-q`
    /// silences output; a repo with no commits exits non-zero (→ nil), which the
    /// caller reads as "empty repo, diff against the empty tree".
    static func hasHEADArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--verify", "-q", "HEAD"]
    }

    /// argv for the current branch name (the header's left half):
    /// `git -C <cwd> rev-parse --abbrev-ref HEAD` → e.g. `main`.
    static func branchHeaderArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
    }

    // MARK: Tracked diff

    /// The normal tracked diff against HEAD: `git -C <cwd> --no-pager diff
    /// --no-color HEAD`. Plain `git diff` exits **0** even with changes (only
    /// `--exit-code`/`--no-index` exit non-zero), so it's compatible with the
    /// runner (which returns nil on a non-zero exit). `--no-pager` defeats a
    /// configured pager; `--no-color` keeps the output a clean unified diff.
    static func headDiffArgv(cwd: String) -> [String] {
        ["-C", cwd, "--no-pager", "diff", "--no-color", "HEAD"]
    }

    /// The empty-repo form (no commits yet, so `HEAD` doesn't resolve):
    /// `git -C <cwd> --no-pager diff --no-color` shows the staged + unstaged
    /// changes against the (empty) index instead of HEAD.
    static func noHeadDiffArgv(cwd: String) -> [String] {
        ["-C", cwd, "--no-pager", "diff", "--no-color"]
    }

    /// The tracked-diff argv to run, choosing the HEAD form vs the empty-repo form
    /// from a prior `hasHEAD` probe.
    static func trackedDiffArgv(cwd: String, hasHEAD: Bool) -> [String] {
        hasHEAD ? headDiffArgv(cwd: cwd) : noHeadDiffArgv(cwd: cwd)
    }

    // MARK: Untracked files

    /// argv to list untracked files (respecting `.gitignore`), NUL-separated so
    /// paths with spaces/newlines survive: `git -C <cwd> ls-files --others
    /// --exclude-standard -z`.
    static func untrackedListArgv(cwd: String) -> [String] {
        ["-C", cwd, "ls-files", "--others", "--exclude-standard", "-z"]
    }

    /// Parse the NUL-separated `ls-files -z` output into paths (relative to cwd),
    /// capped to `maxUntrackedFiles`. Returns the kept paths plus how many were
    /// dropped past the cap so the caller can surface it.
    static func parseUntrackedList(_ output: String) -> (paths: [String], dropped: Int) {
        let all = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard all.count > maxUntrackedFiles else { return (all, 0) }
        return (Array(all.prefix(maxUntrackedFiles)), all.count - maxUntrackedFiles)
    }

    /// Cap a file's contents to `maxUntrackedFileBytes` on a UTF-8 boundary,
    /// returning the (possibly truncated) contents and whether truncation
    /// happened so the caller can log it.
    static func capContents(_ contents: String) -> (contents: String, truncated: Bool) {
        guard contents.utf8.count > maxUntrackedFileBytes else { return (contents, false) }
        let prefix = Array(contents.utf8.prefix(maxUntrackedFileBytes))
        return (String(decoding: prefix, as: UTF8.self), true)
    }

    /// Synthesize a unified-diff "added file" block for an untracked file, the way
    /// `git diff` would render a brand-new file: a `diff --git` header, the
    /// `new file mode 100644` marker, then a single `@@ -0,0 +1,N @@` hunk with
    /// every line prefixed `+`.
    ///
    /// Edge cases match git:
    ///  - **Empty file** ⇒ header + `new file mode` only, no hunk (nothing to add).
    ///  - **No trailing newline** ⇒ the `\ No newline at end of file` marker after
    ///    the last `+` line.
    ///
    /// `path` is used verbatim as the `a/`/`b/` path (it's the repo-relative path
    /// from `ls-files`).
    static func untrackedFilePatch(path: String, contents: String) -> String {
        var out = "diff --git a/\(path) b/\(path)\n"
        out += "new file mode 100644\n"
        if contents.isEmpty { return out }  // empty new file: no hunk, matching git

        let hasTrailingNewline = contents.hasSuffix("\n")
        var lines = contents.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }  // drop the empty tail a final \n yields

        out += "--- /dev/null\n"
        out += "+++ b/\(path)\n"
        out += "@@ -0,0 +1,\(lines.count) @@\n"
        for line in lines { out += "+\(line)\n" }
        if !hasTrailingNewline { out += "\\ No newline at end of file\n" }
        return out
    }

    /// Concatenate the tracked patch and the synthesized untracked patches into
    /// one patch string, tracked first then untracked in list order. Each piece is
    /// newline-terminated so the next `diff --git` header always starts its own
    /// line; empty pieces (no tracked changes / no untracked files) are skipped.
    static func combine(tracked: String, untracked: [String]) -> String {
        var pieces: [String] = []
        if !tracked.isEmpty { pieces.append(tracked) }
        pieces.append(contentsOf: untracked.filter { !$0.isEmpty })
        return pieces.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
    }

    // MARK: Helpers

    /// Join a repo-relative path onto `cwd` for an absolute path `cat` can read
    /// (the relative path comes from `git -C <cwd> ls-files`). Normalizes a
    /// trailing slash on `cwd` so the result never has a doubled separator.
    static func joinPath(cwd: String, relative: String) -> String {
        let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return "\(base)/\(relative)"
    }

    /// Number of files the patch touches — counted from the `diff --git ` header
    /// lines — for the pane's "branch · N files changed" header.
    static func changedFileCount(in patch: String) -> Int {
        patch.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.count
    }
}
