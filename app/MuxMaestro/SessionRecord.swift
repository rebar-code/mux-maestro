import Foundation

/// Which agent CLI a recorded session belongs to. The raw value is what the
/// `SessionStart` hook writes, and it selects the resume command.
enum RecoveryAgent: String, Codable {
    case claude
    case codex

    /// The command that reopens `sessionId` in this agent. Staged (typed, not
    /// run) into the restored pane, so the user fires each one when they get to
    /// it rather than booting 28 agents at once.
    func resumeCommand(sessionId: String) -> String {
        switch self {
        case .claude: return "claude --resume \(sessionId)"
        case .codex: return "codex resume \(sessionId)"
        }
    }
}

/// One `SessionStart` observation: an agent session id bound to the tmux pane it
/// started in. Written by `Resources/recovery/record-agent-session.sh`.
struct AgentRecord: Equatable {
    /// tmux pane id, e.g. "%248" — the join key against the topology snapshot.
    let pane: String
    let agent: RecoveryAgent
    /// The agent's session UUID, the argument to `--resume` / `resume`.
    let sessionId: String
    /// The directory the session started in.
    let cwd: String
}

/// The tmux tree as it stood at the last poll before the server died. Written by
/// the app from the poll it already runs, so recovery reads *what existed*
/// rather than inferring it from transcript mtimes.
///
/// It also captures the Claude/Codex ids visible on each polled pane.
/// `AgentRecord` supplements those ids for panes the status poll could not
/// identify. That sidesteps needing a session-close event — Codex has no
/// `SessionEnd` — because a session killed before the reboot simply isn't in the
/// last snapshot.
struct TreeSnapshot: Codable, Equatable {
    /// When the snapshot was taken. Compared against the boot time to tell a
    /// pre-reboot tree (worth restoring) from one this run just wrote.
    let at: Date
    let sessions: [Session]

    struct Session: Codable, Equatable {
        let name: String
        let windows: [Window]
    }

    struct Window: Codable, Equatable {
        let index: Int
        let name: String
        /// Optional so older snapshots still decode.
        var layout: String? = nil
        var active: Bool? = nil
        let panes: [Pane]
    }

    struct Pane: Codable, Equatable {
        /// tmux pane id, e.g. "%248".
        let id: String
        let cwd: String
        /// Optional so older snapshots still decode.
        var active: Bool? = nil
        var claudeSessionId: String? = nil
        var codexSessionId: String? = nil
    }
}

/// One restored pane: where it opens and what is staged at its prompt.
struct RestorePane: Equatable {
    let cwd: String
    /// `claude --resume <id>` / `codex resume <id>`, or nil for a pane that held
    /// no agent (a plain shell, an editor) — restored empty so the tree keeps its
    /// shape.
    let resumeCommand: String?
    var active = false
}

struct RestoreWindow: Equatable {
    let name: String
    let panes: [RestorePane]
    var index: Int? = nil
    var layout: String? = nil
    var active = false
}

struct RestoreSession: Equatable {
    let name: String
    let windows: [RestoreWindow]

    /// The directory the session itself is created in — its first pane's.
    var cwd: String { windows.first?.panes.first?.cwd ?? "" }
}

/// Durable progress for a restore interrupted by an app crash or a failed tmux
/// command. The original tree remains the restore source until the full plan is
/// rebuilt successfully.
struct RestoreProgress: Codable, Equatable {
    let bootTime: Date
    let snapshotAt: Date
    /// Random per-restore namespace. Interrupted sessions are built under names
    /// derived from this token, so a retry can identify and replace only its own
    /// incomplete work without touching a user's session with the intended name.
    let restoreToken: String
    /// Manual restore policy survives an interrupted rebuild. Manual restores
    /// choose a free name to preserve sessions that were already running.
    let uniqueNames: Bool
    /// Original session name -> actual name created by tmux (which may be
    /// suffixed if a manual restore encountered a name collision).
    var completed: [String: String]
    /// Original session name -> temporary tmux session being rebuilt. Written
    /// before `new-session`, so a retry can find a tree interrupted mid-build.
    var inProgress: [String: String]

    private enum CodingKeys: String, CodingKey {
        case bootTime, snapshotAt, restoreToken, uniqueNames, completed, inProgress
    }

    init(
        bootTime: Date, snapshotAt: Date, restoreToken: String, uniqueNames: Bool,
        completed: [String: String], inProgress: [String: String]
    ) {
        self.bootTime = bootTime
        self.snapshotAt = snapshotAt
        self.restoreToken = restoreToken
        self.uniqueNames = uniqueNames
        self.completed = completed
        self.inProgress = inProgress
    }

    /// Older progress files recorded completed names only. Preserve those
    /// entries and upgrade them on the next atomic write.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bootTime = try values.decode(Date.self, forKey: .bootTime)
        snapshotAt = try values.decode(Date.self, forKey: .snapshotAt)
        restoreToken = try values.decodeIfPresent(String.self, forKey: .restoreToken)
            ?? UUID().uuidString
        uniqueNames = try values.decodeIfPresent(Bool.self, forKey: .uniqueNames) ?? false
        completed = try values.decodeIfPresent([String: String].self, forKey: .completed) ?? [:]
        inProgress = try values.decodeIfPresent([String: String].self, forKey: .inProgress) ?? [:]
    }
}

/// Reading and joining the two recovery files under
/// `~/Library/Application Support/MuxMaestro/recovery/`:
///
/// - `agents.jsonl` — appended by the `SessionStart` hook, one line per session
///   start, latest line wins per pane.
/// - `tree.json` — overwritten by the app whenever the polled tmux tree changes.
///
/// The pure core here is IO-free so the join, the last-line-wins collapse and
/// the drop rules are unit-tested directly.
enum SessionRecord {
    private static let snapshotWriteLock = NSLock()
    private static var snapshotWritesSuspended = false

    /// Hold snapshot writes while launch recovery is deciding whether the last
    /// tree belongs to the previous boot. This prevents the first empty tmux poll
    /// from replacing the tree before it can be rebuilt.
    static func suspendSnapshotWrites() {
        snapshotWriteLock.lock()
        snapshotWritesSuspended = true
        snapshotWriteLock.unlock()
    }

    static func resumeSnapshotWrites() {
        snapshotWriteLock.lock()
        snapshotWritesSuspended = false
        snapshotWriteLock.unlock()
    }

    static var canWriteSnapshot: Bool {
        snapshotWriteLock.lock()
        defer { snapshotWriteLock.unlock() }
        return !snapshotWritesSuspended
    }

    // MARK: Locations

    /// `~/Library/Application Support/MuxMaestro/recovery/`, created on demand —
    /// the hook script writes into it too, and either side can get there first.
    static func directory() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }
        let dir = support.appendingPathComponent("MuxMaestro/recovery", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        return dir
    }

    static func agentsURL() -> URL? { directory()?.appendingPathComponent("agents.jsonl") }
    static func treeURL() -> URL? { directory()?.appendingPathComponent("tree.json") }

    /// Marks the boot whose tree.json has already been rebuilt, so a second launch
    /// in the same boot doesn't recreate every session on top of the first set.
    static func restoredMarkerURL() -> URL? {
        directory()?.appendingPathComponent("restored-boot")
    }

    static func restoreProgressURL() -> URL? {
        directory()?.appendingPathComponent("restore-progress.json")
    }

    /// The installed copy of the hook script. It lives outside the app bundle
    /// because the config files point at it by absolute path and `make install`
    /// replaces the bundle wholesale.
    static func hookScriptURL() -> URL? {
        directory()?.appendingPathComponent("record-agent-session.sh")
    }

    // MARK: Pure core (unit-tested)

    /// Parse `agents.jsonl` into one record per pane, last line winning. A pane
    /// is reused by successive sessions over a day, and there is no close event,
    /// so "the newest start seen on this pane" is the live session by definition.
    /// Malformed or unknown-agent lines are skipped rather than failing the parse.
    static func parseAgents(_ text: String) -> [String: AgentRecord] {
        var byPane: [String: AgentRecord] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pane = obj["pane"] as? String, !pane.isEmpty,
                  let agent = (obj["agent"] as? String).flatMap(RecoveryAgent.init(rawValue:)),
                  let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty,
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            byPane[pane] = AgentRecord(
                pane: pane, agent: agent, sessionId: sessionId, cwd: cwd)
        }
        return byPane
    }

    /// Records keyed by directory instead of pane, newest-last-wins — the
    /// fallback for a pane the hook never recorded (the session predates the
    /// install, or started outside tmux and was moved in).
    static func byDirectory(_ records: [String: AgentRecord]) -> [String: AgentRecord] {
        var out: [String: AgentRecord] = [:]
        for record in records.values { out[record.cwd] = record }
        return out
    }

    /// A snapshot of the tmux tree, dropping panes that reported no path (tmux
    /// occasionally returns an empty `pane_current_path`) — a pane with no
    /// directory can't be restored anywhere useful.
    static func snapshot(from sessions: [TmuxSession], at date: Date) -> TreeSnapshot {
        TreeSnapshot(
            at: date,
            sessions: sessions.map { session in
                TreeSnapshot.Session(
                    name: session.name,
                    windows: session.windows.map { window in
                        TreeSnapshot.Window(
                            index: window.index, name: window.name,
                            layout: window.layout.isEmpty ? nil : window.layout,
                            active: window.active,
                            panes: window.panes
                                .filter { !$0.path.isEmpty }
                                .map { TreeSnapshot.Pane(
                                    id: $0.id, cwd: $0.path, active: $0.active,
                                    claudeSessionId: $0.claudeSessionId,
                                    codexSessionId: $0.codexSessionId) })
                    })
            })
    }

    /// Check whether a live tmux session is already the result of rebuilding
    /// `expected`. Used after an interrupted restore so retries don't make a
    /// second copy of a session that finished just before the app stopped.
    static func matches(_ expected: RestoreSession, actual: TmuxSession) -> Bool {
        guard expected.name == actual.name,
              expected.windows.count == actual.windows.count else { return false }
        for (wanted, found) in zip(expected.windows, actual.windows) {
            guard wanted.name == found.name,
                  wanted.index == nil || wanted.index == found.index,
                  wanted.panes.count == found.panes.count,
                  wanted.panes.map(\.cwd) == found.panes.map(\.path) else { return false }
        }
        return true
    }

    /// The join: the snapshot says what existed, the records say which agent
    /// session each pane held.
    ///
    /// A pane is dropped when its directory no longer exists — the repo moved or
    /// was deleted, and `--resume` needs somewhere to run (the same guard the
    /// transcript-scan recovery applies). A window with no surviving pane, and a
    /// session with no surviving window, drop with it.
    ///
    /// `fallbackByDirectory` supplies an id for a pane the hook never recorded,
    /// matched on directory — the first reboot after installing the hooks has a
    /// full tree.json but a thin agents.jsonl.
    static func restorePlan(
        tree: TreeSnapshot,
        records: [String: AgentRecord],
        fallbackByDirectory: [String: AgentRecord] = [:],
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [RestoreSession] {
        tree.sessions.compactMap { session in
            let windows: [RestoreWindow] = session.windows.compactMap { window in
                let panes: [RestorePane] = window.panes.compactMap { pane in
                    guard !pane.cwd.isEmpty, directoryExists(pane.cwd) else { return nil }
                    let record = records[pane.id] ?? fallbackByDirectory[pane.cwd]
                    let capturedResume = pane.claudeSessionId.map {
                        RecoveryAgent.claude.resumeCommand(sessionId: $0)
                    } ?? pane.codexSessionId.map {
                        RecoveryAgent.codex.resumeCommand(sessionId: $0)
                    }
                    return RestorePane(
                        cwd: pane.cwd,
                        resumeCommand: capturedResume ?? record.map {
                            $0.agent.resumeCommand(sessionId: $0.sessionId)
                        }, active: pane.active ?? false)
                }
                guard !panes.isEmpty else { return nil }
                return RestoreWindow(
                    name: window.name, panes: panes, index: window.index,
                    layout: panes.count == window.panes.count ? window.layout : nil,
                    active: window.active ?? false)
            }
            guard !windows.isEmpty else { return nil }
            return RestoreSession(name: session.name, windows: windows)
        }
    }

    /// How many panes in `plan` have an agent session staged — the number the
    /// summary quotes, and the signal that a restore is worth doing at all.
    static func stagedPaneCount(_ plan: [RestoreSession]) -> Int {
        plan.reduce(0) { total, session in
            total + session.windows.reduce(0) { $0 + $1.panes.filter {
                $0.resumeCommand != nil }.count }
        }
    }

    // MARK: Encoding

    /// Dates as epoch seconds so the file stays readable and version-independent.
    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }

    static func encode(_ snapshot: TreeSnapshot) -> Data? {
        try? coder().0.encode(snapshot)
    }

    static func decode(_ data: Data) -> TreeSnapshot? {
        try? coder().1.decode(TreeSnapshot.self, from: data)
    }

    // MARK: Filesystem

    /// Read and join both files. Returns nil when there is no snapshot to work
    /// from. Blocking; call off the main thread.
    static func loadPlan(
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (snapshot: TreeSnapshot, plan: [RestoreSession])? {
        guard let treeURL = treeURL(),
              let data = try? Data(contentsOf: treeURL),
              let snapshot = decode(data)
        else { return nil }
        let text = agentsURL().flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let records = parseAgents(text)
        return (snapshot, restorePlan(
            tree: snapshot, records: records,
            directoryExists: directoryExists))
    }

    /// Overwrite `tree.json`. Atomic so a crash mid-write can't leave a truncated
    /// snapshot where the whole point is surviving an unclean shutdown.
    @discardableResult
    static func writeSnapshot(_ snapshot: TreeSnapshot) -> Bool {
        guard let url = treeURL(), let data = encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func readRestoreProgress() -> RestoreProgress? {
        guard let url = restoreProgressURL(),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? coder().1.decode(RestoreProgress.self, from: data)
    }

    @discardableResult
    static func writeRestoreProgress(_ progress: RestoreProgress) -> Bool {
        guard let url = restoreProgressURL(),
              let data = try? coder().0.encode(progress)
        else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func clearRestoreProgress() {
        guard let url = restoreProgressURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether this boot's tree has already been rebuilt.
    static func hasRestored(bootTime: Date) -> Bool {
        guard let url = restoredMarkerURL(),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            == String(Int(bootTime.timeIntervalSince1970))
    }

    static func markRestored(bootTime: Date) {
        guard let url = restoredMarkerURL() else { return }
        try? String(Int(bootTime.timeIntervalSince1970)).write(
            to: url, atomically: true, encoding: .utf8)
    }
}
