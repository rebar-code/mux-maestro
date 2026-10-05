import Cocoa

/// Everything the rail renders in one value, so the 1.5s poll publishes a single
/// diffable snapshot instead of three independent callbacks that each redraw.
struct ManagerSnapshot: Equatable {
    let needsYou: [NeedsYouItem]
    let recentWork: [WorkLogRow]
    let updates: [ManagerUpdate]

    static let empty = ManagerSnapshot(needsYou: [], recentWork: [], updates: [])

    /// Fold the three DB reads into the "Needs you" list. Pure, so the titles are
    /// decided in one place and the view only draws what it is handed.
    ///
    /// Agents come first (newest `since` first), then the agent's own review
    /// items, which the store already returns in severity order.
    static func build(
        waiting: [AgentStateRow],
        reviews: [ManagerReviewItem],
        workLog: [WorkLogRow],
        updates: [ManagerUpdate]
    ) -> ManagerSnapshot {
        var work: [String: WorkLogRow] = [:]
        for row in workLog where !row.sessionId.isEmpty && work[row.sessionId] == nil {
            work[row.sessionId] = row
        }

        var needsYou: [NeedsYouItem] = []
        for row in waiting.sorted(by: { $0.since > $1.since }) {
            needsYou.append(NeedsYouItem(
                kind: .agent(row),
                link: row.sessionId.isEmpty ? nil : .thread(id: row.sessionId),
                title: agentTitle(row, work: work[row.sessionId]),
                detail: oneLine(row.reason)))
        }
        for item in reviews {
            let remote = !item.host.isEmpty && item.host != Host.local.name
            let title = remote ? "\(item.session)@\(item.host)" : item.session
            let link: ThreadLink? = item.session.isEmpty ? nil : .open(
                session: item.session, window: item.window, pane: nil,
                host: item.host.isEmpty ? Host.local.name : item.host)
            needsYou.append(NeedsYouItem(
                kind: .review(item), link: link,
                title: title.isEmpty ? "—" : title, detail: item.text))
        }
        return ManagerSnapshot(needsYou: needsYou, recentWork: workLog, updates: updates)
    }

    /// Name the work, not the plumbing: the repo and branch the agent is on when
    /// `work_log` knows them, its tmux address when it only knows that, and the
    /// thread id as the last resort so a row is never blank.
    private static func agentTitle(_ row: AgentStateRow, work: WorkLogRow?) -> String {
        if let work, !work.repo.isEmpty {
            return [work.repo, work.branch].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let work, !work.session.isEmpty {
            return work.window.map { "\(work.session):\($0)" } ?? work.session
        }
        return "thread \(TmuxCommands.abbreviatedSessionId(row.sessionId))"
    }

    /// A reason is free text a hook wrote; the row gives it one line.
    private static func oneLine(_ text: String, limit: Int = 120) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

extension ManagerSnapshot {
    /// The same rows for the phone's manager home.
    var mobileBoard: MobileManagerBoard {
        MobileManagerBoard(
            items: needsYou.map { item in
                switch item.kind {
                case .agent(let row):
                    return MobileManagerItem(
                        kind: .agent, title: item.title, detail: item.detail,
                        at: row.since, link: item.link)
                case .review(let review):
                    return MobileManagerItem(
                        kind: .review, key: review.key, title: item.title, detail: item.detail,
                        severity: review.severity, at: review.updatedAt, link: item.link,
                        pointer: review.isPointer, card: MobileCard(review))
                }
            },
            updates: updates)
    }
}

/// One "Needs you" row: an agent blocked on the human, or a review item the
/// manager agent raised. The view draws `title`/`detail` and opens `link`; the
/// kind is kept so a review row can still offer its dismiss checkbox.
struct NeedsYouItem: Equatable {
    enum Kind: Equatable {
        case agent(AgentStateRow)
        case review(ManagerReviewItem)
    }

    let kind: Kind
    let link: ThreadLink?
    let title: String
    let detail: String
}

/// Orchestrates the manager agent's machinery: the seeded home dir + shared
/// SQLite store, the DB poll that feeds the rail's snapshot and toasts, the
/// session snapshot the agent reads back through `mux sessions`, and the pane
/// driver that carries the rail's chat into the `mux-manager` pane.
///
/// The agent is **on demand**: nothing here types into the `mux-manager` session
/// on its own. It acts when the human talks to it, and surveys the fleet from
/// the snapshot this controller publishes rather than by shelling out per host.
///
/// All store access runs on one serial queue (the store is not re-entrant);
/// timers fire on the main run loop and hop over. Main-thread API unless noted.
final class ManagerController {
    private let service: TmuxService
    private(set) var home: URL?
    private var store: ManagerStore?
    private(set) var started = false

    /// Serial home for the blocking work: SQLite reads/writes and tmux
    /// shell-outs (bounded by the CommandRunner timeout, but never on main).
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.manager")
    /// The driver polls a transcript file for the length of a turn, which is far
    /// longer than a DB poll may block for, so it gets its own serial queue.
    private let driverQueue = DispatchQueue(label: "is.rebar.muxmaestro.manager.driver")
    private var pollTimer: Timer?
    private var driver: ManagerPaneDriver?
    private var lastSnapshot = ManagerSnapshot.empty

    /// Everything the rail renders, published only when it changed (main thread).
    var onSnapshot: ((ManagerSnapshot) -> Void)?
    /// A new toast: the newest unseen notification + how many more arrived with
    /// it (main thread).
    var onToast: ((ManagerNotification, Int) -> Void)?

    static let pollInterval: TimeInterval = 1.5

    init(service: TmuxService) {
        self.service = service
    }

    /// Seed the home, open the store, create the tmux session, and start the DB
    /// poll. Idempotent; returns whether the machinery is running.
    @discardableResult
    func startIfNeeded() -> Bool {
        if started { return true }
        do {
            let home = try ManagerHome.ensure()
            self.home = home
            self.store = try ManagerStore(dbPath: ManagerHome.dbPath(home: home))
        } catch {
            NSLog("manager: start failed — \(error)")
            return false
        }
        started = true
        queue.async { [store] in try? store?.pruneDismissed() }
        ensureSession()
        if let tmux = service.tmuxPath {
            driver = ManagerPaneDriver(
                config: .init(tmuxPath: tmux, tmuxSession: ManagerHome.sessionName),
                runner: ProcessCommandRunner(),
                statusOverride: { [weak self] id in self?.hookStatus(sessionId: id) },
                queue: driverQueue,
                callbackQueue: .main)
        }

        let pollT = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(pollT, forMode: .common)
        pollTimer = pollT
        poll()
        return true
    }

    /// What the rail terminal runs: attach to `mux-manager`, creating it (in the
    /// manager home, running claude with `bin/mux` on PATH) when missing — so
    /// first open and every reattach are the same command. The inner sh string
    /// only runs on create; `-A` attaches straight to an existing session.
    func attachCommand() -> String? {
        guard let tmux = service.tmuxPath, let home else { return nil }
        showPane(homePath: home.path)
        return Self.attachCommandString(tmux: tmux, homePath: home.path)
    }

    /// Put the Maestro's window in front before the rail terminal attaches: a
    /// session shows its current window, and that may be one somebody added.
    private func showPane(homePath: String) {
        let service = self.service
        queue.async {
            guard let pane = ManagerPane.resolve(homePath: homePath, run: { service.runTmux($0) }) else { return }
            _ = service.runTmux(ManagerPane.showArgv(pane: pane))
        }
    }

    /// Pure builder for the attach-or-create command, split out so it's testable
    /// without a seeded home. See `launchShell` for the login-shell rationale.
    static func attachCommandString(tmux: String, homePath: String) -> String {
        return "\(tmux) new-session -A -s \(ManagerHome.sessionName) "
            + "-c \(Ssh.shellQuote(homePath)) \(Ssh.shellQuote(launchShell(homePath: homePath)))"
    }

    /// tmux argv that creates the session **detached**, running the same command
    /// the rail terminal would. The chat works with the terminal hidden, so the
    /// session has to exist before anyone attaches to it; the rail's
    /// `new-session -A` then simply attaches to what this created.
    ///
    /// The same tmux call marks the new pane as the Maestro's (`ManagerPane`),
    /// while it is still the only pane the session has.
    static func createCommandArgs(homePath: String) -> [String] {
        ["new-session", "-d", "-s", ManagerHome.sessionName, "-c", homePath,
         launchShell(homePath: homePath)] + ManagerPane.createMarkArgv(session: ManagerHome.sessionName)
    }

    /// The pane command, shared by the attach and the detached-create paths so
    /// the session is identical whichever one wins the race.
    ///
    /// It runs `claude` through a **login shell** (`$SHELL -lc`) rather than
    /// execing it bare. A Finder-launched app inherits a stunted PATH (just
    /// `/etc/paths`: no `/opt/homebrew/bin`, no `~/.local/bin`), which tmux passes
    /// straight through to the pane. A bare `exec claude` then isn't found, the
    /// pane command exits on create, and tmux tears the session down instantly —
    /// the "manager terminal flashes and dies" bug. The login shell sources the
    /// user's profile so `claude` (and its own subprocesses) resolve. `bin/` is
    /// prepended *inside* the login shell so the agent's `mux` CLI still wins over
    /// the profile PATH.
    ///
    /// The agent and its model are the ones Settings holds when the session is
    /// made; a running session keeps what it started with until it is restarted.
    static func launchShell(homePath: String) -> String {
        let agent = Settings.maestroAgent()
        return ManagerPane.launchShell(
            homePath: homePath, agent: agent, model: Settings.maestroModel(agent))
    }

    /// Kill the manager session and hand back a fresh attach-or-create command
    /// for the rail terminal to swap to (nil when tmux/home is unavailable).
    ///
    /// The replacement session is created here, on the same serial queue as the
    /// kill, rather than left to whoever attaches next: with the terminal hidden
    /// behind the toggle nobody attaches, and the chat still needs a pane.
    func restart(completion: @escaping (String?) -> Void) {
        let service = self.service
        let path = home?.path
        queue.async { [weak self] in
            _ = service.killSession(name: ManagerHome.sessionName)
            if let path {
                _ = service.runTmux(Self.createCommandArgs(homePath: path))
            }
            DispatchQueue.main.async { completion(self?.attachCommand()) }
        }
    }

    /// The human ticked a review row's checkbox — sticky ack in the DB.
    func dismiss(key: String) {
        queue.async { [store] in try? store?.dismiss(key: key) }
    }

    /// A card's answer reached its pane: kept on the row, so every reader of
    /// the list sees it was answered.
    func answered(key: String, label: String, at: Int) {
        queue.async { [store] in try? store?.recordAnswer(key: key, label: label, at: at) }
    }

    /// Send one prompt to the manager pane. `onDelta` streams the reply as it
    /// lands, `completion` fires once with the outcome (both on main).
    func send(
        _ text: String,
        requireIdle: Bool = false,
        onDelta: @escaping (String) -> Void,
        completion: @escaping (ManagerTurnOutcome) -> Void
    ) {
        guard let driver else {
            DispatchQueue.main.async { completion(.unreachable("tmux not found")) }
            return
        }
        driver.send(text, requireIdle: requireIdle, onDelta: onDelta, completion: completion)
    }

    /// The manager pane's status and transcript, for the phone server. Take it
    /// on the main thread; the two readers may then run on any queue. nil until
    /// the machinery has started.
    func paneReader() -> (status: () -> ManagerTurnStatus?, transcript: () -> URL?)? {
        guard started, let driver else { return nil }
        return (
            status: { driver.paneStatus() },
            transcript: { driver.transcript() })
    }

    /// Publish the app's freshly-refreshed session tree into the shared DB, where
    /// `mux sessions` reads it. This is the whole point of the snapshot: the agent
    /// surveys every host from one local SQLite read instead of fanning ssh calls
    /// out to each of them. Called from the sidebar's refresh callback on main;
    /// the write hops to the serial queue. A no-op until the machinery starts.
    func publishSessions(_ rows: [ManagerSessionRow]) {
        guard started, let store else { return }
        queue.async { try? store.replaceSessions(rows) }
    }

    // MARK: Internals

    /// Create the `mux-manager` session detached when it isn't there, so the chat
    /// has a pane to type into even though the terminal is hidden behind a toggle.
    private func ensureSession() {
        guard let home else { return }
        let service = self.service
        let path = home.path
        queue.async {
            guard !service.hasSession(ManagerHome.sessionName) else { return }
            _ = service.runTmux(Self.createCommandArgs(homePath: path))
        }
    }

    /// The driver's status source: the manager pane's own `agent_state` row, which
    /// its hooks write and which is fresher than any file the driver can scan,
    /// until it is not: a row no hook has written for a while gives way to
    /// Claude's own status file when the two disagree.
    ///
    /// Called synchronously on the driver queue, once per poll, with the session
    /// id the driver resolved when the turn started. The store is opened
    /// FULLMUTEX, so reading it from that queue cannot deadlock.
    private func hookStatus(sessionId id: String) -> ManagerTurnStatus? {
        guard let store, !id.isEmpty,
              let row = (try? store.agentStates())?.first(where: { $0.sessionId == id })
        else { return nil }
        return ManagerPaneDriver.status(
            for: row, fileStatus: driver?.fileStatus(), now: Int(Date().timeIntervalSince1970))
    }

    private func poll() {
        guard let store else { return }
        queue.async { [weak self] in
            let reviews = (try? store.reviewItems()) ?? []
            let waiting = (try? store.waitingAgents()) ?? []
            let workLog = (try? store.workLog(limit: 12)) ?? []
            let dayAgo = Int(Date().timeIntervalSince1970) - 86_400
            let updates = (try? store.updates(since: dayAgo, limit: 12)) ?? []
            let unseen = (try? store.unseenNotifications()) ?? []
            if let maxId = unseen.last?.id { try? store.markSeen(upTo: maxId) }
            let snapshot = ManagerSnapshot.build(
                waiting: waiting, reviews: reviews, workLog: workLog, updates: updates)
            DispatchQueue.main.async {
                guard let self else { return }
                if snapshot != self.lastSnapshot {
                    self.lastSnapshot = snapshot
                    self.onSnapshot?(snapshot)
                }
                if let newest = unseen.last {
                    self.onToast?(newest, unseen.count - 1)
                }
            }
        }
    }
}
