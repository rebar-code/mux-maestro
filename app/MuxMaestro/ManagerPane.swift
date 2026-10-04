import Foundation

/// Which pane of the `mux-manager` session is the Maestro.
///
/// A tmux target that is only a session name means the session's active pane.
/// The session can hold more windows than the one the app made (a shell opened
/// from the rail terminal, a second agent), and the chat was once typed into
/// whichever was active. So nothing addresses the session: every read and
/// write goes to one pane id, found here.
///
/// The pane the app creates carries a pane option, `@mux_maestro`. The mark
/// stays with the pane when windows are added, moved or selected. A session
/// from before the mark gets it on first use: the first-created pane that
/// was started with the app's launch command, or that sits in the manager home.
enum ManagerPane {
    static let mark = "@mux_maestro"

    struct Row: Equatable {
        var id: String
        var marked: Bool
        /// Started with the app's launch command (`launchShell`).
        var launched: Bool
        /// At a shell now. The Maestro's pane execs the agent, so a shell
        /// there is a launch that has not finished, or not the Maestro.
        var shell: Bool
        var path: String
    }

    /// What the session holds for the Maestro.
    enum Lookup: Equatable {
        case pane(String)
        /// The app's own launch, still in its login shell. The agent follows.
        case starting
        case none
    }

    /// tmux works out every yes/no itself and prints `1` or `0`; the only free
    /// text is the path, and it is last. Spaces part the fields, not tabs: a
    /// tmux client with no UTF-8 locale (an app opened from Finder) prints
    /// every control character as `_`.
    private static let format = [
        "#{pane_id}", "#{?#{\(mark)},1,0}", "#{m:*exec claude*,#{pane_start_command}}",
        "#{m/r:^-?(zsh|bash|sh|fish|dash|ksh|tcsh|csh|nu)$,#{pane_current_command}}",
        "#{pane_current_path}",
    ].joined(separator: " ")

    /// Every pane of the session, in all its windows.
    static func listArgv(session: String) -> [String] {
        ["list-panes", "-s", "-t", "=\(session)", "-F", format]
    }

    static func markArgv(pane: String) -> [String] {
        ["set-option", "-p", "-t", pane, mark, "1"]
    }

    /// Appended to the `new-session` that makes the session: marks its pane in
    /// the same tmux call, while it is the only pane the session has.
    static func createMarkArgv(session: String) -> [String] {
        [";"] + markArgv(pane: "=\(session):")
    }

    /// Bring the Maestro's window to the front of its session.
    static func showArgv(pane: String) -> [String] {
        ["select-window", "-t", pane]
    }

    static func parse(_ output: String) -> [Row] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
                .map(String.init)
            let flags = fields.dropFirst().prefix(3)
            guard fields.count >= 4, fields[0].hasPrefix("%"),
                  flags.allSatisfy({ $0 == "1" || $0 == "0" }) else { return nil }
            return Row(
                id: fields[0], marked: fields[1] == "1", launched: fields[2] == "1",
                shell: fields[3] == "1", path: fields.count > 4 ? fields[4] : "")
        }
    }

    /// The Maestro's pane among `rows`: the marked one, else the first-created
    /// pane that the app launched or that sits in `homePath`. One rule for
    /// every caller, so two agents in the session never trade places.
    static func pinned(_ rows: [Row], homePath: String?) -> Row? {
        let home = homePath.map(resolved)
        let marked = rows.filter(\.marked)
        let candidates = marked.isEmpty
            ? rows.filter { $0.launched || (home != nil && resolved($0.path) == home) }
            : marked
        // Pane ids count up for the life of the server: the lowest came first.
        return candidates.min { number($0.id) < number($1.id) }
    }

    /// Find the Maestro's pane, and mark it when the rule found it unmarked.
    /// Blocking shell-out.
    static func lookup(
        session: String = ManagerHome.sessionName,
        homePath: String? = ManagerHome.defaultHome()?.path,
        run: ([String]) -> String?
    ) -> Lookup {
        guard let output = run(listArgv(session: session)),
              let row = pinned(parse(output), homePath: homePath) else { return .none }
        guard !row.shell else { return row.launched ? .starting : .none }
        if !row.marked { _ = run(markArgv(pane: row.id)) }
        return .pane(row.id)
    }

    /// The id of the Maestro's pane, or nil when the session has none or the
    /// pane is at a shell. nil means: type nothing. Blocking shell-out.
    static func resolve(
        session: String = ManagerHome.sessionName,
        homePath: String? = ManagerHome.defaultHome()?.path,
        run: ([String]) -> String?
    ) -> String? {
        guard case .pane(let id) = lookup(session: session, homePath: homePath, run: run) else { return nil }
        return id
    }

    private static func number(_ id: String) -> Int {
        Int(id.dropFirst()) ?? .max
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
