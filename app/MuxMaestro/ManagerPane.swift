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
        /// `pane_current_command`: what runs in the pane now.
        var command: String
        var path: String
        /// `pane_start_command`: empty for a pane that began as a plain shell.
        var start: String
    }

    private static let format = ["#{pane_id}", "#{\(mark)}", "#{pane_current_command}",
                                 "#{pane_current_path}", "#{pane_start_command}"].joined(separator: "\t")
    /// What a pane at a prompt runs. The Maestro's pane execs the agent, so a
    /// shell there is the launch that has not finished, or not the Maestro.
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]

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
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, fields[0].hasPrefix("%") else { return nil }
            return Row(
                id: fields[0], marked: !fields[1].isEmpty, command: fields[2], path: fields[3],
                start: fields.dropFirst(4).joined(separator: "\t"))
        }
    }

    /// The Maestro's pane among `rows`: the marked one, else the first-created
    /// pane that the app launched or that sits in `homePath`. One rule for
    /// every caller, so two agents in the session never trade places.
    static func pinned(_ rows: [Row], homePath: String?) -> Row? {
        let home = homePath.map(resolved)
        let marked = rows.filter(\.marked)
        let candidates = marked.isEmpty
            ? rows.filter { $0.start.contains("exec claude") || (home != nil && resolved($0.path) == home) }
            : marked
        // Pane ids count up for the life of the server: the lowest came first.
        return candidates.min { number($0.id) < number($1.id) }
    }

    static func isAgent(_ row: Row) -> Bool {
        let command = row.command.hasPrefix("-") ? String(row.command.dropFirst()) : row.command
        return !command.isEmpty && !shells.contains(command)
    }

    /// The id of the Maestro's pane, or nil when the session has none or the
    /// pane is at a shell. nil means: type nothing. Blocking shell-out.
    static func resolve(
        session: String = ManagerHome.sessionName,
        homePath: String? = ManagerHome.defaultHome()?.path,
        run: ([String]) -> String?
    ) -> String? {
        guard let output = run(listArgv(session: session)),
              let row = pinned(parse(output), homePath: homePath), isAgent(row) else { return nil }
        if !row.marked { _ = run(markArgv(pane: row.id)) }
        return row.id
    }

    private static func number(_ id: String) -> Int {
        Int(id.dropFirst()) ?? .max
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
