import Foundation

/// One `agent_state` row: the state a Claude Code or Codex session last reported
/// through its hooks (`mux event`).
struct AgentStateRow: Equatable {
    enum State: String {
        /// Blocked on the human: a permission prompt, a question, a failed turn.
        case waiting
        /// A turn is running.
        case busy
        /// Started, no turn yet.
        case idle
        /// The last turn finished.
        case done
        /// The session exited (Claude Code only — Codex sends no end event).
        case ended
    }

    let sessionId: String
    /// "claude" or "codex".
    let agent: String
    let state: State
    let reason: String
    /// The tmux pane the hook ran in (`$TMUX_PANE`); empty outside tmux.
    let pane: String
    let cwd: String
    /// When the session entered `state`, epoch seconds. Moves only when the
    /// state changes.
    let since: Int
    /// The last event, epoch seconds.
    let updatedAt: Int
}

/// The hook state carried on a `TmuxPane`. Only fields that change with the
/// state, so a busy agent's stream of tool events causes no row diffs.
struct AgentPaneState: Equatable {
    let sessionId: String
    let state: AgentStateRow.State
    let since: Int
}

/// Rules for folding hook state into the sidebar and into toasts. Pure, so they
/// are unit-tested without a tree or a DB.
enum AgentState {
    /// How long the status scan (`sessions.py`) may disagree before it wins. The
    /// scan is cached for 5s and the tree polls every 1.5s, so a new hook state
    /// routinely leads it by a few seconds.
    static let scanLagSeconds = 20

    /// A Codex `busy` row with no event for this long stops counting: an
    /// interrupted turn sends no event, and Codex has no scan status to correct it.
    static let busySeconds = 600

    /// A state first seen longer ago than this does not toast — a pane that
    /// finished an hour ago is history, not news.
    static let toastRecentSeconds = 60

    /// An agent idle this long dozes: 💤 on its pane's row, and on its window's
    /// row and tmux name. Also the cache TTL assumed when a transcript shows none.
    static let dozeSeconds = 3600

    /// A Claude thread whose prompt cache expires within this long yawns: 🥱.
    static let yawnSeconds = 600

    /// Where an agent pane sits on the way to losing its prompt cache.
    ///
    /// With a readable transcript (`cache`), the clock is the cache's: idle since
    /// the last reply, against the TTL of the last cache write (1h when unknown).
    /// 🥱 covers the TTL's last `yawnSeconds`, so a 5-minute cache never yawns;
    /// 💤 starts at the TTL. Without one (Codex, remote hosts), 💤 after
    /// `dozeSeconds` in the idle status, and no 🥱. Only idle agents count —
    /// `waiting` needs the human, it is not idle.
    static func idleStage(
        attention: AttentionStatus, cache: CacheClock?, statusSince: Int?, now: Int
    ) -> IdleStage {
        guard attention == .idle else { return .awake }
        if let cache {
            let ttl = cache.ttlSeconds ?? dozeSeconds
            let idle = now - cache.lastReplyAt
            if idle >= ttl { return .dozing }
            return ttl > yawnSeconds && idle >= ttl - yawnSeconds ? .yawning : .awake
        }
        guard let statusSince else { return .awake }
        return now - statusSince >= dozeSeconds ? .dozing : .awake
    }

    /// A window's stage from its agent panes' stages: 💤 when all doze, 🥱 when
    /// all are 🥱 or 💤 and at least one yawns, else awake. No agents: awake.
    static func rollup(_ stages: [IdleStage]) -> IdleStage {
        guard !stages.isEmpty, stages.allSatisfy({ $0 != .awake }) else { return .awake }
        return stages.allSatisfy { $0 == .dozing } ? .dozing : .yawning
    }

    /// Whether `row` replaces the scan's status for the pane running its
    /// session. `scanStatus` is the scan's status for that pane (nil for Codex,
    /// which the scan can't see).
    ///
    /// Hooks miss some turns: Claude Code fires no `Stop` when the human
    /// interrupts, and a background task can start a turn with no prompt. The
    /// scan reads the status Claude Code keeps for itself, so once it disagrees
    /// for longer than its lag, it wins. The row still wins while the scan lags
    /// behind it, and whenever the two agree — which keeps `done` apart from
    /// `idle`.
    static func isFresh(_ row: AgentStateRow, scanStatus: AttentionStatus?, now: Int) -> Bool {
        guard row.state != .ended else { return false }
        let age = now - row.updatedAt
        if let scanStatus, scanStatus != .unknown {
            return scanStatus == attention(row.state) || age <= scanLagSeconds
        }
        return row.state != .busy || age <= busySeconds
    }

    /// The sidebar dot for a hook state.
    static func attention(_ state: AgentStateRow.State) -> AttentionStatus {
        switch state {
        case .waiting: return .waiting
        case .busy: return .busy
        case .idle, .done: return .idle
        case .ended: return .unknown
        }
    }

    /// The link a toast gives to the agent's thread. Every toast builds it here,
    /// so moving to `muxmaestro://thread/<id>` is a one-line change.
    static func threadLink(_ toast: AgentToast) -> String {
        "\(toast.session):\(toast.windowIndex)"
    }

    static func toastText(_ toast: AgentToast) -> String {
        let label = toast.state == .waiting ? "Needs you" : "Done"
        return "\(label) · \(toast.windowName)\n\(threadLink(toast))"
    }
}

/// An agent pane's idle stage. Exclusive: a row shows 🥱, 💤 or nothing.
enum IdleStage: Equatable {
    case awake
    /// The prompt cache expires within `AgentState.yawnSeconds`.
    case yawning
    /// Idle past the cache TTL (or `AgentState.dozeSeconds`).
    case dozing

    var tag: String? {
        switch self {
        case .awake: return nil
        case .yawning: return "🥱"
        case .dozing: return "💤"
        }
    }

    static let allTags = ["🥱", "💤"]
}

/// What the tail of a Claude Code transcript says about the thread's prompt cache.
struct CacheClock: Equatable {
    /// Epoch seconds of the last real assistant entry — the last API call, which
    /// wrote or read the cache and so restarted its TTL.
    let lastReplyAt: Int
    /// TTL of the last cache write in the tail: 3600 or 300. nil when the tail has
    /// no write (every turn only read the cache).
    let ttlSeconds: Int?

    /// Parse the tail of a transcript JSONL. The first line may be cut; lines
    /// that do not parse are skipped. nil when the tail holds no assistant entry.
    static func parse(tail: Data) -> CacheClock? {
        var lastReplyAt: Int?
        var ttl: Int?
        let marker = Data("\"assistant\"".utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            if lastReplyAt != nil, ttl != nil { break }
            guard line.range(of: marker) != nil,
                  let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  message["model"] as? String != "<synthetic>"
            else { continue }
            if lastReplyAt == nil {
                guard let stamp = entry["timestamp"] as? String, let at = parseTimestamp(stamp)
                else { continue }
                lastReplyAt = at
            }
            if ttl == nil,
               let creation = (message["usage"] as? [String: Any])?["cache_creation"] as? [String: Any] {
                if ((creation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0) > 0 {
                    ttl = 3600
                } else if ((creation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0) > 0 {
                    ttl = 300
                }
            }
        }
        return lastReplyAt.map { CacheClock(lastReplyAt: $0, ttlSeconds: ttl) }
    }

    static func parseTimestamp(_ s: String) -> Int? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        return date.map { Int($0.timeIntervalSince1970) }
    }
}

/// The first line of the user's last prompt in an agent thread: line 2 of the
/// thread's window and pane rows.
struct LastPrompt: Equatable {
    /// The prompt's first non-empty line, trimmed, at most `maxLength` characters.
    let text: String
    /// Epoch seconds of the entry. 0 when it has no readable timestamp.
    let at: Int

    /// A row shows one tail-truncated line, so longer text is never drawn.
    static let maxLength = 200

    /// The latest human prompt in the tail of a Claude Code transcript. Tool
    /// results, `isMeta` and compact-summary entries, interrupt markers and text
    /// that opens with `<` (slash commands, command output, reminders) are not
    /// prompts. A `!` shell command reads as `! <command>`, and a message typed
    /// while the agent was busy (a human `queued_command`) counts. The first line
    /// may be cut; lines that do not parse are skipped.
    static func parse(claudeTail tail: Data) -> LastPrompt? {
        lastMatch(in: tail) { entry in
            if entry["type"] as? String == "attachment" {
                guard let queued = entry["attachment"] as? [String: Any],
                      queued["type"] as? String == "queued_command",
                      queued["commandMode"] as? String == "prompt",
                      (queued["origin"] as? [String: Any])?["kind"] as? String == "human"
                else { return nil }
                return queued["prompt"] as? String
            }
            guard entry["type"] as? String == "user",
                  entry["isMeta"] as? Bool != true,
                  entry["isCompactSummary"] as? Bool != true,
                  let content = (entry["message"] as? [String: Any])?["content"]
            else { return nil }
            if let text = content as? String { return shellCommand(text) }
            guard let blocks = content as? [[String: Any]],
                  !blocks.contains(where: { $0["type"] as? String == "tool_result" })
            else { return nil }
            return (blocks.first { $0["type"] as? String == "text" }?["text"] as? String).map(shellCommand)
        }
    }

    /// `<bash-input>cmd</bash-input>` as `! cmd`; any other text unchanged.
    private static func shellCommand(_ text: String) -> String {
        guard text.hasPrefix("<bash-input>") else { return text }
        let command = text.dropFirst("<bash-input>".count)
            .replacingOccurrences(of: "</bash-input>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "! " + command
    }

    /// The latest user prompt in the tail of a Codex rollout. A TUI thread writes
    /// it as a `response_item` user message (checked against codex-cli
    /// 0.147–0.154 rollouts, which carry no `user_message` event); an
    /// `event_msg` `user_message` counts too. Context blocks open with `<`.
    static func parse(codexTail tail: Data) -> LastPrompt? {
        lastMatch(in: tail) { entry in
            guard let payload = entry["payload"] as? [String: Any] else { return nil }
            switch (entry["type"] as? String, payload["type"] as? String) {
            case ("response_item", "message"):
                guard payload["role"] as? String == "user",
                      let blocks = payload["content"] as? [[String: Any]]
                else { return nil }
                return blocks.first { $0["type"] as? String == "input_text" }?["text"] as? String
            case ("event_msg", "user_message"):
                return payload["message"] as? String
            default:
                return nil
            }
        }
    }

    /// Walk the tail's lines newest first; the first entry `text` accepts and
    /// whose text is a prompt wins.
    private static func lastMatch(
        in tail: Data, text: ([String: Any]) -> String?
    ) -> LastPrompt? {
        let marker = Data("\"user".utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: marker) != nil,
                  let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let raw = text(entry),
                  let first = firstLine(raw)
            else { continue }
            let at = (entry["timestamp"] as? String).flatMap(CacheClock.parseTimestamp) ?? 0
            return LastPrompt(text: first, at: at)
        }
        return nil
    }

    /// The first non-empty line, or nil when there is none or the text is not a
    /// human prompt.
    static func firstLine(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted"),
              let line = trimmed.split(whereSeparator: \.isNewline)
                  .map({ $0.trimmingCharacters(in: .whitespaces) })
                  .first(where: { !$0.isEmpty })
        else { return nil }
        return String(line.prefix(maxLength))
    }
}

/// What the tail of every tracked transcript says: Claude session id → cache
/// clock, and Claude or Codex session id → last prompt and the epoch seconds of
/// the transcript's newest timestamped entry (anything the user or the agent
/// posted). Not the file's mtime: Claude Code appends untimestamped bookkeeping
/// (`last-prompt`, `cost-state`, `ai-title`) to idle transcripts.
struct TranscriptTails: Equatable {
    var clocks: [String: CacheClock] = [:]
    var prompts: [String: LastPrompt] = [:]
    var lastWrites: [String: Int] = [:]
    /// Claude session id → its transcript as last stat'ed. Codex rollouts are
    /// left out. Session triage reads from here rather than looking again.
    var files: [String: TranscriptFile] = [:]
}

/// A transcript's path, and its size and mtime when last stat'ed.
struct TranscriptFile: Equatable {
    let path: String
    let size: UInt64
    let mtime: Date
}

/// Reads the tails of local agent transcripts: Claude Code's
/// (`~/.claude/projects/<cwd with non-alphanumerics as ->/<session-id>.jsonl`)
/// for `CacheClock`s and `LastPrompt`s, and Codex rollouts for `LastPrompt`s.
/// The tree polls every 1.5s, so a transcript is read only when its size or
/// mtime changed, and then only from its end. Safe to call from any queue.
final class TranscriptTailReader {
    private struct Entry {
        let path: String
        let codex: Bool
        var size: UInt64
        var mtime: Date
        var clock: CacheClock?
        var prompt: LastPrompt?
        /// End of the last whole line already searched for a prompt. Transcripts
        /// only grow, so a later read searches for a newer prompt above it only.
        var searchedTo: UInt64
        /// Epoch seconds of the newest timestamped entry.
        var lastWrite: Int?
    }

    private let projectsDir: URL
    private let tailBytes: Int
    private let promptCapBytes: UInt64
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Transcript reads so far. For tests.
    private(set) var readCount = 0

    init(
        projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        tailBytes: Int = 64_000,
        promptCapBytes: UInt64 = 2_000_000
    ) {
        self.projectsDir = projectsDir
        self.tailBytes = tailBytes
        self.promptCapBytes = promptCapBytes
    }

    /// The tails of the Claude sessions in `sessionCwds` (session id → cwd) and
    /// the Codex conversations in `codexRollouts` (session id → rollout path)
    /// whose transcript exists. Sessions absent from both are forgotten.
    func read(
        sessionCwds: [String: String], codexRollouts: [String: String] = [:]
    ) -> TranscriptTails {
        lock.lock()
        defer { lock.unlock() }
        var next: [String: Entry] = [:]
        var out = TranscriptTails()
        let wanted = sessionCwds.map { ($0.key, false, $0.value) }
            + codexRollouts.map { ($0.key, true, $0.value) }
        for (sessionId, codex, location) in wanted {
            var known = entries[sessionId]
            // A Codex conversation can move to a new rollout file.
            if let k = known, k.codex != codex || (codex && k.path != location) { known = nil }
            let path = codex ? location : (known?.path ?? findTranscript(sessionId: sessionId, cwd: location))
            guard let path,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            var entry = known ?? Entry(
                path: path, codex: codex, size: 0, mtime: .distantPast, searchedTo: 0)
            if known == nil || entry.size != size || entry.mtime != mtime {
                // A shorter file was rewritten, not appended to: start over.
                if size < entry.size {
                    entry.prompt = nil
                    entry.searchedTo = 0
                }
                entry.size = size
                entry.mtime = mtime
                readTail(into: &entry)
            }
            next[sessionId] = entry
            if let clock = entry.clock { out.clocks[sessionId] = clock }
            if let prompt = entry.prompt { out.prompts[sessionId] = prompt }
            if let at = entry.lastWrite { out.lastWrites[sessionId] = at }
            if !codex { out.files[sessionId] = TranscriptFile(path: path, size: size, mtime: mtime) }
        }
        entries = next
        return out
    }

    private func findTranscript(sessionId: String, cwd: String) -> String? {
        let fm = FileManager.default
        let name = "\(sessionId).jsonl"
        if !cwd.isEmpty {
            let folder = String(cwd.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
            })
            let path = projectsDir.appendingPathComponent(folder).appendingPathComponent(name).path
            if fm.fileExists(atPath: path) { return path }
        }
        // The session may have started in another folder than its current cwd.
        let folders = (try? fm.contentsOfDirectory(atPath: projectsDir.path)) ?? []
        return folders.lazy
            .map { self.projectsDir.appendingPathComponent($0).appendingPathComponent(name).path }
            .first { fm.fileExists(atPath: $0) }
    }

    /// Read backwards from the end in doubling chunks until the clock and a
    /// prompt are found. One reply can outgrow the first chunk (a long answer, a
    /// big tool call), so the clock search goes up to `maxTailBytes`. A tool loop
    /// can push the last prompt far back, so the prompt search goes up to
    /// `promptCapBytes`, and never below `searchedTo`: a prompt found there before
    /// still stands unless a newer one was appended.
    private func readTail(into entry: inout Entry) {
        guard let handle = FileHandle(forReadingAtPath: entry.path) else { return }
        defer { try? handle.close() }
        readCount += 1
        let size = entry.size
        let floor = min(entry.searchedTo, size)
        var needClock = !entry.codex
        var needPrompt = true
        var clock: CacheClock?
        var prompt: LastPrompt?
        var searchedTo = floor
        var length = UInt64(tailBytes)
        while true {
            let offset = size > length ? size - length : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: Int(min(length, size)))
            else { break }
            if length == UInt64(tailBytes) {
                if let newline = data.lastIndex(of: UInt8(ascii: "\n")) {
                    searchedTo = max(floor, offset + UInt64(newline - data.startIndex) + 1)
                }
                if let at = Self.newestTimestamp(in: data) { entry.lastWrite = at }
            }
            if needClock, let found = CacheClock.parse(tail: data) {
                clock = found
                needClock = false
            }
            if needPrompt {
                let skip = floor > offset ? Int(floor - offset) : 0
                let parse = entry.codex ? LastPrompt.parse(codexTail:) : LastPrompt.parse(claudeTail:)
                if skip < data.count, let found = parse(data.dropFirst(skip)) {
                    prompt = found
                }
                // Found, searched down to the floor, or at the cap: done either way.
                needPrompt = prompt == nil && offset > floor && length < promptCapBytes
            }
            if needClock, length >= Self.maxTailBytes { needClock = false }
            guard offset > 0, needClock || needPrompt else { break }
            length *= 2
        }
        if !entry.codex { entry.clock = clock }
        if let prompt { entry.prompt = prompt }
        entry.searchedTo = searchedTo
    }

    static let maxTailBytes: UInt64 = 4_000_000

    /// The newest top-level `timestamp` in a tail. Lines that do not parse are skipped.
    static func newestTimestamp(in tail: Data) -> Int? {
        let marker = Data("\"timestamp\"".utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: marker) != nil,
                  let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let at = (entry["timestamp"] as? String).flatMap(CacheClock.parseTimestamp)
            else { continue }
            return at
        }
        return nil
    }
}

/// The 🥱 / 💤 status tag on a window's tmux name. Kept in the same `@tn_base` /
/// `@tn_tags` options the naming script uses, and rebuilt the way it
/// rebuilds them, so an agent's own `--tag` / `--untag` keeps the stage tag and the
/// app's untag keeps the agent's tags.
enum IdleTag {

    /// `display-message` format for the three values `update` reads.
    static let optionsFormat = "#{window_name}\t#{@tn_base}\t#{@tn_tags}"

    /// The window's new base, tags and name when its stage tag must change to
    /// match `stage`, or nil when it already does. 🥱 and 💤 swap in one write, so
    /// the name never carries both.
    ///
    /// A name that no longer equals base + tags was renamed outside the naming script
    /// (the rename field, the AI namer). That name becomes the base and the stale
    /// tags are dropped, so an untag never reverts a rename.
    static func update(
        name: String, base: String, tags: String, stage: IdleStage
    ) -> (base: String, tags: String, name: String)? {
        var base = base
        var tagList = tags.split(whereSeparator: \.isWhitespace).map(String.init)
        if base.isEmpty || name != ([base] + tagList).joined(separator: " ") {
            base = name
            tagList = []
        }
        let present = tagList.filter { IdleStage.allTags.contains($0) }
        guard present != [stage.tag].compactMap({ $0 }) else { return nil }
        tagList.removeAll { IdleStage.allTags.contains($0) }
        if let tag = stage.tag { tagList.append(tag) }
        return (base, tagList.joined(separator: " "), ([base] + tagList).joined(separator: " "))
    }

    /// A window row's label. The stage tag leads it, where truncation can't
    /// reach, and both tags come off the name so none shows twice or gets cut.
    static func windowLabel(_ w: TmuxWindow) -> String {
        let name = w.name.split(separator: " ", omittingEmptySubsequences: false)
            .filter { !IdleStage.allTags.contains(String($0)) }.joined(separator: " ")
        return lead(w.idleStage, "\(w.index): \(name)\(w.active ? " ●" : "")")
    }

    /// A pane row's label, led by its agent's stage tag.
    static func paneLabel(_ p: TmuxPane) -> String {
        lead(p.idleStage, "\(p.id) \(p.command)\(p.active ? " ◀" : "")")
    }

    private static func lead(_ stage: IdleStage, _ label: String) -> String {
        stage.tag.map { "\($0) \(label)" } ?? label
    }

    /// Whether a fresh read is safe to act on. A name that does not match base +
    /// tags is an outside rename, or the naming script caught between setting the
    /// options and renaming. Acting on the second would fold the agent's tags into
    /// the base, so a mismatch counts only when the poll (`seen`) saw it too.
    static func isSettled(
        name: String, base: String, tags: String,
        seen: (name: String, base: String, tags: String)
    ) -> Bool {
        let tagList = tags.split(whereSeparator: \.isWhitespace).map(String.init)
        return base.isEmpty || name == ([base] + tagList).joined(separator: " ")
            || (name, base, tags) == seen
    }

    /// One `if-shell -F` that writes `update` only while the window still has the
    /// `name`, `base` and `tags` it was read with. tmux runs a command list without
    /// interleaving another client's commands, so the naming script's --tag landing
    /// between the read and this write turns it into a no-op instead of being
    /// overwritten. The next poll reads again and retries.
    static func syncCommand(
        target: String, name: String, base: String, tags: String,
        update: (base: String, tags: String, name: String)
    ) -> [String] {
        let same = "#{&&:#{==:#{window_name},\(formatLiteral(name))},"
            + "#{&&:#{==:#{@tn_base},\(formatLiteral(base))},#{==:#{@tn_tags},\(formatLiteral(tags))}}}"
        let t = Ssh.shellQuote(target)
        let writes = [
            "set-window-option -t \(t) @tn_base \(Ssh.shellQuote(update.base))",
            "set-window-option -t \(t) @tn_tags \(Ssh.shellQuote(update.tags))",
            "set-window-option -t \(t) automatic-rename off",
            // rename-window expands formats; `##` keeps a `#W` in a name literal,
            // or every poll would expand it and see an outside rename.
            "rename-window -t \(t) \(Ssh.shellQuote(update.name.replacingOccurrences(of: "#", with: "##")))",
        ].joined(separator: " ; ")
        return ["if-shell", "-F", "-t", target, same, writes]
    }

    /// `s` as a literal inside a tmux format argument: `#`, `,` and `}` escaped.
    private static func formatLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "#", with: "##")
            .replacingOccurrences(of: ",", with: "#,")
            .replacingOccurrences(of: "}", with: "#}")
    }
}

/// A session that just entered `waiting` or `done`, and where it runs.
struct AgentToast: Equatable {
    let sessionId: String
    let state: AgentStateRow.State
    let since: Int
    let session: String
    let windowIndex: Int
    let windowName: String
    /// The pane is the active pane of its session's active window — what a
    /// client attached to that session shows.
    let visible: Bool
}

/// Remembers the state each session was last seen in, so each entry into
/// `waiting` or `done` toasts once.
struct AgentToastTracker {
    private var seen: [String: AgentPaneState] = [:]

    /// This refresh's toasts, `waiting` first, then newest. Every pane's state is
    /// recorded, including ones that don't toast, so a state never toasts late.
    mutating func toasts(in sessions: [TmuxSession], now: Int) -> [AgentToast] {
        var out: [AgentToast] = []
        for session in sessions {
            for window in session.windows {
                for pane in window.panes {
                    guard let agent = pane.agentState, seen[agent.sessionId] != agent else { continue }
                    seen[agent.sessionId] = agent
                    guard agent.state == .waiting || agent.state == .done,
                          now - agent.since <= AgentState.toastRecentSeconds
                    else { continue }
                    out.append(AgentToast(
                        sessionId: agent.sessionId, state: agent.state, since: agent.since,
                        session: session.name, windowIndex: window.index,
                        windowName: window.name, visible: window.active && pane.active))
                }
            }
        }
        return out.sorted { a, b in
            if (a.state == .waiting) != (b.state == .waiting) { return a.state == .waiting }
            return a.since > b.since
        }
    }
}

/// Reads `agent_state` for the local tree poll. The DB may not exist yet (no
/// hook has fired and the manager home was never seeded), so it opens lazily and
/// keeps the handle once open. Safe to call from any queue.
final class AgentStateReader {
    private let dbPath: String?
    private let lock = NSLock()
    private var store: ManagerStore?

    init(dbPath: String? = ManagerHome.defaultDBPath()) {
        self.dbPath = dbPath
    }

    func rows() -> [AgentStateRow] {
        lock.lock()
        defer { lock.unlock() }
        if store == nil, let dbPath, FileManager.default.fileExists(atPath: dbPath) {
            store = try? ManagerStore(dbPath: dbPath)
        }
        return (try? store?.agentStates()) ?? []
    }
}
