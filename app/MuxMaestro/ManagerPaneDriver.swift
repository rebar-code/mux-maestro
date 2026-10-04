import Foundation

/// Drives the `mux-manager` Claude Code pane the way a person does: paste a
/// prompt into its input, then read the reply back out of Claude Code's own
/// per-session JSONL transcript. A port of an earlier voice prototype (`chat/pane_driver.py`),
/// which has run this loop over a live pane for months.
///
/// There is exactly ONE client on that session (the TUI in the pane), so nothing
/// here resumes or forks a session: the turn literally lands in the pane the
/// human can also type into. Turn completion is read from Claude Code's own
/// state, never scraped from the terminal:
///
///   `~/.claude/sessions/<pid>.json`          live status: idle | busy | waiting
///   `~/.claude/projects/<slug>/<sid>.jsonl`  one record per message
///
/// The transcript is located by globbing `<sid>.jsonl` across every project dir
/// rather than reconstructing the cwd→slug encoding, which is ambiguous on disk.
///
/// Foundation only, no AppKit: the reading and the state machine are pure so
/// they can be tested against fixture transcripts and a synthetic clock.

/// One turn's terminal outcome.
enum ManagerTurnOutcome: Equatable {
    case done(reply: String)
    /// The pane hit a permission prompt; `reply` is the pre-prompt text.
    case permission(reply: String)
    case timeout(reply: String)
    /// The pane couldn't be typed into; the message is for the human.
    case unreachable(String)
    /// Refused to send: the pane is waiting on a prompt, or there was nothing
    /// to send, or a turn is already running.
    case refused(String)
}

/// What the status source says the pane is doing. Raw values are the strings
/// Claude Code writes into `sessions/<pid>.json`.
enum ManagerTurnStatus: String, Equatable {
    case idle, busy, waiting
}

/// Pure transcript reading: the JSONL functions from `pane_driver.py`, over
/// lines that the caller has already read. Kept separate from the driver so
/// fixtures test them with no filesystem and no clock.
enum ManagerTranscript {
    /// The last human prompt in the transcript, with its full text. Unlike the
    /// sidebar's `LastPrompt`, this is not shortened for display.
    static func lastUserPromptText(lines: [String]) -> String {
        for line in lines.reversed() {
            guard let record = record(line), record["isMeta"] as? Bool != true else { continue }
            let text: String
            if record["type"] as? String == "attachment",
               let attachment = record["attachment"] as? [String: Any],
               attachment["type"] as? String == "queued_command",
               attachment["commandMode"] as? String == "prompt",
               (attachment["origin"] as? [String: Any])?["kind"] as? String == "human" {
                text = attachment["prompt"] as? String ?? ""
            } else if record["type"] as? String == "user" {
                text = userPromptText(record)
            } else {
                continue
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !clean.hasPrefix("<"),
               !clean.hasPrefix("[Request interrupted") { return clean }
        }
        return ""
    }

    /// Concatenated assistant `text` blocks from records after `start`.
    ///
    /// Skips `thinking` and `tool_use` blocks and non-assistant records, so the
    /// result is the clean reply with no TUI chrome. A partial trailing line
    /// (the transcript is being appended to while we read) is ignored.
    static func assistantText(lines: [String], after start: Int) -> String {
        var parts: [String] = []
        for line in window(lines, from: start) {
            guard let record = record(line), record["type"] as? String == "assistant" else { continue }
            for block in contentBlocks(record) where block["type"] as? String == "text" {
                if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if a `tool_use` after `start` has no matching `tool_result` yet.
    ///
    /// During a tool call the transcript tail is an assistant record ending in a
    /// `tool_use` block (carrying an `id`); its result arrives later as a `user`
    /// record with a `tool_result` block whose `tool_use_id` matches. Until that
    /// result lands the turn is STILL IN PROGRESS, so a quiet gap here must not
    /// count as done.
    static func toolCallInFlight(lines: [String], after start: Int) -> Bool {
        var used: Set<String> = []
        var resulted: Set<String> = []
        for line in window(lines, from: start) {
            guard let record = record(line) else { continue }
            for block in contentBlocks(record) {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String { used.insert(id) }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { resulted.insert(id) }
                default:
                    continue
                }
            }
        }
        return !used.subtracting(resulted).isEmpty
    }

    /// True if any assistant record after `start` carries a `stop_reason`.
    ///
    /// Gates `turnEnded`: when false (older Claude builds, or fixtures that omit
    /// the field) callers fall back to `toolCallInFlight` so nothing regresses.
    static func hasStopData(lines: [String], after start: Int) -> Bool {
        for line in window(lines, from: start) {
            guard let record = record(line), record["type"] as? String == "assistant" else { continue }
            if message(record).index(forKey: "stop_reason") != nil { return true }
        }
        return false
    }

    /// True once the turn's FINAL assistant record has a terminal `stop_reason`.
    ///
    /// Intermediate segments that precede a tool call carry
    /// `stop_reason: "tool_use"`; the model WILL continue after the tool returns,
    /// even when no tool is in flight right now (a fast tool whose result landed
    /// in the same beat). The final segment carries "end_turn" (also
    /// "max_tokens", "stop_sequence"), so the authoritative completion signal is
    /// the LAST assistant record having a stop_reason that is non-null and not
    /// "tool_use".
    static func turnEnded(lines: [String], after start: Int) -> Bool {
        var seen = false
        var lastStop: String?
        for line in window(lines, from: start) {
            guard let record = record(line), record["type"] as? String == "assistant" else { continue }
            let message = message(record)
            guard message.index(forKey: "stop_reason") != nil else { continue }
            seen = true
            lastStop = message["stop_reason"] as? String
        }
        return seen && lastStop != nil && lastStop != "tool_use"
    }

    /// The assistant text of the most recent turn that actually said something.
    ///
    /// Walks BACKWARD from the end, collecting assistant `text` blocks until the
    /// user record that STARTED that turn. Records living inside a turn are
    /// stepped over: tool_results (a user record with no prompt text) and isMeta
    /// harness notes. The newest turn is sometimes textless (a slash command's
    /// echo carries no reply), so the walk keeps going back until a turn spoke.
    static func lastReplyText(lines: [String]) -> String {
        var parts: [String] = []
        for line in lines.reversed() {
            guard let record = record(line) else { continue }
            let kind = record["type"] as? String
            if kind == "assistant" {
                for block in contentBlocks(record).reversed() where block["type"] as? String == "text" {
                    if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
                }
                continue
            }
            guard kind == "user", record["isMeta"] as? Bool != true else { continue }
            guard !userPromptText(record).isEmpty else { continue }
            if !parts.isEmpty { break }  // this record opened the newest turn that spoke
        }
        return parts.reversed().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The most recent user and assistant text in a Codex rollout. Codex stores
    /// messages as `response_item` records with `input_text` / `output_text`
    /// blocks; this reader skips tool and developer records.
    static func lastCodexUserText(lines: [String]) -> String {
        for line in lines.reversed() {
            guard let record = record(line),
                  let payload = record["payload"] as? [String: Any] else { continue }
            let text: String
            if record["type"] as? String == "event_msg",
               payload["type"] as? String == "user_message" {
                text = payload["message"] as? String ?? ""
            } else if payload["type"] as? String == "message",
                      payload["role"] as? String == "user",
                      let blocks = payload["content"] as? [[String: Any]] {
                text = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "input_text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
            } else {
                continue
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !clean.hasPrefix("<"),
               !clean.hasPrefix("[Request interrupted") { return clean }
        }
        return ""
    }

    static func lastCodexReplyText(lines: [String]) -> String {
        var parts: [String] = []
        for line in lines.reversed() {
            guard let record = record(line),
                  let payload = record["payload"] as? [String: Any] else { continue }
            if record["type"] as? String == "event_msg",
               payload["type"] as? String == "agent_message",
               let message = payload["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard payload["type"] as? String == "message" else { continue }
            if payload["role"] as? String == "assistant",
               let blocks = payload["content"] as? [[String: Any]] {
                let text = blocks.compactMap { block -> String? in
                    guard ["output_text", "text"].contains(block["type"] as? String ?? "")
                    else { return nil }
                    return block["text"] as? String
                }
                parts.append(contentsOf: text.reversed())
            } else if payload["role"] as? String == "user", !parts.isEmpty {
                break
            }
        }
        return parts.reversed().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The transcript's lines. Mirrors Python's `splitlines()`: a final newline
    /// does not produce a trailing empty line, so counts line up with the
    /// `start` offsets the watcher carries.
    static func lines(of url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    static func lineCount(of url: URL) -> Int {
        lines(of: url).count
    }

    /// Locate `<sessionId>.jsonl` under `projectsDir/*/`, first sorted hit.
    static func findJSONL(sessionId: String, projectsDir: URL) -> URL? {
        guard !sessionId.isEmpty else { return nil }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return nil }
        for dir in dirs.sorted() {
            let candidate = projectsDir.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The Claude session id of the pane running tmux session `tmuxSession`.
    static func sessionId(forTmuxSession tmuxSession: String, sessionsDir: URL) -> String? {
        session(forTmuxSession: tmuxSession, sessionsDir: sessionsDir)?.id
    }

    /// The session id AND its status file in one scan. The status file is named
    /// by pid, so both are found by the same walk of `sessions/`; the driver
    /// needs both every turn and there is no point reading the directory twice.
    ///
    /// The match is on the `tmux` field starting with `"<tmuxSession>:"` — the
    /// field holds `session:window.pane`, and a session name that is a prefix of
    /// another's must not match it. When several files match (a restarted
    /// manager whose old file has not been removed yet) the most recently
    /// updated one is the live pane.
    static func session(forTmuxSession tmuxSession: String, sessionsDir: URL) -> (id: String, file: URL)? {
        guard !tmuxSession.isEmpty else { return nil }
        let prefix = tmuxSession + ":"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path) else {
            return nil
        }
        var best: (id: String, file: URL, updatedAt: Double)?
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = sessionsDir.appendingPathComponent(name)
            guard let object = object(at: url),
                  let tmux = object["tmux"] as? String, tmux.hasPrefix(prefix),
                  let id = object["sessionId"] as? String, !id.isEmpty
            else { continue }
            let updatedAt = (object["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            if best == nil || updatedAt > best!.updatedAt {
                best = (id, url, updatedAt)
            }
        }
        return best.map { ($0.id, $0.file) }
    }

    /// (status, waitingFor) from a `sessions/<pid>.json`. Both nil when the file
    /// is unreadable or the status is one this build doesn't know.
    static func status(sessionFile: URL) -> (ManagerTurnStatus?, String?) {
        guard let object = object(at: sessionFile) else { return (nil, nil) }
        let status = (object["status"] as? String).flatMap(ManagerTurnStatus.init(rawValue:))
        return (status, object["waitingFor"] as? String)
    }

    // MARK: Parsing

    private static func window(_ lines: [String], from start: Int) -> ArraySlice<String> {
        let index = max(0, min(start, lines.count))
        return lines[index...]
    }

    /// One JSONL record, or nil for a blank or half-written trailing line.
    private static func record(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func message(_ record: [String: Any]) -> [String: Any] {
        record["message"] as? [String: Any] ?? [:]
    }

    /// The typed content blocks of a record. A user record whose content is a
    /// plain string yields none, which is what every block-wise caller wants.
    static func contentBlocks(_ record: [String: Any]) -> [[String: Any]] {
        guard let content = message(record)["content"] as? [Any] else { return [] }
        return content.compactMap { $0 as? [String: Any] }
    }

    /// The text of a user record — empty for tool_results and other non-prompts.
    private static func userPromptText(_ record: [String: Any]) -> String {
        let content = message(record)["content"]
        if let text = content as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = content as? [Any] else { return "" }
        let texts = blocks.compactMap { $0 as? [String: Any] }
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Builds the text shared by the floating Handoff commands. This keeps the
/// transcript formats out of the AppKit action and makes the copied block useful
/// in any fresh Claude Code or Codex conversation.
enum AgentHandoff {
    enum Agent: String, Equatable {
        case claude = "Claude Code"
        case codex = "Codex"

        var resetCommand: String { self == .claude ? "/clear" : "/new" }
        var launchCommand: String { self == .claude ? "claude" : "codex" }
    }

    /// A new-window handoff types the agent command into a shell. The agent is
    /// up once the pane's foreground command is no longer that shell.
    static func agentStarted(command: String, shell: String) -> Bool {
        !command.isEmpty && command != shell
    }

    static func makeText(
        agent: Agent, sessionId: String, tmuxSession: String, pane: String,
        transcript: String
    ) -> String? {
        let lines = transcript.components(separatedBy: .newlines)
        let user: String
        let reply: String
        switch agent {
        case .claude:
            user = ManagerTranscript.lastUserPromptText(lines: lines)
            reply = ManagerTranscript.lastReplyText(lines: lines)
        case .codex:
            user = ManagerTranscript.lastCodexUserText(lines: lines)
            reply = ManagerTranscript.lastCodexReplyText(lines: lines)
        }
        guard !user.isEmpty || !reply.isEmpty else { return nil }
        return """
        Continue this work in a fresh \(agent.rawValue) conversation. Treat the exchange below as context from the previous conversation, and continue from where it left off.

        Source session ID: \(sessionId)
        Source tmux session: \(tmuxSession) (pane \(pane))

        Last user message:
        \(user.isEmpty ? "(No user message was found.)" : user)

        Last agent message:
        \(reply.isEmpty ? "(No agent reply was found.)" : reply)
        """
    }
}

/// The turn state machine, pure: whoever polls feeds it (now, status, lines) and
/// it says what new reply text to emit and whether the turn has settled. Every
/// threshold is the one `pane_driver.py` arrived at in the field.
struct ManagerTurnWatcher {
    /// Seconds between polls. The driver's default cadence.
    static let poll: TimeInterval = 0.2
    /// The transcript must be quiet this long before a turn counts as done.
    static let settle: TimeInterval = 0.6
    /// Status-less panes (a Codex CLI, an older build, a session that never
    /// wrote a status file): treat a turn as done after this much quiet instead.
    static let quietFallback: TimeInterval = 4
    /// If nothing ever stirs, assume an instant or empty turn.
    static let grace: TimeInterval = 6
    /// What a turn that never started says: nothing reached the transcript and
    /// the pane never went busy, so the prompt was not submitted.
    static let neverStarted = "The manager did not pick up the message"
    /// Hard ceiling on a single turn.
    static let timeout: TimeInterval = 90
    /// After a permission prompt, how long to wait for the keyboard.
    static let approvalWait: TimeInterval = 180
    /// Guard: stop re-reading after this many prompts in one turn.
    static let maxPermissionRounds = 12

    enum Phase {
        /// Watching the turn we typed.
        case main
        /// A permission prompt is up; waiting for the human at the keyboard.
        case awaitingApproval
        /// Approved (or denied) and running again.
        case resumed
    }

    private(set) var phase: Phase = .main
    private var startLine: Int
    private var start: TimeInterval
    private var lastCount: Int
    private var lastGrowth: TimeInterval
    private var activity = false
    /// How much of the assistant text has already gone out as a delta.
    private var emitted = 0

    init(startLine: Int, startedAt: TimeInterval) {
        self.startLine = startLine
        self.start = startedAt
        self.lastCount = startLine
        self.lastGrowth = startedAt
    }

    /// Feed one poll. Returns the new assistant-text delta to emit (may be
    /// empty) and, once the turn settles, its outcome. Same decision logic as
    /// `_stream_reply` / `_await_resume`.
    mutating func step(
        now: TimeInterval, status: ManagerTurnStatus?, lines: [String]
    ) -> (delta: String, outcome: ManagerTurnOutcome?) {
        if lines.count > lastCount {
            lastCount = lines.count
            lastGrowth = now
            activity = true
        }
        if status == .busy { activity = true }

        if phase == .awaitingApproval {
            if status == .waiting {
                // Nagging is worse than quiet: the human was already told to use
                // the keyboard, so a never-approved prompt just ends the turn.
                guard now - start >= Self.approvalWait else { return ("", nil) }
                return ("", .permission(reply: reply(lines)))
            }
            phase = .resumed
            lastGrowth = now  // the resumed turn gets its own quiet window
        }

        let delta = emit(lines)
        let quiet = now - lastGrowth
        if status == .waiting {
            return (delta, .permission(reply: reply(lines)))
        }
        if phase == .resumed {
            if activity && status == .idle && quiet >= Self.settle {
                return (delta, .done(reply: reply(lines)))
            }
            if now - start >= Self.approvalWait + Self.timeout {
                return (delta, .timeout(reply: reply(lines)))
            }
            return (delta, nil)
        }

        // A quiet gap mid-turn is NOT a finished turn. Two ways the model
        // resumes after a quiet beat: a slow `tool_use` still awaiting its
        // result, and a fast tool whose result already landed but whose final
        // assistant segment has not. `turnEnded` is the authoritative signal;
        // transcripts with no stop_reason at all fall back to the in-flight check.
        let terminal = ManagerTranscript.hasStopData(lines: lines, after: startLine)
            ? ManagerTranscript.turnEnded(lines: lines, after: startLine)
            : !ManagerTranscript.toolCallInFlight(lines: lines, after: startLine)
        if terminal && activity && status == .idle && quiet >= Self.settle {
            return (delta, .done(reply: reply(lines)))
        }
        if terminal && activity && status == nil && quiet >= Self.quietFallback {
            return (delta, .done(reply: reply(lines)))
        }
        if !activity && now - start >= Self.grace {
            return (delta, .unreachable(Self.neverStarted))
        }
        if now - start >= Self.timeout {
            return (delta, .timeout(reply: reply(lines)))
        }
        return (delta, nil)
    }

    /// After a `.permission` outcome, keep watching from the current line count.
    /// The pre-approval text was already emitted, so the resumed round streams
    /// only what lands after the human answers.
    mutating func resume(fromLine: Int, at now: TimeInterval) {
        phase = .awaitingApproval
        startLine = fromLine
        start = now
        lastCount = fromLine
        lastGrowth = now
        activity = false
        emitted = 0
    }

    private func reply(_ lines: [String]) -> String {
        ManagerTranscript.assistantText(lines: lines, after: startLine)
    }

    /// The new suffix of the assistant text, "" when nothing new. Assistant text
    /// is append-only, so the suffix is always safe; a transient shrink (a
    /// half-written line we skipped last poll) emits nothing rather than a
    /// garbage slice.
    private mutating func emit(_ lines: [String]) -> String {
        let full = reply(lines)
        guard full.count > emitted else { return "" }
        let delta = String(full[full.index(full.startIndex, offsetBy: emitted)...])
        emitted = full.count
        return delta
    }
}

/// Drives the `mux-manager` pane: pastes a prompt in, reads the reply back.
///
/// One turn at a time. All mutable state lives on `queue`; `onDelta` and
/// `completion` hop to `callbackQueue`.
final class ManagerPaneDriver {
    struct Config {
        var tmuxPath: String
        var tmuxSession: String
        var claudeDir: URL
        var pollInterval: TimeInterval

        init(
            tmuxPath: String,
            tmuxSession: String = ManagerHome.sessionName,
            claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true),
            pollInterval: TimeInterval = ManagerTurnWatcher.poll
        ) {
            self.tmuxPath = tmuxPath
            self.tmuxSession = tmuxSession
            self.claudeDir = claudeDir
            self.pollInterval = pollInterval
        }
    }

    /// How long the input box gets to settle between the paste and Enter. Too
    /// short and the Enter lands before the pasted text is in the box.
    private static let enterDelay: TimeInterval = 0.3

    private let config: Config
    private let runner: CommandRunner
    /// The app's `agent_state` read for the turn's session id, consulted before
    /// the status file on every poll. nil means "no fresh row, fall through".
    private let statusOverride: ((String) -> ManagerTurnStatus?)?
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    // Turn state. Touched only on `queue`.
    private var running = false
    private var watcher = ManagerTurnWatcher(startLine: 0, startedAt: 0)
    private var sessionId = ""
    private var jsonl: URL?
    private var sessionFile: URL?
    private var rounds = 0
    /// The pre-approval reply of the prompt we are currently sitting on, so a
    /// never-approved turn completes with the text the pane did manage to say.
    private var pendingReply = ""
    private var onDelta: ((String) -> Void)?
    private var completion: ((ManagerTurnOutcome) -> Void)?
    /// Bumped by `cancel()` and by each new turn so a scheduled poll from a dead
    /// turn does nothing when it fires.
    private var generation = 0

    init(
        config: Config,
        runner: CommandRunner,
        statusOverride: ((String) -> ManagerTurnStatus?)? = nil,
        queue: DispatchQueue,
        callbackQueue: DispatchQueue = .main
    ) {
        self.config = config
        self.runner = runner
        self.statusOverride = statusOverride
        self.queue = queue
        self.callbackQueue = callbackQueue
    }

    /// Fold an `agent_state` row's state onto the status vocabulary, so the app's
    /// `statusOverride` closure is one line. `.ended` has nothing to say about a
    /// live turn, so it reads as no status at all.
    static func status(for state: AgentStateRow.State) -> ManagerTurnStatus? {
        switch state {
        case .waiting: return .waiting
        case .busy: return .busy
        case .idle, .done: return .idle
        case .ended: return nil
        }
    }

    /// The resolved Claude session id for the manager pane, re-read each call:
    /// restarting the pane gives the manager a new id.
    func currentSessionId() -> String? {
        ManagerTranscript.sessionId(forTmuxSession: config.tmuxSession, sessionsDir: sessionsDir)
    }

    /// The manager pane's transcript file, once its session has written one.
    func transcript() -> URL? {
        currentSessionId().flatMap {
            ManagerTranscript.findJSONL(sessionId: $0, projectsDir: projectsDir)
        }
    }

    static let waitingMessage = "Manager is waiting on a prompt"
    static let busyMessage = "Manager is busy"
    static let notReadyMessage = "Manager is not ready"

    /// The pane's status now, read apart from any turn: safe on any queue.
    /// nil when the pane has no session yet or its state is not known.
    func paneStatus() -> ManagerTurnStatus? {
        guard let resolved = ManagerTranscript.session(
            forTmuxSession: config.tmuxSession, sessionsDir: sessionsDir) else { return nil }
        if let statusOverride, let status = statusOverride(resolved.id) { return status }
        return ManagerTranscript.status(sessionFile: resolved.file).0
    }

    /// Why text must not go into a pane in `status`; nil when it may. The pane
    /// on a prompt always refuses. With `requireIdle`, so does a busy pane and
    /// one whose state is not known: either may be on a prompt by the time the
    /// Enter lands.
    static func refusal(status: ManagerTurnStatus?, requireIdle: Bool) -> String? {
        switch status {
        case .waiting: return waitingMessage
        case .idle: return nil
        case .busy: return requireIdle ? busyMessage : nil
        case nil: return requireIdle ? notReadyMessage : nil
        }
    }

    /// The pane's most recent substantive reply, for "catch me up".
    func lastReply() -> String {
        guard let id = currentSessionId(),
              let url = ManagerTranscript.findJSONL(sessionId: id, projectsDir: projectsDir)
        else { return "" }
        return ManagerTranscript.lastReplyText(lines: ManagerTranscript.lines(of: url))
    }

    /// Send one prompt. `onDelta` streams reply text as it lands; `completion`
    /// fires exactly once with the outcome. A second call while a turn runs
    /// completes immediately with `.refused`. `requireIdle` is for a sender
    /// that cannot see the pane (the phone): the turn starts only from idle.
    func send(
        _ prompt: String,
        requireIdle: Bool = false,
        onDelta: @escaping (String) -> Void,
        completion: @escaping (ManagerTurnOutcome) -> Void
    ) {
        queue.async {
            guard !self.running else {
                self.report(.refused("A turn is running"), to: completion)
                return
            }
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.report(.refused("Nothing to send"), to: completion)
                return
            }

            let resolved = ManagerTranscript.session(
                forTmuxSession: self.config.tmuxSession, sessionsDir: self.sessionsDir)
            self.sessionId = resolved?.id ?? ""
            self.sessionFile = resolved?.file
            // Typing into a pane that is sitting on a permission prompt answers
            // the prompt with the prompt text. Never do that.
            if let reason = Self.refusal(status: self.currentStatus(), requireIdle: requireIdle) {
                self.report(.refused(reason), to: completion)
                return
            }
            guard self.tmux(["display-message", "-pt", self.config.tmuxSession, "#{pane_id}"]) else {
                self.report(.unreachable("No mux-manager session"), to: completion)
                return
            }

            self.jsonl = self.sessionId.isEmpty
                ? nil
                : ManagerTranscript.findJSONL(sessionId: self.sessionId, projectsDir: self.projectsDir)
            let startLine = self.jsonl.map(ManagerTranscript.lineCount(of:)) ?? 0

            // A pane in copy mode (the human scrolled the terminal) reads the Enter
            // as a copy-mode key, and the prompt sits unsent in the input box.
            _ = self.tmux(["copy-mode", "-q", "-t", self.config.tmuxSession])

            // Paste rather than `send-keys -l`: the text goes in over stdin, so a
            // multi-line prompt with metacharacters is safe by construction.
            let paste = TmuxCommands.pastePrompt(session: self.config.tmuxSession)
            guard self.tmux(paste.load, stdin: Data(text.utf8)), self.tmux(paste.paste) else {
                self.report(.unreachable("Could not paste into the manager pane"), to: completion)
                return
            }

            self.running = true
            self.generation += 1
            self.rounds = 0
            self.pendingReply = ""
            self.onDelta = onDelta
            self.completion = completion
            self.watcher = ManagerTurnWatcher(startLine: startLine, startedAt: Self.now())

            let generation = self.generation
            self.queue.asyncAfter(deadline: .now() + Self.enterDelay) {
                guard self.generation == generation, self.running else { return }
                // A prompt that came up since the paste would take the Enter as
                // its answer. Checked again here, as late as it can be.
                if let reason = Self.refusal(status: self.currentStatus(), requireIdle: requireIdle) {
                    // The text is in the input box already. Take it out, or
                    // the next Enter in the pane would send it.
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                    self.tmux(TmuxCommands.clearInput(target: self.config.tmuxSession, lines: lines))
                    self.finish(.refused(reason))
                    return
                }
                guard self.tmux(["send-keys", "-t", self.config.tmuxSession, "Enter"]) else {
                    self.finish(.unreachable("Could not send Enter to the manager pane"))
                    return
                }
                self.poll(generation: generation)
            }
        }
    }

    /// Stop watching. The pane keeps running; we just stop reporting on it.
    func cancel() {
        queue.async {
            self.generation += 1
            self.running = false
            self.onDelta = nil
            self.completion = nil
        }
    }

    // MARK: The poll loop

    private func poll(generation: Int) {
        guard self.generation == generation, running else { return }

        // A fresh session has no transcript until the first message lands; it
        // appears mid-turn (startLine was 0), so pick it up here.
        if jsonl == nil, !sessionId.isEmpty {
            jsonl = ManagerTranscript.findJSONL(sessionId: sessionId, projectsDir: projectsDir)
        }
        let lines = jsonl.map(ManagerTranscript.lines(of:)) ?? []
        let now = Self.now()
        let (delta, outcome) = watcher.step(now: now, status: currentStatus(), lines: lines)
        if !delta.isEmpty, let onDelta {
            callbackQueue.async { onDelta(delta) }
        }

        guard let outcome else {
            queue.asyncAfter(deadline: .now() + config.pollInterval) {
                self.poll(generation: generation)
            }
            return
        }

        guard case .permission(let reply) = outcome else {
            finish(outcome)
            return
        }
        // Sitting on a prompt that was never answered: the pane said all it is
        // going to say this turn.
        if watcher.phase == .awaitingApproval {
            finish(.permission(reply: pendingReply))
            return
        }
        rounds += 1
        guard rounds <= ManagerTurnWatcher.maxPermissionRounds else {
            finish(.permission(reply: reply))
            return
        }
        pendingReply = reply
        watcher.resume(fromLine: lines.count, at: now)
        queue.asyncAfter(deadline: .now() + config.pollInterval) {
            self.poll(generation: generation)
        }
    }

    private func finish(_ outcome: ManagerTurnOutcome) {
        running = false
        generation += 1
        let completion = self.completion
        self.completion = nil
        self.onDelta = nil
        if let completion { callbackQueue.async { completion(outcome) } }
    }

    /// Complete a turn that never started, without disturbing turn state.
    private func report(
        _ outcome: ManagerTurnOutcome, to completion: @escaping (ManagerTurnOutcome) -> Void
    ) {
        callbackQueue.async { completion(outcome) }
    }

    // MARK: Helpers

    private var sessionsDir: URL {
        config.claudeDir.appendingPathComponent("sessions", isDirectory: true)
    }

    private var projectsDir: URL {
        config.claudeDir.appendingPathComponent("projects", isDirectory: true)
    }

    /// The `agent_state` row wins over the status file: it is written by the
    /// pane's own hooks and is fresher than anything we can scan for.
    private func currentStatus() -> ManagerTurnStatus? {
        if let statusOverride, let status = statusOverride(sessionId) { return status }
        guard let sessionFile else { return nil }
        return ManagerTranscript.status(sessionFile: sessionFile).0
    }

    @discardableResult
    private func tmux(_ args: [String], stdin: Data? = nil) -> Bool {
        runner.run(config.tmuxPath, args, stdin: stdin) != nil
    }

    /// A monotonic clock: the turn's deadlines must not move when the wall clock
    /// does.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
