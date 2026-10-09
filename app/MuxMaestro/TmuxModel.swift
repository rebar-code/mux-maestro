import Foundation
import CoreGraphics

/// Attention status for a session, sourced from Claude Code's session files.
/// Mirrors the `status` field emitted by `tools/sessions.py`.
enum AttentionStatus: String {
    /// Needs the human: a permission prompt or otherwise waiting on input. Red.
    case waiting
    /// Actively running / busy. Green.
    case busy
    /// Idle, nothing pending. Grey.
    case idle
    /// No Claude session mapped to this tmux session. Grey (no dot emphasis).
    case unknown

    /// Sort rank — lower sorts to the top. Needs-you first, then running, then
    /// idle, then unknown.
    var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .busy: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    /// The dot glyph shown next to a session in the sidebar.
    var dot: String {
        switch self {
        case .waiting: return "🔴"
        case .busy: return "🟢"
        case .idle, .unknown: return "⚪"
        }
    }

    /// Short, subtle label shown after the session name (empty for the quiet
    /// states so idle rows stay clean).
    var label: String {
        switch self {
        case .waiting: return "needs you"
        case .busy: return "running"
        case .idle, .unknown: return ""
        }
    }
}

/// What a thread's status dot draws. Solid means "look at it", a grey ring
/// means nothing to do, motion means the agent is at work. Green is only for
/// a thread that is new to the user, or one the user flagged.
enum StatusIndicator: String {
    /// Needs the human. Solid red.
    case needsYou
    /// The agent finished and the thread was not opened since. Solid green.
    case unviewed
    /// A turn is running. Grey ring with a circling arc.
    case working
    /// The user flagged the thread to come back to. Green ring.
    case flagged
    /// The agent finished and the thread was opened since. Grey ring.
    case viewed
    /// An agent with no turn yet. Grey ring.
    case idle
    /// No agent. Small grey dot.
    case none

    /// Lower is more urgent: what a window, session or host shows for its panes.
    var rank: Int {
        switch self {
        case .needsYou: return 0
        case .unviewed: return 1
        case .working: return 2
        case .flagged: return 3
        case .viewed: return 4
        case .idle: return 5
        case .none: return 6
        }
    }

    /// The dot for a status alone, where no pane says whether it was viewed.
    init(_ attention: AttentionStatus) {
        switch attention {
        case .waiting: self = .needsYou
        case .busy: self = .working
        case .idle: self = .viewed
        case .unknown: self = .none
        }
    }

    static func rollup(_ indicators: some Sequence<StatusIndicator>) -> StatusIndicator {
        indicators.min { $0.rank < $1.rank } ?? .none
    }
}

/// When the user last had each thread open, by thread id (`MobileSnapshot.threadID`).
/// One store for the Mac sidebar and the phone, so a thread opened on either
/// shows as viewed on both.
struct ViewedThreads: Equatable {
    /// A thread never opened counts as opened at this time: the store's first
    /// run. Without it, every thread that finished before this build would show
    /// as not viewed.
    var baseline: Int
    var viewedAt: [String: Int] = [:]
    /// The threads the user flagged. A flag stays until the user takes it off.
    var flagged: Set<String> = []

    /// Whether the thread was opened after it finished. A thread with no known
    /// finish time is viewed: there is nothing new to look at.
    func isViewed(_ id: String, finishedAt: Int?) -> Bool {
        guard let finishedAt else { return true }
        return (viewedAt[id] ?? baseline) >= finishedAt
    }

    /// Record that the thread is open now. `finishedAt` may be ahead of `now`
    /// (a remote host's clock), so the later of the two is kept. False when
    /// nothing changed.
    @discardableResult
    mutating func mark(_ id: String, finishedAt: Int?, now: Int) -> Bool {
        guard !isViewed(id, finishedAt: finishedAt) else { return false }
        viewedAt[id] = max(now, finishedAt ?? now)
        return true
    }

    /// Drop the threads of `host` that are gone. A tmux pane id is not given
    /// out twice while its server runs, so a dropped id does not come back.
    mutating func prune(host: String, live: Set<String>) {
        let prefix = host + ":"
        viewedAt = viewedAt.filter { !$0.key.hasPrefix(prefix) || live.contains($0.key) }
        flagged = flagged.filter { !$0.hasPrefix(prefix) || live.contains($0) }
    }

    /// Put the flag on the thread or take it off. False when nothing changed.
    @discardableResult
    mutating func setFlagged(_ id: String, _ on: Bool) -> Bool {
        guard flagged.contains(id) != on else { return false }
        if on { flagged.insert(id) } else { flagged.remove(id) }
        return true
    }

    var json: [String: Any] {
        ["baseline": baseline, "viewedAt": viewedAt, "flagged": flagged.sorted()]
    }

    init(baseline: Int, viewedAt: [String: Int] = [:], flagged: Set<String> = []) {
        self.baseline = baseline
        self.viewedAt = viewedAt
        self.flagged = flagged
    }

    /// The stored value, or a new store that starts now.
    init(json: Any?, now: Int) {
        let object = json as? [String: Any]
        baseline = (object?["baseline"] as? NSNumber)?.intValue ?? now
        viewedAt = (object?["viewedAt"] as? [String: NSNumber])?.mapValues(\.intValue) ?? [:]
        flagged = Set(object?["flagged"] as? [String] ?? [])
    }
}

/// A tmux pane.
struct TmuxPane: Equatable {
    /// Pane id, e.g. "%12".
    let id: String
    /// Index within its window, e.g. 0.
    let index: Int
    /// The pane's foreground command, e.g. "nvim".
    let command: String
    /// The pane's title (often the current path or set title).
    let title: String
    /// Whether this is the active pane in its window.
    let active: Bool
    /// The pane's current working directory (`#{pane_current_path}`). Empty when
    /// tmux didn't report it.
    var path: String = ""
    /// Pane geometry within its window, in terminal cells (top-left origin,
    /// border- and status-line-excluded — `#{pane_left/top/width/height}`).
    /// Defaulted to 0 so callers that don't care (and older parses) still build.
    /// Drives the drag-to-rearrange overlay's pixel mapping.
    var left = 0
    var top = 0
    var width = 0
    var height = 0
    /// The pane's shell pid (`#{pane_pid}`) — the root of the pane's process
    /// tree. Codex ids are resolved by walking a `codex` process's parents up to
    /// this pid. Defaulted to 0 so older parses and fixtures still build.
    var pid = 0
    /// Attention status of the Claude/agent session running in this pane, joined
    /// from `sessions.py` by pane id. `.unknown` when no agent maps to this pane.
    /// Part of `==` so a status change re-renders the pane's row via the diff.
    var attention: AttentionStatus = .unknown
    /// The Claude Code session UUID running in this pane, joined from `sessions.py`
    /// by pane id — the id `claude --resume <uuid>` needs, so "Beam to server" can
    /// move *this exact conversation*. nil when no Claude session maps to the pane
    /// (plain shell / nvim / status tool unavailable). Stable across polls for a
    /// running session, so keeping it in `==` costs no diff thrash.
    var claudeSessionId: String? = nil
    /// The codex conversation UUID running in this pane — the id `codex resume
    /// <uuid>` needs — resolved by `CodexSessions` from the rollout files the
    /// codex process holds open. nil when no codex runs here, and always nil for
    /// remote panes (the scan is local-only). Stable across polls, like
    /// `claudeSessionId`, so keeping it in `==` costs no diff thrash.
    var codexSessionId: String? = nil
    /// What this pane's agent last reported through its hooks, when that report
    /// is trusted over the status scan (see `AgentState.isFresh`). nil otherwise.
    var agentState: AgentPaneState? = nil
    /// How close the pane's agent is to losing its prompt cache: 🥱, 💤 or
    /// neither (see `AgentState.idleStage`).
    var idleStage: IdleStage = .awake
    /// The first line of the user's last prompt in the pane's Claude or Codex
    /// thread: the row's line 2. nil for a pane with no readable thread.
    var lastPrompt: LastPrompt? = nil
    /// Epoch seconds the pane's Claude or Codex thread was last written: the
    /// age on the right of line 2. nil for a pane with no readable thread.
    var lastActivityAt: Int? = nil
    /// Epoch seconds the pane's agent finished its last turn. nil while it
    /// runs or waits, before its first turn, and for a pane with no agent.
    var finishedAt: Int? = nil
    /// Whether the user opened the thread after `finishedAt` (`ViewedThreads`).
    /// Stamped on the main thread when a tree lands, not by the poll.
    var viewed = true
    /// Whether the user flagged the thread (`ViewedThreads.flagged`).
    var flagged = false

    /// What the pane's status dot draws.
    var indicator: StatusIndicator {
        switch attention {
        case .waiting: return .needsYou
        case .busy: return .working
        case .unknown: return flagged ? .flagged : .none
        case .idle:
            if agentState?.state == .idle { return flagged ? .flagged : .idle }
            if !viewed { return .unviewed }
            return flagged ? .flagged : .viewed
        }
    }
}

/// A tmux window, containing panes.
extension TmuxWindow {
    /// The pane whose agent thread stands for this window (the Artifacts panel
    /// follows it): the active pane when it runs a Claude or Codex thread, else
    /// the first pane that does, else the active pane.
    var agentPane: TmuxPane? {
        let hasThread = { (p: TmuxPane) in p.claudeSessionId != nil || p.codexSessionId != nil }
        return panes.first { $0.active && hasThread($0) }
            ?? panes.first(where: hasThread) ?? panes.first(where: \.active)
    }
}

struct TmuxWindow: Equatable {
    /// Window index within its session, e.g. 1.
    let index: Int
    /// Window name, e.g. "server".
    let name: String
    /// Whether this is the active window in its session.
    let active: Bool
    var panes: [TmuxPane]
    /// tmux's opaque layout tree, including pane arrangement and proportions.
    /// Empty when an older tmux format or fixture did not provide it.
    var layout: String = ""
    /// The PR numbers an agent declared on this window via the `@mm_prs` tmux user
    /// option, e.g. [1082, 1085]. Empty when unset. The option lives in tmux server
    /// memory, so it vanishes when the server exits.
    var declaredPRs: [Int] = []
    /// The `owner/repo` slug an agent declared via the `@mm_repo` tmux user option,
    /// e.g. "rebar-code/mux-maestro". Empty when unset; like `declaredPRs`, gone
    /// when the server exits.
    var declaredRepo: String = ""
    /// The `@tn_base` / `@tn_tags` options the naming script keeps: the window's base
    /// name and its space-separated status tags. Empty when unset.
    var nameBase: String = ""
    var nameTags: String = ""

    /// The agent panes' stages rolled up (see `AgentState.rollup`). Panes with
    /// no agent don't count; a window with no agent is awake.
    var idleStage: IdleStage {
        AgentState.rollup(panes.filter { $0.attention != .unknown }.map(\.idleStage))
    }

    /// The newest last prompt across the window's agent panes: its row's line 2.
    var lastPrompt: LastPrompt? {
        panes.compactMap(\.lastPrompt).max { $0.at < $1.at }
    }

    /// The newest thread write across the window's agent panes.
    var lastActivityAt: Int? {
        panes.compactMap(\.lastActivityAt).max()
    }

    /// Newest last prompt first; windows with none go last. Ties keep index
    /// order. Keyed on the user's prompt, not `lastActivityAt`: agents write
    /// constantly, and rows that jump on every tool call are unusable.
    static func byRecent(_ windows: [TmuxWindow]) -> [TmuxWindow] {
        windows.sorted { a, b in
            let x = a.lastPrompt?.at ?? Int.min, y = b.lastPrompt?.at ?? Int.min
            return x != y ? x > y : a.index < b.index
        }
    }

    /// Whether the sidebar shows the window under `filter`. A window that is
    /// not asleep always shows; the wider modes also keep a sleeping one that
    /// was written recently enough.
    func shows(under filter: SidebarFilter, now: Int, calendar: Calendar = .current) -> Bool {
        guard filter != .off, idleStage == .dozing else { return true }
        guard let since = filter.since(now: now, calendar: calendar),
              let lastActivityAt else { return false }
        return lastActivityAt >= since
    }

    /// The window's working directory: its active pane's path (falling back to the
    /// first pane). Empty when no pane reported one. Each window can be a different
    /// repo/branch, which is why PR detection keys on this rather than the session.
    var cwd: String {
        let pane = panes.first(where: { $0.active }) ?? panes.first
        return pane?.path ?? ""
    }

    /// The window's rolled-up attention: the most-urgent status across its panes
    /// (waiting → busy → idle → unknown), so a window whose one pane needs you
    /// shows red even while collapsed. `.unknown` for a window with no panes.
    var attention: AttentionStatus {
        panes.map(\.attention).min { $0.sortRank < $1.sortRank } ?? .unknown
    }

    /// The window's dot: the most urgent of its panes' dots.
    var indicator: StatusIndicator { StatusIndicator.rollup(panes.map(\.indicator)) }
}

/// What the sidebar leaves out. Each mode after `sleepy` is wider: it keeps
/// the sleeping windows that were written within its time span.
enum SidebarFilter: String, CaseIterable {
    case off
    case sleepy
    case twoHours
    case today

    /// The modes the control's menu lists.
    static let modes: [SidebarFilter] = [.sleepy, .twoHours, .today]

    var title: String {
        switch self {
        case .off: return ""
        case .sleepy: return "1 hour"
        case .twoHours: return "2 hours"
        case .today: return "Today"
        }
    }

    /// What one click on the control gives: Sleepy from off, off from any mode.
    var toggled: SidebarFilter { self == .off ? .sleepy : .off }

    /// Epoch seconds from which a sleeping window still shows. nil: none does.
    func since(now: Int, calendar: Calendar = .current) -> Int? {
        switch self {
        case .off, .sleepy: return nil
        case .twoHours: return now - 2 * 3600
        case .today:
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
            return Int(day.timeIntervalSince1970)
        }
    }

    /// `sessions` with the windows the filter hides taken out, and no session
    /// left without a window. `keeping` names a window that shows whatever the
    /// filter says: the selected one.
    func apply(
        to sessions: [TmuxSession], now: Int, calendar: Calendar = .current,
        keeping: (TmuxSession, TmuxWindow) -> Bool = { _, _ in false }
    ) -> [TmuxSession] {
        guard self != .off else { return sessions }
        return sessions.compactMap { session in
            var kept = session
            kept.windows = session.windows.filter {
                $0.shows(under: self, now: now, calendar: calendar) || keeping(session, $0)
            }
            return kept.windows.isEmpty ? nil : kept
        }
    }
}

/// A tmux session, containing windows, plus its derived attention status.
struct TmuxSession: Equatable {
    /// Session name (also the join key against Claude session data), e.g.
    /// "my-site".
    let name: String
    /// Whether a client is currently attached to this session.
    let attached: Bool
    /// tmux `session_id` (`$3`), empty when it was not read. Never given to
    /// another session while the tmux server runs. Not part of `==`.
    var id: String = ""
    var windows: [TmuxWindow]
    /// Attention status joined from Claude Code session data; defaults to
    /// `.unknown` until joined.
    var attention: AttentionStatus = .unknown
    /// tmux `session_activity` (epoch seconds) — the "Most Recent" sort key. Not
    /// part of `==` (it changes constantly and would thrash the sidebar diff); the
    /// recency sort reads it directly from the freshly-loaded session list.
    var activity: Int = 0

    static func == (lhs: TmuxSession, rhs: TmuxSession) -> Bool {
        lhs.name == rhs.name && lhs.attached == rhs.attached
            && lhs.windows == rhs.windows && lhs.attention == rhs.attention
    }

    /// The session's working directory: the active pane of the active window
    /// (falling back to the first pane / first window). Empty when no pane
    /// reported a path. This is the key the sidebar groups by in directory mode.
    var cwd: String {
        let window = windows.first(where: { $0.active }) ?? windows.first
        guard let window else { return "" }
        let pane = window.panes.first(where: { $0.active }) ?? window.panes.first
        return pane?.path ?? ""
    }

    /// The session's dot: the most urgent of its panes' dots. When no pane has
    /// a status (a host whose scan gives none per pane), the session's own.
    var indicator: StatusIndicator {
        let panes = StatusIndicator.rollup(windows.map(\.indicator))
        return panes == .none ? StatusIndicator(attention) : panes
    }

    /// The session with each pane's `viewed` and `flagged` set from `store`. `threadID` gives
    /// a pane's id in the store.
    func stamped(_ store: ViewedThreads, threadID: (String) -> String) -> TmuxSession {
        var s = self
        s.windows = windows.map { window in
            var w = window
            w.panes = window.panes.map { pane in
                var p = pane
                let id = threadID(pane.id)
                p.viewed = store.isViewed(id, finishedAt: pane.finishedAt)
                p.flagged = store.flagged.contains(id)
                return p
            }
            return w
        }
        return s
    }
}

/// Which region of a target pane a drag was dropped on. Edges dock the dragged
/// pane to that side (a `join-pane`); the center swaps the two (`swap-pane`).
enum PaneDropZone {
    case top, bottom, left, right, center
}

/// Pure parsing + sorting logic for the tmux tree. No process spawning here so
/// it is fully unit-testable against canned `-F` output.
enum TmuxModel {
    /// Field separator passed to tmux `-F` strings: ASCII **tab**. tmux session
    /// and window names cannot contain whitespace and `pane_current_command` is a
    /// single program token, so a tab never collides with a field's value.
    ///
    /// Tab (not the ASCII Unit Separator `\u{1f}` used originally) is required
    /// because the **remote** path runs `ssh <host> tmux -F <format>`: ssh joins
    /// the remote argv and re-parses it through the remote login shell, which
    /// escapes a raw control byte like `\u{1f}` into the literal text `\037` —
    /// breaking the format string. A tab survives the ssh round-trip intact, so
    /// the same separator works identically local and remote (a malformed line is
    /// skipped by the parsers regardless).
    static let fieldSep = "\t"

    /// `-F` format for `list-sessions`: name, attached flag, session group.
    /// The group lets us collapse tmux "grouped" sessions (which share windows,
    /// so they'd otherwise show as identical duplicates).
    /// Last comes the session id (`$3`): the one name for a session that
    /// tmux never gives to another, which the phone's actions target.
    static let sessionsFormat =
        "#{session_name}\t#{session_attached}\t#{session_group}\t#{session_activity}\t#{session_id}"

    /// `-F` format for `list-windows -t <session>`: index, name, active flag, then
    /// the `@mm_prs` / `@mm_repo` user options an agent may have set on the window,
    /// then the naming script's `@tn_base` / `@tn_tags` (tmux expands an unset option
    /// to an empty string).
    static let windowsFormat =
        "#{window_index}\t#{window_name}\t#{window_active}\t#{@mm_prs}\t#{@mm_repo}"
        + "\t#{@tn_base}\t#{@tn_tags}\t#{window_layout}"

    /// `-F` format for `list-panes -t <session>:<window>`: id, index, command,
    /// title, active flag, current path, then cell geometry (left, top, width,
    /// height), then the pane's shell pid. The path lets the sidebar group
    /// sessions by directory and the header open the session's cwd in an editor;
    /// the geometry drives the drag-to-rearrange overlay (mapping panes to
    /// on-screen rects); the pid anchors the codex-session-id lookup.
    static let panesFormat =
        "#{pane_id}\t#{pane_index}\t#{pane_current_command}\t#{pane_title}\t#{pane_active}\t#{pane_current_path}"
        + "\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{pane_pid}"

    /// `-F` format for a server-wide `list-windows -a`: the owning session name,
    /// then the usual window fields.
    static let allWindowsFormat = "#{session_name}\t" + windowsFormat

    /// `-F` format for a server-wide `list-panes -a`: the owning session name and
    /// window index, then the usual pane fields.
    static let allPanesFormat = "#{session_name}\t#{window_index}\t" + panesFormat

    /// Key into `parseAllPanes`' result: a window is only unique per session.
    static func paneKey(session: String, window: Int) -> String { "\(session)\t\(window)" }

    /// Parse a server-wide `list-windows -a`, grouped by session name.
    ///
    /// One shell-out for the whole server instead of one per session — and for a
    /// remote host, one SSH round-trip instead of one per session.
    static func parseAllWindows(_ output: String) -> [String: [TmuxWindow]] {
        var bySession: [String: [TmuxWindow]] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let sep = line.firstIndex(of: "\t") else { continue }
            let session = String(line[..<sep])
            let rest = String(line[line.index(after: sep)...])
            guard let window = parseWindows(rest).first else { continue }
            bySession[session, default: []].append(window)
        }
        return bySession
    }

    /// Parse a server-wide `list-panes -a`, grouped by `paneKey(session:window:)`.
    static func parseAllPanes(_ output: String) -> [String: [TmuxPane]] {
        var byWindow: [String: [TmuxPane]] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.components(separatedBy: fieldSep)
            guard fields.count >= 2, let window = Int(fields[1]) else { continue }
            let rest = fields.dropFirst(2).joined(separator: fieldSep)
            guard let pane = parsePanes(rest).first else { continue }
            byWindow[paneKey(session: fields[0], window: window), default: []].append(pane)
        }
        return byWindow
    }

    /// Parse `list-sessions` output. One session per non-empty line. `group` is
    /// the tmux session-group name (empty for an ungrouped session).
    static func parseSessions(
        _ output: String
    ) -> [(name: String, attached: Bool, group: String, activity: Int)] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.components(separatedBy: fieldSep)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            // `session_activity` is epoch seconds — the recency sort key. Older tmux
            // or a missing field → 0 (sorts to the bottom).
            return (name: f[0], attached: f[1] == "1", group: f.count >= 3 ? f[2] : "",
                    activity: f.count >= 4 ? Int(f[3]) ?? 0 : 0)
        }
    }

    /// Each session's id (`$3`) by its name, from the same `list-sessions`
    /// output. A line without one (an older format) is left out.
    static func parseSessionIds(_ output: String) -> [String: String] {
        var ids: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.components(separatedBy: fieldSep)
            guard f.count >= 5, !f[0].isEmpty, f[4].hasPrefix("$") else { continue }
            ids[f[0]] = f[4]
        }
        return ids
    }

    /// Collapse tmux grouped sessions to one row per group (they share windows,
    /// so the rest are duplicates). Ungrouped sessions all pass through. For a
    /// group, keep the session named exactly after the group (the namesake) if it
    /// exists, else the first one seen. Order is otherwise preserved.
    static func dedupeGroups(
        _ rows: [(name: String, attached: Bool, group: String, activity: Int)]
    ) -> [(name: String, attached: Bool, group: String, activity: Int)] {
        let namesakes = Set(rows.filter { !$0.group.isEmpty && $0.name == $0.group }.map(\.group))
        var seen = Set<String>()
        var out: [(name: String, attached: Bool, group: String, activity: Int)] = []
        for row in rows {
            if row.group.isEmpty { out.append(row); continue }
            if seen.contains(row.group) { continue }
            // A namesake represents the group; skip the suffixed clones.
            if namesakes.contains(row.group) && row.name != row.group { continue }
            seen.insert(row.group)
            out.append(row)
        }
        return out
    }

    /// Parse `list-windows` output for one session. The trailing `@mm_prs` /
    /// `@mm_repo` fields are read defensively — absent fields (the old 3-field
    /// format) leave `declaredPRs` empty and `declaredRepo` "".
    static func parseWindows(_ output: String) -> [TmuxWindow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.components(separatedBy: fieldSep)
            guard f.count >= 3, let idx = Int(f[0]) else { return nil }
            var window = TmuxWindow(index: idx, name: f[1], active: f[2] == "1", panes: [])
            window.declaredPRs = parseDeclaredPRs(f.count >= 4 ? f[3] : "")
            window.declaredRepo = (f.count >= 5 ? f[4] : "").trimmingCharacters(in: .whitespaces)
            window.nameBase = f.count >= 6 ? f[5] : ""
            window.nameTags = f.count >= 7 ? f[6] : ""
            window.layout = f.count >= 8 ? f[7] : ""
            return window
        }
    }

    /// Parse an `@mm_prs` value leniently: whitespace-separated tokens, each an
    /// optional single leading `#` then a positive integer (`1082 #1085`). Junk
    /// tokens are skipped rather than failing the whole value; repeats are deduped
    /// in order.
    static func parseDeclaredPRs(_ value: String) -> [Int] {
        var out: [Int] = []
        var seen = Set<Int>()
        for token in value.split(whereSeparator: \.isWhitespace) {
            let digits = token.hasPrefix("#") ? token.dropFirst() : token[...]
            guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n > 0,
                  seen.insert(n).inserted else { continue }
            out.append(n)
        }
        return out
    }

    /// Parse `list-panes` output for one window. The trailing fields (geometry and
    /// pane pid) are read defensively — absent or unparseable values default to 0
    /// so output from a tmux that omits them (or the old format) still parses.
    static func parsePanes(_ output: String) -> [TmuxPane] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.components(separatedBy: fieldSep)
            guard f.count >= 5, let idx = Int(f[1]) else { return nil }
            let path = f.count >= 6 ? f[5] : ""
            func cell(_ i: Int) -> Int { f.count > i ? (Int(f[i]) ?? 0) : 0 }
            return TmuxPane(
                id: f[0], index: idx, command: f[2], title: f[3], active: f[4] == "1", path: path,
                left: cell(6), top: cell(7), width: cell(8), height: cell(9), pid: cell(10))
        }
    }

    // MARK: Drag-to-rearrange geometry (pure; drives the terminal overlay)

    /// Map panes to on-screen rects (top-left origin, in view points) given the
    /// point size of one terminal cell. `topOffsetCells` accounts for a top status
    /// line (0 for the default bottom status). Panes with zero geometry collapse to
    /// empty rects, which never contain a point — so they're simply un-hittable.
    static func paneRects(
        _ panes: [TmuxPane], cellW: CGFloat, cellH: CGFloat, topOffsetCells: Int = 0
    ) -> [(id: String, rect: CGRect)] {
        panes.map { p in
            (p.id, CGRect(
                x: CGFloat(p.left) * cellW,
                y: CGFloat(p.top + topOffsetCells) * cellH,
                width: CGFloat(p.width) * cellW,
                height: CGFloat(p.height) * cellH))
        }
    }

    /// The number of side-by-side columns across `panes`: the count of distinct
    /// pane left-offsets (stacked panes share a `left`; side-by-side panes don't).
    /// At least 1 — an empty/geometry-less window is a single column. Drives the
    /// terminal's readable-width cap (columns × per-column width).
    static func columnCount(of panes: [TmuxPane]) -> Int {
        max(1, Set(panes.map(\.left)).count)
    }

    /// Classify where `point` falls within `rect`: the inner 40%×40% core is
    /// `.center` (swap); otherwise the dominant edge (larger normalized distance
    /// from center, sign picks the side). `rect` is top-left origin.
    static func dropZone(for point: CGPoint, in rect: CGRect) -> PaneDropZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let cx = (point.x - rect.midX) / rect.width   // -0.5…0.5
        let cy = (point.y - rect.midY) / rect.height  // -0.5…0.5, y-down
        if abs(cx) < 0.2 && abs(cy) < 0.2 { return .center }
        if abs(cx) > abs(cy) { return cx < 0 ? .left : .right }
        return cy < 0 ? .top : .bottom
    }

    /// The pane under `point` and the drop zone within it, or nil when the point
    /// isn't over any pane. First containing rect wins (panes don't overlap).
    static func dropTarget(
        at point: CGPoint, in rects: [(id: String, rect: CGRect)]
    ) -> (id: String, zone: PaneDropZone)? {
        guard let hit = rects.first(where: { $0.rect.contains(point) }) else { return nil }
        return (hit.id, dropZone(for: point, in: hit.rect))
    }

    /// The `join-pane` orientation for an edge zone: `horizontal` = left/right
    /// split (`-h`), `before` = the source lands on the leading side (`-b`, i.e.
    /// left or top). nil for `.center`, which is a swap, not a join.
    static func joinArgs(for zone: PaneDropZone) -> (horizontal: Bool, before: Bool)? {
        switch zone {
        case .left:   return (horizontal: true, before: true)
        case .right:  return (horizontal: true, before: false)
        case .top:    return (horizontal: false, before: true)
        case .bottom: return (horizontal: false, before: false)
        case .center: return nil
        }
    }

    /// Join attention statuses (keyed by tmux session name) onto sessions and
    /// sort **alphabetically by name only** — a stable, fixed order so a session
    /// never jumps position when its activity changes (the attention dot conveys
    /// status without moving the row).
    /// Map each codex conversation to the tmux pane it runs in, by walking the
    /// codex process's parents until one of them is a pane's shell pid — the same
    /// PID-ancestry join `sessions.py` does for Claude.
    ///
    /// `seen` makes the walk terminate on a malformed process table (a ppid cycle
    /// would otherwise loop forever on the poll queue). Codex pids are visited in
    /// ascending order so a pane somehow hosting two codex processes resolves
    /// deterministically — to the newest (highest pid) one.
    static func paneCodexIds(
        panePidToId: [Int: String], codexByPid: [Int: String], ppids: [Int: Int]
    ) -> [String: String] {
        var out: [String: String] = [:]
        for pid in codexByPid.keys.sorted() {
            guard let sessionId = codexByPid[pid] else { continue }
            var current = pid
            var seen = Set<Int>()
            while seen.insert(current).inserted {
                if let pane = panePidToId[current] {
                    out[pane] = sessionId
                    break
                }
                guard let parent = ppids[current], parent > 1 else { break }
                current = parent
            }
        }
        return out
    }

    static func sorted(
        sessions: [TmuxSession],
        statuses: [String: AttentionStatus],
        activity: [String: Int] = [:],
        paneStatuses: [String: AttentionStatus] = [:],
        paneSessionIds: [String: String] = [:],
        paneStatusSince: [String: Int] = [:],
        codexByPid: [Int: String] = [:],
        ppids: [Int: Int] = [:],
        paneCodexSessionIds joinedOnHost: [String: String] = [:],
        agentStates: [String: AgentStateRow] = [:],
        cacheClocks: [String: CacheClock] = [:],
        fallbackTTL: Int? = nil,
        lastPrompts: [String: LastPrompt] = [:],
        lastWrites: [String: Int] = [:],
        now: Int = Int(Date().timeIntervalSince1970)
    ) -> [TmuxSession] {
        // A Claude pane with no TTL of its own takes the one this user's other
        // threads show, here or (`fallbackTTL`) on the host that has transcripts.
        let claudeTTL = AgentState.observedTTL(cacheClocks.values) ?? fallbackTTL
            ?? AgentState.dozeSeconds
        // Codex ids join by process ancestry, not pane id, so resolve them to pane
        // ids once against the whole tree before walking it. A remote host did
        // that join itself (`joinedOnHost`): its process table is not here.
        var paneCodexSessionIds = joinedOnHost
        if !codexByPid.isEmpty {
            var panePidToId: [Int: String] = [:]
            for session in sessions {
                for window in session.windows {
                    for pane in window.panes where pane.pid > 0 {
                        panePidToId[pane.pid] = pane.id
                    }
                }
            }
            paneCodexSessionIds.merge(paneCodexIds(
                panePidToId: panePidToId, codexByPid: codexByPid, ppids: ppids)) { _, here in here }
        }
        let joined = sessions.map { session -> TmuxSession in
            var s = session
            s.attention = statuses[session.name] ?? .unknown
            // Prefer the Claude "last message/response" time for the recency sort;
            // fall back to the tmux value already on the session for non-Claude ones.
            if let a = activity[session.name] { s.activity = a }
            // Join per-pane status + Claude session id by pane id so window/pane
            // rows show which exact pane is running/waiting (status) and so "Beam
            // to server" can resume the right conversation (session id). Windows
            // roll the status up (see TmuxWindow.attention).
            if !paneStatuses.isEmpty || !paneSessionIds.isEmpty
                || !paneCodexSessionIds.isEmpty {
                var hookStateApplied = false
                s.windows = s.windows.map { window in
                    var w = window
                    w.panes = w.panes.map { pane in
                        var p = pane
                        p.attention = paneStatuses[pane.id] ?? .unknown
                        p.claudeSessionId = paneSessionIds[pane.id]
                        p.codexSessionId = paneCodexSessionIds[pane.id]
                        // A hook row applies to the pane the scan says runs its
                        // session — the scan owns where a session is, the hooks
                        // own what state it is in.
                        let row = [p.claudeSessionId, p.codexSessionId]
                            .compactMap { $0.flatMap { agentStates[$0] } }.first
                        if let row, AgentState.isFresh(
                            row, scanStatus: paneStatuses[pane.id], now: now) {
                            p.attention = AgentState.attention(row.state)
                            p.agentState = AgentPaneState(
                                sessionId: row.sessionId, state: row.state, since: row.since)
                            hookStateApplied = true
                        }
                        // A Claude pane's transcript gives the cache clock. Without
                        // one, the hook's `since` (which keeps `done` apart from
                        // `idle`), else the scan's own status time.
                        p.idleStage = AgentState.idleStage(
                            attention: p.attention,
                            cache: p.claudeSessionId.flatMap { cacheClocks[$0] },
                            statusSince: p.agentState?.since ?? paneStatusSince[pane.id],
                            now: now,
                            fallbackTTL: p.codexSessionId == nil ? claudeTTL : AgentState.dozeSeconds)
                        p.finishedAt = AgentState.finishedAt(
                            attention: p.attention, hook: p.agentState,
                            scanSince: paneStatusSince[pane.id])
                        p.lastPrompt = [p.claudeSessionId, p.codexSessionId]
                            .compactMap { $0.flatMap { lastPrompts[$0] } }.first
                        p.lastActivityAt = [p.claudeSessionId, p.codexSessionId]
                            .compactMap { $0.flatMap { lastWrites[$0] } }.first
                        return p
                    }
                    return w
                }
                // The scan's session-level status would lag the hook by up to its
                // cache, so a session with hook state rolls up from its panes.
                if hookStateApplied {
                    s.attention = s.windows.map(\.attention)
                        .min { $0.sortRank < $1.sortRank } ?? .unknown
                }
            }
            return s
        }
        return joined.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Reorder `sessions` to match the saved `order` (by name): names listed in
    /// `order` come first, in that order; names not in `order` keep their incoming
    /// (alphabetical) order, appended after the known ones. Saved names that no
    /// longer exist are ignored. Pure so it's tested without the view.
    static func applyCustomOrder(_ sessions: [TmuxSession], order: [String]) -> [TmuxSession] {
        guard !order.isEmpty else { return sessions }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return sessions.enumerated().sorted { a, b in
            let ra = rank[a.element.name], rb = rank[b.element.name]
            switch (ra, rb) {
            case let (x?, y?): return x < y          // both pinned → saved order
            case (_?, nil):    return true           // pinned before unpinned
            case (nil, _?):    return false
            case (nil, nil):   return a.offset < b.offset  // stable: keep alpha
            }
        }.map(\.element)
    }

    /// Directory-mode group order: pinned dirs first (in pin order), then the dirs
    /// that have sessions, sorted by label. Pinned dirs with no sessions are still
    /// listed — that is what a pin buys. `label` is passed in (rather than read
    /// from the view layer) so this stays testable without AppKit.
    static func directoryOrder(
        sessionDirs: [String], pinned: [String], label: (String) -> String
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for dir in pinned where !seen.contains(dir) {
            seen.insert(dir)
            out.append(dir)
        }
        let rest = sessionDirs.filter { !seen.contains($0) }
        // De-dupe the incoming session dirs too — callers may pass a raw list.
        var restSeen = Set<String>()
        let unique = rest.filter { restSeen.insert($0).inserted }
        out += unique.sorted {
            label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending
        }
        return out
    }

    /// The most-urgent attention status across a host's sessions (lowest
    /// `sortRank` wins: waiting → busy → idle → unknown), or nil when the host has
    /// no loaded sessions. Drives the aggregated dot on a collapsed watched host
    /// row so it still signals "something needs you" without expanding it. Pure so
    /// it's tested without the view.
    static func rollupAttention(_ sessions: [TmuxSession]) -> AttentionStatus? {
        sessions.map(\.attention).min { $0.sortRank < $1.sortRank }
    }

    /// Parse the JSON emitted by `tools/sessions.py list` into a
    /// tmuxSession → AttentionStatus map. Unrecognized status strings map to
    /// `.idle`. Entries without a tmuxSession are skipped. When multiple Claude
    /// sessions map to the same tmux session, the most attention-worthy wins.
    static func parseStatuses(fromSessionsJSON data: Data) -> [String: AttentionStatus] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: AttentionStatus] = [:]
        for entry in arr {
            guard let tmuxName = entry["tmuxSession"] as? String, !tmuxName.isEmpty else { continue }
            let raw = (entry["status"] as? String) ?? "idle"
            let status = AttentionStatus(rawValue: raw) ?? .idle
            if let existing = map[tmuxName], existing.sortRank <= status.sortRank {
                continue
            }
            map[tmuxName] = status
        }
        return map
    }

    /// Parse `tools/sessions.py list` JSON into **pane id** → AttentionStatus (e.g.
    /// "%30" → .busy), using the exact pane each Claude session was resolved to by
    /// PID ancestry. Entries without a `pane` are skipped (they only carry a
    /// session-level status). When two agents somehow map to one pane, the most
    /// attention-worthy wins — mirroring `parseStatuses`.
    static func parsePaneStatuses(fromSessionsJSON data: Data) -> [String: AttentionStatus] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: AttentionStatus] = [:]
        for entry in arr {
            guard let pane = entry["pane"] as? String, !pane.isEmpty else { continue }
            let raw = (entry["status"] as? String) ?? "idle"
            let status = AttentionStatus(rawValue: raw) ?? .idle
            if let existing = map[pane], existing.sortRank <= status.sortRank { continue }
            map[pane] = status
        }
        return map
    }

    /// Parse `tools/sessions.py list` JSON into **pane id** → Claude session UUID
    /// (e.g. "%30" → "3f2c…"), from the same `pane`/`sessionId` fields the status
    /// parse uses. This is what "Beam to server" resumes on the far host. Entries
    /// without a `pane` or a non-empty `sessionId` are skipped. When two sessions
    /// somehow map to one pane, the busiest one's id wins (matching how
    /// `parsePaneStatuses` resolves the same collision), so the dot and the beamed
    /// session agree.
    static func parsePaneSessionIds(fromSessionsJSON data: Data) -> [String: String] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: String] = [:]
        var rankAtPane: [String: Int] = [:]
        for entry in arr {
            guard let pane = entry["pane"] as? String, !pane.isEmpty,
                  let sid = entry["sessionId"] as? String, !sid.isEmpty else { continue }
            let raw = (entry["status"] as? String) ?? "idle"
            let rank = (AttentionStatus(rawValue: raw) ?? .idle).sortRank
            if let existing = rankAtPane[pane], existing <= rank { continue }
            rankAtPane[pane] = rank
            map[pane] = sid
        }
        return map
    }

    /// Parse `tools/sessions.py list` JSON into tmuxSession → last-updated epoch
    /// **seconds** (from the payload's `updatedAt`, which is milliseconds). This is
    /// the "last time a message was sent or an agent responded" time — the real
    /// recency signal for the Most Recent sort (tmux `session_activity` doesn't
    /// track pane output reliably and behaves like creation time). When multiple
    /// Claude sessions map to one tmux name, the most recent wins.
    static func parseActivity(fromSessionsJSON data: Data) -> [String: Int] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: Int] = [:]
        for entry in arr {
            guard let name = entry["tmuxSession"] as? String, !name.isEmpty else { continue }
            let ms: Int
            if let n = entry["updatedAt"] as? Int { ms = n }
            else if let d = entry["updatedAt"] as? Double { ms = Int(d) }
            else { continue }
            let sec = ms / 1000
            if sec > (map[name] ?? 0) { map[name] = sec }
        }
        return map
    }

    /// Parse `tools/sessions.py list` JSON into Claude session UUID → the session's
    /// cwd (empty when missing), which names its transcript folder for 🥱.
    static func parseSessionCwds(fromSessionsJSON data: Data) -> [String: String] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: String] = [:]
        for entry in arr {
            guard let sid = entry["sessionId"] as? String, !sid.isEmpty else { continue }
            map[sid] = (entry["cwd"] as? String) ?? ""
        }
        return map
    }

    /// Parse `tools/sessions.py list --full` JSON into what a remote host says
    /// of its transcripts. Every value is data from that host: an id that is
    /// not a session id is dropped, and a prompt goes through the same
    /// `LastPrompt.firstLine` cut as one read on this Mac. Output of an older
    /// copy of the script (no `--full`) parses to empty maps and schema 0.
    static func parseRemoteFields(fromSessionsJSON data: Data) -> RemoteSessionFields {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return RemoteSessionFields()
        }
        var out = RemoteSessionFields()
        var pidAtPane: [String: Int] = [:]
        for entry in arr {
            let id: String
            switch entry["agent"] as? String {
            case "meta":
                out.schema = max(out.schema, (entry["schema"] as? NSNumber)?.intValue ?? 0)
                continue
            case "codex":
                guard let codex = entry["codexSessionId"] as? String,
                      RemoteTranscriptMirror.isSessionID(codex) else { continue }
                id = codex
                if let path = entry["rolloutPath"] as? String, !path.isEmpty { out.codexRollouts[id] = path }
                // Two codex processes in one pane: the newest (highest pid)
                // names it, as `paneCodexIds` has it on this Mac.
                let pid = (entry["codexPid"] as? NSNumber)?.intValue ?? 0
                if let pane = entry["codexPane"] as? String, !pane.isEmpty, pid >= pidAtPane[pane] ?? 0 {
                    pidAtPane[pane] = pid
                    out.paneCodexSessionIds[pane] = id
                }
            case nil:
                guard let claude = entry["sessionId"] as? String, !claude.isEmpty else { continue }
                id = claude
            default:
                continue
            }
            if let prompt = entry["lastPrompt"] as? [String: Any],
               let text = (prompt["text"] as? String).flatMap(LastPrompt.firstLine) {
                out.lastPrompts[id] = LastPrompt(
                    text: text, at: max(0, (prompt["at"] as? NSNumber)?.intValue ?? 0))
            }
            if let at = (entry["lastWriteAt"] as? NSNumber)?.intValue, at > 0 { out.lastWrites[id] = at }
        }
        return out
    }

    /// Parse `tools/sessions.py list` JSON into **pane id** → epoch **seconds** the
    /// pane's session entered its status (`updatedAt`, which `sessions.py` takes
    /// from Claude Code's `statusUpdatedAt`). When two sessions map to one pane,
    /// the busiest one's time wins, matching `parsePaneStatuses`.
    static func parsePaneStatusSince(fromSessionsJSON data: Data) -> [String: Int] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: Int] = [:]
        var rankAtPane: [String: Int] = [:]
        for entry in arr {
            guard let pane = entry["pane"] as? String, !pane.isEmpty,
                  let ms = (entry["updatedAt"] as? NSNumber)?.intValue, ms > 0 else { continue }
            let raw = (entry["status"] as? String) ?? "idle"
            let rank = (AttentionStatus(rawValue: raw) ?? .idle).sortRank
            if let existing = rankAtPane[pane], existing <= rank { continue }
            rankAtPane[pane] = rank
            map[pane] = ms / 1000
        }
        return map
    }
}

/// What `sessions.py list --full` on a remote host says of the transcripts
/// there: this Mac cannot read them, so the host reads their tails itself.
struct RemoteSessionFields: Equatable {
    /// pane id → Codex conversation id, joined by process ancestry on the host.
    var paneCodexSessionIds: [String: String] = [:]
    /// Codex conversation id → the path of its rollout as the host gave it.
    /// Not checked here: see `RemoteTranscriptMirror.isRollout`.
    var codexRollouts: [String: String] = [:]
    /// Claude or Codex session id → last prompt, and → epoch seconds of the
    /// transcript's newest timestamped entry.
    var lastPrompts: [String: LastPrompt] = [:]
    var lastWrites: [String: Int] = [:]
    /// The output format the host's copy of the script says it writes. 0 for
    /// a copy older than `--full`.
    var schema = 0
}
