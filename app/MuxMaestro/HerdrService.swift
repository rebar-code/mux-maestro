import Foundation

/// Drives the **herdr** multiplexer — a separate, non-tmux session source. Mirrors
/// `TmuxService`'s role (load the tree, drive attach + lifecycle) but speaks the
/// herdr CLI instead of tmux. Every invocation runs through the shared
/// `CommandRunner` seam, so the whole service is asserted against a FakeRunner
/// with no real herdr spawned.
///
/// This is purely additive: `TmuxService` is untouched. The sidebar adds herdr as
/// a top-level node sibling to localhost + the ssh hosts.
final class HerdrService {
    /// Absolute path to the herdr binary, or nil if not installed.
    let herdrPath: String?
    private let runner: CommandRunner

    /// Default-init: discover herdr on the usual brew/local paths, real runner.
    convenience init() {
        self.init(runner: ProcessCommandRunner(), herdrPath: Self.discoverHerdr())
    }

    /// Designated init for testing/injection: pass a FakeRunner and a fixed path.
    init(runner: CommandRunner, herdrPath: String?) {
        self.runner = runner
        self.herdrPath = herdrPath
    }

    /// True when herdr is installed and usable.
    var isAvailable: Bool { herdrPath != nil }

    private static func discoverHerdr() -> String? {
        ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "/usr/bin/herdr"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a herdr argv, returning stdout or nil. nil if herdr isn't installed.
    @discardableResult
    private func herdr(_ args: [String]) -> String? {
        guard let herdrPath else { return nil }
        return runner.run(herdrPath, args)
    }

    /// Build the herdr session → tab → pane tree from three list calls. Does real
    /// work (serial shell-outs); call it off the main thread. Empty if herdr is
    /// unavailable or no sessions exist.
    func loadTree() -> [HerdrSession] {
        guard isAvailable,
              let sessOut = herdr(HerdrModel.sessionListArgv),
              let sessData = sessOut.data(using: .utf8)
        else { return [] }
        let sessions = HerdrModel.parseSessions(sessData)
        guard !sessions.isEmpty else { return [] }

        let tabs = herdr(HerdrModel.tabListArgv)
            .flatMap { $0.data(using: .utf8) }
            .map(HerdrModel.parseTabs) ?? []
        let panes = herdr(HerdrModel.paneListArgv)
            .flatMap { $0.data(using: .utf8) }
            .map(HerdrModel.parsePanes) ?? []
        return HerdrModel.assemble(sessions: sessions, tabs: tabs, panes: panes)
    }

    /// The shell command the libghostty surface runs to attach to `session`.
    /// nil if herdr isn't installed.
    func attachCommand(session: String) -> String? {
        guard let herdrPath else { return nil }
        return HerdrModel.attachCommand(herdrPath: herdrPath, session: session)
    }

    /// Stop a herdr session's server. Returns whether the command succeeded.
    @discardableResult
    func stopSession(name: String) -> Bool {
        herdr(HerdrModel.stopArgv(session: name)) != nil
    }

    /// Delete a herdr session. Returns whether the command succeeded.
    @discardableResult
    func deleteSession(name: String) -> Bool {
        herdr(HerdrModel.deleteArgv(session: name)) != nil
    }
}
