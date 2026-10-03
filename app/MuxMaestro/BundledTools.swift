import Foundation

/// A helper script MuxMaestro ships in `Resources/tools/` rather than expecting
/// at a path on one person's Mac. The raw value is its file name there.
enum BundledTool: String, CaseIterable {
    /// Claude Code attention status (`sessions.py list`), local and remote.
    case sessions = "sessions.py"
    /// Grab to Scratchpad (`scratchpad.py add|push`).
    case scratchpad = "scratchpad.py"
    /// Worktree cleanup after a close (`spindown.py --worktree … --yes --json`).
    case spindown = "spindown.py"
}

/// Where the bundled helper scripts live at runtime.
///
/// The app copies `Resources/tools/` to
/// `~/Library/Application Support/MuxMaestro/tools/` and runs the scripts from
/// there: a stable absolute path that survives `make install` replacing the
/// bundle, and that a hook or the manager agent can be pointed at. Remote hosts
/// get their copy pushed over ssh (see `RemoteSessionsPyStatusProvider`).
///
/// `path(_:)` is the one resolver — a call site that hard-codes
/// `~/.claude/skills/…` swaps to it in one line.
enum BundledTools {
    /// Where scripts land on a remote host, which has no Application Support.
    /// Callers leave it unquoted so the remote shell expands `~`.
    static let remoteDirectory = "~/.muxmaestro/tools"

    /// Absolute path to `tool`'s installed copy. The first call in a process
    /// installs every bundled tool, so no caller depends on launch order. Falls
    /// back to the copy inside the bundle when Application Support can't be
    /// written, and to "" when there is no bundle copy either (the test bundle)
    /// — callers already treat a missing file as "tool unavailable".
    static func path(_ tool: BundledTool) -> String {
        if let installedDirectory {
            return installedDirectory.appendingPathComponent(tool.rawValue).path
        }
        return bundleDirectory?.appendingPathComponent(tool.rawValue).path ?? ""
    }

    /// `tool` on a remote host.
    static func remotePath(_ tool: BundledTool) -> String {
        "\(remoteDirectory)/\(tool.rawValue)"
    }

    /// `tool`'s bytes, for pushing to a remote host. nil when unavailable.
    static func contents(_ tool: BundledTool) -> Data? {
        let path = path(tool)
        return path.isEmpty ? nil : try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Copy every item in `source` into `destination`, replacing what is there.
    /// Each item is staged beside its target and swapped in, so a poll running
    /// `sessions.py` mid-install never finds a missing or half-written file.
    static func install(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let target = destination.appendingPathComponent(name)
            let staged = destination.appendingPathComponent(".\(name).staging-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: source.appendingPathComponent(name), to: staged)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        }
    }

    /// `Contents/Resources/tools` in the running app; nil when absent.
    private static var bundleDirectory: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("tools", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.path)
        else { return nil }
        return dir
    }

    /// Installed once per process on first use (`static let` initialization is
    /// lazy and thread-safe). Re-copied every launch so an app update refreshes it.
    private static let installedDirectory: URL? = {
        guard let source = bundleDirectory,
              let support = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask,
                  appropriateFor: nil, create: true)
        else { return nil }
        let destination = support.appendingPathComponent("MuxMaestro/tools", isDirectory: true)
        do {
            try install(from: source, to: destination)
            return destination
        } catch {
            NSLog("MuxMaestro: couldn’t install bundled tools to \(destination.path): "
                + error.localizedDescription)
            return nil
        }
    }()
}
