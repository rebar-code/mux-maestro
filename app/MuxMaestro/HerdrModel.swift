import Foundation

/// herdr — a SEPARATE terminal multiplexer (NOT tmux). It runs its own server +
/// sockets under `~/.config/herdr` and exposes a CLI (`/opt/homebrew/bin/herdr`).
/// It will NOT appear through tmux discovery, so MuxMaestro treats it as its own
/// session SOURCE alongside the tmux hosts.
///
/// herdr's tree is **session → workspace → tab → pane**. In practice the
/// workspace level is a thin container under a session (a session usually has one
/// workspace), so the sidebar folds it away and shows **session → tab → pane** —
/// the same three-level shape the tmux tree uses (session → window → pane). Each
/// tab keeps its workspace id + label, and panes carry the agent/cwd herdr
/// reports.
///
/// JSON shapes (captured from herdr 0.6.10):
///   herdr session list --json
///     {"sessions":[{"default":true,"name":"default","running":true, … }]}
///   herdr tab list            (no --json flag; output IS already JSON)
///     {"id":…,"result":{"type":"tab_list","tabs":[
///        {"tab_id":"w…:1","workspace_id":"w…","number":1,"label":"1",
///         "pane_count":1,"agent_status":"unknown","focused":false}, … ]}}
///   herdr pane list
///     {"id":…,"result":{"type":"pane_list","panes":[
///        {"pane_id":"w…-1","tab_id":"w…:1","workspace_id":"w…",
///         "agent":"claude","agent_status":"working","cwd":"/…",
///         "focused":false,"terminal_id":"term_…"}, … ]}}

/// A herdr pane (leaf). Mirrors the fields herdr's `pane list` reports.
struct HerdrPane: Equatable {
    /// Pane id, e.g. "w6544bc199ea351-1".
    let id: String
    /// Owning tab id, e.g. "w6544bc199ea351:1".
    let tabID: String
    /// The agent label herdr detected/was-told runs here (e.g. "claude"), if any.
    let agent: String?
    /// herdr's own agent status: idle | working | blocked | unknown.
    let agentStatus: HerdrAgentStatus
    /// The pane's working directory, if reported.
    let cwd: String?
    /// Whether this pane is focused.
    let focused: Bool
}

/// A herdr tab, containing panes.
struct HerdrTab: Equatable {
    /// Tab id, e.g. "w6544bc199ea351:1".
    let id: String
    /// Owning workspace id, e.g. "w6544bc199ea351".
    let workspaceID: String
    /// 1-based tab number within its workspace.
    let number: Int
    /// Tab label (defaults to the number as a string).
    let label: String
    /// herdr's agent status rolled up for the tab.
    let agentStatus: HerdrAgentStatus
    /// Whether this tab is focused.
    let focused: Bool
    var panes: [HerdrPane]
}

/// A herdr session (top of the tree). Named (e.g. "default").
struct HerdrSession: Equatable {
    /// Session name — also the argument to `herdr session attach/stop/delete`.
    let name: String
    /// Whether this is the default session.
    let isDefault: Bool
    /// Whether the session's server is running.
    let running: Bool
    var tabs: [HerdrTab]
}

/// herdr's own agent state, reported per pane/tab. Distinct from tmux's
/// Claude-derived `AttentionStatus`, but maps onto it for a uniform sidebar dot.
enum HerdrAgentStatus: String {
    case idle
    case working
    case blocked
    case unknown

    init(raw: String?) {
        self = HerdrAgentStatus(rawValue: raw ?? "") ?? .unknown
    }

    /// Map herdr's agent state onto the sidebar's shared attention dot so a herdr
    /// session reads the same way a tmux one does: blocked → needs you (red),
    /// working → running (green), idle/unknown → quiet (grey).
    var attention: AttentionStatus {
        switch self {
        case .blocked: return .waiting
        case .working: return .busy
        case .idle: return .idle
        case .unknown: return .unknown
        }
    }
}

/// Pure parsing + command construction for herdr. No process spawning here, so
/// every JSON shape and every argv is unit-tested against a FakeRunner.
enum HerdrModel {
    // MARK: Command construction

    /// `herdr session list --json` — the one subcommand that takes `--json`.
    static let sessionListArgv = ["session", "list", "--json"]
    /// `herdr tab list` — already emits JSON (no `--json` flag exists).
    static let tabListArgv = ["tab", "list"]
    /// `herdr pane list` — already emits JSON.
    static let paneListArgv = ["pane", "list"]

    /// The shell command the libghostty surface runs to attach to `session`.
    /// Single-quoted so a session name with shell metacharacters is safe.
    static func attachCommand(herdrPath: String, session: String) -> String {
        "\(herdrPath) session attach \(shellQuote(session))"
    }

    /// `herdr session stop <name>` argv (graceful stop of the session's server).
    static func stopArgv(session: String) -> [String] {
        ["session", "stop", session]
    }

    /// `herdr session delete <name>` argv (remove the session).
    static func deleteArgv(session: String) -> [String] {
        ["session", "delete", session]
    }

    /// Single-quote for safe embedding in a shell command line.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Parsing

    /// Parse `herdr session list --json`:
    /// `{"sessions":[{"name":"default","default":true,"running":true, …}]}`.
    /// Tabs/panes are attached by the caller from separate list calls.
    static func parseSessions(_ data: Data) -> [HerdrSession] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = obj["sessions"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return HerdrSession(
                name: name,
                isDefault: (row["default"] as? Bool) ?? false,
                running: (row["running"] as? Bool) ?? false,
                tabs: [])
        }
    }

    /// Parse `herdr tab list`:
    /// `{"result":{"type":"tab_list","tabs":[{"tab_id":…, …}]}}`.
    static func parseTabs(_ data: Data) -> [HerdrTab] {
        guard let rows = resultArray(data, key: "tabs") else { return [] }
        return rows.compactMap { row in
            guard let id = row["tab_id"] as? String, !id.isEmpty else { return nil }
            let number = intValue(row["number"]) ?? 0
            return HerdrTab(
                id: id,
                workspaceID: (row["workspace_id"] as? String) ?? "",
                number: number,
                label: (row["label"] as? String) ?? String(number),
                agentStatus: HerdrAgentStatus(raw: row["agent_status"] as? String),
                focused: (row["focused"] as? Bool) ?? false,
                panes: [])
        }
    }

    /// Parse `herdr pane list`:
    /// `{"result":{"type":"pane_list","panes":[{"pane_id":…, …}]}}`.
    static func parsePanes(_ data: Data) -> [HerdrPane] {
        guard let rows = resultArray(data, key: "panes") else { return [] }
        return rows.compactMap { row in
            guard let id = row["pane_id"] as? String, !id.isEmpty else { return nil }
            return HerdrPane(
                id: id,
                tabID: (row["tab_id"] as? String) ?? "",
                agent: (row["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                agentStatus: HerdrAgentStatus(raw: row["agent_status"] as? String),
                cwd: (row["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                focused: (row["focused"] as? Bool) ?? false)
        }
    }

    /// Assemble the full tree: panes nest under their tabs (by `tab_id`), and tabs
    /// nest under sessions. herdr's tab/pane lists are server-wide (not per
    /// session), and the running server backs exactly one session at a time, so
    /// all tabs/panes belong to the single running session. If a session isn't
    /// running it gets no tabs. Tabs sort by number; panes by id (stable order).
    static func assemble(
        sessions: [HerdrSession], tabs: [HerdrTab], panes: [HerdrPane]
    ) -> [HerdrSession] {
        let panesByTab = Dictionary(grouping: panes, by: { $0.tabID })
        let builtTabs = tabs
            .sorted { $0.number < $1.number }
            .map { tab -> HerdrTab in
                var t = tab
                t.panes = (panesByTab[tab.id] ?? []).sorted { $0.id < $1.id }
                return t
            }
        return sessions.map { session -> HerdrSession in
            var s = session
            s.tabs = session.running ? builtTabs : []
            return s
        }
    }

    /// A session's rolled-up attention for its sidebar dot: the most
    /// attention-worthy state across its tabs/panes (blocked > working > idle),
    /// so a herdr session needing input surfaces like a waiting tmux one.
    static func sessionAttention(_ session: HerdrSession) -> AttentionStatus {
        let statuses = session.tabs.flatMap { tab in
            [tab.agentStatus] + tab.panes.map(\.agentStatus)
        }
        return statuses.map(\.attention).min(by: { $0.sortRank < $1.sortRank }) ?? .unknown
    }

    // MARK: helpers

    /// Pull the `result.<key>` array out of a `{id,result:{type,…}}` envelope.
    private static func resultArray(_ data: Data, key: String) -> [[String: Any]]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let rows = result[key] as? [[String: Any]]
        else { return nil }
        return rows
    }

    /// Coerce a JSON number that may arrive as Int, Double, or String.
    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
