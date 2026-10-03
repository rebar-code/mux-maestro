import Foundation

/// One turn of the digest jev reads.
struct TriageTurn: Encodable, Equatable {
    let role: String
    let text: String
}

/// What jev is shown about one Claude thread: the goal it was started for, its
/// last few turns, and whether the agent is idle or waiting. Kept near 6k
/// tokens; jev's window is 32k.
struct TriageState: Encodable, Equatable {
    let goal: String
    let recentTurns: [TriageTurn]
    let agentStatus: String
    let idleMinutes: Int
}

/// The sidebar chip, most urgent first. The app shows it and never acts on it.
enum TriageChip: String, CaseIterable {
    case urgent = "Urgent"
    case yourMove = "Your move"
    case blocked = "Blocked"
    case waiting = "Waiting"
    case close = "Close?"
    case done = "Done"

    var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

/// jev's reading of one thread. `chip` is nil when the thread is working or no
/// answer cleared its bar; the tooltip still carries the numbers.
struct TriageVerdict: Equatable {
    let chip: TriageChip?
    let tooltip: String

    /// The most urgent chip among `verdicts`; nil when none has one. `Done` and
    /// `Close?` count only when `settled`: a session with an agent still running
    /// or waiting is neither.
    static func rollup(_ verdicts: [TriageVerdict], settled: Bool = true) -> TriageVerdict? {
        verdicts
            .filter { v in v.chip.map { settled || ($0 != .done && $0 != .close) } ?? false }
            .min { ($0.chip?.rank ?? 0) < ($1.chip?.rank ?? 0) }
    }
}

enum SessionTriage {
    static let turnLimit = 8
    static let turnMaxChars = 1_500
    static let goalMaxChars = 1_500

    static let threadStates = [
        "working", "needs_user_reply", "needs_user_action", "waiting_on_third_party",
        "blocked", "done", "abandoned",
    ]

    static let questions: [String: JevQuestion] = [
        "threadState": .choice(
            instructions: "Which one best describes where this coding-agent thread stands now?",
            options: [
                "working": "The agent is still doing the task and will go on without the user.",
                "needs_user_reply":
                    "The agent asked the user a question or for a decision and waits for the answer.",
                "needs_user_action":
                    "The user must do something outside the chat, such as run a command, approve a merge, or log in.",
                "waiting_on_third_party":
                    "The work waits on someone or something other than the user, such as CI, a reviewer, or a deploy.",
                "blocked": "The agent hit an error or obstacle it cannot get past on its own.",
                "done": "The stated goal is finished and nothing is left to do.",
                "abandoned": "The user moved on and left the thread unfinished.",
            ]),
        "goalMet": .boolean(
            instructions: "The goal the user stated at the start of this thread is achieved."),
        "userActionOutstanding": .boolean(
            instructions: "The user still has to do something before this work is complete."),
        "waitingOnThirdParty": .boolean(
            instructions: "The work waits on a person or system other than the user, such as CI, a reviewer, or a deploy."),
        "unshippedWork": .boolean(
            instructions: "The thread mentions work that is not yet committed, pushed, or merged."),
        "safeToClose": .boolean(
            instructions: "The user can close this thread now and lose nothing."),
        "urgent": .boolean(
            instructions: "The user should look at this thread within the next hour."),
        "important": .boolean(
            instructions: "This thread affects production, money, customer data, or another person who waits on the user."),
    ]

    /// The digest of a transcript. `head` is the start of the file (for the
    /// first prompt); `tail` its end (for the title and the recent turns).
    static func state(
        head: [String], tail: [String], agentStatus: String, idleMinutes: Int
    ) -> TriageState {
        let prompt = ManagerTranscript.firstPrompt(lines: head).map {
            $0.count > goalMaxChars ? String($0.prefix(goalMaxChars - 1)) + "…" : $0
        }
        // A long thread's newest title is in the tail; a short one's may sit in
        // the head alone.
        let title = ManagerTranscript.aiTitle(lines: tail) ?? ManagerTranscript.aiTitle(lines: head)
        let goal = [prompt, title.map { "Summary: \($0)" }]
            .compactMap { $0 }.joined(separator: "\n\n")
        let turns = ManagerTranscript.recentTurns(
            lines: tail, limit: turnLimit, maxChars: turnMaxChars)
        return TriageState(
            goal: goal, recentTurns: turns.map { TriageTurn(role: $0.role, text: $0.text) },
            agentStatus: agentStatus, idleMinutes: idleMinutes)
    }

    /// The chip, first rule that matches. Fails closed: an answer that is
    /// missing never satisfies a rule, so a partial response can show nothing
    /// but can never show `Close?`.
    static func chip(_ answers: [String: JevAnswer]) -> TriageChip? {
        let state = answers["threadState"]
        func p(_ option: String) -> Double { state?.probability(of: option) ?? 0 }
        func yes(_ key: String, atLeast bar: Double) -> Bool {
            (answers[key]?.probability).map { $0 >= bar } ?? false
        }
        func no(_ key: String, below bar: Double) -> Bool {
            (answers[key]?.probability).map { $0 < bar } ?? false
        }
        var chosen: String?
        if case .choice(let c, _)? = state { chosen = c }

        if yes("urgent", atLeast: 0.8),
           let chosen, ["needs_user_reply", "needs_user_action", "blocked"].contains(chosen) {
            return .urgent
        }
        if p("needs_user_reply") + p("needs_user_action") >= 0.7 { return .yourMove }
        if p("waiting_on_third_party") >= 0.7 { return .waiting }
        if p("blocked") >= 0.7 { return .blocked }
        let finished = p("done") + p("abandoned") >= 0.7
        if finished, yes("safeToClose", atLeast: 0.8), no("unshippedWork", below: 0.3) {
            return .close
        }
        if p("done") >= 0.7 { return .done }
        return nil
    }

    /// `Goal met 92% · Your action 10% · Third party 4% · Unshipped 61%`. An
    /// answer that is missing reads `?`, never 0%.
    static func tooltip(_ answers: [String: JevAnswer]) -> String {
        [("Goal met", "goalMet"), ("Your action", "userActionOutstanding"),
         ("Third party", "waitingOnThirdParty"), ("Unshipped", "unshippedWork")]
            .map { label, key in
                let value = (answers[key]?.probability).map { "\(Int(($0 * 100).rounded()))%" } ?? "?"
                return "\(label) \(value)"
            }
            .joined(separator: " · ")
    }

    static func verdict(_ response: JevResponse) -> TriageVerdict {
        TriageVerdict(chip: chip(response.answers), tooltip: tooltip(response.answers))
    }
}

/// Classifies idle local Claude threads with jev and stamps the verdict on
/// their panes. `TmuxService.loadTree()` calls `apply` every poll with the
/// transcripts `TranscriptTailReader` found; a call only goes out for a thread
/// whose transcript has changed since its last verdict and then sat still for
/// `quietPeriod`. The verdict lands on the next poll.
final class SessionTriageService {
    struct Transcript {
        let head: [String]
        let tail: [String]
    }

    static let quietPeriod: TimeInterval = 20
    static let backoff: TimeInterval = 300
    static let maxInFlight = 2
    /// How long a failed key read stands before the store is read again.
    static let keyRetry: TimeInterval = 60

    /// The app's instance, over the Keychain key and this Mac's transcripts.
    static let live = SessionTriageService()

    private let store: SecretStore
    private let transport: HTTPTransport
    private let now: () -> Date
    private let read: (_ path: String) -> Transcript?
    /// Runs a classification off the poll. Tests run it inline.
    private let run: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    /// The key once read. While there is none, the store is read at most once
    /// per `keyRetry` (the Keychain read is a system call, and this is the poll).
    private var key: String?
    private var keyMissingSince: Date?
    private var verdicts: [String: (file: TranscriptFile, verdict: TriageVerdict)] = [:]
    private var failedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    init(
        store: SecretStore = GatewayKey.shared,
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping () -> Date = Date.init,
        read: @escaping (String) -> Transcript? = SessionTriageService.readTranscript,
        run: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }
    ) {
        self.store = store
        self.transport = transport
        self.now = now
        self.read = read
        self.run = run
        NotificationCenter.default.addObserver(
            forName: GatewayKey.didChange, object: nil, queue: nil
        ) { [weak self] _ in self?.keyChanged() }
    }

    /// Forget the cached key so the next poll reads the store again.
    func keyChanged() {
        lock.lock()
        key = nil
        keyMissingSince = nil
        lock.unlock()
    }

    private func currentKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        let at = now()
        if let since = keyMissingSince, at.timeIntervalSince(since) < Self.keyRetry { return nil }
        key = store.read()
        keyMissingSince = key == nil ? at : nil
        return key
    }

    /// Stamp each pane's last verdict and start classifying the panes that are
    /// due. `transcripts` is Claude session id → transcript, from
    /// `TranscriptTailReader`.
    func apply(to sessions: [TmuxSession], transcripts: [String: TranscriptFile]) -> [TmuxSession] {
        // Forget threads whose transcript is gone, as `TranscriptTailReader` does.
        lock.lock()
        verdicts = verdicts.filter { transcripts[$0.key] != nil }
        failedAt = failedAt.filter { transcripts[$0.key] != nil }
        lock.unlock()
        guard let key = currentKey() else { return sessions }
        return sessions.map { session in
            var s = session
            s.windows = s.windows.map { window in
                var w = window
                w.panes = w.panes.map { pane in
                    var p = pane
                    guard let sid = pane.claudeSessionId, pane.attention != .busy else { return p }
                    p.triage = visit(sessionId: sid, file: transcripts[sid],
                                     attention: pane.attention, key: key)
                    return p
                }
                return w
            }
            return s
        }
    }

    /// The pane's verdict, if it was made for the transcript as it is now: one
    /// made for an older size or mtime is stale, and unknown shows no chip.
    /// Starts a classification when one is due.
    private func visit(
        sessionId: String, file: TranscriptFile?, attention: AttentionStatus, key: String
    ) -> TriageVerdict? {
        guard let current = file else { return nil }
        let at = now()
        lock.lock()
        let last = verdicts[sessionId]
        let due = at.timeIntervalSince(current.mtime) >= Self.quietPeriod
            && last?.file != current
            && !inFlight.contains(sessionId)
            && inFlight.count < Self.maxInFlight
            && failedAt[sessionId].map { at.timeIntervalSince($0) >= Self.backoff } ?? true
        if due { inFlight.insert(sessionId) }
        lock.unlock()
        if due {
            let idle = Int(at.timeIntervalSince(current.mtime) / 60)
            let status = attention == .waiting ? "waiting_for_user" : "idle"
            run { [self] in
                classify(sessionId: sessionId, file: current,
                         agentStatus: status, idleMinutes: idle, key: key)
            }
        }
        return last?.file == current ? last?.verdict : nil
    }

    private func classify(
        sessionId: String, file: TranscriptFile,
        agentStatus: String, idleMinutes: Int, key: String
    ) {
        guard let transcript = read(file.path) else {
            return finish(sessionId, file: file, result: .failure(.badResponse))
        }
        let state = SessionTriage.state(
            head: transcript.head, tail: transcript.tail,
            agentStatus: agentStatus, idleMinutes: idleMinutes)
        JevClient(key: key, transport: transport)
            .evaluate(state: state, questions: SessionTriage.questions) { [self] result in
                finish(sessionId, file: file, result: result)
            }
    }

    /// A failure holds the thread off for `backoff`. No toast: the pane shows
    /// no chip until a call succeeds.
    private func finish(_ sessionId: String, file: TranscriptFile, result: Result<JevResponse, JevError>) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(sessionId)
        switch result {
        case .success(let response):
            verdicts[sessionId] = (file, SessionTriage.verdict(response))
            failedAt[sessionId] = nil
        case .failure(let error):
            failedAt[sessionId] = now()
            Diag.log("triage", "\(sessionId) failed: \(error.message)")
        }
    }

    // MARK: This Mac's transcripts

    /// The first 256 KB and the last 512 KB, split into lines. A cut line at
    /// either edge fails to parse and is skipped.
    static func readTranscript(path: String) -> Transcript? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 * 1024),
              let end = try? handle.seekToEnd()
        else { return nil }
        let tailBytes: UInt64 = 512 * 1024
        guard (try? handle.seek(toOffset: end > tailBytes ? end - tailBytes : 0)) != nil,
              let tail = try? handle.readToEnd()
        else { return nil }
        func lines(_ data: Data) -> [String] {
            String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        return Transcript(head: lines(head), tail: lines(tail))
    }
}
