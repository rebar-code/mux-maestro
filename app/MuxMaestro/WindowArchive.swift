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
    /// Resume commands that were not typed, because the pane never showed a
    /// shell prompt to type them at.
    var unsentResumes: [String] = []
}

enum WindowRestoreFailure: Error, Equatable {
    /// A pane's directory is gone (a cleaned-up worktree, a deleted repo).
    case directoryMissing(String)
    /// The window's session was ended some other way after the archive. Undo
    /// only creates a session that the archive itself ended.
    case sessionGone(String)
    /// The host did not answer, so nothing is known about the directory or the
    /// session. Not the same as either being gone.
    case hostUnreachable(String)
    case nothingToRestore
    case tmux(String)

    var message: String {
        switch self {
        case .directoryMissing(let path): return "\(path) no longer exists."
        case .sessionGone(let session): return "The session “\(session)” no longer exists."
        case .hostUnreachable(let host): return "\(host) did not answer."
        case .nothingToRestore: return "The window has no pane to restore."
        case .tmux(let reason): return reason
        }
    }

    /// Whether the same undo can succeed later (an ssh timeout, a busy tmux).
    /// The archive stays on the undo stack for these.
    var isRetryable: Bool {
        switch self {
        case .tmux, .hostUnreachable: return true
        case .directoryMissing, .sessionGone, .nothingToRestore: return false
        }
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
           isAgentCommand(pane.command, agent: record.agent) || pane.attention != .unknown {
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

    /// Whether `command` (`#{pane_current_command}`) is `agent`: its own name,
    /// or for Claude Code a bare version number, which is how it names its
    /// process. `node` does not count: it is just as often a dev server.
    static func isAgentCommand(_ command: String, agent: RecoveryAgent) -> Bool {
        if command == agent.rawValue { return true }
        return agent == .claude && command.range(
            of: "^[0-9]+[.][0-9]+[.][0-9]+$", options: .regularExpression) != nil
    }

    /// Whether a pane is at a shell prompt, from `TmuxService.shellPromptFormat`
    /// output: its foreground command is a shell and the cursor has left column
    /// zero, so a prompt is drawn. A shell still running its login scripts, or
    /// anything else in the foreground, is not a place to type a command.
    static func isShellPrompt(_ probe: String) -> Bool {
        let fields = probe.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        guard fields.count == 2, let column = Int(fields[1]), column > 0 else { return false }
        let command = fields[0].hasPrefix("-") ? String(fields[0].dropFirst()) : fields[0]
        return shells.contains(command)
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
    ///
    /// `directoryExists` answers nil when the host could not be asked. That is
    /// not a missing directory: the undo stays available.
    static func restorePlan(
        _ archived: ArchivedWindow, directoryExists: (String) -> Bool?
    ) -> Result<RestoreWindow, WindowRestoreFailure> {
        for pane in archived.panes {
            guard let exists = directoryExists(pane.cwd) else {
                return .failure(.hostUnreachable(archived.host.name))
            }
            if !exists { return .failure(.directoryMissing(pane.cwd)) }
        }
        let plan = SessionRecord.restorePlan(
            tree: snapshot(of: archived), records: [:], directoryExists: { _ in true })
        guard let window = plan.first?.windows.first else {
            return .failure(.nothingToRestore)
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
        if let resume = restored.unsentResumes.first { return "Shell not ready. Run: \(resume)" }
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
        /// Whether the archive ended the session. A redo can change it.
        private(set) var removedSession: Bool
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

        /// Redo archived the window again: take what changed in the new capture.
        func adopt(_ again: ArchivedWindow) {
            removedSession = again.removedSession
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

    /// A host's tree reloaded with the sessions `live`. An archive whose session
    /// was ended some other way cannot be undone and leaves. One whose archive
    /// ended the session stays: undo creates that session again.
    func dropEndedSessions(host: Host, live: Set<String>) {
        for entry in entries where entry.isArchived && entry.host == host
            && !entry.removedSession && !live.contains(entry.session) {
            remove(entry)
        }
    }

    /// A remote host was removed from the app.
    func dropHost(alias: String) {
        for entry in entries where entry.host.sshAlias == alias { remove(entry) }
    }

    /// Worktrees whose cleanup is waiting on an archive, in archive order.
    var pendingWorktrees: [String] {
        var pending: [String] = []
        for entry in entries where entry.isArchived {
            if let worktree = entry.worktree, !pending.contains(worktree) { pending.append(worktree) }
        }
        return pending
    }

    /// The app is quitting, so no undo is offered any more: empty the history
    /// and return every worktree that is due for cleanup.
    func drain() -> [String] {
        let due = pendingWorktrees
        entries = []
        return due
    }
}

/// The worktrees whose cleanup is waiting on an archive, kept on disk so a crash
/// or a kill does not forget them. Paths only: nothing about the windows. The
/// next launch offers the list; it never cleans up by itself.
enum PendingWorktreeCleanups {
    static func fileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }
        return support.appendingPathComponent("MuxMaestro/pending-worktree-cleanups.json")
    }

    /// Write `paths`, or remove the file when there are none.
    @discardableResult
    static func save(_ paths: [String], to url: URL? = fileURL()) -> Bool {
        guard let url else { return false }
        guard !paths.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(paths) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func load(from url: URL? = fileURL()) -> [String] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func offerTitle(_ paths: [String]) -> String {
        paths.count == 1
            ? "Clean up 1 worktree of an archived window?"
            : "Clean up \(paths.count) worktrees of archived windows?"
    }
}
