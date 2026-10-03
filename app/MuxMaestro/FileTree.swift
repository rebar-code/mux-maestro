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
