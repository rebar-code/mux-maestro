import Foundation

/// A node in the repo file tree (the Tree side panel): a folder (with children)
/// or a file (a leaf). Pure data — no AppKit — built from `git ls-files` output
/// so the construction is unit-testable and the service can hand it across
/// threads, mirroring `GitDiffResult` for the Diff pane.
struct FileTreeNode: Equatable {
    /// The last path component (what the row shows), e.g. `app.ts`.
    let name: String
    /// The repo-relative path from the root, e.g. `src/app.ts` — joined onto the
    /// session cwd to open the file in the editor.
    let relativePath: String
    let isDir: Bool
    var children: [FileTreeNode]
}

/// The result of listing a working directory's tracked + untracked-non-ignored
/// files as a tree: the top-level nodes, whether the cwd is a git repo (so the
/// pane can show "Not a git repository" like Diff), and whether the file count
/// was capped.
struct FileTreeResult: Equatable {
    let root: [FileTreeNode]
    /// False when `cwd` isn't inside a git work tree — the pane shows a friendly
    /// "not a git repository" state, exactly like the Diff pane.
    let isRepo: Bool
    /// True when more than `FileTree.maxFiles` files were listed and the rest were
    /// dropped — surfaced so a giant tree never silently truncates.
    let truncated: Bool
}

/// Pure construction of the git argv + the nested folder/file tree for the Tree
/// side panel. No process spawning here so every piece is unit-testable against a
/// canned `ls-files` blob (like `GitDiff`).
enum FileTree {
    /// Cap on how many files are built into the tree, so a repo with an enormous
    /// tracked set (or an untracked `node_modules` slip-through) can't wedge the
    /// pane. Anything past this is dropped and `FileTreeResult.truncated` is set.
    static let maxFiles = 5000

    /// argv listing tracked + untracked-non-ignored files (honoring `.gitignore`),
    /// NUL-separated so paths with spaces/newlines survive:
    /// `git -C <cwd> ls-files --cached --others --exclude-standard -z`. Same
    /// `git -C` style as `GitDiff.untrackedListArgv`.
    static func listArgv(cwd: String) -> [String] {
        ["-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    }

    /// Build the nested tree from the NUL-separated relative-path list. Folders
    /// sort before files; within each kind, names sort case-insensitively. Capped
    /// to `maxFiles` (the extras dropped) with the truncated flag returned.
    static func build(fromNulList output: String) -> (root: [FileTreeNode], truncated: Bool) {
        var paths = output.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var truncated = false
        if paths.count > maxFiles {
            paths = Array(paths.prefix(maxFiles))
            truncated = true
        }

        let root = Builder(name: "", relativePath: "", isDir: true)
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            var accum = ""
            for (i, part) in parts.enumerated() {
                accum = accum.isEmpty ? part : accum + "/" + part
                let isLast = i == parts.count - 1
                if let existing = node.childrenByName[part] {
                    node = existing
                } else {
                    let child = Builder(name: part, relativePath: accum, isDir: !isLast)
                    node.childrenByName[part] = child
                    node.order.append(part)
                    node = child
                }
            }
        }
        return (root.toTreeNodes(), truncated)
    }

    /// Mutable tree node used only during construction (a value-type `FileTreeNode`
    /// can't be grown incrementally cheaply); converted to immutable `FileTreeNode`s,
    /// sorted folders-first then case-insensitive by name, at the end.
    private final class Builder {
        let name: String
        let relativePath: String
        let isDir: Bool
        var childrenByName: [String: Builder] = [:]
        var order: [String] = []

        init(name: String, relativePath: String, isDir: Bool) {
            self.name = name
            self.relativePath = relativePath
            self.isDir = isDir
        }

        func toTreeNodes() -> [FileTreeNode] {
            order.map { childrenByName[$0]! }
                .sorted { lhs, rhs in
                    if lhs.isDir != rhs.isDir { return lhs.isDir }  // folders first
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map { FileTreeNode(
                    name: $0.name, relativePath: $0.relativePath,
                    isDir: $0.isDir, children: $0.toTreeNodes()) }
        }
    }
}

/// The ⌘P quick-open palette's file list beyond `git ls-files`: a capped walk
/// for a folder that is not a git repo, and the merge with the pane's
/// artifacts, which can live anywhere on disk. Pure, like `FileTree`.
enum QuickOpenFiles {
    /// Cap on the walk, so a huge folder such as `$HOME` stays quick: `head`
    /// closes the pipe at the cap and `find` stops there.
    static let maxFiles = 20_000
    static let maxDepth = 8

    /// Folders the walk never enters: dot-folders (`.git`, caches) and
    /// dependency, build and macOS library trees.
    static let skippedFolders = [
        ".*", "node_modules", "Library", "build", "dist", "target",
        "DerivedData", "Pods", "__pycache__", "venv",
    ]

    /// `sh` argv that lists the files under `cwd` as `./`-prefixed lines.
    /// `cwd` goes in as `$1`, so it needs no quoting inside the script, and the
    /// script has no single quotes, so it survives `Ssh.shellQuote` for a
    /// remote host. Errors (unreadable folders) are dropped; `head` sets the
    /// exit status, so a partial walk still counts as success.
    static func walkArgv(cwd: String) -> [String] {
        let names = skippedFolders.map { "-name \"\($0)\"" }.joined(separator: " -o ")
        let script = "cd \"$1\" && find . -mindepth 1 -maxdepth \(maxDepth)"
            + " \\( -type d \\( \(names) \\) \\) -prune -o -type f -print 2>/dev/null"
            + " | head -n \(maxFiles)"
        return ["-c", script, "sh", cwd]
    }

    /// The walk's lines as paths relative to the walked folder.
    static func parseWalk(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.hasPrefix("./") ? String(line.dropFirst(2)) : String(line)
        }
    }

    /// The palette's entries: the artifacts first, then the listed files.
    /// An artifact under `cwd` shows as a relative path and is not listed
    /// twice; one elsewhere shows as `~/…` under `home`, else absolute.
    static func merge(listed: [String], artifacts: [String], cwd: String, home: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in artifacts.map({ display($0, cwd: cwd, home: home) }) + listed
        where seen.insert(entry).inserted {
            out.append(entry)
        }
        return out
    }

    /// The absolute path of a `merge` entry.
    static func absolutePath(_ entry: String, cwd: String, home: String) -> String {
        if entry.hasPrefix("/") { return entry }
        if entry.hasPrefix("~/") { return home + entry.dropFirst() }
        return GitDiff.joinPath(cwd: cwd, relative: entry)
    }

    private static func display(_ path: String, cwd: String, home: String) -> String {
        if let rest = relative(path, under: cwd) { return rest }
        if let rest = relative(path, under: home) { return "~/" + rest }
        return path
    }

    private static func relative(_ path: String, under folder: String) -> String? {
        guard !folder.isEmpty else { return nil }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}
