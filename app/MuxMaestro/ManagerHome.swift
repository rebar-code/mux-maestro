import Foundation

/// The manager agent's home directory under Application Support and the seeding
/// that keeps it in sync with the app bundle. The agent runs `claude` from here
/// in the `mux-manager` tmux session; it reads `AGENT.md` (its operating doc,
/// symlinked to `CLAUDE.md` so Claude auto-loads it) and writes only through
/// `bin/mux`. The bundle is the source of truth, so `AGENT.md` and `bin/mux` are
/// overwritten on every `ensure()`; `manager.db` is left to `ManagerStore`.
enum ManagerHome {
    static let sessionName = "mux-manager"

    /// The home, relative to Application Support.
    private static let relativePath = "MuxMaestro/manager"

    static func dbPath(home: URL) -> String {
        home.appendingPathComponent("manager.db").path
    }

    /// Where the home lives, without creating anything.
    static func defaultHome() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    /// Where `manager.db` lives, without creating anything — for the tree poll,
    /// which reads hook state but must not seed the home.
    static func defaultDBPath() -> String? {
        defaultHome().map(dbPath(home:))
    }

    /// Create/refresh `~/Library/Application Support/MuxMaestro/manager/` and
    /// return it. Throws only on unrecoverable filesystem errors.
    @discardableResult
    static func ensure() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let home = support.appendingPathComponent(relativePath, isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        let agent = home.appendingPathComponent("AGENT.md")
        try copyBundleResource(name: "AGENT", ext: "md", to: agent, executable: false)

        let mux = bin.appendingPathComponent("mux")
        try copyBundleResource(name: "mux", ext: nil, to: mux, executable: true)

        // CLAUDE.md -> AGENT.md so `claude` in this dir loads the operating doc
        // automatically. Created once; never clobbered if the user replaced it.
        let claudeMd = home.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: claudeMd.path) {
            try fm.createSymbolicLink(at: claudeMd, withDestinationURL: agent)
        }
        return home
    }

    private static func copyBundleResource(name: String, ext: String?, to dest: URL, executable: Bool) throws {
        guard let source = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "manager") else {
            throw ManagerHomeError.missingResource("\(name)\(ext.map { ".\($0)" } ?? "")")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
        if executable {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }
}

enum ManagerHomeError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "manager bundle resource missing: \(name)"
        }
    }
}
