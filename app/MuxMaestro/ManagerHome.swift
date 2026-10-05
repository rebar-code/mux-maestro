import Foundation

/// The manager agent's home directory under Application Support and the seeding
/// that keeps it in sync with the app bundle. The agent runs from here in the
/// `mux-manager` tmux session and writes only through `bin/mux`.
///
/// Two documents, two owners. `AGENT.md` is the app's: the `mux` CLI reference,
/// overwritten with `bin/mux` on every `ensure()` so it matches the build.
/// `CLAUDE.md` is the user's: how the Maestro behaves and delegates, seeded once
/// and edited in Settings. `AGENTS.md` links to it, so Codex loads the same
/// file. `manager.db` is left to `ManagerStore`.
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
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let home = support.appendingPathComponent(relativePath, isDirectory: true)
        try seed(home: home, resource: bundleResource)
        return home
    }

    /// A bundled file of the `manager` resource folder, by name and extension.
    typealias Resource = (String, String?) -> URL?

    static let bundleResource: Resource = {
        Bundle.main.url(forResource: $0, withExtension: $1, subdirectory: "manager")
    }

    static func seed(home: URL, resource: Resource) throws {
        let fm = FileManager.default
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        let agent = home.appendingPathComponent("AGENT.md")
        try copy(resource, name: "AGENT", ext: "md", to: agent, executable: false)

        let mux = bin.appendingPathComponent("mux")
        try copy(resource, name: "mux", ext: nil, to: mux, executable: true)

        // Until the two documents were split, CLAUDE.md was a link to AGENT.md.
        // That link holds nothing of the user's, so the seed replaces it. A
        // file, or a link to anywhere else, is the user's and stays.
        let context = contextURL(home: home)
        if let link = try? fm.destinationOfSymbolicLink(atPath: context.path),
           URL(fileURLWithPath: link).lastPathComponent == agent.lastPathComponent {
            try fm.removeItem(at: context)
        }
        if !isPresent(context) {
            try copy(resource, name: defaultContextName, ext: "md", to: context, executable: false)
        }

        // Codex reads AGENTS.md. A relative link, so the home can move.
        let agents = home.appendingPathComponent("AGENTS.md")
        if !isPresent(agents) {
            try fm.createSymbolicLink(atPath: agents.path, withDestinationPath: context.lastPathComponent)
        }
    }

    // MARK: Instructions

    private static let defaultContextName = "CLAUDE.default"

    /// The Maestro's instructions: the file Claude loads from the home.
    static func contextURL(home: URL) -> URL {
        home.appendingPathComponent("CLAUDE.md")
    }

    static func readContext(home: URL) -> String? {
        try? String(contentsOf: contextURL(home: home), encoding: .utf8)
    }

    /// Write through a link the user put there, never over it.
    static func writeContext(_ text: String, home: URL) throws {
        try text.write(
            to: contextURL(home: home).resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }

    /// The instructions the app ships, as the seed writes them.
    static func defaultContext(resource: Resource = bundleResource) -> String? {
        resource(defaultContextName, "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Anything at `url`, a link with no target included.
    private static func isPresent(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func copy(
        _ resource: Resource, name: String, ext: String?, to dest: URL, executable: Bool
    ) throws {
        guard let source = resource(name, ext) else {
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
        case .missingResource(let name): return "Maestro bundle resource missing: \(name)"
        }
    }
}
