import Foundation

/// One pane of an archived window, as it stood just before the kill.
struct ArchivedPane: Equatable {
    /// tmux pane id, e.g. "%12". Gone once the window is killed; kept as the key
    /// the agent join used.
    let id: String
    /// `#{pane_current_path}` — where the pane comes back.
    let cwd: String
    /// `#{pane_current_command}`, e.g. "zsh" or "claude".
    let command: String
    let active: Bool
    /// The agent that ran here; nil for a plain shell.
    let agent: RecoveryAgent?
    /// The id the agent's resume command needs; nil when it could not be read.
    let agentSessionId: String?

    /// An agent ran here but its session id is unknown, so undo brings the pane
    /// back as a shell.
    var lostAgentSession: Bool { agent != nil && agentSessionId == nil }
}

/// Everything undo needs about an archived window. It has to be read before the
/// kill: tmux keeps nothing about a window once it is gone. Held in memory only.
struct ArchivedWindow: Equatable {
    let host: Host
    let session: String
    /// Archiving the session's only window ended the session, so undo creates it.
    let removedSession: Bool
    let index: Int
    let name: String
    /// `#{window_layout}`; empty when tmux reported none.
    let layout: String
    let panes: [ArchivedPane]

    /// What the toast and the error call the window.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "window \(index)" : trimmed
    }
}

/// What a successful undo did.
struct RestoredWindow: Equatable {
    /// The window's index now — the archived one unless that index was taken.
    let index: Int
    /// Panes that ran an agent whose session id was never captured.
    let agentsWithoutSession: Int
}

enum WindowRestoreFailure: Error, Equatable {
    /// A pane's directory is gone (a cleaned-up worktree, a deleted repo).
    case directoryMissing(String)
    /// The window's session was ended some other way after the archive. Undo
    /// only creates a session that the archive itself ended.
    case sessionGone(String)
    case tmux(String)

    var message: String {
        switch self {
        case .directoryMissing(let path): return "\(path) no longer exists."
        case .sessionGone(let session): return "The session “\(session)” no longer exists."
        case .tmux(let reason): return reason
        }
    }

    /// Whether the same undo can succeed later (an ssh timeout, a busy tmux).
    /// The archive stays on the undo stack for these.
    var isRetryable: Bool {
        if case .tmux = self { return true }
        return false
    }
}

/// Capture and restore plan for Archive Window / Undo. Pure and Foundation-only:
/// `TmuxService.archiveWindow` and `restoreArchivedWindow` run the tmux commands,
/// and the resume commands come from the session-recovery code (`SessionRecord`).
enum WindowArchive {
    /// How many archived windows undo can reach back through.
    static let historyLimit = 10
    /// Edit menu: "Undo Archive Window" / "Redo Archive Window".
    static let actionName = "Archive Window"

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh"]

    /// Read window `window` of `session` (nil ⇒ its active window) out of a tree
    /// polled just before the kill. `records` are the `SessionStart` hook's pane
    /// records: they supply the id for a pane the status scan could not identify.
    /// nil when the window is not in the tree or no pane reported a directory.
    static func capture(
        tree: [TmuxSession], host: Host, session: String, window: Int?,
        records: [String: AgentRecord] = [:]
    ) -> ArchivedWindow? {
        guard let owner = tree.first(where: { $0.name == session }) else { return nil }
        let match = window.map { index in owner.windows.first { $0.index == index } }
            ?? (owner.windows.first(where: \.active) ?? owner.windows.first)
        guard let match else { return nil }
        let panes = match.panes.filter { !$0.path.isEmpty }.map { pane -> ArchivedPane in
            let (agent, id) = agentSession(of: pane, record: records[pane.id])
            return ArchivedPane(
                id: pane.id, cwd: pane.path, command: pane.command, active: pane.active,
                agent: agent, agentSessionId: id)
        }
        guard !panes.isEmpty else { return nil }
        return ArchivedWindow(
            host: host, session: session, removedSession: owner.windows.count == 1,
            index: match.index, name: match.name,
            layout: panes.count == match.panes.count ? match.layout : "", panes: panes)
    }

    /// Which agent a pane ran and its session id. The polled ids win; the hook
    /// record covers a pane the poll did not identify.
    ///
    /// The record file is append-only and pane ids start again with the tmux
    /// server, so an old record can carry a new pane's id. A record counts only
    /// when it names the pane's directory and the pane runs something that can be
    /// that agent. An id that is not a session id is dropped. In both cases the
    /// pane is reported as "agent session not found": resuming the wrong
    /// conversation is worse than resuming none.
    private static func agentSession(
        of pane: TmuxPane, record: AgentRecord?
    ) -> (RecoveryAgent?, String?) {
        if let id = pane.claudeSessionId { return (.claude, validSessionId(id)) }
        if let id = pane.codexSessionId { return (.codex, validSessionId(id)) }
        if shells.contains(pane.command), pane.attention == .unknown { return (nil, nil) }
        if let record, record.cwd == pane.path,
           isAgentCommand(pane.command, agent: record.agent) {
            return (record.agent, validSessionId(record.sessionId))
        }
        if pane.command == "codex" { return (.codex, nil) }
        if pane.command == "claude" || pane.attention != .unknown { return (.claude, nil) }
        return (nil, nil)
    }

    /// Claude Code and Codex session ids are both UUIDs.
    static func validSessionId(_ id: String) -> String? {
        ClaudeSessionRecovery.isSessionId(id) ? id : nil
    }

    /// Whether `command` (`#{pane_current_command}`) can be `agent`: its own
    /// name, `node`, or a version number, which is how Claude Code names its
    /// process.
    static func isAgentCommand(_ command: String, agent: RecoveryAgent) -> Bool {
        command == agent.rawValue || command == "node"
            || command.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) != nil
    }

    /// The window as a recovery snapshot, so `SessionRecord.restorePlan` builds
    /// the resume commands exactly as a post-reboot restore does.
    static func snapshot(of archived: ArchivedWindow) -> TreeSnapshot {
        let panes = archived.panes.map { pane in
            TreeSnapshot.Pane(
                id: pane.id, cwd: pane.cwd, active: pane.active,
                claudeSessionId: pane.agent == .claude ? pane.agentSessionId : nil,
                codexSessionId: pane.agent == .codex ? pane.agentSessionId : nil)
        }
        let window = TreeSnapshot.Window(
            index: archived.index, name: archived.name,
            layout: archived.layout.isEmpty ? nil : archived.layout, active: true, panes: panes)
        return TreeSnapshot(
            at: Date(), sessions: [TreeSnapshot.Session(name: archived.session, windows: [window])])
    }

    /// The window to rebuild. Fails when any pane's directory is gone rather than
    /// bringing back half a window. No directory fallback for a missing agent id:
    /// such a pane comes back as a shell.
    static func restorePlan(
        _ archived: ArchivedWindow, directoryExists: (String) -> Bool
    ) -> Result<RestoreWindow, WindowRestoreFailure> {
        if let missing = archived.panes.first(where: { !directoryExists($0.cwd) }) {
            return .failure(.directoryMissing(missing.cwd))
        }
        let plan = SessionRecord.restorePlan(
            tree: snapshot(of: archived), records: [:], directoryExists: { _ in true })
        guard let window = plan.first?.windows.first else {
            return .failure(.tmux("The window has no pane to restore."))
        }
        return .success(window)
    }

    // MARK: Copy

    static func archivedTitle(_ archived: ArchivedWindow) -> String {
        "Archived \(archived.displayName)"
    }

    static func restoredTitle(_ archived: ArchivedWindow) -> String {
        "Restored \(archived.displayName)"
    }

    /// Toast body after an undo: empty unless an agent could not be resumed.
    static func restoredNote(_ restored: RestoredWindow) -> String {
        switch restored.agentsWithoutSession {
        case 0: return ""
        case 1: return "Agent session not found"
        default: return "\(restored.agentsWithoutSession) agent sessions not found"
        }
    }

    /// Toast body when the window could not be read before the kill.
    static let notUndoableNote = "Can’t be undone: the window could not be read"

    static func failureMessage(_ archived: ArchivedWindow, _ failure: WindowRestoreFailure) -> String {
        "Couldn’t restore “\(archived.displayName)”. \(failure.message)"
    }
}

/// The archived windows undo can still reach, newest last. Main thread only.
final class WindowArchiveHistory {
    /// One archive on the undo stack, and the target its undo and redo actions
    /// are registered against. `archived` and `restoredIndex` change as the
    /// window is restored and archived again; only the owning host's serial
    /// driver queue reads or writes them.
    final class Entry {
        var archived: ArchivedWindow
        /// Where undo put the window; what redo archives.
        var restoredIndex: Int?

        // The rest is main thread only.

        /// The panes' directories. They do not change across undo and redo.
        let directories: [String]
        /// The window's host and session, for dropping the entry when either goes.
        let host: Host
        let session: String
        let removedSession: Bool
        /// False while undo has the window back (the entry then waits on the
        /// redo stack).
        var isArchived = true
        /// The worktree the close flow would have cleaned up. It is cleaned up
        /// when this entry leaves the history still archived, not before: undo
        /// needs the directory for as long as it is offered.
        var worktree: String?

        init(_ archived: ArchivedWindow, worktree: String? = nil) {
            self.archived = archived
            self.directories = archived.panes.map(\.cwd)
            self.host = archived.host
            self.session = archived.session
            self.removedSession = archived.removedSession
            self.worktree = worktree
        }
    }

    let limit: Int
    private(set) var entries: [Entry] = []
    /// Called with each entry that leaves the history, so its undo actions go
    /// with it, and with the worktree that is now due for cleanup, if any.
    var onLeave: ((Entry, String?) -> Void)?

    init(limit: Int = WindowArchive.historyLimit) {
        self.limit = max(limit, 1)
    }

    /// Add a new archive. Registering its undo clears the redo stack, so entries
    /// whose window is restored can no longer be redone and leave first.
    @discardableResult
    func push(_ archived: ArchivedWindow, worktree: String? = nil) -> Entry {
        for restored in entries where !restored.isArchived { remove(restored) }
        let entry = Entry(archived, worktree: worktree)
        entries.append(entry)
        while entries.count > limit { remove(entries[0]) }
        return entry
    }

    func remove(_ entry: Entry) {
        guard let position = entries.firstIndex(where: { $0 === entry }) else { return }
        entries.remove(at: position)
        var due = entry.isArchived ? entry.worktree : nil
        // Another archived window may still be restored into the same worktree:
        // the cleanup waits for that one instead.
        if let worktree = due, let heir = entries.first(where: { other in
            other.isArchived && other.directories.contains {
                Worktrees.isInside(path: $0, root: worktree)
            }
        }) {
            heir.worktree = heir.worktree ?? worktree
            due = nil
        }
        onLeave?(entry, due)
    }

    /// The app is quitting, so no undo is offered any more: empty the history
    /// and return every worktree that is due for cleanup.
    func drain() -> [String] {
        var due: [String] = []
        for entry in entries where entry.isArchived {
            if let worktree = entry.worktree, !due.contains(worktree) { due.append(worktree) }
        }
        entries = []
        return due
    }
}
