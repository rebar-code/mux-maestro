import Foundation

/// What kind of checkout a directory sits in.
///
/// The distinction that matters is **who reaps it**. A pool worktree is leased and
/// something sweeps it; an unmanaged one has never been swept by anything, which is
/// how 46 of them accumulated 67.1 GB on this machine before anyone looked.
enum WorktreeKind: String, Equatable {
    /// The repo's own checkout (`--git-dir` == `--git-common-dir`).
    case main
    /// A linked worktree under `~/.treehouse/` — leased from the pool.
    case pool
    /// A linked worktree anywhere else. Nothing reaps these.
    case unmanaged
}

/// Whether a worktree holds work that exists nowhere else.
enum WorktreeWork: Equatable {
    /// Not computed yet — the slow sweep hasn't reached this tree. Never means
    /// "safe to delete"; it means "we don't know".
    case unknown
    /// Clean, and every commit is already in the remote default branch.
    case none
    /// Dirty (beyond `supabase/config.toml`) or holding commits the remote default
    /// branch has never seen.
    case unique
}

/// One entry from `git worktree list --porcelain`.
struct WorktreeEntry: Equatable {
    /// Absolute path to the worktree root.
    let path: String
    /// Short branch name, or "" when the head is detached.
    let branch: String
    /// True for the repo's own checkout (always the first record git prints).
    let isMain: Bool
    let kind: WorktreeKind
    /// git registered this worktree but its directory is gone (`prunable <reason>`
    /// in the porcelain listing). A bookkeeping leftover, not a tree on disk —
    /// counting it inflates the pile with entries `git worktree prune` would clear.
    var isPrunable = false

    /// The row label — the directory name, which is what a worktree is recognized
    /// by (`mux-maestro-hdr`, `5`), not the whole path.
    var name: String { (path as NSString).lastPathComponent }
}

/// The sidebar chip for a session working inside a linked worktree. Pure data
/// (a symbol *name*, not an image) so it lives beside the rest of the pure core;
/// `glyph` / `label` mirror `AttentionStatus.dot` / `.label`.
struct WorktreeBadge: Equatable {
    let kind: WorktreeKind
    let work: WorktreeWork

    /// nil for a main checkout: the overwhelmingly common case, and nothing about
    /// it is worth a chip.
    init?(kind: WorktreeKind, work: WorktreeWork) {
        guard kind != .main else { return nil }
        self.kind = kind
        self.work = work
    }

    var glyph: String { "⑂" }

    /// What the session row's chip actually shows. The sidebar is ~220pt wide and
    /// already truncates window names, so the row gets the compact form — the fact
    /// that this is a worktree, plus the alarm — and the kind + full state live in
    /// `tooltip`. `label` (the long form) still goes into the row's diff string.
    var chipText: String { work == .unique ? "\(glyph) work" : glyph }

    /// Short, subtle text after the session name — the same register as
    /// `AttentionStatus.label`. The `·work` suffix is the part that matters: it
    /// marks the trees that can't just be deleted.
    var label: String {
        let base = kind == .pool ? "pool" : "worktree"
        return work == .unique ? "\(base) ·work" : base
    }

    /// SF Symbol for the chip's leading icon.
    var symbolName: String { "arrow.triangle.branch" }

    /// True when the chip should read as "look at me" (amber) rather than muted.
    var isAlert: Bool { work == .unique }

    var tooltip: String {
        let where_ = kind == .pool
            ? "Leased treehouse worktree"
            : "Unmanaged worktree — nothing reaps this"
        switch work {
        case .unknown: return "\(where_). Unique work not checked yet."
        case .none: return "\(where_). No uncommitted or unpushed work."
        case .unique: return "\(where_). Holds work that exists nowhere else."
        }
    }
}

/// Pure git plumbing for worktree awareness: argv builders, output parsers, and
/// the classifier. No process spawning here, so every rule the 2026-08-19 sweep
/// taught us is asserted directly (see WorktreesTests) — same shape as `GitDiff`.
///
/// MuxMaestro **shows and offers; it does not reap.** Nothing in here removes a
/// worktree, releases a lease, or deletes anything. If this and `treehouse-tidy`
/// ever disagree, the script wins.
enum Worktrees {
    // MARK: Cadence

    /// The slow sweep's per-repo cadence. State 3 runs `git fetch`, so this is
    /// network I/O; 10 minutes between sweeps of a repo, backing off to an hour
    /// when git fails. Classification itself is cached forever and never re-runs.
    static let scanBaseInterval: TimeInterval = 600
    static let scanMaxInterval: TimeInterval = 3600

    /// The one path whose modification never means "this tree holds work":
    /// `worktree-supabase.sh` rewrites it in every worktree by design. Counting it
    /// is the bug that made `treehouse-tidy` exit 0 for 11 nights and release
    /// nothing.
    static let ignoredDirtyPaths: Set<String> = ["supabase/config.toml"]

    // MARK: argv builders

    /// `git -C <cwd> rev-parse --path-format=absolute --git-dir` — this checkout's
    /// own git dir. For a linked worktree it's `<common>/worktrees/<name>`.
    static func gitDirArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-dir"]
    }

    /// `git -C <cwd> rev-parse --path-format=absolute --git-common-dir` — the repo's
    /// shared git dir, identical across every worktree of the same repo. Differing
    /// from `--git-dir` is what makes a directory a linked worktree, and it doubles
    /// as the repo key the sweep is scheduled by.
    static func commonDirArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"]
    }

    /// `git -C <cwd> worktree list --porcelain`. Porcelain (not the columnar
    /// default) so paths containing spaces survive parsing.
    static func listArgv(cwd: String) -> [String] {
        ["-C", cwd, "worktree", "list", "--porcelain"]
    }

    /// `git -C <cwd> symbolic-ref --quiet --short refs/remotes/origin/HEAD` →
    /// `origin/main`. Exits non-zero (→ nil) when origin/HEAD was never set, which
    /// is common on clones made by tooling; `fallbackDefaultBranches` covers it.
    static func defaultBranchArgv(cwd: String) -> [String] {
        ["-C", cwd, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]
    }

    /// Tried in order when `origin/HEAD` is unset. Each is probed with
    /// `verifyRefArgv` so a nonexistent ref is never fed to `git cherry`.
    static let fallbackDefaultBranches = ["origin/main", "origin/master"]

    /// `git -C <cwd> rev-parse --verify -q <ref>^{commit}` — succeeds only when the
    /// ref resolves, so an unset default branch fails loudly instead of silently
    /// producing an empty cherry list (which would read as "no unique work").
    static func verifyRefArgv(cwd: String, ref: String) -> [String] {
        ["-C", cwd, "rev-parse", "--verify", "-q", "\(ref)^{commit}"]
    }

    /// `git -C <cwd> fetch --quiet --prune origin`. Required before `cherry`.
    ///
    /// `--prune` is not optional. Without it, branches deleted server-side leave
    /// their remote-tracking refs behind and the tree reads as ahead of work that
    /// has actually shipped: on this machine `.worktrees/ai-chat` looked 17 commits
    /// ahead and `tool-requests` 10, and all 27 patches were already in prod. A
    /// plain fetch refreshes what exists and says nothing about what was deleted.
    static func fetchArgv(cwd: String) -> [String] {
        ["-C", cwd, "fetch", "--quiet", "--prune", "origin"]
    }

    /// `git -C <cwd> cherry <base>` — compares HEAD to `base` **by patch content**,
    /// printing `+ <sha>` for commits with no equivalent upstream and `- <sha>` for
    /// ones already applied there.
    ///
    /// Deliberately not `merge-base --is-ancestor` and not PR state. Both cheap
    /// signals lied on 2026-08-19 in opposite directions: stale refs said merged
    /// work was unpushed, while six branches with a MERGED PR still held commits
    /// prod had never seen. Patch content was the only signal that told the truth.
    static func cherryArgv(cwd: String, base: String) -> [String] {
        ["-C", cwd, "cherry", base]
    }

    /// `git -C <cwd> rev-list --count <base>..HEAD` — how many commits the tree is
    /// ahead, **merge commits included**.
    ///
    /// This exists because `git cherry` silently skips merge commits: it emits one
    /// line per non-merge commit and nothing at all for a merge. A branch that is
    /// ahead only by merges therefore produces empty cherry output, which reads as
    /// "nothing unique here" — i.e. safe to delete. That is not an exotic shape.
    /// This project integrates with merge and never rebases, so "ahead only by
    /// `Merge main into feature`" is the *normal* state of a long-lived branch.
    /// Verified on a scratch repo: 1 commit ahead, zero cherry lines.
    static func aheadCountArgv(cwd: String, base: String) -> [String] {
        ["-C", cwd, "rev-list", "--count", "\(base)..HEAD"]
    }

    // MARK: Classification

    /// Which kind of checkout `path` is, from its two git dirs.
    ///
    /// A path is a **linked worktree** iff its `--git-dir` differs from its
    /// `--git-common-dir`. Returns nil when either is empty (not a repo). `home` is
    /// injected so tests never read `$HOME`.
    static func classify(
        gitDir: String, commonDir: String, path: String, home: String
    ) -> WorktreeKind? {
        let git = normalize(gitDir), common = normalize(commonDir)
        guard !git.isEmpty, !common.isEmpty else { return nil }
        guard git != common else { return .main }
        return linkedKind(path: path, home: home)
    }

    /// Pool vs unmanaged for a directory already known to be a linked worktree.
    ///
    /// "Unmanaged" is **any linked worktree outside `~/.treehouse/`** — not only
    /// trees under a `.worktrees/` directory. This repo alone has 10+ linked
    /// worktrees that are plain siblings (`mux-maestro-hdr`, `-macos26`, `-merge`),
    /// and the narrower rule badges none of them.
    static func linkedKind(path: String, home: String) -> WorktreeKind {
        isInside(path: path, root: normalize(home) + "/.treehouse") ? .pool : .unmanaged
    }

    // MARK: Parsers

    /// Parse `git worktree list --porcelain`. Records are blank-line separated and
    /// start with `worktree <abs path>`; `branch refs/heads/x` names the branch
    /// (absent when detached). The first record is always the main checkout.
    static func parseList(porcelain: String, home: String) -> [WorktreeEntry] {
        var out: [WorktreeEntry] = []
        var path: String?
        var branch = ""
        var prunable = false

        func flush() {
            guard let p = path, !p.isEmpty else {
                path = nil; branch = ""; prunable = false; return
            }
            let isMain = out.isEmpty
            out.append(WorktreeEntry(
                path: normalize(p), branch: branch, isMain: isMain,
                kind: isMain ? .main : linkedKind(path: p, home: home),
                isPrunable: prunable))
            path = nil
            branch = ""
            prunable = false
        }

        for raw in porcelain.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                flush()  // a missing blank line must not merge two records
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            }
        }
        flush()
        return out
    }

    /// Whether `git status --porcelain=v1 -z` output means the tree holds
    /// uncommitted work — **ignoring `supabase/config.toml`**, which every worktree
    /// rewrites by design. Counting it is exactly the gate that wedged the nightly
    /// tidy job.
    static func isDirty(porcelain: String) -> Bool {
        GitCommit.parseStatus(porcelain).contains { !ignoredDirtyPaths.contains($0.path) }
    }

    /// Whether `git cherry <base>` output shows commits with no equivalent upstream
    /// — a `+ <sha>` line. `-` lines are commits already applied to the base under
    /// a different sha (a squash/rebase), which are not unique work.
    static func hasUniqueCommits(cherryOutput: String) -> Bool {
        cherryOutput.components(separatedBy: "\n").contains { $0.hasPrefix("+ ") }
    }

    /// How many commits `git cherry` actually accounted for — every `+` and `-`
    /// line. One line per **non-merge** commit in `base..HEAD`.
    static func cherryLineCount(cherryOutput: String) -> Int {
        cherryOutput.components(separatedBy: "\n")
            .filter { $0.hasPrefix("+ ") || $0.hasPrefix("- ") }.count
    }

    /// Commits ahead that `git cherry` could not speak to — i.e. merge commits.
    ///
    /// `rev-list --count` counts every commit ahead; `cherry` emits a line per
    /// non-merge commit. The difference is merges, and a merge can carry work that
    /// exists nowhere else. Any shortfall means "cherry's silence proves nothing",
    /// so the caller must not read `.none` from it.
    static func unaccountedCommits(aheadCount: Int, cherryOutput: String) -> Int {
        max(0, aheadCount - cherryLineCount(cherryOutput: cherryOutput))
    }

    /// Parse `git rev-list --count`. Returns nil on unparseable output, which the
    /// caller must treat as "unknown", never as zero.
    static func parseAheadCount(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Read the branch out of `symbolic-ref --short refs/remotes/origin/HEAD`
    /// (`origin/main`). nil when origin/HEAD is unset (git printed nothing).
    static func parseDefaultBranch(_ output: String) -> String? {
        let s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: Orphans — the part nothing else can show

    /// The linked worktrees no session is sitting in. This is the whole point: a
    /// worktree outlives the tmux window that created it, and nothing surfaces the
    /// gap until someone goes looking.
    ///
    /// Main checkouts are never orphans — a repo you aren't currently working in is
    /// not a leak. Result order follows `worktrees`.
    static func orphans(worktrees: [WorktreeEntry], sessionCwds: [String]) -> [WorktreeEntry] {
        worktrees.filter { wt in
            !wt.isMain && !wt.isPrunable
                && !sessionCwds.contains { isInside(path: $0, root: wt.path) }
        }
    }

    // MARK: Close-dialog cleanup (delegated to spindown)

    /// What sits at `<dir>/.git`: a directory for a main checkout, a file holding
    /// `gitdir: <path>` for a linked worktree (or a submodule).
    enum DotGit: Equatable {
        case directory
        case file(String)
    }

    /// The root of the linked worktree containing `path`, found by walking up to
    /// the nearest `.git`. nil for a main checkout, a submodule, or no repo at all.
    ///
    /// A filesystem read, not `rev-parse`, because the close confirm must appear
    /// the instant ⌘W lands — a Return typed before the sheet is up goes to the
    /// terminal. The rule is the same one `classify` applies: a linked worktree's
    /// git dir is `<common>/worktrees/<name>`, which is exactly what its `.git`
    /// file names. A submodule's points into `modules/` instead.
    static func linkedWorktreeRoot(of path: String, dotGit: (String) -> DotGit?) -> String? {
        var dir = normalize(path)
        guard dir.hasPrefix("/") else { return nil }
        while true {
            switch dotGit(dir) {
            case .directory?: return nil
            case .file(let text)?: return isLinkedGitdirFile(text) ? dir : nil
            case nil:
                guard dir != "/" else { return nil }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
    }

    /// Whether a `.git` file's `gitdir:` line points at `…/worktrees/<name>`.
    static func isLinkedGitdirFile(_ text: String) -> Bool {
        guard let line = text.components(separatedBy: "\n").first,
              line.hasPrefix("gitdir: ") else { return false }
        let gitdir = normalize(String(line.dropFirst("gitdir: ".count)))
        let parent = (gitdir as NSString).deletingLastPathComponent
        return !gitdir.isEmpty && (parent as NSString).lastPathComponent == "worktrees"
    }

    /// The real `.git` reader for `linkedWorktreeRoot`.
    static func readDotGit(_ dir: String) -> DotGit? {
        let path = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return .directory }
        return .file((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    /// The worktree a close dialog offers to clean up: the linked worktree `cwd`
    /// sits in, when no pane that survives the close still sits in it. nil
    /// otherwise — including every main checkout.
    static func cleanupOffer(
        cwd: String, survivorCwds: [String], dotGit: (String) -> DotGit?
    ) -> String? {
        guard let root = linkedWorktreeRoot(of: cwd, dotGit: dotGit),
              !survivorCwds.contains(where: { isInside(path: $0, root: root) })
        else { return nil }
        return root
    }

    /// `spindown.py`, which owns every safety gate on removing a worktree. The app
    /// only asks; it never decides what is safe.
    static var spindownScriptPath: String { BundledTools.path(.spindown) }

    /// `python3 spindown.py --worktree <path> --yes --json --keep-tmux`.
    ///
    /// Never `--force`: on a plain worktree it deletes uncommitted files.
    /// `--keep-tmux` because the dialog already closed what it named, and
    /// spindown's own window matching would otherwise kill windows it did not —
    /// including the surviving panes of the window a pane was closed from.
    static func spindownArgv(python: String, script: String, worktree: String) -> [String] {
        [python, script, "--worktree", worktree, "--yes", "--json", "--keep-tmux"]
    }

    /// What one spindown run did to the worktree, read from its `--json` report.
    enum CleanupResult: Equatable {
        case cleaned(branch: String?)
        /// The gate refused; spindown's reason, e.g. "HAS WORK — uncommitted: wip.txt".
        case kept(branch: String?, reason: String)
        /// The gate passed but a step failed, e.g. "git: worktree remove failed — …".
        case failed(branch: String?, detail: String)
    }

    /// Parse `spindown.py --json` stdout. nil when there is no report at all —
    /// spindown exits 1 with empty stdout on errors such as a bad path.
    static func parseSpindown(json: String?) -> CleanupResult? {
        guard let data = json?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = (obj["targets"] as? [[String: Any]])?.first
        else { return nil }
        let branch = target["branch"] as? String
        let skipped = target["skipped"] as? [String] ?? []
        let actions = target["actions"] as? [String] ?? []
        if target["cleaned"] as? Bool == true { return .cleaned(branch: branch) }
        if let reason = skipped.first {
            return .kept(branch: branch, reason: reason)
        }
        return .failed(
            branch: branch,
            detail: actions.first { $0.contains(" failed") } ?? "nothing was removed")
    }

    /// Toast title and body for a cleanup. `worktree` names it when spindown
    /// reported no branch.
    static func cleanupToast(_ result: CleanupResult?, worktree: String) -> (title: String, body: String) {
        let name = (worktree as NSString).lastPathComponent
        switch result {
        case .cleaned(let branch)?:
            return (branch ?? name, "Worktree cleaned up")
        case .kept(let branch, let reason)?:
            let short = reason.hasPrefix("HAS WORK — ")
                ? String(reason.dropFirst("HAS WORK — ".count)) : reason
            return (branch ?? name, "Kept worktree: \(short)")
        case .failed(let branch, let detail)?:
            return (branch ?? name, "Worktree cleanup failed: \(detail)")
        case nil:
            return (name, "Worktree cleanup failed")
        }
    }

    // MARK: WORKTREES row → Remove (delegated to spindown)

    /// What right-clicking a WORKTREES row may do. spindown re-checks everything
    /// before it removes anything; this only decides whether to ask.
    enum RemoveOffer: Equatable {
        /// Clean, and every commit is in the remote default branch.
        case confirm
        /// Not classified yet. Offered, but the sheet says so.
        case confirmUnchecked
        /// Not offered; the reason goes in the disabled menu item's title.
        case refuse(String)
    }

    /// Never the main checkout, never a tree known to hold work. Unknown is its
    /// own state — never read as "safe".
    static func removeOffer(entry: WorktreeEntry, work: WorktreeWork) -> RemoveOffer {
        if entry.isMain || entry.kind == .main { return .refuse("main checkout") }
        if entry.isPrunable { return .refuse("already gone") }
        switch work {
        case .unique: return .refuse("holds work")
        case .unknown: return .confirmUnchecked
        case .none: return .confirm
        }
    }

    static func removeMenuTitle(_ offer: RemoveOffer) -> String {
        if case .refuse(let why) = offer { return "Remove Worktree — \(why)" }
        return "Remove Worktree…"
    }

    /// The confirm sheet. Prose is allowed here: this is where work can be lost.
    static func removeConfirm(
        entry: WorktreeEntry, offer: RemoveOffer
    ) -> (title: String, info: String) {
        let branch = entry.branch.isEmpty ? "" : " and its local branch \(entry.branch)"
        var info = "Deletes \(entry.path)\(branch)."
        if offer == .confirmUnchecked {
            info += " It was not checked for unpushed work yet; spindown keeps it if it holds any."
        }
        return ("Remove worktree “\(entry.name)”?", info)
    }

    // MARK: Breadcrumb chip

    /// The breadcrumb chip for a selection whose pane sits in a linked worktree.
    struct Crumb: Equatable {
        let text: String
        let tooltip: String
        let root: String
    }

    /// nil for a main checkout, a submodule, no repo, or a remote host (its paths
    /// mean nothing on this Mac). `home` is injected so tests never read `$HOME`.
    static func worktreeCrumb(
        cwd: String, isLocal: Bool, home: String, dotGit: (String) -> DotGit?
    ) -> Crumb? {
        guard isLocal, let root = linkedWorktreeRoot(of: cwd, dotGit: dotGit) else { return nil }
        let h = normalize(home)
        let shown = isInside(path: root, root: h) && root != h
            ? "~" + root.dropFirst(h.count) : root
        return Crumb(text: "⑂ worktree", tooltip: shown, root: root)
    }

    /// Whether `path` is `root` or sits underneath it, respecting path boundaries
    /// so `/a/foobar` is not "inside" `/a/foo`.
    static func isInside(path: String, root: String) -> Bool {
        let p = normalize(path), r = normalize(root)
        guard !p.isEmpty, !r.isEmpty else { return false }
        return p == r || p.hasPrefix(r + "/")
    }

    /// Trim whitespace/newlines (git output arrives with a trailing `\n`) and drop a
    /// trailing slash so prefix comparisons line up.
    static func normalize(_ path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
