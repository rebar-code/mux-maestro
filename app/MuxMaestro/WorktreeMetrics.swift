import Foundation

/// Everything a WORKTREES row shows beyond git's own verdict: idle age, containers,
/// lease state, which files are dirty, size. Pure — argv builders, parsers and
/// formatting — so every rule is asserted without spawning a process (see
/// WorktreeMetricsTests). No AppKit.
///
/// Display only. Removing a worktree belongs to spindown (`Worktrees.spindownArgv`).

// MARK: - treehouse

/// One row of `treehouse status --json`.
///
/// For a pool worktree this — not anything MuxMaestro derives — is the source of
/// truth for lease state. If the row and the CLI disagree, the CLI wins.
struct TreehouseWorktree: Equatable {
    /// Pool slot name — "1", "13".
    let name: String
    /// Absolute worktree path.
    let path: String
    /// treehouse's own word: `available`, `leased`, `in-use`, `dirty`, `you're here`.
    let status: String
    /// Who holds the lease — `spin:feat/rate-auditor-comp-set`. Empty when unleased.
    let leaseHolder: String
    /// When the lease was taken. nil when unleased.
    let leasedAt: Date?
    /// Live processes treehouse found rooted in the tree, as `name (pid)`.
    let processes: [String]

    /// The row's lease line: "treehouse: leased by spin:feat/x · 2d".
    func summary(now: Date) -> String {
        var out = "treehouse: \(status.isEmpty ? "unknown" : status)"
        if !leaseHolder.isEmpty { out += " by \(leaseHolder)" }
        if let leasedAt { out += " · \(WorktreeMetrics.ageLabel(leasedAt, now: now))" }
        if !processes.isEmpty { out += " · \(processes.joined(separator: ", "))" }
        return out
    }
}

enum Treehouse {
    /// `env -C <repo> <treehouse> status --json`.
    ///
    /// treehouse has no `-C` of its own — it resolves the pool from
    /// `git rev-parse --show-toplevel` — so the working directory is the argument.
    /// `repo` must be the repo's **main checkout**: run from inside a pool tree the
    /// CLI reports that tree as `you're here`.
    static func statusArgv(treehouse: String, repo: String) -> [String] {
        ["-C", Worktrees.normalize(repo), treehouse, "status", "--json"]
    }

    /// Parse `treehouse status --json`. Returns [] on anything unparseable — the
    /// row then has no lease line rather than a wrong one.
    static func parseStatus(_ json: String) -> [TreehouseWorktree] {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let path = row["path"] as? String, !path.isEmpty else { return nil }
            let procs = (row["processes"] as? [[String: Any]] ?? []).compactMap { p -> String? in
                guard let name = p["name"] as? String else { return nil }
                guard let pid = p["pid"] as? Int else { return name }
                return "\(name) (\(pid))"
            }
            return TreehouseWorktree(
                name: row["name"] as? String ?? "",
                path: Worktrees.normalize(path),
                status: row["status"] as? String ?? "",
                leaseHolder: row["lease_holder"] as? String ?? "",
                leasedAt: (row["leased_at"] as? String).flatMap(parseTimestamp),
                processes: procs)
        }
    }

    /// treehouse writes Go RFC3339 with fractional seconds and a numeric offset
    /// (`2026-08-19T14:10:28.97234-05:00`); some rows omit the fraction.
    static func parseTimestamp(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

// MARK: - untracked files

/// How much an untracked file looks like work worth keeping. Used only to stop
/// the `work` chip firing on trees whose sole difference is screenshots and
/// one-off scratch files.
///
/// Three states, not two: `unknown` is never folded into `likelyScratch`. The
/// misses of every two-state rule tried were one-off tools with an unfamiliar
/// extension, and calling those scratch hides real work.
enum UntrackedClass: String, Equatable, Comparable {
    /// The repo authors this file type, and it sits where the project's files sit.
    case work
    /// Unfamiliar. Treated as `work` everywhere.
    case unknown
    /// At the repo root, or under a tool's dot-directory.
    case likelyScratch

    private var order: Int {
        switch self { case .work: return 0; case .unknown: return 1; case .likelyScratch: return 2 }
    }
    static func < (a: UntrackedClass, b: UntrackedClass) -> Bool { a.order < b.order }
}

/// One untracked path plus its verdict.
struct UntrackedFile: Equatable {
    /// Repo-relative path, as `git status` prints it.
    let path: String
    let verdict: UntrackedClass
}

enum UntrackedClassifier {
    /// `git -C <cwd> ls-files` — every tracked path, which is the only input needed
    /// to learn which extensions this repo actually authors. No maintained denylist:
    /// one repo here tracks 17 `.png` and 4 `.xlsx`.
    static func lsFilesArgv(cwd: String) -> [String] {
        ["-C", Worktrees.normalize(cwd), "ls-files"]
    }

    /// The lowercased extensions a repo tracks, from `git ls-files`.
    static func authoredExtensions(lsFiles: String) -> Set<String> {
        var out = Set<String>()
        for line in lsFiles.components(separatedBy: "\n") {
            let ext = ((line as NSString).lastPathComponent as NSString).pathExtension.lowercased()
            if !ext.isEmpty { out.insert(ext) }
        }
        return out
    }

    /// Classify one untracked repo-relative path. Rule order is load-bearing.
    static func classify(path: String, authoredExtensions: Set<String>) -> UntrackedClass {
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let file = parts.last else { return .unknown }

        // 1. The repo root is where downloads, screenshots and pasted files land.
        //    This outranks the extension test: a repo that tracks .png under docs/
        //    still did not ask for `Screenshot 2026-08-06.png` at top level.
        if parts.count == 1 { return .likelyScratch }

        // 2. A leading-dot directory belongs to a tool — `.lavish/`, `.claude/`.
        if parts.dropLast().contains(where: { $0.hasPrefix(".") }) { return .likelyScratch }

        // 3. An extension this repo authors, in a real directory, is work.
        let ext = (file as NSString).pathExtension.lowercased()
        if !ext.isEmpty, authoredExtensions.contains(ext) { return .work }

        // 4. Anything else is unfamiliar — which is not the same as junk.
        return .unknown
    }
}

/// A worktree's working-tree state split into tracked edits and classified
/// untracked files — what `WorktreeWork`'s single `.unique` cannot express.
struct WorktreeChanges: Equatable {
    /// Tracked files with uncommitted edits, minus `supabase/config.toml`.
    var trackedDirty: [String] = []
    /// Untracked files with their verdicts.
    var untracked: [UntrackedFile] = []

    /// Split a `git status --porcelain=v1 -z --untracked-files=all` dump.
    static func parse(porcelain: String, authoredExtensions: Set<String>) -> WorktreeChanges {
        var out = WorktreeChanges()
        for f in GitCommit.parseStatus(porcelain) {
            guard !Worktrees.ignoredDirtyPaths.contains(f.path) else { continue }
            if f.isUntracked {
                out.untracked.append(UntrackedFile(
                    path: f.path,
                    verdict: UntrackedClassifier.classify(
                        path: f.path, authoredExtensions: authoredExtensions)))
            } else {
                out.trackedDirty.append(f.path)
            }
        }
        return out
    }

    /// True when the working tree holds nothing but confidently-scratch untracked
    /// files. `unknown` files make this false.
    var isScratchOnly: Bool {
        trackedDirty.isEmpty && untracked.allSatisfy { $0.verdict == .likelyScratch }
    }

    /// The row's untracked line: basenames plus the set's worst verdict. Names,
    /// never a bare count.
    func untrackedLine(limit: Int = WorktreeMetrics.dirtyPathsShown) -> String? {
        guard !untracked.isEmpty else { return nil }
        let names = WorktreeMetrics.basenames(untracked.map(\.path), limit: limit)
        let verdict: String
        switch untracked.map(\.verdict).min() ?? .unknown {
        case .work: verdict = "work"
        case .unknown: verdict = "unrecognised"
        case .likelyScratch: verdict = "scratch"
        }
        return "untracked \(names) — \(verdict)"
    }
}

// MARK: - metrics

/// The per-worktree facts the row shows. Everything is optional because every one
/// of them can be missing, and a missing metric must read as "unknown" rather than
/// as a reassuring zero.
struct WorktreeMetrics: Equatable {
    /// Newest of: the HEAD commit date, the worktree root's mtime, and the gitdir's
    /// `index` / `HEAD` mtimes. Never a directory walk.
    var lastUsed: Date?
    /// Containers + published ports attributed to this tree. `.unknown` until the
    /// sweep gets a `docker ps` through.
    var docker: DockerAttribution = .unknown
    /// treehouse's verdict for a pool tree. nil for unmanaged trees and whenever the
    /// CLI could not be read.
    var lease: TreehouseWorktree?
    /// Whether HEAD holds commits the default branch has never seen. Asked only for
    /// scratch-only trees, where it decides between the `work` and `scratch` chip.
    /// nil when not asked or not answerable — both keep the `work` chip.
    var hasUnpushedCommits: Bool?
    /// The working tree, split into tracked edits and classified untracked files.
    /// nil until the sweep reads it.
    var changes: WorktreeChanges?
    /// `du -sk`, in kilobytes. Computed only on expand/select, then cached.
    var diskKB: Int?
    /// A `du` is in flight for this tree.
    var diskPending: Bool = false

    /// How many dirty paths to name before falling back to "+N".
    static let dirtyPathsShown = 3

    // MARK: parsing

    /// Newest non-nil date, or nil when every input was missing.
    static func newest(_ dates: [Date?]) -> Date? { dates.compactMap { $0 }.max() }

    /// A unix epoch printed by `git log -1 --format=%ct`, or nil.
    static func parseEpoch(_ output: String) -> Date? {
        let s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = TimeInterval(s), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The kilobyte total from `du -sk <path>` ("2216484\t/path"). nil when
    /// unparseable.
    static func parseDuKB(_ output: String) -> Int? {
        let first = output.components(separatedBy: "\n").first ?? ""
        let field = first.components(separatedBy: CharacterSet(charactersIn: " \t"))
            .first { !$0.isEmpty } ?? ""
        return Int(field)
    }

    // MARK: argv

    /// `du -sk <path>` — kilobytes, one line.
    static func duArgv(path: String) -> [String] { ["-sk", Worktrees.normalize(path)] }

    /// `git -C <cwd> log -1 --format=%ct` — the HEAD commit's committer date.
    static func headCommitDateArgv(cwd: String) -> [String] {
        ["-C", Worktrees.normalize(cwd), "log", "-1", "--format=%ct"]
    }

    // MARK: formatting

    /// A coarse age — "11d", "4h", "12m", "now". One unit: the row is ~220pt wide
    /// and the question is "weeks or minutes".
    static func ageLabel(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        if seconds >= 60 { return "\(Int(seconds / 60))m" }
        return "now"
    }

    /// "2.1 GB" / "812 MB" / "44 KB". Decimal units, matching Finder.
    static func sizeLabel(kb: Int) -> String {
        let bytes = Double(max(0, kb)) * 1000
        for (suffix, scale) in [("GB", 1e9), ("MB", 1e6), ("KB", 1e3)] where bytes >= scale {
            let value = bytes / scale
            return value >= 10
                ? "\(Int(value.rounded())) \(suffix)"
                : String(format: "%.1f %@", value, suffix)
        }
        return "\(max(0, kb)) KB"
    }

    /// The row's name: the branch. Every tree of one repo shares a directory name,
    /// so the branch is the only token that tells rows apart.
    static func branchLabel(entry: WorktreeEntry) -> String {
        entry.branch.isEmpty ? "detached" : entry.branch
    }

    /// Basenames, not paths: `marketplace.ts +2` names the file, while a long path
    /// truncates to a directory. Full paths live in the tooltip.
    static func basenames(_ paths: [String], limit: Int = dirtyPathsShown) -> String {
        let names = paths.prefix(limit).map { ($0 as NSString).lastPathComponent }
        let more = paths.count > limit ? " +\(paths.count - limit)" : ""
        return names.joined(separator: ", ") + more
    }

    /// The row's trailing chips, most urgent first: work, containers, idle, size.
    /// Ports go in the container chip's tooltip — a wall of digits does not fit.
    func chips(work: WorktreeWork, now: Date) -> [WorktreeChip] {
        var out: [WorktreeChip] = []

        if work == .unique {
            // `.unique` counts any untracked file, so `work` fired on nearly every
            // row. When the only difference is confidently-scratch untracked files
            // and nothing is unpushed, say `scratch`, quietly. `== false`, not
            // `!= true`: an unanswered question keeps the `work` chip.
            if changes?.isScratchOnly == true, hasUnpushedCommits == false {
                out.append(WorktreeChip(text: "scratch", tooltip: "Untracked scratch only", tone: .muted))
            } else {
                out.append(WorktreeChip(text: "work", tooltip: "Work that exists nowhere else", tone: .warning))
            }
        }

        if !docker.known {
            out.append(WorktreeChip(text: "⬢?", tooltip: "Docker unavailable", tone: .muted))
        } else if docker.containers > 0 {
            let ports = docker.ports.map { ":\($0)" }.joined(separator: " ")
            out.append(WorktreeChip(
                text: "⬢\(docker.containers)",
                tooltip: ports.isEmpty ? "\(docker.containers) running" : "\(docker.containers) running · \(ports)",
                tone: .muted))
        }

        out.append(WorktreeChip(
            text: lastUsed.map { Self.ageLabel($0, now: now) } ?? "?",
            tooltip: "Idle", tone: .muted))

        if diskPending {
            out.append(WorktreeChip(text: "…", tooltip: "Size", tone: .muted))
        } else if let diskKB {
            out.append(WorktreeChip(text: Self.sizeLabel(kb: diskKB), tooltip: "Size", tone: .muted))
        }
        return out
    }

    /// The expanded detail lines: only what a chip cannot carry — the path, which
    /// files, and who holds the tree.
    func detailLines(entry: WorktreeEntry, work: WorktreeWork, now: Date) -> [String] {
        var lines = [entry.path]

        let dirty = changes?.trackedDirty ?? []
        if !dirty.isEmpty { lines.append("dirty " + Self.basenames(dirty)) }
        if let untracked = changes?.untrackedLine() { lines.append(untracked) }
        if dirty.isEmpty, changes?.untracked.isEmpty ?? true {
            switch work {
            case .unique: lines.append("unpushed commits")
            case .none: lines.append("clean")
            case .unknown: lines.append("not checked")
            }
        }

        if let lease {
            lines.append(lease.summary(now: now))
        } else if entry.kind == .pool {
            lines.append("treehouse: no lease")
        } else {
            lines.append("unmanaged")
        }
        return lines
    }
}

/// One trailing pill on a worktree row. Pure data, like `WorktreeBadge` — the
/// cell turns it into a view.
struct WorktreeChip: Equatable {
    enum Tone: Equatable { case muted, warning }
    let text: String
    let tooltip: String
    let tone: Tone
}
