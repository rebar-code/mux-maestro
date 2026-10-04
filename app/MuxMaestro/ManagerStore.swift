import Foundation
import SQLite3

/// A single review-list row as written by the `mux` CLI (the manager agent's
/// only write path) and rendered by the app. Severities the agent might invent
/// map down to `.info` rather than throwing — the store never rejects a row.
struct ManagerReviewItem: Equatable {
    enum Severity: String {
        case info, warn, blocked

        init(rawValue: String) {
            switch rawValue {
            case "warn": self = .warn
            case "blocked": self = .blocked
            default: self = .info
            }
        }
    }

    let key: String
    let host: String
    let session: String
    let window: Int?
    let severity: Severity
    let text: String
    let updatedAt: Int
    let dismissed: Bool
    /// What makes the row answerable from the phone; nil for a plain row.
    var card: ManagerCard? = nil

    /// The key prefix `mux point` owns. `mux review add` refuses it, so a row
    /// with this prefix names a session the CLI checked.
    static let pointerPrefix = "point:"
    /// The most pointers kept at once. `mux point` drops the oldest above it.
    static let maxPointers = 20

    /// A pointer at a session that needs the human, not a plain review note.
    var isPointer: Bool { key.hasPrefix(Self.pointerPrefix) }
}

/// A transient toast the agent raised via `mux notify`.
struct ManagerNotification: Equatable {
    let id: Int64
    let host: String
    let session: String
    let text: String
    let createdAt: Int
}

/// One `work_log` row: a spawned agent and where its work lives. Written by
/// `mux event` (every hook) and by `spin.py --work-log`, never by hand — the app
/// only reads it, to render "Recent work".
struct WorkLogRow: Equatable {
    let id: Int64
    /// The claude/codex session id, empty until the agent's first event lands.
    let sessionId: String
    /// "claude", "codex", or empty when the spawner didn't say.
    let agent: String
    /// Basename of the main checkout, so worktrees of one repo read as one repo.
    let repo: String
    let branch: String
    /// The `@mm_prs` numbers. The column is the raw space-separated text; a token
    /// that isn't a number is dropped rather than failing the row.
    let prs: [Int]
    let host: String
    /// tmux session name.
    let session: String
    /// tmux window index.
    let window: Int?
    /// tmux pane `%id`.
    let pane: String
    let cwd: String
    /// spawned | idle | busy | waiting | done | ended.
    let lastState: String
    let firstSeen: Int
    let lastSeen: Int
}

/// One line for the manager rail's "Updates" feed: either an agent that finished
/// a turn (`agent_events` Stop) or a toast the agent raised (`mux notify`). The
/// two live in different tables because they have different writers and
/// lifetimes, so the feed is a read-time union rather than a third table.
struct ManagerUpdate: Equatable {
    enum Kind: String {
        /// An agent's turn ended.
        case done
        /// A `mux notify` toast.
        case notification
    }

    let kind: Kind
    /// The agent's session id. Empty for notifications, which aren't tied to one.
    let sessionId: String
    let host: String
    let session: String
    let window: Int?
    let text: String
    let at: Int
}

/// One session as the app's last tree refresh saw it. The app replaces the whole
/// set each refresh; the agent reads it back with `mux sessions` to survey every
/// host at once — without spawning an ssh per host of its own.
struct ManagerSessionRow: Equatable {
    /// The three states the survey speaks in. Deliberately coarser than
    /// `AttentionStatus`: the manager only cares who is working, who is quiet,
    /// and who is stuck waiting on a human.
    enum State: String {
        /// Working — an agent is running in the session.
        case active
        /// Nothing pending, or no agent mapped to the session.
        case inactive
        /// Blocked on a prompt / needs a response.
        case waiting

        /// Fold the sidebar's attention status onto the survey vocabulary.
        /// `.unknown` (no Claude session maps to the tmux session) reads as
        /// inactive — a plain shell is not "working".
        init(_ attention: AttentionStatus) {
            switch attention {
            case .waiting: self = .waiting
            case .busy: self = .active
            case .idle, .unknown: self = .inactive
            }
        }

        /// Unrecognized text from the DB reads as inactive, mirroring
        /// `ManagerReviewItem.Severity` — the store never rejects a row.
        init(rawValue: String) {
            switch rawValue {
            case "active": self = .active
            case "waiting": self = .waiting
            default: self = .inactive
            }
        }

        /// Survey order — stuck first, then working, then quiet.
        var sortRank: Int {
            switch self {
            case .waiting: return 0
            case .active: return 1
            case .inactive: return 2
            }
        }
    }

    let name: String
    let host: String
    let attached: Bool
    let state: State
    let windows: Int
    let panes: Int
    let cwd: String
    /// The tmux index of every window, so `mux point` can check a window
    /// without calling tmux. nil when the row came from a snapshot that an
    /// older build wrote, which has no such list.
    var windowIndexes: [Int]? = nil
}

enum ManagerStoreError: LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "Maestro DB open failed: \(m)"
        case .prepare(let m): return "Maestro DB prepare failed: \(m)"
        case .step(let m): return "Maestro DB step failed: \(m)"
        }
    }
}

/// App-side read/write access to the manager's shared SQLite DB — the same file
/// the `mux` CLI writes and the schema of which it also creates, so app and agent
/// can start in either order. One instance per DB path.
///
/// Opened with `FULLMUTEX`, so the handle is safe to share, but callers should
/// still drive it from a single serial queue: statements are prepared and
/// finalized inline per call, and there is no cross-call transaction state to
/// protect beyond what SQLite's own mutex covers.
final class ManagerStore {
    private let db: OpaquePointer

    /// A binding transient that outlives the `sqlite3_bind_text` call. SQLite's
    /// `SQLITE_TRANSIENT` tells it to copy, so a plain Swift `String` bridged to
    /// UTF-8 is enough — but we route every bind through here for one escape hatch.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(dbPath: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw ManagerStoreError.open(message)
        }
        self.db = handle
        do {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA busy_timeout=3000;")
            try exec(Self.schemaSQL)
            try addColumn("window_indexes", "TEXT", to: "sessions")
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Reads

    /// Review rows ordered the way the rail renders them: live items before
    /// dismissed, then most severe first (`blocked` < `warn` < `info`), then most
    /// recently updated. Dismissed rows are excluded unless asked for.
    func reviewItems(includeDismissed: Bool = false) throws -> [ManagerReviewItem] {
        let sql = """
        SELECT r.key, r.host, r.session, r.window, r.severity, r.text, r.updated_at, r.dismissed,
               c.v, c.pane, c.body, c.actions, c.answer, c.answered_at
        FROM review r LEFT JOIN review_card c ON c.key = r.key
        \(includeDismissed ? "" : "WHERE r.dismissed = 0")
        ORDER BY r.dismissed ASC,
                 CASE r.severity WHEN 'blocked' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END,
                 r.updated_at DESC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var items: [ManagerReviewItem] = []
        while try step(stmt) == SQLITE_ROW {
            items.append(ManagerReviewItem(
                key: column(stmt, 0),
                host: column(stmt, 1),
                session: column(stmt, 2),
                window: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3)),
                severity: ManagerReviewItem.Severity(rawValue: column(stmt, 4)),
                text: column(stmt, 5),
                updatedAt: Int(sqlite3_column_int64(stmt, 6)),
                dismissed: sqlite3_column_int64(stmt, 7) != 0,
                // No `review_card` row: every one of its columns is NULL.
                card: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : ManagerCard.row(
                    version: Int(sqlite3_column_int64(stmt, 8)), pane: column(stmt, 9),
                    body: column(stmt, 10), actions: column(stmt, 11), answer: column(stmt, 12),
                    answeredAt: sqlite3_column_type(stmt, 13) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(stmt, 13)))
            ))
        }
        return items
    }

    /// Toasts the app hasn't shown yet, oldest first.
    func unseenNotifications() throws -> [ManagerNotification] {
        let stmt = try prepare("""
        SELECT id, host, session, text, created_at
        FROM notifications WHERE seen = 0 ORDER BY id;
        """)
        defer { sqlite3_finalize(stmt) }
        var items: [ManagerNotification] = []
        while try step(stmt) == SQLITE_ROW {
            items.append(ManagerNotification(
                id: sqlite3_column_int64(stmt, 0),
                host: column(stmt, 1),
                session: column(stmt, 2),
                text: column(stmt, 3),
                createdAt: Int(sqlite3_column_int64(stmt, 4))
            ))
        }
        return items
    }

    /// The last published session snapshot, ordered the way `mux sessions`
    /// prints it: waiting first, then active, then inactive, then by name.
    func sessions() throws -> [ManagerSessionRow] {
        let stmt = try prepare("""
        SELECT name, host, attached, status, windows, panes, cwd, window_indexes
        FROM sessions
        ORDER BY CASE status WHEN 'waiting' THEN 0 WHEN 'active' THEN 1 ELSE 2 END,
                 host, name;
        """)
        defer { sqlite3_finalize(stmt) }
        var rows: [ManagerSessionRow] = []
        while try step(stmt) == SQLITE_ROW {
            rows.append(ManagerSessionRow(
                name: column(stmt, 0),
                host: column(stmt, 1),
                attached: sqlite3_column_int64(stmt, 2) != 0,
                state: ManagerSessionRow.State(rawValue: column(stmt, 3)),
                windows: Int(sqlite3_column_int64(stmt, 4)),
                panes: Int(sqlite3_column_int64(stmt, 5)),
                cwd: column(stmt, 6),
                windowIndexes: sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil : column(stmt, 7).split(separator: ",").compactMap { Int($0) }
            ))
        }
        return rows
    }

    /// Every live `agent_state` row, as the agents' hooks last wrote them through
    /// `mux event`. Ended sessions and states this build doesn't know are skipped.
    func agentStates() throws -> [AgentStateRow] {
        let stmt = try prepare("""
        SELECT session_id, agent, state, reason, pane, cwd, since, updated_at
        FROM agent_state WHERE state <> 'ended';
        """)
        defer { sqlite3_finalize(stmt) }
        var rows: [AgentStateRow] = []
        while try step(stmt) == SQLITE_ROW {
            guard let state = AgentStateRow.State(rawValue: column(stmt, 2)) else { continue }
            rows.append(AgentStateRow(
                sessionId: column(stmt, 0),
                agent: column(stmt, 1),
                state: state,
                reason: column(stmt, 3),
                pane: column(stmt, 4),
                cwd: column(stmt, 5),
                since: Int(sqlite3_column_int64(stmt, 6)),
                updatedAt: Int(sqlite3_column_int64(stmt, 7))
            ))
        }
        return rows
    }

    /// The spawned agents the manager knows about, most recently seen first.
    func workLog(limit: Int = 50) throws -> [WorkLogRow] {
        let stmt = try prepare("""
        SELECT id, session_id, agent, repo, branch, prs, host, session, window,
               pane, cwd, last_state, first_seen, last_seen
        FROM work_log ORDER BY last_seen DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindInt(stmt, 1, limit)
        var rows: [WorkLogRow] = []
        while try step(stmt) == SQLITE_ROW {
            rows.append(WorkLogRow(
                id: sqlite3_column_int64(stmt, 0),
                sessionId: column(stmt, 1),
                agent: column(stmt, 2),
                repo: column(stmt, 3),
                branch: column(stmt, 4),
                prs: Self.parsePRs(column(stmt, 5)),
                host: column(stmt, 6),
                session: column(stmt, 7),
                window: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(stmt, 8)),
                pane: column(stmt, 9),
                cwd: column(stmt, 10),
                lastState: column(stmt, 11),
                firstSeen: Int(sqlite3_column_int64(stmt, 12)),
                lastSeen: Int(sqlite3_column_int64(stmt, 13))
            ))
        }
        return rows
    }

    /// The rail's "Updates" feed since `since` (epoch seconds, inclusive), newest
    /// first. Two sources unioned at read time: a `Stop` event means an agent
    /// finished a turn, a notification is something the agent chose to say. Host,
    /// session and window come from `work_log` when the session is known there;
    /// an agent nobody spawned through `mux spin` still shows, just unplaced.
    func updates(since: Int, limit: Int = 30) throws -> [ManagerUpdate] {
        let stmt = try prepare("""
        SELECT 'done' AS kind, e.session_id, COALESCE(w.host, 'localhost'),
               COALESCE(w.session, ''), w.window, e.summary, e.ts AS at
        FROM agent_events e
        LEFT JOIN work_log w ON w.session_id = e.session_id
        WHERE e.event = 'Stop' AND e.ts >= ?
        UNION ALL
        SELECT 'notification', '', host, session, NULL, text, created_at AS at
        FROM notifications WHERE created_at >= ?
        ORDER BY at DESC LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindInt(stmt, 1, since)
        bindInt(stmt, 2, since)
        bindInt(stmt, 3, limit)
        var rows: [ManagerUpdate] = []
        while try step(stmt) == SQLITE_ROW {
            let kind = ManagerUpdate.Kind(rawValue: column(stmt, 0)) ?? .done
            let text = column(stmt, 5)
            rows.append(ManagerUpdate(
                kind: kind,
                sessionId: column(stmt, 1),
                host: column(stmt, 2),
                session: column(stmt, 3),
                window: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(stmt, 4)),
                // A Stop hook fires with no summary when the turn said nothing;
                // the feed still needs a line, and "Done" is what it means.
                text: text.isEmpty && kind == .done ? "Done" : text,
                at: Int(sqlite3_column_int64(stmt, 6))
            ))
        }
        return rows
    }

    /// The agents blocked on the human — the rail's "Needs you" section. Filtered
    /// in Swift because `agentStates()` already drops ended and unknown states.
    func waitingAgents() throws -> [AgentStateRow] {
        try agentStates().filter { $0.state == .waiting }
    }

    /// `@mm_prs` is stored verbatim (space-separated numbers). A token that isn't
    /// a number is dropped: the column is whatever the window title carried, and
    /// one odd token must not cost the whole row.
    private static func parsePRs(_ text: String) -> [Int] {
        text.split(separator: " ").compactMap { Int($0) }
    }

    // MARK: Writes

    /// Forget every hook-reported state. Called when the hooks are removed:
    /// nothing would move a row after that, so a stale `waiting` would stay red.
    func clearAgentStates() throws {
        try exec("DELETE FROM agent_state;")
    }

    /// Replace the whole session snapshot in one transaction. A snapshot, not a
    /// merge: a session that vanished must disappear from the survey, and the
    /// shared `updated_at` is what `mux sessions` uses to call the data stale
    /// when the app is not running.
    func replaceSessions(_ rows: [ManagerSessionRow]) throws {
        let now = Int(Date().timeIntervalSince1970)
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM sessions;")
            let stmt = try prepare("""
            INSERT INTO sessions(
              name, host, attached, status, windows, panes, cwd, updated_at, window_indexes)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }
            for row in rows {
                sqlite3_reset(stmt)
                bindText(stmt, 1, row.name)
                bindText(stmt, 2, row.host)
                bindInt(stmt, 3, row.attached ? 1 : 0)
                bindText(stmt, 4, row.state.rawValue)
                bindInt(stmt, 5, row.windows)
                bindInt(stmt, 6, row.panes)
                bindText(stmt, 7, row.cwd)
                bindInt(stmt, 8, now)
                if let indexes = row.windowIndexes {
                    bindText(stmt, 9, indexes.map(String.init).joined(separator: ","))
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                _ = try step(stmt)
            }
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        try exec("COMMIT;")
    }

    /// Human dismissal — sticky, and a different path from the agent's
    /// `mux review done` (which deletes the row). Bumps `updated_at`.
    func dismiss(key: String) throws {
        let stmt = try prepare("UPDATE review SET dismissed = 1, updated_at = ? WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        bindInt(stmt, 1, Int(Date().timeIntervalSince1970))
        bindText(stmt, 2, key)
        _ = try step(stmt)
    }

    /// The human answered a card from the phone and the text reached the pane.
    /// The row stays listed; `mux review list --json` shows the answer.
    func recordAnswer(key: String, label: String, at: Int) throws {
        let stmt = try prepare("UPDATE review_card SET answer = ?, answered_at = ? WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, label)
        bindInt(stmt, 2, at)
        bindText(stmt, 3, key)
        _ = try step(stmt)
    }

    func markSeen(upTo id: Int64) throws {
        let stmt = try prepare("UPDATE notifications SET seen = 1 WHERE id <= ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        _ = try step(stmt)
    }

    func pruneDismissed(olderThanDays: Int = 7) throws {
        let cutoff = Int(Date().timeIntervalSince1970) - olderThanDays * 86_400
        let stmt = try prepare("DELETE FROM review WHERE dismissed = 1 AND updated_at < ?;")
        defer { sqlite3_finalize(stmt) }
        bindInt(stmt, 1, cutoff)
        _ = try step(stmt)
        // A card has no life without its review row.
        try exec("DELETE FROM review_card WHERE key NOT IN (SELECT key FROM review);")
    }

    /// Mirrors `mux review add`: upsert keyed on `key`, preserving `dismissed`
    /// and `created_at` across a conflict. For tests and app-side tooling.
    func upsertReview(
        key: String,
        host: String = "localhost",
        session: String = "",
        window: Int? = nil,
        severity: ManagerReviewItem.Severity = .info,
        text: String
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        let stmt = try prepare("""
        INSERT INTO review(key, host, session, window, severity, text, created_at, updated_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
          host = excluded.host,
          session = excluded.session,
          window = excluded.window,
          severity = excluded.severity,
          text = excluded.text,
          updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, host)
        bindText(stmt, 3, session)
        if let window {
            bindInt(stmt, 4, window)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        bindText(stmt, 5, severity.rawValue)
        bindText(stmt, 6, text)
        bindInt(stmt, 7, now)
        bindInt(stmt, 8, now)
        _ = try step(stmt)
    }

    /// Mirrors `mux notify`.
    func addNotification(host: String = "localhost", session: String = "", text: String) throws {
        let stmt = try prepare("""
        INSERT INTO notifications(host, session, text, created_at) VALUES(?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, host)
        bindText(stmt, 2, session)
        bindText(stmt, 3, text)
        bindInt(stmt, 4, Int(Date().timeIntervalSince1970))
        _ = try step(stmt)
    }

    /// Mirrors what `spin.py --work-log` and `mux event` write. Exists so tests
    /// (and app-side tooling) can build a work log without shelling out to the
    /// CLI; the app itself never writes this table in normal operation.
    func insertWorkLog(
        sessionId: String = "",
        agent: String = "",
        repo: String = "",
        branch: String = "",
        prs: String = "",
        host: String = "localhost",
        session: String = "",
        window: Int? = nil,
        pane: String = "",
        cwd: String = "",
        lastState: String = "spawned",
        firstSeen: Int? = nil,
        lastSeen: Int? = nil
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        let stmt = try prepare("""
        INSERT INTO work_log(session_id, agent, repo, branch, prs, host, session,
                             window, pane, cwd, last_state, first_seen, last_seen)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sessionId)
        bindText(stmt, 2, agent)
        bindText(stmt, 3, repo)
        bindText(stmt, 4, branch)
        bindText(stmt, 5, prs)
        bindText(stmt, 6, host)
        bindText(stmt, 7, session)
        if let window {
            bindInt(stmt, 8, window)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        bindText(stmt, 9, pane)
        bindText(stmt, 10, cwd)
        bindText(stmt, 11, lastState)
        bindInt(stmt, 12, firstSeen ?? now)
        bindInt(stmt, 13, lastSeen ?? firstSeen ?? now)
        _ = try step(stmt)
    }

    /// Mirrors the `agent_events` insert `mux event` makes on every hook. For
    /// tests: the app reads this table, it never appends to it.
    func insertAgentEvent(
        agent: String = "claude",
        sessionId: String,
        event: String,
        cwd: String = "",
        pane: String = "",
        summary: String = "",
        ts: Int? = nil
    ) throws {
        let stmt = try prepare("""
        INSERT INTO agent_events(agent, session_id, event, cwd, pane, summary, ts)
        VALUES(?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, agent)
        bindText(stmt, 2, sessionId)
        bindText(stmt, 3, event)
        bindText(stmt, 4, cwd)
        bindText(stmt, 5, pane)
        bindText(stmt, 6, summary)
        bindInt(stmt, 7, ts ?? Int(Date().timeIntervalSince1970))
        _ = try step(stmt)
    }

    // MARK: SQLite plumbing

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS review (
      key TEXT PRIMARY KEY,
      host TEXT NOT NULL DEFAULT 'localhost',
      session TEXT NOT NULL DEFAULT '',
      window INTEGER,
      severity TEXT NOT NULL DEFAULT 'info',
      text TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      dismissed INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS review_card (
      key TEXT PRIMARY KEY,                 -- the review row this card belongs to
      v INTEGER NOT NULL DEFAULT 1,         -- card format version
      pane TEXT NOT NULL DEFAULT '',        -- %id of the pane that asked
      body TEXT NOT NULL DEFAULT '',
      actions TEXT NOT NULL DEFAULT '[]',   -- JSON array of {label, text}
      answer TEXT NOT NULL DEFAULT '',      -- label of the action that was delivered
      answered_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS notifications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      host TEXT NOT NULL DEFAULT 'localhost',
      session TEXT NOT NULL DEFAULT '',
      text TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      seen INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS sessions (
      name TEXT NOT NULL,
      host TEXT NOT NULL DEFAULT 'localhost',
      attached INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'inactive',
      windows INTEGER NOT NULL DEFAULT 0,
      panes INTEGER NOT NULL DEFAULT 0,
      cwd TEXT NOT NULL DEFAULT '',
      updated_at INTEGER NOT NULL,
      window_indexes TEXT,
      PRIMARY KEY (host, name)
    );
    CREATE TABLE IF NOT EXISTS agent_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent TEXT NOT NULL,
      session_id TEXT NOT NULL,
      event TEXT NOT NULL,
      cwd TEXT NOT NULL DEFAULT '',
      pane TEXT NOT NULL DEFAULT '',
      summary TEXT NOT NULL DEFAULT '',
      ts INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS agent_events_session ON agent_events(session_id, id);
    CREATE INDEX IF NOT EXISTS agent_events_ts ON agent_events(ts);
    CREATE TABLE IF NOT EXISTS agent_state (
      session_id TEXT PRIMARY KEY,
      agent TEXT NOT NULL,
      state TEXT NOT NULL,
      reason TEXT NOT NULL DEFAULT '',
      pane TEXT NOT NULL DEFAULT '',
      cwd TEXT NOT NULL DEFAULT '',
      since INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS work_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL DEFAULT '',   -- claude/codex id; '' until the agent's first event
      agent TEXT NOT NULL DEFAULT '',        -- claude | codex | ''
      repo TEXT NOT NULL DEFAULT '',         -- basename of the main checkout (worktree-aware)
      branch TEXT NOT NULL DEFAULT '',
      prs TEXT NOT NULL DEFAULT '',          -- @mm_prs verbatim: space-separated numbers
      host TEXT NOT NULL DEFAULT 'localhost',
      session TEXT NOT NULL DEFAULT '',      -- tmux session name
      window INTEGER,                        -- tmux window index
      pane TEXT NOT NULL DEFAULT '',         -- %id
      cwd TEXT NOT NULL DEFAULT '',
      last_state TEXT NOT NULL DEFAULT '',   -- spawned | idle | busy | waiting | done | ended
      first_seen INTEGER NOT NULL,
      last_seen INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS work_log_session ON work_log(session_id) WHERE session_id <> '';
    CREATE INDEX IF NOT EXISTS work_log_last_seen ON work_log(last_seen);
    """

    /// Add a column that a table made by an older build does not have:
    /// `CREATE TABLE IF NOT EXISTS` leaves such a table as it is. The `mux`
    /// CLI does the same in `init_db`, so losing that race is not an error.
    /// Only for a column that is nullable or has a default.
    private func addColumn(_ name: String, _ type: String, to table: String) throws {
        guard try !hasColumn(name, in: table) else { return }
        do {
            try exec("ALTER TABLE \(table) ADD COLUMN \(name) \(type);")
        } catch {
            guard try hasColumn(name, in: table) else { throw error }
        }
    }

    private func hasColumn(_ name: String, in table: String) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM pragma_table_info(?) WHERE name = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, table)
        bindText(stmt, 2, name)
        return try step(stmt) == SQLITE_ROW
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw ManagerStoreError.step(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ManagerStoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer) throws -> Int32 {
        let code = sqlite3_step(stmt)
        guard code == SQLITE_ROW || code == SQLITE_DONE else {
            throw ManagerStoreError.step(String(cString: sqlite3_errmsg(db)))
        }
        return code
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }
}
