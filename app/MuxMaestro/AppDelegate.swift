import Cocoa
import GhosttyKit
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct HandoffTarget {
        let service: TmuxService
        let tmuxSession: String
        let pane: String
        let agent: AgentHandoff.Agent
        let sessionId: String
    }
    private var window: NSWindow?
    private weak var launchAtLoginItem: NSMenuItem?
    private weak var recoveryAutoResumeItem: NSMenuItem?
    private var ghostty: GhosttyApp?
    private var tickTimer: Timer?
    private var terminalVC: TerminalViewController?
    private var diffVC: DiffViewController?
    private var treeVC: TreeViewController?
    private var artifactsVC: ArtifactsViewController?
    /// Reads pane transcripts for the Artifacts panel, keeping a byte offset
    /// per transcript so the poll parses only appended lines.
    private let artifactReader = ArtifactTranscriptReader()
    private let artifactQueue = DispatchQueue(label: "is.rebar.MuxMaestro.artifacts", qos: .utility)
    private var runningDrawer: RunningDrawer?
    private var detailVC: DetailViewController?
    private var sidebarVC: SidebarViewController?
    /// The archived windows Edit > Undo can still restore. In memory only.
    private lazy var archiveHistory: WindowArchiveHistory = {
        let history = WindowArchiveHistory()
        history.onLeave = { [weak self] entry, worktree in
            self?.window?.undoManager?.removeAllActions(withTarget: entry)
            if let worktree { self?.cleanUpWorktreeUnlessInUse(worktree) }
            self?.savePendingCleanups()
        }
        return history
    }()
    /// The tmux service for the current breadcrumb selection — the target an inline
    /// breadcrumb rename runs against.
    private var breadcrumbService: TmuxService?
    /// The clickable breadcrumb, hosted in the window titlebar (not the content).
    private let breadcrumb = BreadcrumbHeaderView()
    /// The session cwd + service the Tree panel is currently bound to (resolved
    /// off-main when it opens / refreshes), so search/list/preview/open all reuse
    /// them and open on the right host. Main-thread only.
    private var treeCwd = ""
    private var treeService: TmuxService?
    /// The last full file-tree listing, so toggling the search query back to empty
    /// shows the tree instantly without re-listing.
    private var lastFileTree: FileTreeResult?
    /// Cache of the file currently in the preview, so clicking another match line
    /// of the same file re-scrolls without re-reading it over ssh. Main-thread only.
    private var previewPath = ""
    private var previewContent = ""
    /// The ⌘P quick-open palette + the session it's bound to. Main-thread only.
    private var filePaletteVC: FilePaletteViewController?
    private var quickOpenCwd = ""
    private var quickOpenService: TmuxService?
    /// The ⌘K session switcher. Main-thread only.
    private var sessionPaletteVC: SessionPaletteViewController?
    /// The session recency stack (most-recent first, deduped). Since ⌘` moved to
    /// windows this serves one purpose: picking where to land when the *attached*
    /// session is killed.
    private var sessionMRU: [SessionRef] = []
    /// The ⌘` cycler's stack: most-recently-visited windows, flat across every
    /// session and host. Capped so a long-running app can't grow it without bound.
    private var windowMRU: [WindowRef] = []
    private static let windowMRUCap = 60
    /// Bumped per "All panes" search so a slow host's results can't overwrite a
    /// newer query's. Main-thread only.
    private var paneSearchToken = 0
    /// The cycler's on-screen overlay and the local event monitor that drives a
    /// cycle while ⌘ is held. All main-thread only.
    private var sessionCyclerOverlay: SessionCyclerOverlay?
    private var cycleMonitor: Any?
    /// The ⌥⌘C commit panel + the session/cwd it's bound to. Main-thread only.
    private var commitPanelVC: CommitPanelViewController?
    /// The PRs screen (⌥⌘P / toolbar "PRs"): an overlay on the main window's
    /// content view, created on first open.
    private var pullRequestsVC: PullRequestsViewController?
    private var commitCwd = ""
    private var commitService: TmuxService?
    /// The Help window (feature docs + shortcuts), created on first open.
    private var helpWindowController: HelpWindowController?
    private var settingsWindowController: SettingsWindowController?
    /// Copies of remote agents' transcripts, for the phone's chat and voice.
    private let transcriptMirror = RemoteTranscriptMirror()
    /// The phone server and its "Phone" switch (Settings window). Off by default.
    private lazy var mobileServer = MobileServer(
        staticRoot: Bundle.main.resourceURL?.appendingPathComponent("mobile", isDirectory: true),
        sources: MobileServer.Sources(
            screen: { [registry] thread, lines in
                registry.service(for: thread.host).captureScrollback(target: thread.pane, lines: lines)
            },
            transcript: { [registry, transcriptMirror] thread in
                guard thread.host.isLocal else {
                    // A remote agent session: its transcript as a copy here.
                    return registry.service(for: thread.host).transcriptCopy(
                        claudeSessionId: thread.claudeSessionId, codexSessionId: thread.codexSessionId,
                        in: transcriptMirror)
                }
                return [thread.claudeSessionId, thread.codexSessionId].compactMap { $0 }
                    .compactMap { TranscriptTailReader.shared.transcript(sessionId: $0) }.first
            },
            pane: { [registry, agentStates = AgentStateReader()] thread in
                registry.service(for: thread.host).phonePane(target: thread.pane) { latest in
                    // The hooks' own rows, read now: newer than the tree.
                    MobileReply.state(
                        thread: latest, rows: agentStates.rows(),
                        now: Int(Date().timeIntervalSince1970))
                }
            },
            tmux: { [registry] host in
                { args in registry.service(for: host).phoneTmux(args) }
            },
            shell: { [registry] host in
                let service = registry.service(for: host)
                return MobileActions.HostShell(
                    home: { service.resolveHome() }, run: { service.phoneHostCommand($0) })
            },
            archive: { [weak self] thread in
                // The close flow belongs to the main thread and its kill runs
                // on the host's queue: wait here for both.
                let done = DispatchSemaphore(value: 0)
                var archived = false
                DispatchQueue.main.async {
                    guard let self else {
                        done.signal()
                        return
                    }
                    self.archiveWindowFromPhone(thread) {
                        archived = $0
                        done.signal()
                    }
                }
                done.wait()
                return archived
            },
            changed: { [weak self] in
                // The sidebar loads the tree again, and the phone follows it.
                DispatchQueue.main.async { self?.sidebarVC?.refresh() }
            },
            viewed: { [weak self] thread in
                DispatchQueue.main.async { self?.sidebarVC?.markViewed(threadID: thread) }
            },
            remoteCommands: { [registry] thread in
                registry.service(for: thread.host).phoneCommandFiles(for: thread)
            },
            artifacts: { [artifactReader, registry, transcriptMirror] thread in
                guard !thread.host.isLocal else {
                    return MobileArtifacts.scan(thread: thread, reader: artifactReader)
                }
                // A remote agent session: what its copied transcript mentions,
                // as those files are on its host.
                let service = registry.service(for: thread.host)
                guard let copy = service.transcriptCopy(
                          claudeSessionId: thread.claudeSessionId, codexSessionId: thread.codexSessionId,
                          in: transcriptMirror),
                      let mentions = artifactReader.mentions(transcript: copy.path)
                else { return nil }
                return service.artifactFiles.source(mentions: mentions, cwd: thread.cwd)
            },
            artifactDisk: { [registry] thread in
                registry.service(for: thread.host).artifactFiles.disk()
            },
            running: { [weak self] thread in
                // The sidebar's scan caches belong to the main thread.
                DispatchQueue.main.sync {
                    self?.sidebarVC?.runningSet(paneID: thread.pane, host: thread.host)
                }
            },
            terminal: { [registry] thread, target in
                registry.service(for: thread.host).phoneTerminal(target)
            }),
        manager: MobileServer.Manager(
            pane: { [weak self] in
                // The controller belongs to the main thread; its readers do not.
                guard let reader = DispatchQueue.main.sync(execute: {
                    self?.managerController?.paneReader()
                }) else { return (.off, nil) }
                return (MobileManagerStatus(reader.status()), reader.transcript()?.path)
            },
            send: { [weak self] text, queue, onDelta, completion in
                DispatchQueue.main.async {
                    guard let self else { return completion(.unreachable(MobileManager.offMessage)) }
                    self.runPhoneManagerTurn(text, queue: queue, onDelta: onDelta, completion: completion)
                }
            },
            dismiss: { [weak self] key in
                DispatchQueue.main.async { self?.managerController?.dismiss(key: key) }
            },
            answered: { [weak self] key, label, at in
                DispatchQueue.main.async {
                    self?.managerController?.answered(key: key, label: label, at: at)
                }
            },
            screen: { [registry] lines in
                // The Maestro's own pane, never the session: see `ManagerPane`.
                ManagerPane.resolve(run: { registry.local.runTmux($0) }).flatMap {
                    registry.local.captureScrollback(target: $0, lines: lines)
                }
            },
            io: { [registry] in
                // The server takes the manager's state from `pane` above; the
                // per-thread state source is not used for it.
                guard let pane = ManagerPane.resolve(run: { registry.local.runTmux($0) }) else { return nil }
                let io = registry.local.phonePane(target: pane) { thread in
                    MobilePaneState(status: thread.status, since: thread.since)
                }
                return (pane, io)
            },
            cwd: { ManagerHome.defaultHome()?.path },
            dozing: { [weak self] in
                // The sidebar's tree belongs to the main thread.
                DispatchQueue.main.sync {
                    MobileManager.dozing(self?.sidebarVC?.cachedSessions(host: .local) ?? [])
                }
            }),
        requests: ManagerHome.defaultHome().map {
            RequestTracker(url: $0.appendingPathComponent(RequestTracker.fileName))
        },
        // The phone's takes use the Mac's own engine. Nothing plays here: the
        // phone gets the samples.
        voice: MobileServer.Voice(
            speech: EngineSpeech(),
            warm: { speaker in
                Task { try? await VoiceEngine.shared.loadIfNeeded(speaker ? .all : .whisper) }
            }),
        serving: MobileServer.Serving(
            open: { [weak self] port, https, thread, label, host in
                self?.phoneLink.openMapping(
                    port: port, https: https, thread: thread, label: label, host: host)
                    ?? .unavailable("Phone access is off")
            },
            close: { [weak self] port in self?.phoneLink.closeMapping(port: port) ?? false },
            list: { [weak self] in self?.phoneLink.mappings ?? [] }),
        push: pushCenter,
        logDirectory: Settings.phoneLogDirectory())
    /// The phones that asked for notifications, and the sending.
    private lazy var pushCenter: MobilePushCenter = {
        let center = MobilePushCenter()
        center.configure(Settings.phonePush())
        center.onCount = { [weak self] count in
            DispatchQueue.main.async { self?.settingsWindowController?.phone.renderPushCount(count) }
        }
        return center
    }()
    private lazy var phoneLink: PhoneLink = {
        let link = PhoneLink(server: mobileServer)
        link.onChange = { [weak self] state in
            self?.settingsWindowController?.phone.render(state)
            // The QR code is drawn only in Settings: read the token while it shows.
            if self?.settingsWindowController?.window?.isVisible == true { self?.phoneLink.loadPairing() }
            // Hand the new listener the tree at once, not on the next change.
            if case .on = state { self?.pushMobileSnapshot() }
        }
        link.onMappings = { [weak self] mappings in
            self?.settingsWindowController?.phone.renderMappings(mappings.map(\.port))
        }
        return link
    }()
    /// The 🤖 Manager rail: the far-right split column, its item (collapse),
    /// the machinery behind it, and the toast overlay. Main-thread only.
    private var managerRailVC: ManagerRailViewController?
    private var managerRailItem: NSSplitViewItem?
    private var managerController: ManagerController?
    /// A manager turn is in flight, from the rail or from the phone.
    private var managerTurnRunning = false
    private var managerToast: ManagerToastOverlay?
    /// Push-to-talk, built on first press. The manager pane is its only target
    /// today.
    @MainActor private lazy var voice: VoiceController = {
        let voice = VoiceController(recorder: MicCapture(), speech: EngineSpeech())
        voice.onState = { [weak self] state in
            NSLog("voice: \(state)")
            self?.managerRailVC?.setVoiceState(state)
            // Instant cues: the mic is open, and the take is on its way.
            switch state {
            case .listening: NSSound(named: "Tink")?.play()
            case .transcribing: NSSound(named: "Pop")?.play()
            default: break
            }
        }
        voice.onNote = { [weak self] in self?.managerRailVC?.addNote($0) }
        voice.onSpeechFailed = { [weak self] error in
            NSLog("voice: speech failed — \(error)")
            self?.managerRailVC?.showReplyAsText()
        }
        return voice
    }()
    /// Which agent states have toasted, so each entry into waiting/done toasts once.
    private var agentToasts = AgentToastTracker()
    /// Whether the launch-time "manager session already running" reattach check
    /// has concluded (it retries each refresh until the local tree loads once).
    private var managerAutoStartChecked = false
    /// A `muxmaestro://` link waiting for the tree to hold its target, and when
    /// it stops waiting (see `openLink`).
    private var pendingLink: (link: ThreadLink, deadline: Date)?
    /// The two "Group by" menu items, kept so the checkmark can follow the mode.
    private weak var groupByHostItem: NSMenuItem?
    private weak var groupByDirItem: NSMenuItem?
    private weak var groupByRecentItem: NSMenuItem?
    /// The "Open in editor" split button, kept so its icon can follow the
    /// last-opened editor.
    private weak var openDirItem: NSMenuToolbarItem?
    /// One TmuxService per host (local + each remote). The local service backs
    /// the startup attach + self-tests; remote services are created on demand.
    private let registry = HostRegistry()
    /// True while a "Beam to server" is running, so a second beam can't race the
    /// same pane/host. Main-thread only.
    fileprivate var beamInFlight = false
    private var tmuxService: TmuxService { registry.local }
    /// The tmux session the single terminal is currently attached to. Selection
    /// only re-attaches (recreates the surface) when this changes. Read/written
    /// on the main thread only.
    private var attachedSession: String?
    /// The service the terminal is currently attached through (local or a remote
    /// ssh service) — so a follow-up window/pane select on the same session
    /// drives the right host. Main-thread only.
    private var attachedService: TmuxService?
    /// A handoff spans transcript reading, a reset, and a delayed paste. Only
    /// one may be in flight so repeated menu clicks cannot queue duplicate turns.
    private var handoffInFlight = false

    /// Fallback serial queue for host-AGNOSTIC driver work only: the M8/M14
    /// self-tests (which iterate every host) and the managed-hosts-file write.
    /// Per-host tmux drivers (select/create/kill/rename/cwd/probe) now run on
    /// their own `TmuxService.driverQueue` so a wedged remote can't head-of-line
    /// block a switch on another host — see that property's doc comment. Keeps
    /// the synchronous `Process` shell-outs off the main thread; we hop back to
    /// main for refresh()/alerts/surface attach.
    private static let driverQueue = DispatchQueue(label: "is.rebar.muxmaestro.drivers")

    // Toolbar item identifiers.
    private static let tbNew = NSToolbarItem.Identifier("new")
    private static let tbAddServer = NSToolbarItem.Identifier("addServer")
    private static let tbZoom = NSToolbarItem.Identifier("zoom")
    private static let tbKill = NSToolbarItem.Identifier("kill")
    private static let tbDiff = NSToolbarItem.Identifier("diff")
    private static let tbTree = NSToolbarItem.Identifier("tree")
    private static let tbArtifacts = NSToolbarItem.Identifier("artifacts")
    private static let tbSidebar = NSToolbarItem.Identifier("sidebar")
    private static let tbOpenDir = NSToolbarItem.Identifier("openDir")
    private static let tbGroup = NSToolbarItem.Identifier("group")
    private static let tbPRs = NSToolbarItem.Identifier("prs")
    private static let tbCommit = NSToolbarItem.Identifier("commit")
    private static let tbManager = NSToolbarItem.Identifier("manager")
    private static let tbGitHub = NSToolbarItem.Identifier("github")
    private static let tbBreadcrumb = NSToolbarItem.Identifier("breadcrumb")
    /// The toolbar item hosting `breadcrumb`, kept so its size can follow the
    /// crumbs (a custom-view item is measured only once, at insertion).
    private weak var breadcrumbItem: NSToolbarItem?
    /// The toolbar "PRs" dropdown + its menu (rebuilt on open from the sidebar's
    /// detected PRs).
    private weak var prsItem: NSMenuToolbarItem?
    private weak var prsMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The first sidebar poll can see an empty server before recovery runs.
        // Keep those polls from replacing the previous boot's snapshot.
        SessionRecord.suspendSnapshotWrites()
        guard let ghostty = GhosttyApp() else {
            fatalError("Failed to initialize libghostty app")
        }
        self.ghostty = ghostty
        // Copies of remote transcripts nobody opened for a week.
        DispatchQueue.global(qos: .utility).async { [transcriptMirror] in transcriptMirror.purge() }

        // Match the system appearance for the terminal palette.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty.setColorScheme(dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        // Build the split: live session tree (left) + one terminal (right).
        let sidebar = SidebarViewController(registry: registry)
        sidebar.selectionDelegate = self
        sidebar.actionDelegate = self
        // Keep the terminal's ⌘⇧-drag rearrange fed with fresh pane geometry, and
        // republish the session snapshot the manager agent surveys via
        // `mux sessions` (the app already has the data; the agent never re-scans).
        sidebar.onRefreshed = { [weak self, weak sidebar] in
            self?.pushRearrangePanes()
            self?.managerAutoStartCheck()
            self?.showAgentToasts()
            self?.retryPendingLink()
            self?.refreshArtifacts()
            self?.pushMobileSnapshot()
            guard let manager = self?.managerController, let sidebar else { return }
            manager.publishSessions(sidebar.managerSessionSnapshot())
        }
        self.sidebarVC = sidebar
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 400

        // The terminal starts attached to whatever `tmux attach` picks (the most
        // recently active session). Resolve that session explicitly and attach to
        // it by name so we can RECORD it as the attach state — otherwise
        // `attachedSession`/`attachedService` stay nil until the first sidebar
        // click, and a file dropped on the terminal before that click falls back
        // to typing the local path instead of routing through the session-aware
        // transfer (copy into the cwd + paste the path).
        let startup: String?
        if let session = registry.local.mostRecentSession(),
           let command = registry.local.attachCommand(session: session) {
            startup = command
            attachedSession = session
            attachedService = registry.local
        } else {
            startup = Self.startupCommand()
        }
        let terminal = TerminalViewController(ghostty: ghostty, command: startup)
        terminal.onRearrange = { [weak self] source, target, zone in
            self?.performRearrange(source: source, target: target, zone: zone)
        }
        terminal.onFileDrop = { [weak self] urls in
            self?.terminalDropFiles(urls) ?? false
        }
        terminal.onOpenLink = { [weak self] url in
            self?.terminalOpenLink(url) ?? false
        }
        self.terminalVC = terminal
        let diff = DiffViewController()
        diff.delegate = self
        self.diffVC = diff
        let tree = TreeViewController()
        tree.delegate = self
        self.treeVC = tree
        let running = RunningViewController()
        running.delegate = self
        let drawer = RunningDrawer(content: running, expanded: Settings.runningDrawerExpanded())
        drawer.onToggle = { Settings.setRunningDrawerExpanded($0) }
        self.runningDrawer = drawer
        let artifacts = ArtifactsViewController()
        artifacts.delegate = self
        self.artifactsVC = artifacts
        let rightSidebar = RightSidebarViewController(diff: diff, tree: tree, artifacts: artifacts)
        let detail = DetailViewController(
            terminal: terminal, rightSidebar: rightSidebar, runningDrawer: drawer)
        self.detailVC = detail
        detail.handoffCommands.onCopyContext = { [weak self] in
            self?.copyHandoffContext()
        }
        detail.handoffCommands.onHandoff = { [weak self] in
            self?.performHandoff(newWindow: false)
        }
        detail.handoffCommands.onHandoffNewWindow = { [weak self] in
            self?.performHandoff(newWindow: true)
        }
        // ⌘F find-bar events → tmux copy-mode search on the attached session.
        detail.findBar.onNeedleChange = { [weak self] needle in
            self?.findNeedleChanged(needle)
        }
        detail.findBar.onStep = { [weak self] older in self?.findStep(up: older) }
        detail.findBar.onClose = { [weak self] in self?.closeFindBar() }
        let detailItem = NSSplitViewItem(viewController: detail)
        // Keep the detail side from collapsing the window to a sliver.
        detailItem.minimumThickness = 560

        // The 🤖 Manager rail: a third, collapsible far-right column. Its view
        // is cheap until first reveal (the terminal surface installs lazily).
        let managerRail = ManagerRailViewController()
        self.managerRailVC = managerRail
        let managerItem = NSSplitViewItem(viewController: managerRail)
        managerItem.canCollapse = true
        managerItem.minimumThickness = 300
        // Wide enough for the list and the chat side by side.
        managerItem.maximumThickness = 1100
        // Hold the rail's width on window resizes — extra space goes to detail.
        managerItem.holdingPriority = NSLayoutConstraint.Priority(261)
        self.managerRailItem = managerItem

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        split.addSplitViewItem(managerItem)
        managerItem.isCollapsed = !Settings.managerRailShown()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "MuxMaestro"
        // Hide the native title text: the breadcrumb below IS the title now, so
        // showing both duplicated the path. `window.title` is still set (for
        // Mission Control / the Window menu), just not drawn in the titlebar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        // Force the dark appearance so the unified titlebar/toolbar render in
        // near-black to match the Geist theme (instead of stock light macOS
        // chrome), and paint the window base with the theme background.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.current.bg
        window.toolbar = makeToolbar()
        window.contentViewController = split
        // A hard floor so the window can never be dragged/restored to a sliver
        // (the saved frame is clamped to this on restore).
        window.minSize = NSSize(width: 900, height: 540)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.setFrameAutosaveName("SidekickMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // The clickable breadcrumb rides in the toolbar row itself (a leading
        // toolbar item, see `tbBreadcrumb`), so the header stays one row tall.
        // Renames route to the selected node's tmux service.
        breadcrumb.onRename = { [weak self] target, name in
            self?.performBreadcrumbRename(target, name)
        }
        breadcrumb.onWidthChange = { [weak self] width in
            self?.resizeBreadcrumbItem(to: width)
        }

        sidebar.wantsAllHostStats = { [weak self] in
            guard let self, self.phoneLink.isOn else { return false }
            return self.mobileServer.hasRecentClient
        }
        mobileServer.configure(Settings.phoneConfig())
        if Settings.phoneEnabled() { phoneLink.turnOn() } else { phoneLink.removeLeftoverMapping() }
        // `mux phone on|off`: the switch, for someone who is not at the Mac.
        if let request = PhoneRequest.defaultURL() {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let on = PhoneRequest.take(at: request) else { return }
                // On already: a second start would drop the phones that are connected.
                if on, self.phoneLink.isOn { return }
                self.setPhone(on)
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        NSApp.mainMenu = makeMenu()
        NSApp.activate(ignoringOtherApps: true)
        if !SetupTools.missingRequired(isExecutable: FileManager.default.isExecutableFile(atPath:)).isEmpty {
            showSettings(.tools)
        }

        // Wire the manager machinery (started lazily — on first rail reveal, or
        // right away when the rail was open last quit / a manager session from a
        // previous run is still alive; see managerAutoStartCheck).
        let manager = ManagerController(service: registry.local)
        manager.onSnapshot = { [weak self, weak managerRail] snapshot in
            managerRail?.setSnapshot(snapshot)
            self?.mobileServer.updateManager(snapshot.mobileBoard)
        }
        manager.onToast = { [weak self] notification, extra in
            self?.showManagerToast(notification, extra: extra)
        }
        managerRail.onDismiss = { [weak manager] key in manager?.dismiss(key: key) }
        managerRail.onOpen = { [weak self] item in
            self?.openManagerTarget(session: item.session, host: item.host)
        }
        managerRail.onRestart = { [weak self] in self?.actionRestartManager() }
        managerRail.onOpenLink = { [weak self] link in self?.openLink(link) }
        managerRail.onSend = { [weak self] text in self?.runManagerTurn(text) }
        managerRail.onTalk = { [weak self] in self?.actionTalk() }
        managerRail.onShowTerminal = { [weak self] in self?.installManagerTerminalIfNeeded() }
        managerRail.requests = ManagerHome.defaultHome().map {
            RequestTracker(url: $0.appendingPathComponent(RequestTracker.fileName), origin: .mac)
        }
        self.managerController = manager
        if Settings.managerRailShown() { startManagerMachinery() }
        startManagerForPhoneIfNeeded()

        // Drive libghostty. wakeup_cb also ticks on demand, but a steady timer
        // keeps animations/cursor blink and the renderer healthy.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.ghostty?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.tickTimer = timer

        restoreAfterRebootIfNeeded()
        // After the first tree load, so a worktree with a live pane is left alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.offerPendingWorktreeCleanups()
        }
        // Voice models fetch once, in the background; nothing waits on them.
        VoiceModels.shared.start()
        VoiceSelfTest.runIfRequested()
        SettingsSelfTest.runIfRequested()

        if ProcessInfo.processInfo.environment["SIDEKICK_ARCHIVE_SELFTEST"] == "1" {
            runArchiveSelfTest()
        }
        if ProcessInfo.processInfo.environment["SIDEKICK_M2_SELFTEST"] == "1" {
            runSelfTest()
        }
        if ProcessInfo.processInfo.environment["SIDEKICK_M3_SELFTEST"] == "1" {
            runM3SelfTest()
        }
        if ProcessInfo.processInfo.environment["SIDEKICK_M4_SELFTEST"] == "1" {
            runM4SelfTest()
        }
        if ProcessInfo.processInfo.environment["SIDEKICK_M8_SELFTEST"] == "1" {
            runM8SelfTest()
        }
        if ProcessInfo.processInfo.environment["SIDEKICK_M14_SELFTEST"] == "1" {
            runM14SelfTest()
        }
        if ProcessInfo.processInfo.environment["SIDEKICK_RECOVERY_SELFTEST"] == "1" {
            runRecoverySelfTest()
        }
        if ProcessInfo.processInfo.environment["SIDEKICK_SCROLL_SELFTEST"] == "1" {
            runScrollSelfTest()
        }
    }

    /// Sidebar scroll self-test: scroll the sidebar down, reorder a session's
    /// windows with its sort button (a full reload), and check the scroll stays.
    /// It flips the session's sort mode twice, so the setting ends as it began.
    /// Needs a live tree with a session header 400pt down. Prints PASSED/FAILED
    /// and exits. The first reorder used to snap the sidebar to the top.
    private func runScrollSelfTest() {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "scroll self-test")
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let root = self?.window?.contentView,
                  let outline = all(root).first(where: { $0 is NSOutlineView }) as? NSOutlineView,
                  let scroll = outline.enclosingScrollView
            else { print("SCROLL SELFTEST FAILED: no sidebar"); exit(1) }
            let start = NSPoint(x: 0, y: 400)
            scroll.contentView.scroll(to: start)
            scroll.reflectScrolledClipView(scroll.contentView)
            // A session whose recent order differs from its index order, so the
            // click really reorders rows (a one-window session proves nothing).
            let visible = outline.rows(in: outline.visibleRect)
            guard let row = (visible.lowerBound..<visible.upperBound).first(where: { r in
                guard case .session(_, let s)? = (outline.item(atRow: r) as? SidebarNode)?.kind
                else { return false }
                return TmuxWindow.byRecent(s.windows).map(\.index) != s.windows.map(\.index)
            }),
                  let header = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionCellView,
                  let node = outline.item(atRow: row) as? SidebarNode
            else { print("SCROLL SELFTEST SKIPPED: no reorderable session in view"); exit(2) }
            let name = header.nameField.stringValue
            // A full reload swaps the node objects, so find the header by identity.
            let headerRow = {
                (0..<outline.numberOfRows).first {
                    (outline.item(atRow: $0) as? SidebarNode)?.identity == node.identity
                }
            }
            let order = { headerRow().flatMap { (outline.item(atRow: $0) as? SidebarNode)?.children.map(\.identity) } }
            let before = order()
            header.sortButton.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let afterSort = scroll.contentView.bounds.origin.y
                let after = order()
                let moved = before != nil && after != nil && after != before
                headerRow().flatMap {
                    outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SessionCellView
                }?.sortButton.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    _ = activity
                    let afterRestore = scroll.contentView.bounds.origin.y
                    let ok = moved && afterSort == start.y && afterRestore == start.y
                    print("SCROLL SELFTEST \(ok ? "PASSED" : "FAILED"): session=\(name) moved=\(moved) "
                        + "start=\(Int(start.y)) afterSort=\(Int(afterSort)) afterRestore=\(Int(afterRestore))")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// Session-recovery self-test: snapshot a live tmux tree, kill the server,
    /// rebuild it from disk, and diff the result against what was there.
    ///
    /// **Run it against an isolated tmux server, never the live one** — it kills
    /// every session it can see. `TMUX_TMPDIR` is inherited by the tmux
    /// subprocesses, so `TMUX_TMPDIR=/tmp/whatever` puts the whole test on its own
    /// socket. `scripts/recovery-selftest.sh` sets that up and reads the result.
    ///
    /// Proves the three things unit tests can't: that a real poll produces a
    /// restorable snapshot, that the rebuild reproduces the names and directories,
    /// and that every resume line is left **unexecuted** at its prompt.
    private func runRecoverySelfTest() {
        Self.driverQueue.async { [registry] in
            let service = registry.local
            var lines = ["RECOVERY SELFTEST"]
            var ok = true
            func check(_ label: String, _ passed: Bool, _ detail: String = "") {
                ok = ok && passed
                lines.append("  \(passed ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  \(detail)")")
            }

            /// A comparable shape: session → windows → (name, [pane cwd]).
            func shape(_ tree: [TmuxSession]) -> [String: [(String, [String])]] {
                var out: [String: [(String, [String])]] = [:]
                for session in tree.sorted(by: { $0.name < $1.name }) {
                    out[session.name] = session.windows.map {
                        ($0.name, $0.panes.map(\.path))
                    }
                }
                return out
            }
            func describe(_ shape: [String: [(String, [String])]]) -> String {
                shape.keys.sorted().map { name in
                    "\(name)[" + (shape[name] ?? []).map {
                        "\($0.0):\($0.1.count)" }.joined(separator: " ") + "]"
                }.joined(separator: " ")
            }

            // 0. Refuse to run anywhere but a scratch socket. This test KILLS every
            // session it can see, and `$TMUX` overrides `$TMUX_TMPDIR` — so a run
            // started from inside a tmux pane would aim the whole thing at the live
            // server. That is not hypothetical: it destroyed 28 live agent sessions
            // on 2026-08-28. The shell script unsets `$TMUX`; this is the backstop
            // in case the app is ever launched some other way.
            let socket = service.socketPath() ?? ""
            guard socket.contains("muxmaestro-recovery-selftest") else {
                lines.append("  REFUSING TO RUN — tmux socket is \(socket.isEmpty ? "unknown" : socket),")
                lines.append("  not a scratch socket. Run via scripts/recovery-selftest.sh.")
                FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                exit(3)
            }

            // 1. The fixture, as the poll sees it, and the snapshot it writes.
            guard let before = service.loadTree(), !before.isEmpty else {
                lines.append("  no fixture sessions on this tmux server — nothing to test")
                FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                exit(2)
            }
            let snapshot = SessionRecord.snapshot(from: before, at: Date())
            check("snapshot written", SessionRecord.writeSnapshot(snapshot))

            // 2. Join it against agents.jsonl, exactly as recovery does.
            let text = SessionRecord.agentsURL()
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let records = SessionRecord.parseAgents(text)
            let plan = SessionRecord.restorePlan(tree: snapshot, records: records)
            let staged = SessionRecord.stagedPaneCount(plan)
            check("plan covers every session", plan.count == before.count,
                  "\(plan.count)/\(before.count)")
            lines.append("  \(records.count) pane record(s), \(staged) resume line(s) staged")

            // 3. Kill the server and rebuild from the plan alone.
            for session in before { _ = service.killSession(name: session.name) }
            check("server emptied", (service.loadTree() ?? []).isEmpty)
            let created = service.recoverTopology(plan)
            check("sessions rebuilt", created.count == plan.count,
                  "\(created.count)/\(plan.count)")

            // 4. Diff the rebuilt tree against the fixture.
            let after = service.loadTree() ?? []
            let want = shape(before), got = shape(after)
            check("session names", Set(want.keys) == Set(got.keys))
            check("window names + pane counts",
                  want.mapValues { $0.map(\.0) } == got.mapValues { $0.map(\.0) })
            check("pane directories", want.mapValues { $0.map(\.1) } == got.mapValues { $0.map(\.1) })
            lines.append("  before: \(describe(want))")
            lines.append("  after:  \(describe(got))")

            // 5. Every staged line is typed and NOT running.
            var typed = 0, running = 0
            for session in after {
                for window in session.windows {
                    for pane in window.panes {
                        let text = service.capturePane(target: pane.id) ?? ""
                        if text.contains("--resume ") || text.contains("codex resume ") { typed += 1 }
                        if pane.command == "claude" || pane.command == "codex" { running += 1 }
                    }
                }
            }
            check("resume lines typed", typed == staged, "\(typed)/\(staged)")
            check("nothing auto-started", running == 0, "\(running) agent(s) running")

            lines.append("")
            lines.append(ok ? "RECOVERY SELFTEST PASSED" : "RECOVERY SELFTEST FAILED")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(ok ? 0 : 1)
        }
    }

    /// M14 self-test: drive the real cold-scan tiering against the live ssh-config.
    /// Resolves every alias to its machine, cold-scans the non-watched remotes, and
    /// prints the resulting ACTIVE membership — proving dedupe + auto-discovery on
    /// real hosts rather than fakes.
    private func runM14SelfTest() {
        Self.driverQueue.async { [registry] in
            let hosts = SshConfig.loadHosts()
            let remotes = hosts.filter { !$0.isLocal }
            var lines = ["M14 SELFTEST — alias → machine identity:"]
            SshIdentity.prewarm(hosts)
            for h in remotes {
                lines.append("  \(h.name.padding(toLength: 16, withPad: " ", startingAt: 0))"
                    + "→ \(SshIdentity.cached(h) ?? "?")  watch=\(Settings.watch(host: h))")
            }

            let unique = SshIdentity.dedupe(remotes) { SshIdentity.cached($0) }
            lines.append("")
            lines.append("deduped: \(remotes.count) alias(es) → \(unique.count) machine(s): "
                + unique.map(\.name).joined(separator: ", "))

            // Cold-scan every unique remote exactly as `startColdScan` does.
            var sessionsByHost: [String: [TmuxSession]] = [:]
            let scheduler = RemoteScanScheduler()
            lines.append("")
            lines.append("cold scan:")
            for h in unique {
                let svc = registry.service(for: h)
                let started = Date()
                var reach = svc.probeReachability()
                var tree: [TmuxSession] = []
                if reach == .reachable {
                    if svc.hasTmux() { tree = svc.loadTree() ?? [] } else { reach = .tmuxMissing }
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if reach == .reachable { scheduler.recordSuccess(h.name, now: Date()) }
                else { scheduler.recordFailure(h.name, now: Date()) }
                if !tree.isEmpty { sessionsByHost[h.name] = tree }
                let due = scheduler.nextDue(h.name).map { Int($0.timeIntervalSinceNow) } ?? -1
                lines.append("  \(h.name.padding(toLength: 16, withPad: " ", startingAt: 0))"
                    + "\(reach)  sessions=\(tree.count)  \(ms)ms  next in \(due)s")
            }

            // The exact function buildHostNodes uses.
            let active = RemoteTier.active(
                remotes,
                watched: { Settings.watch(host: $0) },
                hasSessions: { !(sessionsByHost[$0.name] ?? []).isEmpty },
                identity: { SshIdentity.cached($0) })
            lines.append("")
            lines.append("ACTIVE remotes (\(active.count)):")
            for h in active {
                let names = (sessionsByHost[h.name] ?? []).map(\.name)
                let hot = RemoteTier.isHot(
                    watched: Settings.watch(host: h), expanded: false,
                    hasSessions: !names.isEmpty)
                lines.append("  \(h.name)  tier=\(hot ? "hot" : "cold")  sessions=\(names)")
            }
            // The duplicate bug = two ACTIVE remotes backed by the same machine, so
            // every one of its sessions renders twice. Assert one machine per row.
            let machines = active.map { SshIdentity.cached($0) ?? $0.name }
            let dupes = Dictionary(grouping: machines, by: { $0 }).filter { $1.count > 1 }
            let rows = active.reduce(0) { $0 + (sessionsByHost[$1.name] ?? []).count }
            lines.append("")
            lines.append(dupes.isEmpty
                ? "M14 OK — \(rows) session row(s) across \(active.count) active remote(s), one per machine"
                : "M14 FAIL — machines listed twice: \(dupes.keys.sorted())")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(dupes.isEmpty ? 0 : 1)
        }
    }

    // MARK: - Toolbar

    /// Hold the breadcrumb toolbar item to the strip's measured width. Without
    /// this the item keeps the width it had when the toolbar inserted it (empty,
    /// so ~0pt) and the crumbs draw outside their clipping viewer.
    private func resizeBreadcrumbItem(to width: CGFloat) {
        guard let item = breadcrumbItem else { return }
        let size = NSSize(width: width, height: BreadcrumbHeaderView.barHeight)
        item.minSize = size
        item.maxSize = size
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "SidekickToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    private func toolbarButton(
        _ id: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector,
        shortcut: String? = nil
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        // Reveal the chord on hover (menus already show it; the toolbar didn't).
        item.toolTip = shortcut.map { "\(label)  (\($0))" } ?? label
        return item
    }

    /// SF Symbols has no robot — draw the 🤖 emoji into a toolbar-sized image so
    /// the Manager toggle reads as what it is.
    private static func robotToolbarImage() -> NSImage {
        let size = NSSize(width: 19, height: 19)
        return NSImage(size: size, flipped: false) { rect in
            let str = NSAttributedString(
                string: "🤖", attributes: [.font: NSFont.systemFont(ofSize: 15)])
            let s = str.size()
            str.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
            return true
        }
    }

    // MARK: - Menu (keyboard shortcuts)

    private func makeMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MuxMaestro", action: nil, keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(actionShowSettings), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit MuxMaestro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Edit menu — standard text-editing commands. Without this menu the system
        // has no key equivalents for ⌘Z/⌘X/⌘C/⌘V/⌘A, so those don't work in any
        // text field (the ⌘P/⌘K palettes' search fields, the commit message box,
        // etc.). Items keep target=nil so they dispatch up the responder chain to
        // whatever field editor is focused.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Session menu — the M4 actions with shortcuts.
        let sessionItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        let new = NSMenuItem(
            title: "New Window", action: #selector(actionNewSession), keyEquivalent: "n")
        sessionMenu.addItem(new)
        let newRoot = NSMenuItem(
            title: "New Terminal at Root", action: #selector(actionNewRootSession), keyEquivalent: "n")
        newRoot.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(newRoot)
        let newPane = NSMenuItem(
            title: "New Pane", action: #selector(actionNewPane), keyEquivalent: "t")
        newPane.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(newPane)
        // Add Server has no shortcut (⌘⇧N now starts a fresh root terminal); it
        // stays reachable here and from the sidebar host **+** button.
        let addServer = NSMenuItem(
            title: "Add Server…", action: #selector(actionAddServer), keyEquivalent: "")
        sessionMenu.addItem(addServer)
        let recover = NSMenuItem(
            title: "Recover Previous Sessions…", action: #selector(actionRecoverSessions),
            keyEquivalent: "")
        sessionMenu.addItem(recover)
        let recoveryHooks = NSMenuItem(
            title: "Session Recovery Hooks…", action: #selector(actionSessionRecoveryHooks),
            keyEquivalent: "")
        sessionMenu.addItem(recoveryHooks)
        let autoResume = NSMenuItem(
            title: "Start Agents Automatically After Recovery",
            action: #selector(actionToggleRecoveryAutoResume), keyEquivalent: "")
        autoResume.target = self
        autoResume.state = Settings.sessionRecoveryAutoResumeAgents() ? .on : .off
        recoveryAutoResumeItem = autoResume
        sessionMenu.addItem(autoResume)
        let loginItem = NSMenuItem(
            title: "Open Mux Maestro at Login", action: #selector(actionToggleLaunchAtLogin),
            keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchAtLoginItem = loginItem
        sessionMenu.addItem(loginItem)
        let statusHooks = NSMenuItem(
            title: "Agent Status Hooks…", action: #selector(actionAgentStatusHooks),
            keyEquivalent: "")
        sessionMenu.addItem(statusHooks)
        // ⌘⇧R, not ⌘R — ⌘R is the universal "reload" shortcut.
        let rename = NSMenuItem(
            title: "Rename Session…", action: #selector(actionRenameSelected), keyEquivalent: "r")
        rename.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(rename)
        let zoom = NSMenuItem(
            title: "Toggle Zoom", action: #selector(actionToggleZoom), keyEquivalent: "\r")
        zoom.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(zoom)
        sessionMenu.addItem(.separator())
        // No shortcut — ⌘⌫ is a terminal hotkey (delete to line start) and must
        // reach the pane; killing a session stays a deliberate menu/toolbar act.
        let kill = NSMenuItem(
            title: "Kill Session", action: #selector(actionKillSelected), keyEquivalent: "")
        sessionMenu.addItem(kill)
        let closeWindow = NSMenuItem(
            title: "Archive Window", action: #selector(actionCloseWindow), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(closeWindow)
        sessionMenu.addItem(.separator())
        let showDiff = NSMenuItem(
            title: "Show Diff", action: #selector(actionShowDiff), keyEquivalent: "")
        sessionMenu.addItem(showDiff)
        let showTree = NSMenuItem(
            title: "Show Tree", action: #selector(actionToggleTree), keyEquivalent: "")
        sessionMenu.addItem(showTree)
        let showArtifacts = NSMenuItem(
            title: "Show Artifacts", action: #selector(actionToggleArtifacts), keyEquivalent: "")
        sessionMenu.addItem(showArtifacts)
        let showRunning = NSMenuItem(
            title: "Show Running", action: #selector(actionToggleRunning), keyEquivalent: "")
        sessionMenu.addItem(showRunning)
        let toggleSidebar = NSMenuItem(
            title: "Toggle Sidebar", action: #selector(actionToggleSidebar), keyEquivalent: "b")
        toggleSidebar.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(toggleSidebar)
        let sidebarLayout = NSMenuItem(
            title: "Toggle Sidebar Layout", action: #selector(actionToggleSidebarLayout), keyEquivalent: "l")
        sidebarLayout.keyEquivalentModifierMask = [.command, .control]
        sessionMenu.addItem(sidebarLayout)
        let toggleManager = NSMenuItem(
            title: "Toggle Maestro", action: #selector(actionToggleManager), keyEquivalent: "m")
        toggleManager.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(toggleManager)
        let talk = NSMenuItem(title: "Talk to Maestro", action: #selector(actionTalk), keyEquivalent: "t")
        talk.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(talk)
        let restartManager = NSMenuItem(
            title: "Restart Maestro Agent", action: #selector(actionRestartManager), keyEquivalent: "")
        sessionMenu.addItem(restartManager)
        // ⌘F searches the pane on screen (tmux scrollback); ⌘⇧F opens the search
        // panel, whose scope switch chooses every pane or the selected repo.
        let findInSession = NSMenuItem(
            title: "Find in Session", action: #selector(actionFindInSession), keyEquivalent: "f")
        findInSession.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(findInSession)
        let findInRepo = NSMenuItem(
            title: "Search…", action: #selector(actionSearchRepo), keyEquivalent: "f")
        findInRepo.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(findInRepo)
        let goToFile = NSMenuItem(
            title: "Go to File…", action: #selector(actionQuickOpen), keyEquivalent: "p")
        goToFile.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(goToFile)
        // Also accept ⌘⇧P (VS Code muscle memory) via a hidden twin that still
        // fires its key equivalent while hidden — so the menu shows one "Go to
        // File…" (⌘P) but both chords open the picker.
        let goToFileAlt = NSMenuItem(
            title: "Go to File…", action: #selector(actionQuickOpen), keyEquivalent: "p")
        goToFileAlt.keyEquivalentModifierMask = [.command, .shift]
        goToFileAlt.isHidden = true
        goToFileAlt.allowsKeyEquivalentWhenHidden = true
        sessionMenu.addItem(goToFileAlt)
        let goToSession = NSMenuItem(
            title: "Go to Session…", action: #selector(actionQuickSwitch), keyEquivalent: "k")
        goToSession.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(goToSession)
        // ⌘` MRU cycler. The menu's key equivalent only fires to *start* a cycle;
        // once cycling, the local event monitor swallows every ⌘` so the menu item
        // never re-fires (see actionCycleWindows / the monitor).
        let cycle = NSMenuItem(
            title: "Cycle Recent Windows", action: #selector(actionCycleWindows), keyEquivalent: "`")
        cycle.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(cycle)
        let commit = NSMenuItem(
            title: "Commit…", action: #selector(actionCommit), keyEquivalent: "c")
        commit.keyEquivalentModifierMask = [.command, .option]
        sessionMenu.addItem(commit)
        let openGitHub = NSMenuItem(
            title: "Open on GitHub", action: #selector(actionOpenGitHub), keyEquivalent: "g")
        openGitHub.keyEquivalentModifierMask = [.command, .option]
        sessionMenu.addItem(openGitHub)
        let pullRequests = NSMenuItem(
            title: "Pull Requests", action: #selector(actionShowPullRequests), keyEquivalent: "p")
        pullRequests.keyEquivalentModifierMask = [.command, .option]
        sessionMenu.addItem(pullRequests)
        sessionMenu.addItem(.separator())
        // Split the attached session's active pane (tmux-native, persists on the
        // server). ⌘D / ⌘⇧D match iTerm's split shortcuts.
        let splitRight = NSMenuItem(
            title: "Split Right", action: #selector(actionSplitRight), keyEquivalent: "d")
        splitRight.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(splitRight)
        let splitDown = NSMenuItem(
            title: "Split Down", action: #selector(actionSplitDown), keyEquivalent: "D")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(splitDown)
        for item in sessionMenu.items { item.target = self }
        sessionItem.submenu = sessionMenu
        mainMenu.addItem(sessionItem)

        // Help menu — in-app feature docs + the full keyboard-shortcut reference.
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let helpDoc = helpMenu.addItem(
            withTitle: "MuxMaestro Help", action: #selector(actionShowHelp), keyEquivalent: "?")
        helpDoc.target = self
        let helpKeys = helpMenu.addItem(
            withTitle: "Keyboard Shortcuts", action: #selector(actionShowShortcuts), keyEquivalent: "/")
        helpKeys.target = self
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    // MARK: - Help

    @objc private func actionShowHelp() { helpControllerOrCreate().show() }
    @objc private func actionShowShortcuts() { helpControllerOrCreate().show(scrollTo: "shortcuts") }

    // MARK: - Settings

    @objc private func actionShowSettings() {
        showSettings(nil)
    }

    private func showSettings(_ tab: SettingsWindowController.Tab?) {
        if settingsWindowController == nil {
            let setup = SettingsWindowController()
            setup.maestro.onRestart = { [weak self] in self?.actionRestartManager() }
            setup.onInstall = { [weak self] tool in self?.runSetupInstall(tool) }
            setup.phone.onToggle = { [weak self] on in self?.setPhone(on) }
            setup.phone.onCapability = { [weak self] capability, on in
                Settings.setPhoneCapability(capability, on)
                self?.mobileServer.configure(Settings.phoneConfig())
                // A dev server stays published only while its switch is on.
                if capability == .localServers, !on { self?.phoneLink.closeAllMappings() }
                self?.startManagerForPhoneIfNeeded()
            }
            setup.phone.onPort = { [weak self] port in
                Settings.setPhonePort(port)
                // The listener and the tailnet mapping both move to the new port.
                if Settings.phoneEnabled() { self?.phoneLink.turnOn() }
            }
            setup.phone.onGrouping = { [weak self] grouping in
                Settings.setPhoneGrouping(grouping)
                self?.mobileServer.configure(Settings.phoneConfig())
            }
            setup.phone.onVoice = { [weak self] voice in
                Settings.setPhoneVoice(voice)
                self?.mobileServer.configure(Settings.phoneConfig())
            }
            setup.phone.onUploadLimit = { [weak self] bytes in
                Settings.setPhoneUploadLimit(bytes)
                self?.mobileServer.configure(Settings.phoneConfig())
            }
            setup.phone.onUploadFolder = { [weak self] folder in
                Settings.setPhoneUploadFolder(folder)
                self?.mobileServer.configure(Settings.phoneConfig())
            }
            setup.phone.onPush = { [weak self] options in
                Settings.setPhonePush(options)
                self?.pushCenter.configure(options)
            }
            setup.phone.onTestPush = { [weak self] in
                self?.pushCenter.sendTest { result in
                    DispatchQueue.main.async { self?.settingsWindowController?.phone.renderPushTest(result) }
                }
            }
            setup.phone.onRotate = { [weak self] in self?.phoneLink.rotateToken() }
            setup.phone.onKeepAwake = { [weak self] on in
                Settings.setPhoneKeepAwake(on)
                self?.phoneLink.refreshKeepAwake()
            }
            setup.phone.render(phoneLink.state)
            setup.phone.renderMappings(phoneLink.mappings.map(\.port))
            settingsWindowController = setup
            // The count is in the Keychain: only a Mac that uses notifications reads it.
            if Settings.phoneCapability(.notifications) { pushCenter.reportCount() }
        }
        settingsWindowController?.show(tab)
        phoneLink.loadPairing()
    }

    /// Turn the Phone switch: from the Setup window, or from `mux phone on|off`.
    private func setPhone(_ on: Bool) {
        Settings.setPhoneEnabled(on)
        if on { phoneLink.turnOn() } else { phoneLink.turnOff() }
        startManagerForPhoneIfNeeded()
    }

    /// Give the phone server the tree the sidebar just loaded. Costs nothing
    /// while the phone switch is off.
    private func pushMobileSnapshot() {
        guard phoneLink.isOn, let sidebar = sidebarVC else { return }
        let snapshot = sidebar.mobileSnapshot()
        mobileServer.update(snapshot)
        // A published dev server is closed once it stops, or its thread goes.
        phoneLink.sweep(snapshot: snapshot) { sidebar.runningSet(paneID: $0.pane, host: $0.host) }
    }

    /// Run a Setup install recipe in the terminal, like the remote mosh install:
    /// it can prompt for a password, and its output stays on screen.
    private func runSetupInstall(_ tool: SetupTool) {
        guard let install = tool.install else { return }
        attachedSession = nil
        attachedService = nil
        window?.title = "Installing \(tool.name)…"
        terminalVC?.swap(command: SetupTools.terminalCommand(install: install))
        window?.makeKeyAndOrderFront(nil)
    }

    private func helpControllerOrCreate() -> HelpWindowController {
        if let helpWindowController { return helpWindowController }
        let c = HelpWindowController()
        helpWindowController = c
        return c
    }

    // MARK: - Actions

    /// ⌘N — instant: a new tmux window in the selected session (on its host's
    /// service, so it works on remotes too), or — with nothing selected — a new
    /// session at home. No prompt either way. The prompt-based new-session flow
    /// stays reachable via the sidebar host **+** button.
    @objc private func actionNewSession() {
        if let session = sidebarVC?.selectedSessionName {
            newWindow(session: session, service: sidebarVC?.selectedService ?? registry.local)
            return
        }
        let dir = NSHomeDirectory()
        createSessionInstant(
            name: (dir as NSString).lastPathComponent, dir: dir,
            launchClaude: false, host: .local, service: registry.local)
    }

    /// ⌘⇧N — always start a fresh top-level ("root") session on the local host at
    /// the home directory, regardless of the current selection (unlike ⌘N, which
    /// adds a window to the selected session). Instant, no prompt.
    @objc private func actionNewRootSession() {
        let dir = NSHomeDirectory()
        createSessionInstant(
            name: (dir as NSString).lastPathComponent, dir: dir,
            launchClaude: false, host: .local, service: registry.local)
    }

    /// Create a new session on `host` via `service`. Defaults the working
    /// directory to home (`~`) — no folder picker; navigate inside the session
    /// afterwards. The name is pre-filled and auto-deduped, so repeats never collide.
    private func newSession(host: Host, service: TmuxService) {
        let defaultDir = host.isLocal ? NSHomeDirectory() : "~"
        let result: (name: String, dir: String, launchClaude: Bool)?
        if host.isLocal {
            let defaultName = (defaultDir as NSString).lastPathComponent
            result = NewSessionPrompt.runQuick(
                window: window, defaultName: defaultName, defaultDir: defaultDir)
        } else {
            result = NewSessionPrompt.runRemote(
                window: window, host: host.name, defaultDir: defaultDir)
        }
        guard let (name, dir, launchClaude) = result else { return }
        createSessionInstant(
            name: name, dir: dir, launchClaude: launchClaude, host: host, service: service)
    }

    /// Create a session off-main and, on success, refresh + select it on its host.
    /// Shared by the ⌘N instant path and the prompt-based `newSession` flow.
    private func createSessionInstant(
        name: String, dir: String, launchClaude: Bool, host: Host, service: TmuxService
    ) {
        service.driverQueue.async {
            let created = service.newSession(name: name, dir: dir, launchClaude: launchClaude)
            DispatchQueue.main.async {
                if let created {
                    // Render + select the new row NOW (before the reconciling
                    // refresh's ~300ms status snapshot + remote barrier), attach the
                    // terminal, then refresh to reconcile the real subtree in.
                    self.sidebarVC?.insertOptimisticSession(created, host: host)
                    self.sidebarDidSelectSession(created, service: service)
                    self.sidebarVC?.selectSessionWhenReady(created, host: host)
                    // Created from a sidebar "+"? First responder is the outline
                    // view, so hand the keyboard to the new session's terminal.
                    self.detailVC?.focusTerminal()
                } else {
                    self.presentError(
                        "Couldn’t create the session. The name may already be in use.")
                }
            }
        }
    }

    /// Recover agent sessions lost to a reboot / OS update / tmux-server death.
    ///
    /// Two paths, best first. When `recovery/tree.json` exists, rebuild its
    /// sessions, windows, pane layouts, and selections, staging each captured
    /// Claude/Codex resume command. The snapshot gets agent ids from the normal
    /// pane poll; hook records and transcript scanning fill gaps. With no usable
    /// snapshot, offer the newest Claude transcript per project directory.
    ///
    /// Local host only: the snapshot, the transcripts and the boot time are all
    /// this Mac's.
    @objc private func actionRecoverSessions() {
        registry.local.driverQueue.async { [weak self] in
            let exact = Self.pendingRestorePlan()
            let fallback = exact == nil ? ClaudeSessionRecovery.lostSessions : []
            DispatchQueue.main.async {
                guard let self else { return }
                if let exact {
                    self.confirmRestoreTopology(exact)
                } else {
                    self.presentRecoverSessions(fallback)
                }
            }
        }
    }

    /// The restore plan waiting on disk, or nil when there is nothing to rebuild.
    /// If the snapshot has no agent id for a pane, borrow one from the hook log or
    /// transcript scan matched by directory. Blocking; call off the main thread.
    private static func pendingRestorePlan() -> (snapshot: TreeSnapshot, plan: [RestoreSession])? {
        guard let treeURL = SessionRecord.treeURL(),
              let data = try? Data(contentsOf: treeURL),
              let snapshot = SessionRecord.decode(data)
        else { return nil }
        let text = SessionRecord.agentsURL()
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let records = SessionRecord.parseAgents(text)
        var fallback = SessionRecord.byDirectory(records)
        for lost in ClaudeSessionRecovery.lostSessions where fallback[lost.cwd] == nil {
            fallback[lost.cwd] = AgentRecord(
                pane: "", agent: .claude, sessionId: lost.id, cwd: lost.cwd)
        }
        let plan = SessionRecord.restorePlan(
            tree: snapshot, records: records, fallbackByDirectory: fallback)
        return plan.isEmpty ? nil : (snapshot, plan)
    }

    /// Ask before rebuilding — the menu can fire onto a server that already has
    /// sessions. Existing names are preserved by choosing a free suffix.
    private func confirmRestoreTopology(_ pending: (snapshot: TreeSnapshot, plan: [RestoreSession])) {
        let windows = pending.plan.reduce(0) { $0 + $1.windows.count }
        let staged = SessionRecord.stagedPaneCount(pending.plan)
        let resumePolicy = Settings.sessionRecoveryAutoResumeAgents()
            ? "Known agent sessions will start automatically."
            : "Resume commands will be typed at their prompts, not run."
        let alert = NSAlert()
        alert.messageText = "Rebuild \(pending.plan.count) session(s)?"
        alert.informativeText = "From the tmux tree recorded "
            + "\(Self.recoveryTimestamp(pending.snapshot.at)): \(pending.plan.count) session(s), "
            + "\(windows) window(s), \(staged) with an agent to resume. " + resumePolicy
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        let go = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            self?.restoreTopology(pending.plan, announce: true, snapshot: pending.snapshot)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: go)
        } else {
            go(alert.runModal())
        }
    }

    /// Run the rebuild off-main, then refresh the sidebar and attach the first
    /// session — mirroring what creating a session does.
    private func restoreTopology(
        _ plan: [RestoreSession], announce: Bool, snapshot: TreeSnapshot? = nil,
        automaticBoot: Date? = nil
    ) {
        if snapshot != nil { SessionRecord.suspendSnapshotWrites() }
        let service = registry.local
        service.driverQueue.async { [weak self] in
            let boot = automaticBoot ?? ClaudeSessionRecovery.bootTime()
            let savedProgress = SessionRecord.readRestoreProgress()
            let progressMatches: RestoreProgress?
            if let snapshot, let savedProgress, let boot,
               savedProgress.snapshotAt == snapshot.at, savedProgress.bootTime == boot {
                progressMatches = savedProgress
            } else {
                progressMatches = nil
            }
            let usesJournal = snapshot != nil && boot != nil
            var progress: RestoreProgress?
            if let progressMatches {
                progress = progressMatches
            } else if usesJournal, let boot, let snapshot {
                progress = RestoreProgress(
                    bootTime: boot, snapshotAt: snapshot.at, restoreToken: UUID().uuidString,
                    uniqueNames: automaticBoot == nil, completed: [:], inProgress: [:])
            }
            let progressWriteOK = progress.map(SessionRecord.writeRestoreProgress) ?? true

            let mode: TopologyRestoreMode
            if usesJournal, let progress {
                mode = .resume(
                    completed: progress.completed, inProgress: progress.inProgress,
                    token: progress.restoreToken, uniqueNames: progress.uniqueNames)
            } else {
                mode = .uniqueNames
            }
            let report: TopologyRestoreReport
            if usesJournal, !progressWriteOK {
                report = TopologyRestoreReport(failures: plan.map {
                    TopologyRestoreFailure(
                        session: $0.name, reason: "could not save recovery progress")
                })
            } else {
                report = service.recoverTopology(
                    plan, mode: mode,
                    resumeAgentsImmediately: Settings.sessionRecoveryAutoResumeAgents(),
                    onSessionStarting: { name, temporaryName in
                        guard var current = progress else { return true }
                        current.inProgress[name] = temporaryName
                        guard SessionRecord.writeRestoreProgress(current) else { return false }
                        progress = current
                        return true
                    }
                ) { name, actualName, succeeded in
                    guard succeeded, var current = progress, let actualName else { return }
                    current.inProgress.removeValue(forKey: name)
                    current.completed[name] = actualName
                    progress = current
                    _ = SessionRecord.writeRestoreProgress(current)
                }
            }

            if snapshot != nil, report.isComplete, report.completedCount == plan.count {
                if usesJournal, let progress {
                    SessionRecord.markRestored(bootTime: progress.bootTime)
                    SessionRecord.clearRestoreProgress()
                }
                SessionRecord.resumeSnapshotWrites()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sidebarVC?.refresh()
                if let first = report.created.first ?? report.alreadyPresent.first {
                    self.sidebarDidSelectSession(first, service: service)
                    self.sidebarVC?.selectSessionWhenReady(first, host: .local)
                }
                let incomplete = !report.isComplete || report.completedCount < plan.count
                guard announce || incomplete else { return }
                if incomplete {
                    let failures = report.failures.map { "\($0.session): \($0.reason)" }
                        .joined(separator: "\n")
                    self.presentError(
                        "Rebuilt \(report.completedCount) of \(plan.count) sessions. "
                            + "The saved recovery snapshot is retained so you can retry."
                            + (failures.isEmpty ? "" : "\n\(failures)"))
                }
            }
        }
    }

    /// Rebuild the pre-reboot tmux tree at launch, silently. Every guard has to
    /// hold: the user opted in, tmux is here, the local server has **no** sessions
    /// (so this can't pile a second copy on top of live work), the snapshot
    /// predates the last boot (it is the dead tree, not one this run wrote), and
    /// this boot hasn't already been restored by an earlier launch.
    private func restoreAfterRebootIfNeeded() {
        // Manual recovery still needs the last tree when automatic recovery is
        // off. Keep the startup write barrier in place through an empty server;
        // TmuxService releases it when a live tree appears.
        guard Settings.sessionRecoveryEnabled() else { return }
        guard let boot = ClaudeSessionRecovery.bootTime() else {
            SessionRecord.resumeSnapshotWrites()
            return
        }
        guard !SessionRecord.hasRestored(bootTime: boot) else {
            SessionRecord.resumeSnapshotWrites()
            return
        }
        let service = registry.local
        service.driverQueue.async { [weak self] in
            guard service.hasTmux() else { return }
            // With no tmux server yet, list-sessions returns nil. Treat that as
            // empty here; no other writer can replace the snapshot while the
            // startup barrier is held.
            let live = service.loadTree() ?? []
            let savedProgress = SessionRecord.readRestoreProgress()
            if let savedProgress, savedProgress.bootTime == boot,
               let pending = Self.pendingRestorePlan(),
               pending.snapshot.at == savedProgress.snapshotAt {
                DispatchQueue.main.async {
                    self?.restoreTopology(
                        pending.plan, announce: false, snapshot: pending.snapshot,
                        automaticBoot: boot)
                }
                return
            }

            // A non-empty server without our journal belongs to live user work.
            // A successfully read empty tree is the only safe first attempt.
            guard live.isEmpty,
                  let pending = Self.pendingRestorePlan(), pending.snapshot.at < boot
            else {
                SessionRecord.resumeSnapshotWrites()
                return
            }
            DispatchQueue.main.async {
                self?.restoreTopology(
                    pending.plan, announce: false, snapshot: pending.snapshot,
                    automaticBoot: boot)
            }
        }
    }

    @objc private func actionToggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            let status = SMAppService.mainApp.status
            launchAtLoginItem?.state = status == .enabled ? .on : .off
            if status == .requiresApproval {
                presentInfo(
                    "Allow Mux Maestro in System Settings → General → Login Items to "
                        + "finish enabling launch at login.")
            }
        } catch {
            launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            presentError("Couldn’t update Mux Maestro’s Login Item: \(error.localizedDescription)")
        }
    }

    @objc private func actionToggleRecoveryAutoResume() {
        let enabled = !Settings.sessionRecoveryAutoResumeAgents()
        Settings.setSessionRecoveryAutoResumeAgents(enabled)
        recoveryAutoResumeItem?.state = enabled ? .on : .off
    }

    private static func recoveryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Install or remove the `SessionStart` hooks that make exact recovery
    /// possible, in `~/.claude/settings.json` and `~/.codex/hooks.json`. Only ever
    /// from this explicit menu action — the app never edits an agent's config on
    /// its own. Installing also turns the snapshot writer on; removing turns it off.
    @objc private func actionSessionRecoveryHooks() {
        let installed = AgentHookInstall.isInstalled() && Settings.sessionRecoveryEnabled()
        let alert = NSAlert()
        alert.messageText = installed
            ? "Remove session recovery hooks?" : "Install session recovery hooks?"
        alert.informativeText = installed
            ? "Removes the MuxMaestro SessionStart hook from ~/.claude/settings.json and "
                + "~/.codex/hooks.json, and stops recording the tmux tree. Other hooks are "
                + "left alone."
            : "Adds a SessionStart hook to ~/.claude/settings.json and ~/.codex/hooks.json "
                + "that records each agent session against its tmux pane, and starts "
                + "recording the tmux tree. After a reboot MuxMaestro rebuilds the same "
                + "sessions and windows with each agent's resume line staged.\n\n"
                + "Codex trusts hooks one at a time: the next codex start will say “Hooks "
                + "need review” — approve it once, or the hook won’t run."
        alert.addButton(withTitle: installed ? "Remove" : "Install")
        alert.addButton(withTitle: "Cancel")
        let go = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyRecoveryHooks(install: !installed)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: go)
        } else {
            go(alert.runModal())
        }
    }

    private func applyRecoveryHooks(install: Bool) {
        registry.local.driverQueue.async { [weak self] in
            let outcome = AgentHookInstall.run(install: install)
            DispatchQueue.main.async {
                guard let self else { return }
                Settings.setSessionRecoveryEnabled(install)
                if !outcome.failed.isEmpty {
                    self.presentError(outcome.failed
                        .map { "\($0.target.displayName): \($0.reason)" }
                        .joined(separator: "\n"))
                    return
                }
                let touched = (outcome.changed + outcome.unchanged)
                    .map(\.displayName).joined(separator: " and ")
                self.presentInfo(install
                    ? "Session recovery is on for \(touched). Approve the hook once when "
                        + "Codex next asks, then start a session in each pane you want "
                        + "recovered — the record only covers sessions started from now on."
                    : "Session recovery is off. The hook was removed from \(touched).")
            }
        }
    }

    /// Install or remove the hooks that report each agent's state through
    /// `mux event` — the source of the exact dots and the waiting/done toasts. Only
    /// from this menu action, and only after the alert lists every hook it adds
    /// or removes in each file.
    @objc private func actionAgentStatusHooks() {
        let installed = AgentHookInstall.isInstalled(.events)
        let changes = AgentHookInstall.preview(.events, install: !installed)
        // Nothing to list: already in that state, or a file that won't parse —
        // `run` changes nothing either way and reports which.
        guard !changes.isEmpty else {
            applyAgentStatusHooks(install: !installed)
            return
        }
        let sign = installed ? "−" : "+"
        let diff = changes
            .map { "\($0.target.displayPath)\n\(sign) \($0.events.joined(separator: ", "))" }
            .joined(separator: "\n\n")
        let alert = NSAlert()
        alert.messageText = installed ? "Remove agent status hooks?" : "Install agent status hooks?"
        alert.informativeText = installed
            ? diff
            : diff + "\n\nEach runs '\(AgentHookInstall.scriptPath(for: .events))' event "
                + "<agent>, which records the agent’s state for the sidebar and toasts.\n\n"
                + "Codex trusts hooks one at a time: the next codex start will say “Hooks "
                + "need review” — approve them once, or they won’t run."
        alert.addButton(withTitle: installed ? "Remove" : "Install")
        alert.addButton(withTitle: "Cancel")
        let go = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyAgentStatusHooks(install: !installed)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: go)
        } else {
            go(alert.runModal())
        }
    }

    private func applyAgentStatusHooks(install: Bool) {
        registry.local.driverQueue.async { [weak self] in
            let outcome = AgentHookInstall.run(.events, install: install)
            // Nothing moves a row once the hooks are gone, so forget them all.
            if !install, outcome.failed.isEmpty, let dbPath = ManagerHome.defaultDBPath(),
               FileManager.default.fileExists(atPath: dbPath) {
                try? ManagerStore(dbPath: dbPath).clearAgentStates()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if !outcome.failed.isEmpty {
                    self.presentError(outcome.failed
                        .map { "\($0.target.displayName): \($0.reason)" }
                        .joined(separator: "\n"))
                    return
                }
                let touched = (outcome.changed + outcome.unchanged)
                    .map(\.displayName).joined(separator: " and ")
                self.presentInfo(install
                    ? "Agent status hooks are on for \(touched)."
                    : "Agent status hooks are off for \(touched).")
            }
        }
    }

    private func presentRecoverSessions(_ candidates: [RecoverableSession]) {
        guard !candidates.isEmpty else {
            presentInfo("No recoverable Claude Code sessions found — nothing was "
                + "active in the \(Int(ClaudeSessionRecovery.defaultWindow) / 3600) "
                + "hours before the last boot.")
            return
        }
        guard let choice = RecoverSessionsPrompt.run(window: window, candidates: candidates)
        else { return }
        let service = registry.local
        service.driverQueue.async { [weak self] in
            var firstCreated: String?
            var failures = 0
            for session in choice.sessions {
                let created = service.recoverSession(
                    name: session.suggestedSessionName, dir: session.cwd,
                    claudeSessionId: session.id, autostart: choice.autostart)
                if let created, firstCreated == nil { firstCreated = created }
                if created == nil { failures += 1 }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sidebarVC?.refresh()
                if let first = firstCreated {
                    // Attach the first recovered session, mirroring new-session.
                    self.sidebarDidSelectSession(first, service: service)
                    self.sidebarVC?.selectSessionWhenReady(first, host: .local)
                }
                if failures > 0 {
                    self.presentError("Couldn’t recover \(failures) of "
                        + "\(choice.sessions.count) sessions.")
                }
            }
        }
    }

    /// Add a remote SSH host (M10): present the sheet, persist to the managed
    /// hosts file (so ssh can resolve the alias), run the test-on-save probe, and
    /// surface success/failure — letting the user keep a failing entry or remove
    /// it. On success the sidebar host list picks up the new alias (the parser
    /// follows the `Include`), so we refresh.
    @objc private func actionAddServer() {
        guard let prompt = AddServerPrompt.run(window: window) else { return }
        let entry = prompt.entry
        // Persist first so `ssh <name>` can resolve via the Include before the
        // probe. Done on main (fast string/file ops); the probe runs off-main.
        let result: AddServer.SaveResult
        do {
            result = try AddServer.save(
                entry: entry,
                managedHostsPath: AddServer.managedHostsPath,
                configPath: AddServer.sshConfigPath)
        } catch {
            presentError("Couldn’t save the server: \(error.localizedDescription)")
            return
        }
        // mosh/watch are app settings, not ssh directives — persist them keyed by
        // the alias so the new host honors them on first poll/attach.
        AddServer.applyConnectionSettings(
            alias: entry.name, useMosh: prompt.useMosh, watch: prompt.watch)
        sidebarVC?.refresh()  // the new host appears immediately.

        // Test-on-save off-main (BatchMode ssh; may trigger Touch ID). When mosh
        // was chosen, also probe for mosh-server so we can offer to install it.
        let host = Host(name: entry.name, sshAlias: entry.name)
        registry.service(for: host).driverQueue.async { [weak self] in
            let ok = AddServer.testConnection(name: entry.name)
            let moshMissing = ok && prompt.useMosh
                && !TmuxService(host: host).hasMoshServer()
            DispatchQueue.main.async {
                guard let self else { return }
                if !ok {
                    self.handleFailedServerTest(entry: entry, result: result)
                } else if moshMissing {
                    self.offerInstallMosh(host: host)
                } else {
                    self.presentInfo(
                        "Added “\(entry.name)” and verified the connection.")
                }
            }
        }
    }

    /// Edit an existing MuxMaestro-managed server: prefill the sheet from its
    /// current `Host` block, then re-save. A rename removes the old block and
    /// carries the per-alias settings across; hand-added directives the sheet has
    /// no field for are read out first and re-appended so a save can't drop them.
    ///
    /// Only hosts in the managed file are editable — a host from the user's
    /// hand-maintained `~/.ssh/config` is never rewritten (the menu hides Edit for
    /// it, and this re-checks rather than trusting the caller).
    func editServer(alias: String) {
        let managed = (try? String(
            contentsOfFile: AddServer.managedHostsPath, encoding: .utf8)) ?? ""
        guard let existing = AddServer.entry(forAlias: alias, in: managed) else {
            presentError(
                "“\(alias)” isn’t managed by MuxMaestro — it comes from your "
                    + "~/.ssh/config. Edit that file directly.")
            return
        }
        let extras = AddServer.preservedDirectives(forAlias: alias, in: managed)
        let host = Host(name: alias, sshAlias: alias)
        guard let prompt = AddServerPrompt.run(
            window: window, editing: existing,
            useMosh: Settings.useMosh(host: host),
            watch: Settings.watch(host: host))
        else { return }

        let entry = prompt.entry
        do {
            try AddServer.save(
                entry: entry,
                managedHostsPath: AddServer.managedHostsPath,
                configPath: AddServer.sshConfigPath,
                replacingAlias: alias,
                preserving: extras)
        } catch {
            presentError("Couldn’t save the server: \(error.localizedDescription)")
            return
        }
        // Move mosh/watch/order to the new alias before writing the sheet's own
        // choices, so the migration can't clobber what the user just picked.
        AddServer.migrateConnectionSettings(from: alias, to: entry.name)
        AddServer.applyConnectionSettings(
            alias: entry.name, useMosh: prompt.useMosh, watch: prompt.watch)
        sidebarVC?.refresh()
        presentInfo("Saved “\(entry.name)”.")
    }

    /// The server was added + verified, but it chose mosh and `mosh-server` isn't
    /// installed there. Offer to provision it now (ssh attach still works
    /// without it). Confirmed here, so it runs the install directly.
    private func offerInstallMosh(host: Host) {
        let alert = NSAlert()
        alert.messageText = "Added “\(host.name)”, but mosh-server isn’t installed."
        alert.informativeText = "You chose mosh for this server. Install mosh-server "
            + "now so the roaming terminal attach works? (ssh attach works without it.)"
        alert.addButton(withTitle: "Install mosh…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            runInstallMosh(host: host)
        }
    }

    /// The test-on-save probe failed. The entry is already saved (needed so ssh
    /// could resolve the alias for the probe); let the user keep it anyway,
    /// remove it, or — when we have a public key path to work with — open a
    /// `ssh-copy-id` command in Terminal so they can install it on the remote
    /// themselves. MuxMaestro never sees the password that step needs: the
    /// command runs in the user's own Terminal window, not in this process.
    private func handleFailedServerTest(
        entry: ServerEntry, result: AddServer.SaveResult
    ) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t verify “\(entry.name)”."
        let copyCommand = AddServer.sshCopyIdCommand(for: entry)
        alert.informativeText = "The SSH test connection failed (host unreachable, "
            + "auth declined, or tmux/login issue). The entry is saved — keep it, "
            + "or remove it."
            + (copyCommand != nil
                ? " If auth was declined, your public key likely isn’t installed on "
                    + "the remote yet — “Copy Key to Server…” opens the command that "
                    + "installs it."
                : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Anyway")
        alert.addButton(withTitle: "Remove")
        if copyCommand != nil { alert.addButton(withTitle: "Copy Key to Server…") }
        let remove = { [weak self] in
            Self.driverQueue.async {
                let existing = (try? String(
                    contentsOfFile: result.managedHostsPath, encoding: .utf8)) ?? ""
                let cleaned = AddServer.removingHostBlock(
                    alias: entry.name, from: existing)
                try? cleaned.write(
                    toFile: result.managedHostsPath, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { [weak self] in self?.sidebarVC?.refresh() }
            }
        }
        let copyKey = { [weak self] in
            guard let copyCommand else { return }
            self?.openInTerminal(command: copyCommand, host: entry.name)
        }
        if let window {
            alert.beginSheetModal(for: window) { resp in
                switch resp {
                case .alertSecondButtonReturn: remove()
                case .alertThirdButtonReturn: copyKey()
                default: break
                }
            }
        } else {
            switch alert.runModal() {
            case .alertSecondButtonReturn: remove()
            case .alertThirdButtonReturn: copyKey()
            default: break
            }
        }
    }

    /// Opens `command` in a new Terminal.app window via a throwaway `.command`
    /// script — NOT by piping the command through this process — so a password
    /// prompt (`ssh-copy-id` falls back to password auth to install the key)
    /// happens in the user's own Terminal, never inside MuxMaestro. Mirrors the
    /// "never writes a secret" rule the rest of the Add Server flow follows:
    /// MuxMaestro only ever hands over a command, never a credential.
    private func openInTerminal(command: String, host: String) {
        let script = """
            #!/bin/bash
            echo "Installing your SSH key on \u{201C}\(host)\u{201D}…"
            echo
            \(command)
            echo
            echo "Press Return to close this window."
            read -r
            """
        let name = "muxmaestro-ssh-copy-id-\(Int(Date().timeIntervalSince1970))-"
            + "\(Int.random(in: 1000...9999)).command"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch {
            presentError("Couldn’t open Terminal: \(error.localizedDescription)")
        }
    }

    @objc private func actionRenameSelected() {
        guard let name = sidebarVC?.selectedSessionName,
              let service = sidebarVC?.selectedService else { return }
        promptRename(session: name, service: service)
    }

    private func promptRename(session: String, service: TmuxService) {
        guard let new = TextPrompt.run(
            window: window, title: "Rename Session",
            message: "Rename “\(session)” to:", defaultValue: session)
        else { return }
        // Rename off-main (shell-out); mutate attachedSession + refresh on main.
        let host = service.host
        service.driverQueue.async {
            let renamed = service.renameSession(from: session, to: new)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let renamed {
                    if self.attachedSession == session { self.attachedSession = renamed }
                    self.sidebarVC?.selectSessionWhenReady(renamed, host: host)
                } else {
                    self.presentError("Couldn’t rename the session.")
                }
            }
        }
    }

    @objc private func actionKillSelected() {
        guard let name = sidebarVC?.selectedSessionName,
              let service = sidebarVC?.selectedService else { return }
        confirmKill(session: name, service: service)
    }

    /// Kill a session, behind a confirm unless `source` is the sidebar's
    /// right-click menu (see `CloseWindowPrompt.needsConfirm`).
    private func confirmKill(
        session: String, service: TmuxService, source: CloseWindowPrompt.Source = .keyboard
    ) {
        let cwd = sidebarVC?.cachedSessions(host: service.host)
            .first { $0.name == session }?.cwd ?? ""
        let worktree = worktreeToCleanUp(cwd: cwd, host: service.host) { s, _, _ in s == session }
        guard CloseWindowPrompt.needsConfirm(source) else {
            // No sheet, so no checkbox: keep its default (on).
            killSession(session, service: service, cleanUp: worktree)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Kill session “\(session)”?"
        alert.informativeText = "This ends the tmux session and any processes running in it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        if worktree != nil { Self.addWorktreeCleanupCheckbox(to: alert) }
        let go = { [weak self] in
            let cleanUp = alert.suppressionButton?.state == .on ? worktree : nil
            self?.killSession(session, service: service, cleanUp: cleanUp)
        }
        if let window {
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn { go() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            go()
        }
    }

    /// The kill itself, once confirmed (or not needing to be). `cleanUp` is the
    /// worktree to hand to spindown after a successful kill.
    private func killSession(_ session: String, service: TmuxService, cleanUp: String?) {
        // Kill off-main (shell-out); mutate attachedSession + refresh on main.
        service.driverQueue.async { [weak self] in
            let killed = service.killSession(name: session)
            DispatchQueue.main.async {
                guard let self else { return }
                if killed, let cleanUp { self.cleanUpWorktree(cleanUp) }
                if killed {
                    // Drop the cached surface so recreating a same-named session
                    // spawns a fresh client instead of reusing this dead one.
                    self.terminalVC?.evictSurface(
                        command: service.attachCommand(
                            session: session,
                            useMosh: Settings.useMosh(host: service.host)))
                    self.sessionMRU.removeAll {
                        $0 == SessionRef(name: session, host: service.host)
                    }
                    self.windowMRU.removeAll {
                        $0.session == session && $0.host == service.host
                    }
                    // If we just killed the attached session, evicting left the
                    // pane blank — fall back to the most-recent remaining session.
                    let wasAttached =
                        self.attachedSession == session
                        && self.attachedService?.host == service.host
                    if wasAttached {
                        self.attachedSession = nil
                        self.attachedService = nil
                        if let next = self.sessionMRU.first {
                            self.sidebarDidSelectSession(
                                next.name, service: self.registry.service(for: next.host))
                            self.sidebarVC?.selectSession(next.name, host: next.host)
                        }
                    }
                    self.sidebarVC?.refresh()
                } else {
                    self.presentError("Couldn’t kill the session.")
                }
            }
        }
    }

    /// ⌘W — close what the human is working in. If a floating palette/panel is
    /// key, close that (standard). Otherwise close the focused **pane** of the
    /// attached tmux session's active window, falling back to the window itself
    /// when the pane is the only one. The attached terminal redraws the surviving
    /// panes; the sidebar updates on the next poll.
    ///
    /// It used to always kill the window: ⌘W typed inside one pane of a
    /// three-pane window took all three with it. `paneFirst` is what asks for the
    /// narrower target; the sidebar's explicit Archive Window items don't.
    @objc private func actionCloseWindow() {
        if let panel = NSApp.keyWindow as? NSPanel, panel.isFloatingPanel {
            panel.close()
            return
        }
        guard let session = attachedSession, let service = attachedService,
              !session.hasPrefix("herdr:") else { return }
        confirmCloseWindow(session: session, window: nil, service: service, paneFirst: true)
    }

    /// Gate a `kill-pane`/`kill-window` behind a confirm that names the exact
    /// target (⌘W and both sidebar Archive Window items land here; the sidebar
    /// items skip the sheet). Confirm is the default button, so ⌘W → Return still
    /// closes in one beat; Escape cancels.
    ///
    /// `window` nil means "the session's active window" (⌘W). The cached sidebar
    /// tree resolves that to a concrete index, and the kill then targets that
    /// exact index — so we never kill a *different* window that became active
    /// while the sheet was up. Only when the tree hasn't loaded the session do we
    /// fall back to tmux's own active-window resolution.
    ///
    /// `paneFirst` is ⌘W's "close the smallest thing" intent. The pane-vs-window
    /// choice itself is `CloseWindowPrompt.action(for:)`, so it is decided and
    /// tested away from AppKit; here we only pick which target we hand it. The
    /// named pane id is killed by id for the same reason the window index is:
    /// what the sheet named is what dies, even if focus moved while it was up.
    ///
    /// `source` `.contextMenu`, `.mergedTrash` and `.phone` skip the sheet (see
    /// `CloseWindowPrompt.needsConfirm`). `completion` is for those: it comes on
    /// the main thread with whether the kill ran, and never after a sheet.
    /// `.phone` also shows no alert on failure: its caller tells the phone.
    private func confirmCloseWindow(
        session: String, window: Int?, service: TmuxService, paneFirst: Bool = false,
        source: CloseWindowPrompt.Source = .keyboard, completion: ((Bool) -> Void)? = nil
    ) {
        let target = closeTarget(session: session, window: window, service: service)
        let action = paneFirst ? CloseWindowPrompt.action(for: target) : .window
        let index = target.index
        let worktree: String? = index.flatMap { index in
            guard let tree = sidebarVC?.windowForConfirm(
                host: service.host, session: session, index: index)?.window else { return nil }
            if case .pane(let id) = action {
                return worktreeToCleanUp(
                    cwd: tree.panes.first { $0.id == id }?.path ?? "", host: service.host
                ) { _, _, pane in pane.id == id }
            }
            return worktreeToCleanUp(cwd: tree.cwd, host: service.host) { s, w, _ in
                s == session && w == index
            }
        }
        let failure = action == .window
            ? "Couldn’t archive the window." : "Couldn’t close the pane."
        // Written by `perform` on the driver queue, read by `archived` on main
        // once it has returned.
        var archivedWindow: ArchivedWindow?
        let perform = {
            if let index, case .pane(let pane) = action {
                return service.killPane(session: session, window: index, pane: pane)
            }
            let result = service.archiveWindow(session: session, window: index)
            archivedWindow = result.archived
            return result.killed
        }
        // An archive keeps its worktree until undo is no longer offered, so the
        // cleanup the sheet asked for goes with the archive instead of running now.
        let archived: ((String?) -> Void)? = action == .window ? { [weak self] cleanUp in
            self?.didArchive(archivedWindow, service: service, worktree: cleanUp)
        } : nil
        guard CloseWindowPrompt.needsConfirm(source) else {
            performDestructive(
                failure: source == .phone ? nil : failure, on: service, cleanUp: worktree,
                perform: perform, onSuccess: archived, completion: completion)
            return
        }
        confirmDestructive(
            title: CloseWindowPrompt.title(target, action),
            info: CloseWindowPrompt.info(target, action),
            confirmTitle: CloseWindowPrompt.confirmTitle(action),
            failure: failure,
            on: service,
            worktree: worktree,
            perform: perform,
            onSuccess: archived)
    }

    /// Archive the window that holds `thread`, for the phone: the sidebar's
    /// Archive Window, so the Mac's Edit > Undo brings it back. The window is
    /// found by the thread's pane in the tree as it is now: tmux may have
    /// renumbered the windows since the phone's tree was read. `done` comes on
    /// the main thread, false when the pane has gone or the kill failed.
    private func archiveWindowFromPhone(_ thread: MobileThread, done: @escaping (Bool) -> Void) {
        guard let ref = sidebarVC?.windowRef(paneID: thread.pane, host: thread.host) else {
            return done(false)
        }
        confirmCloseWindow(
            session: ref.session, window: ref.window, service: registry.service(for: ref.host),
            source: .phone, completion: done)
    }

    /// Read a close target out of the cached sidebar tree (`window` nil ⇒ the
    /// session's active window). Shared by the confirm sheet and by the ⌘W menu
    /// item's title, so the label and the sheet can never name different things.
    private func closeTarget(
        session: String, window: Int?, service: TmuxService
    ) -> CloseWindowPrompt.Target {
        let found = sidebarVC?.windowForConfirm(
            host: service.host, session: session, index: window)
        return CloseWindowPrompt.Target(
            session: session,
            index: found?.window.index ?? window,
            name: found?.window.name ?? "",
            attention: found?.window.attention ?? .unknown,
            isLastWindow: found?.isLast ?? false,
            panes: (found?.window.panes ?? []).map {
                CloseWindowPrompt.Pane(id: $0.id, active: $0.active, attention: $0.attention)
            })
    }

    // MARK: - Window / pane actions (M9)

    /// The linked worktree a close would leave with no pane in it — what the close
    /// confirm offers to clean up. `closing(session, window, pane)` says which
    /// panes the close takes. nil (no checkbox) off the local host, when spindown
    /// isn't installed, or for a main checkout.
    private func worktreeToCleanUp(
        cwd: String, host: Host, closing: (String, Int, TmuxPane) -> Bool
    ) -> String? {
        guard host.isLocal, let sidebarVC, FileTransfer.python3Path != nil,
              FileManager.default.fileExists(atPath: Worktrees.spindownScriptPath)
        else { return nil }
        let survivors = sidebarVC.cachedSessions(host: host).flatMap { s in
            s.windows.flatMap { w in
                w.panes.filter { !closing(s.name, w.index, $0) }.map(\.path)
            }
        }
        return Worktrees.cleanupOffer(
            cwd: cwd, survivorCwds: survivors, dotGit: Worktrees.readDotGit)
    }

    private static func addWorktreeCleanupCheckbox(to alert: NSAlert) {
        alert.showsSuppressionButton = true
        guard let box = alert.suppressionButton else { return }
        box.title = "Also clean up worktree"
        box.state = .on
        box.toolTip = "Removes the worktree and its local branch unless either holds unpushed work"
    }

    /// Hand a just-emptied worktree to spindown, which owns every safety gate, then
    /// toast what it did. A utility queue, not the host's driver queue: a run can
    /// take minutes (it fetches, and may stop a Supabase stack), and tmux actions
    /// must not queue behind it.
    private func cleanUpWorktree(_ worktree: String) {
        guard let python = FileTransfer.python3Path else { return }
        let argv = Worktrees.spindownArgv(
            python: python, script: Worktrees.spindownScriptPath, worktree: worktree)
        // spindown runs `treehouse` by bare name, and it lives in ~/go/bin — not on
        // the child PATH the runner builds.
        let path = NSHomeDirectory() + "/go/bin:"
            + (ProcessCommandRunner.childEnvironment["PATH"] ?? "")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = ProcessCommandRunner(timeout: 900).run("/usr/bin/env", ["PATH=\(path)"] + argv)
            let result = Worktrees.parseSpindown(json: out)
            let toast = Worktrees.cleanupToast(result, worktree: worktree)
            DispatchQueue.main.async {
                guard let self, let window = self.window else { return }
                if case .cleaned? = result {
                    self.sidebarVC?.forgetWorktree(path: worktree)
                } else {
                    self.sidebarVC?.refresh()
                }
                self.toast.show(over: window, glyph: "⑂", title: toast.title, text: toast.body)
            }
        }
    }

    /// Run a destructive tmux mutation behind a confirmation sheet. `perform`
    /// returns whether the mutation succeeded; it runs off-main and the result
    /// drives a tree refresh or an error on main. Mirrors `confirmKill`.
    ///
    /// `worktree` adds the "Also clean up worktree" checkbox; when it is left on
    /// and the mutation succeeds, that worktree goes to spindown.
    private func confirmDestructive(
        title: String, info: String, confirmTitle: String,
        failure: String, on service: TmuxService? = nil, worktree: String? = nil,
        perform: @escaping () -> Bool, onSuccess: ((String?) -> Void)? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
        // Confirm is the default button (Return fires it), Cancel takes Escape —
        // stated explicitly rather than relying on NSAlert's implicit defaulting,
        // because ⌘W → Return is the whole point of the close-window confirm.
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.keyEquivalent = "\r"
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        if worktree != nil { Self.addWorktreeCleanupCheckbox(to: alert) }
        let go = { [weak self] in
            let cleanUp = alert.suppressionButton?.state == .on ? worktree : nil
            self?.performDestructive(
                failure: failure, on: service, cleanUp: cleanUp, perform: perform,
                onSuccess: onSuccess)
        }
        if let window {
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn { go() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            go()
        }
    }

    /// Run a destructive tmux mutation now — what a confirm sheet does once
    /// accepted, and what a sidebar right-click does with no sheet. `perform` runs
    /// off-main; success refreshes the tree and hands `cleanUp` to spindown,
    /// failure shows `failure` (nil shows nothing). With `onSuccess`, the worktree
    /// goes to it instead: an archive decides when its worktree is cleaned up.
    /// `completion` comes on the main thread with whether `perform` succeeded.
    private func performDestructive(
        failure: String?, on service: TmuxService?, cleanUp: String?,
        perform: @escaping () -> Bool, onSuccess: ((String?) -> Void)? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        // Route to the target host's serial queue so a wedged remote can't block
        // another host; herdr and host-agnostic ops fall back to the global queue.
        let queue = service?.driverQueue ?? Self.driverQueue
        queue.async { [weak self] in
            let ok = perform()
            DispatchQueue.main.async {
                defer { completion?(ok) }
                guard let self else { return }
                if ok { self.sidebarVC?.refresh() } else if let failure { self.presentError(failure) }
                guard ok else { return }
                if let onSuccess {
                    onSuccess(cleanUp)
                } else if let cleanUp {
                    self.cleanUpWorktree(cleanUp)
                }
            }
        }
    }

    /// Run a non-destructive tmux mutation off-main, refreshing on success and
    /// surfacing `failure` on error.
    private func performMutation(
        failure: String, on service: TmuxService? = nil, _ perform: @escaping () -> Bool
    ) {
        let queue = service?.driverQueue ?? Self.driverQueue
        queue.async { [weak self] in
            let ok = perform()
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { self.sidebarVC?.refresh() } else { self.presentError(failure) }
            }
        }
    }

    private func promptRenameWindow(session: String, window: Int, service: TmuxService) {
        guard let new = TextPrompt.run(
            window: self.window,
            title: "Rename Window",
            message: "Rename window \(window) in “\(session)” to:", defaultValue: "")
        else { return }
        performMutation(failure: "Couldn’t rename the window.", on: service) {
            service.renameWindow(session: session, window: window, to: new) != nil
        }
    }

    /// Create a window in `session` and go to it. Anything you just made should be
    /// the thing you are looking at and typing into, so this attaches the session
    /// (a no-op when it is already attached), selects the new window in tmux,
    /// highlights its row once the refresh brings it in, and moves keyboard focus
    /// to the terminal.
    private func newWindow(session: String, service: TmuxService) {
        service.driverQueue.async { [weak self] in
            // Open in the session's current working directory (its active pane's
            // path); tmux's new-window otherwise uses the session start dir (often
            // ~), not where the user is working. Resolved here, off-main.
            let created = service.newWindow(session: session, cwd: service.sessionCwd(session))
            DispatchQueue.main.async {
                guard let self else { return }
                guard let created else {
                    self.presentError("Couldn’t create the window.")
                    return
                }
                self.focusNew(session: session, window: created, pane: nil, service: service)
            }
        }
    }

    /// Put the user in a just-created window or pane (or the one a link points
    /// at): attach its session, select
    /// it inside tmux, highlight its sidebar row when the tree catches up, and
    /// hand keyboard focus to the terminal. `pane` nil means "a whole new window".
    private func focusNew(session: String, window: Int, pane: String?, service: TmuxService) {
        sidebarDidSelectSession(session, service: service)
        if let pane {
            // The pane's window is where you now are — head of the ⌘` stack. The
            // poll would notice within a tick anyway; recording it here keeps the
            // stack exact from the moment the pane exists.
            noteWindowVisited(WindowRef(session: session, window: window, host: service.host))
            service.driverQueue.async {
                // Not zoomed: a split you just made is meant to sit beside its
                // sibling, not cover it.
                service.selectPane(session: session, window: window, pane: pane, zoom: false)
            }
        } else {
            sidebarDidSelectWindow(session: session, window: window, service: service)
        }
        sidebarVC?.selectWindowWhenReady(window, session: session, host: service.host)
        detailVC?.focusTerminal()
    }

    private func confirmKillPane(
        session: String, window: Int, pane: String, service: TmuxService,
        source: CloseWindowPrompt.Source
    ) {
        let cwd = sidebarVC?.windowForConfirm(host: service.host, session: session, index: window)?
            .window.panes.first { $0.id == pane }?.path ?? ""
        let worktree = worktreeToCleanUp(cwd: cwd, host: service.host) { _, _, p in p.id == pane }
        let failure = "Couldn’t kill the pane."
        let perform = { service.killPane(session: session, window: window, pane: pane) }
        guard CloseWindowPrompt.needsConfirm(source) else {
            performDestructive(failure: failure, on: service, cleanUp: worktree, perform: perform)
            return
        }
        confirmDestructive(
            title: "Kill pane \(pane) in “\(session)”?",
            info: "This closes the pane and the process running in it.",
            confirmTitle: "Kill Pane",
            failure: failure,
            on: service,
            worktree: worktree,
            perform: perform)
    }

    private func splitPane(
        session: String, window: Int, pane: String, vertical: Bool, service: TmuxService
    ) {
        createPane(on: service, session: session, failure: "Couldn’t split the pane.") {
            service.splitPane(session: session, window: window, pane: pane, vertical: vertical)
        }
    }

    /// Run a split off-main and go to the pane it created (or report the failure).
    /// Shared by every split entry point — ⌘D / ⌘⇧D, ⌘T, and the sidebar rows —
    /// so a new pane always ends up focused, however it was made.
    private func createPane(
        on service: TmuxService, session: String? = nil, failure: String,
        _ perform: @escaping () -> TmuxCommands.CreatedPane?
    ) {
        service.driverQueue.async { [weak self] in
            let created = perform()
            DispatchQueue.main.async {
                guard let self else { return }
                guard let created else { self.presentError(failure); return }
                guard let session = session ?? self.sidebarVC?.selectedSessionName
                        ?? self.attachedSession else {
                    self.sidebarVC?.refresh()
                    return
                }
                self.focusNew(
                    session: session, window: created.window, pane: created.pane,
                    service: service)
            }
        }
    }

    // MARK: - Move / merge (sidebar reorganisation)
    //
    // None of these confirm except the merge. A move is reorganisation, not
    // destruction: nothing is closed and every one of them is undone by moving the
    // row back. The merge is the exception because tmux ends a session once its
    // last window leaves, so the source row vanishes as a side effect.

    private func moveWindow(
        session: String, window: Int, to destination: String, service: TmuxService
    ) {
        performMutation(failure: "Couldn’t move the window.", on: service) {
            service.moveWindow(session: session, window: window, toSession: destination)
        }
    }

    private func moveWindowToNewSession(session: String, window: Int, service: TmuxService) {
        guard let name = TextPrompt.run(
            window: self.window,
            title: "Move to New Session",
            message: "Move window \(window) out of “\(session)” into a new session named:",
            defaultValue: "")
        else { return }
        performMutation(failure: "Couldn’t move the window to a new session.", on: service) {
            service.moveWindowToNewSession(
                session: session, window: window, name: name) != nil
        }
    }

    private func movePane(
        session: String, window: Int, pane: String, toSession destination: String,
        service: TmuxService
    ) {
        performMutation(failure: "Couldn’t move the pane.", on: service) {
            service.movePane(
                session: session, window: window, pane: pane, toSession: destination)
        }
    }

    private func movePane(
        session: String, window: Int, pane: String, toWindow destination: Int,
        service: TmuxService
    ) {
        performMutation(failure: "Couldn’t move the pane.", on: service) {
            service.movePane(
                session: session, window: window, pane: pane, toWindow: destination)
        }
    }

    private func movePaneToNewSession(
        session: String, window: Int, pane: String, service: TmuxService
    ) {
        guard let name = TextPrompt.run(
            window: self.window,
            title: "Move to New Session",
            message: "Move pane \(pane) out of “\(session)” into a new session named:",
            defaultValue: "")
        else { return }
        performMutation(failure: "Couldn’t move the pane to a new session.", on: service) {
            service.movePaneToNewSession(
                session: session, window: window, pane: pane, name: name) != nil
        }
    }

    /// The one confirmed move: merging leaves the source session with no windows,
    /// and tmux ends a session at that point, so the row the user right-clicked
    /// disappears. Nothing inside it closes — say so, because "the session is
    /// gone" otherwise reads as a kill.
    private func confirmMergeSession(
        session: String, windows: [Int], into destination: String, service: TmuxService
    ) {
        let count = windows.count
        confirmDestructive(
            title: "Merge “\(session)” into “\(destination)”?",
            info: "\(count) window\(count == 1 ? "" : "s") move to “\(destination)”. "
                + "Nothing closes, but tmux ends a session when its last window leaves, "
                + "so “\(session)” disappears from the sidebar.",
            confirmTitle: "Merge",
            failure: "Couldn’t merge the session.",
            on: service,
            perform: { service.mergeSession(session, windows: windows, into: destination) })
    }

    // MARK: - File drop (M11)

    /// Drop a local file onto a session: copy to its cwd + paste the path (no
    /// auto-run). Runs off-main. Success is silent — the pasted path is already
    /// visible in the pane, so no confirmation is shown (local or remote); only a
    /// real failure surfaces (rare).
    private func dropFile(
        localPath: String, session: String, service: TmuxService, trailingSpace: Bool = false
    ) {
        service.driverQueue.async { [weak self] in
            let dest = service.dropFileToSession(
                session: session, localFile: localPath, trailingSpace: trailingSpace)
            guard dest == nil else { return }
            DispatchQueue.main.async {
                self?.presentError("Couldn’t send the file to “\(session)”.")
            }
        }
    }

    /// A link ⌘-clicked in the main terminal. Paths live on the attached session's
    /// host; a relative one resolves against that session's cwd, fetched off-main.
    private func terminalOpenLink(_ url: String) -> Bool {
        guard let session = attachedSession, let service = attachedService,
              !session.hasPrefix("herdr:") else {
            return openTerminalLink(url, cwd: nil, host: .local)
        }
        guard case .unresolved = LinkRoute.route(url, cwd: nil, home: NSHomeDirectory()) else {
            return openTerminalLink(url, cwd: nil, host: service.host)
        }
        service.driverQueue.async { [weak self] in
            let cwd = service.sessionCwd(session)
            DispatchQueue.main.async {
                _ = self?.openTerminalLink(url, cwd: cwd, host: service.host)
            }
        }
        return true
    }

    /// Open a ⌘-clicked link per `LinkRoute`. Files go to the default editor
    /// until the Artifacts panel can preview them.
    private func openTerminalLink(_ url: String, cwd: String?, host: Host) -> Bool {
        let home = host.isLocal ? NSHomeDirectory() : "~"
        switch LinkRoute.route(url, cwd: cwd, home: home) {
        case .browser(let u), .system(let u):
            NSWorkspace.shared.open(u)
        case .thread(let link):
            openLink(link)
        case .badLink(let text):
            presentError(ThreadLinks.LinkError.malformed(text).message)
        case .file(let path, let line):
            // `open(file:)` reports a remote host its editor cannot reach.
            if let editor = defaultEditor {
                open(file: path, line: line, host: host, in: editor)
            } else if host.isLocal {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                presentError("No editor installed to open \(path)")
            }
        case .unresolved(let text):
            guard !text.isEmpty else { return false }
            presentError("Couldn’t find \(text)")
        }
        return true
    }

    /// A file (or files) dropped onto the terminal surface. Route it through the
    /// same session-aware transfer the sidebar uses — copy into the attached
    /// session's cwd (cp local / scp remote), then paste the destination path —
    /// so a REMOTE session gets the real bytes instead of a dead local path.
    /// Returns whether the drop was handled; false lets the surface fall back to
    /// typing the local path (no attached tmux session — herdr / plain shell).
    private func terminalDropFiles(_ urls: [URL]) -> Bool {
        guard let session = attachedSession, let service = attachedService,
              !session.hasPrefix("herdr:") else { return false }
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return false }
        for url in files {
            dropFile(localPath: url.path, session: session, service: service, trailingSpace: true)
        }
        return true
    }

    // MARK: - Diff pane (M14)

    /// Toolbar/menu "Show Diff" — compute the selected session's working-directory
    /// diff and reveal the Diff pane with it.
    @objc private func actionShowDiff() {
        refreshDiff(reveal: true)
    }

    /// Header "Diff" button — open/close the diff side panel; populate it for the
    /// current selection when opening.
    @objc private func actionToggleDiff() {
        guard let shown = detailVC?.toggleDiff() else { return }
        if shown { refreshDiff(reveal: false) }
    }

    // MARK: - Tree side panel

    /// Toolbar/menu "Show Tree" — open/close the Tree side panel (sharing the
    /// detail slot with the Diff pane); populate it for the current selection when
    /// it opens onto the Tree.
    @objc private func actionToggleTree() {
        guard let shown = detailVC?.toggle(.tree) else { return }
        if shown { openTreePanel(focusSearch: false) }
    }

    // MARK: - Artifacts side panel

    /// Toolbar/menu "Artifacts" — open/close the Artifacts side panel and fill it
    /// for the current selection when it opens.
    @objc private func actionToggleArtifacts() {
        guard let shown = detailVC?.toggle(.artifacts) else { return }
        if shown { refreshArtifacts() }
    }

    /// Re-list what the selected pane's agent made, plus the servers it runs
    /// and the links it gave. Runs on every selection change and every poll
    /// while the panel is on screen. The transcript read happens off-main and
    /// parses only lines appended since the last read; the panel ignores a
    /// render that matches what it already shows.
    func refreshArtifacts() {
        guard let vc = artifactsVC, detailVC?.isShown(.artifacts) == true else { return }
        guard let (pane, host) = sidebarVC?.selectedAgentPane else { vc.render(.noSelection); return }
        guard host.isLocal else { vc.render(.remote); return }
        let runningSet = sidebarVC?.runningSet(forPane: pane, host: host) ?? .unknown
        let running = runningSet.resources.compactMap { r -> ArtifactRunningServer? in
            guard case .server(let port) = r.kind else { return nil }
            return ArtifactRunningServer(port: port, url: r.url)
        }
        let claude = pane.claudeSessionId, codex = pane.codexSessionId
        guard claude != nil || codex != nil else {
            // No thread to read, but what the pane runs is still worth listing.
            let web = ArtifactScanner.web(urls: [:], running: running, runningKnown: runningSet.known)
            vc.render(web.servers.isEmpty ? .noThread : .list(ArtifactsContent(servers: web.servers)))
            return
        }
        let reader = artifactReader
        artifactQueue.async { [weak self] in
            let fm = FileManager.default
            let content = reader.transcript(claudeSessionId: claude, codexSessionId: codex)
                .flatMap { reader.mentions(transcript: $0) }
                .map { mentions -> ArtifactsContent in
                    let web = ArtifactScanner.web(
                        urls: mentions.urls, running: running, runningKnown: runningSet.known)
                    return ArtifactsContent(
                        artifacts: ArtifactScanner.resolve(
                            mentions, fileExists: { fm.fileExists(atPath: $0) },
                            mtime: { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }),
                        servers: web.servers, links: web.links)
                }
            DispatchQueue.main.async {
                guard let self, let now = self.sidebarVC?.selectedAgentPane,
                      now.pane.id == pane.id, now.host == host else { return }
                vc.render(content.map { .list($0) } ?? .noThread)
            }
        }
    }

    // MARK: - Running drawer

    /// Menu "Show Running" — open/close the drawer over the terminal, the same
    /// as clicking its pill.
    @objc private func actionToggleRunning() {
        guard let drawer = runningDrawer else { return }
        drawer.setExpanded(!drawer.isExpanded)
    }

    /// The drawer's current content, recomputed from the sidebar's caches. Cheap —
    /// the scans themselves run on their own cadence, off this call.
    private var runningGroups: [RunningGroup] { sidebarVC?.runningGroupsForSelection() ?? [] }

    /// Re-render for the current selection: the pill's count and the list. It
    /// never opens itself — the count is the signal.
    func refreshRunning() {
        runningDrawer?.render(runningGroups)
        refreshHandoffCommands()
    }

    /// Resolve the agent mapped to the pane currently shown in the attached
    /// session. The sidebar cache already carries both agent IDs, so this does
    /// not add a tmux or SSH round-trip just to show the button.
    private func currentHandoffTarget() -> HandoffTarget? {
        guard let session = attachedSession, let service = attachedService,
              let panes = sidebarVC?.activeWindowPanes(host: service.host, session: session),
              let pane = panes.first(where: \.active) ?? panes.first else { return nil }
        if let id = pane.claudeSessionId, !id.isEmpty {
            return HandoffTarget(
                service: service, tmuxSession: session, pane: pane.id,
                agent: .claude, sessionId: id)
        }
        if let id = pane.codexSessionId, !id.isEmpty {
            return HandoffTarget(
                service: service, tmuxSession: session, pane: pane.id,
                agent: .codex, sessionId: id)
        }
        return nil
    }

    private func refreshHandoffCommands() {
        detailVC?.handoffCommands.setAvailable(currentHandoffTarget() != nil)
    }

    private func loadHandoffText(
        for target: HandoffTarget, completion: @escaping (String?) -> Void
    ) {
        target.service.driverQueue.async { [weak self] in
            let transcript = target.service.handoffTranscript(
                agent: target.agent, sessionId: target.sessionId)
            let text = transcript.flatMap {
                AgentHandoff.makeText(
                    agent: target.agent, sessionId: target.sessionId,
                    tmuxSession: target.tmuxSession, pane: target.pane, transcript: $0)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                completion(text)
            }
        }
    }

    private func copyHandoffContext() {
        guard let target = currentHandoffTarget() else {
            detailVC?.handoffCommands.flashStatus("No agent")
            return
        }
        loadHandoffText(for: target) { [weak self] text in
            guard let self else { return }
            guard let text else {
                self.presentError("Couldn’t read the current agent transcript.")
                return
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                self.presentError("Couldn’t copy the handoff context.")
                return
            }
            self.detailVC?.handoffCommands.flashStatus("Copied")
        }
    }

    /// `newWindow` keeps the source agent running and starts the fresh one in a
    /// new window beside it; otherwise the source pane's conversation is reset.
    private func performHandoff(newWindow: Bool) {
        guard !handoffInFlight else { return }
        guard let target = currentHandoffTarget() else {
            detailVC?.handoffCommands.flashStatus("No agent")
            return
        }
        handoffInFlight = true
        detailVC?.handoffCommands.flashStatus("Preparing")
        loadHandoffText(for: target) { [weak self] text in
            guard let self else { return }
            guard let text else {
                self.handoffInFlight = false
                self.presentError("Couldn’t read the current agent transcript.")
                return
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                self.handoffInFlight = false
                self.presentError("Couldn’t copy the handoff context.")
                return
            }
            guard !newWindow else {
                target.service.performHandoffInNewWindow(
                    session: target.tmuxSession, source: target.pane, agent: target.agent,
                    prompt: text) { [weak self] created in
                        guard let self else { return }
                        self.handoffInFlight = false
                        guard let created else {
                            self.presentError(
                                "The context is copied, but Mux Maestro couldn’t start the new agent.")
                            return
                        }
                        self.focusNew(
                            session: target.tmuxSession, window: created.window, pane: nil,
                            service: target.service)
                    }
                return
            }
            target.service.performHandoff(
                target: target.pane, agent: target.agent, prompt: text) { [weak self] sent in
                    guard let self else { return }
                    self.handoffInFlight = false
                    if sent {
                        self.detailVC?.handoffCommands.flashStatus("Pasted")
                        self.detailVC?.focusTerminal()
                    } else {
                        self.presentError(
                            "The context is copied, but Mux Maestro couldn’t send it to the agent.")
                    }
                }
        }
    }

    /// Menu "Find in Repo…" (⌘⇧F) — reveal the Tree panel on its "This repo"
    /// scope and focus its search field, so search and the file tree are one
    /// surface (results filter the tree).
    @objc private func actionSearchRepo() {
        detailVC?.show(.tree)
        treeVC?.selectRepoScope()
        openTreePanel(focusSearch: true)
    }


    // MARK: - Find in Session (⌘F)

    /// Debounce for the per-keystroke search so fast typing coalesces into one
    /// tmux round-trip (matters for remote sessions).
    private var findDebounce: DispatchWorkItem?

    /// Menu "Find in Session" (⌘F) — search the attached tmux session's
    /// scrollback via copy-mode search, driven from a native find bar. tmux does
    /// the searching because the embedded surface only holds the visible screen
    /// (the history lives on the tmux server), it highlights matches in place,
    /// and it works unchanged for remote hosts.
    @objc private func actionFindInSession() {
        detailVC?.showFindBar()
    }

    /// A find-bar keystroke: debounce, then restart the search for the new
    /// needle and report the match count back to the bar.
    private func findNeedleChanged(_ needle: String) {
        findDebounce?.cancel()
        guard let session = attachedSession, let service = attachedService else { return }
        let work = DispatchWorkItem { [weak self] in
            let label = service.searchInPane(session: session, needle: needle)
            DispatchQueue.main.async { self?.detailVC?.findBar.setCount(label) }
        }
        findDebounce = work
        Self.driverQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// ⏎ / ⇧⏎ / the chevrons: step to the next match (up == older).
    private func findStep(up: Bool) {
        guard let session = attachedSession, let service = attachedService,
              !(detailVC?.findBar.needle.isEmpty ?? true) else { return }
        Self.driverQueue.async { [weak self] in
            let label = service.searchStep(session: session, up: up)
            DispatchQueue.main.async { self?.detailVC?.findBar.setCount(label) }
        }
    }

    /// Esc / ✕ / a session switch: hide the bar and end the search so the pane
    /// leaves copy-mode and resumes live output. Safe to call when not open.
    private func closeFindBar() {
        guard detailVC?.isFindBarShown == true else { return }
        findDebounce?.cancel()
        detailVC?.hideFindBar()
        detailVC?.findBar.setCount(nil)
        guard let session = attachedSession, let service = attachedService else { return }
        Self.driverQueue.async { service.endSearch(session: session) }
    }

    /// Toolbar/menu "Toggle Sidebar" (⌘B) — collapse/expand the whole right
    /// sidebar (Tree/Diff rail), VS Code / Zed style. Remembers what was shown.
    @objc private func actionToggleSidebar() {
        detailVC?.toggleSidebar()
    }

    /// Menu "Toggle Sidebar Layout" (⌃⌘L) — flip the right sidebar's Tree/Diff
    /// panes between columns (side by side) and rows (stacked).
    @objc private func actionToggleSidebarLayout() {
        detailVC?.toggleOrientation()
    }

    // MARK: - Manager rail (🤖)

    /// Toolbar 🤖 / menu "Toggle Manager" (⌘⇧M) — collapse/expand the far-right
    /// manager rail. First reveal boots the machinery + installs the terminal
    /// (whose attach-or-create command spawns the `mux-manager` claude session).
    @objc private func actionToggleManager() {
        guard let managerRailItem else { return }
        let showing = managerRailItem.isCollapsed
        managerRailItem.animator().isCollapsed = !showing
        Settings.setManagerRailShown(showing)
        if showing { startManagerMachinery() }
    }

    /// Menu "Restart Manager Agent" / the rail header's ↻ — kill the manager
    /// session and re-attach the rail terminal, which recreates it fresh.
    @objc private func actionRestartManager() {
        if managerRailItem?.isCollapsed == true {
            managerRailItem?.animator().isCollapsed = false
            Settings.setManagerRailShown(true)
        }
        startManagerMachinery()
        managerController?.restart { [weak self] command in
            // With the terminal behind the toggle there may be nothing to swap
            // yet; the controller recreated the session, so the next install
            // attaches to the fresh one.
            guard let command, let terminal = self?.managerRailVC?.terminal else { return }
            terminal.swap(command: command)
        }
    }

    /// Menu "Talk to Manager" (⌘⇧T) / the rail header's mic. One press starts a
    /// take, the next sends it, and a press during the spoken reply stops it.
    /// Opens the rail first, so the take's text has somewhere to show.
    @MainActor @objc private func actionTalk() {
        if managerRailItem?.isCollapsed == true {
            managerRailItem?.animator().isCollapsed = false
            Settings.setManagerRailShown(true)
        }
        startManagerMachinery()
        voice.press(target: VoiceTarget(acknowledgement: "Got it, checking. ") { [weak self] text, onReply, done in
            guard let self else { return done(nil) }
            self.runManagerTurn(text, onDelta: onReply) { done($0.readback) }
        })
    }

    /// One turn with the manager pane, drawn in the rail's chat. The input field
    /// and the voice take both come through here.
    private func runManagerTurn(
        _ text: String,
        requireIdle: Bool = false,
        onDelta: @escaping (String) -> Void = { _ in },
        completion: @escaping (ManagerTurnOutcome) -> Void = { _ in }
    ) {
        guard let manager = managerController else {
            completion(.unreachable("Maestro not running"))
            return
        }
        // The phone follows the same turn. A second call while one runs is
        // refused by the driver and must not end the first one's record.
        let tracked = !managerTurnRunning
        if tracked {
            managerTurnRunning = true
            mobileServer.managerTurnBegan(text)
        }
        managerRailVC?.beginTurn(text)
        manager.send(
            text,
            requireIdle: requireIdle,
            onDelta: { [weak self] delta in
                self?.managerRailVC?.appendReply(delta)
                if tracked { self?.mobileServer.managerTurnAppended(delta) }
                onDelta(delta)
            },
            completion: { [weak self] outcome in
                self?.managerRailVC?.endTurn(outcome)
                if tracked {
                    self?.managerTurnRunning = false
                    self?.mobileServer.managerTurnEnded()
                }
                completion(outcome)
            })
    }

    /// A turn the phone sent: the same turn as one typed into the rail, so it
    /// shows there too. The rail holds its input while a turn runs; the phone
    /// has no such hold, so a second turn is refused here, before it is drawn.
    private func runPhoneManagerTurn(
        _ text: String,
        queue: Bool,
        onDelta: @escaping (String) -> Void,
        completion: @escaping (ManagerTurnOutcome) -> Void
    ) {
        guard !managerTurnRunning else { return completion(.refused(MobileManager.busyMessage)) }
        // The phone cannot see the pane: its turn starts only from idle,
        // unless the human asked for a busy agent to hold the text.
        runManagerTurn(text, requireIdle: !queue, onDelta: onDelta, completion: completion)
    }

    /// The phone's manager home needs the manager running, rail shown or not.
    private func startManagerForPhoneIfNeeded() {
        guard Settings.phoneEnabled(), Settings.phoneCapability(.manager) else { return }
        startManagerMachinery()
    }

    /// Boot the manager machinery (home + store + session + timers). Idempotent.
    private func startManagerMachinery() {
        guard let managerController, managerController.startIfNeeded() else { return }
        installManagerTerminalIfNeeded()
    }

    /// Build the rail's terminal surface, but only once the rail is actually
    /// showing it: the chat talks to the `mux-manager` session through tmux, so a
    /// hidden terminal is a surface nobody is looking at.
    private func installManagerTerminalIfNeeded() {
        guard let managerRailVC, !managerRailVC.hasTerminal,
              managerRailVC.isTerminalShown,
              managerRailItem?.isCollapsed == false,
              let ghostty,
              let command = managerController?.attachCommand() else { return }
        let managerTerminal = TerminalViewController(
            ghostty: ghostty, command: command, useManagerTheme: true)
        managerTerminal.onOpenLink = { [weak self] url in
            self?.openTerminalLink(url, cwd: nil, host: .local) ?? false
        }
        managerRailVC.installTerminal(managerTerminal)
        // Installing a surface grabs first responder — hand focus back to the
        // main terminal; the manager is ambient, not the thing you type into.
        if let surface = terminalVC?.surfaceView {
            window?.makeFirstResponder(surface)
        }
    }

    /// Launch-time reattach: when a `mux-manager` session from a previous run is
    /// still alive, start the machinery even with the rail collapsed so the
    /// session snapshot + toasts keep flowing. Retries each sidebar refresh
    /// until the local tree has loaded once (only then is the session visible).
    private func managerAutoStartCheck() {
        guard !managerAutoStartChecked, let sidebarVC else { return }
        let managerAlive = sidebarVC.sessionAttention(ManagerHome.sessionName) != nil
        guard managerAlive || !sidebarVC.switcherSessions().isEmpty else { return }
        managerAutoStartChecked = true
        if managerAlive { startManagerMachinery() }
    }

    /// Show the manager's toast for a `mux notify` (newest of the batch + count).
    private func showManagerToast(_ notification: ManagerNotification, extra: Int) {
        guard let window else { return }
        toast.show(over: window, notification: notification, extra: extra)
    }

    /// The one toast panel — manager notifications and worktree cleanups share it,
    /// so a new toast replaces the last instead of stacking on it.
    private var toast: ManagerToastOverlay {
        if let managerToast { return managerToast }
        let o = ManagerToastOverlay()
        o.onOpen = { [weak self] n in
            self?.openManagerTarget(session: n.session, host: n.host)
        }
        o.onOpenLink = { [weak self] link in self?.openLink(link) }
        managerToast = o
        return o
    }

    /// Toast when a local agent starts waiting on you or finishes a turn, from
    /// the hook state the refresh just joined onto the tree. The pane you are
    /// looking at doesn't toast.
    private func showAgentToasts() {
        guard let sidebarVC else { return }
        let toasts = agentToasts
            .toasts(in: sidebarVC.loadedSessions(), now: Int(Date().timeIntervalSince1970))
            .filter { toast in
                !(NSApp.isActive && toast.visible && toast.session == attachedSession
                    && attachedService?.host.isLocal == true)
            }
        guard let first = toasts.first else { return }
        showManagerToast(
            ManagerNotification(
                id: 0, host: "localhost", session: first.session,
                text: AgentState.toastText(first), createdAt: first.since),
            extra: toasts.count - 1)
    }

    /// Open a session referenced by a review row / toast: attach the main
    /// terminal and highlight the sidebar row (mirrors a ⌘K activation).
    private func openManagerTarget(session: String, host hostName: String) {
        guard !session.isEmpty else { return }
        let host: Host = (hostName.isEmpty || hostName == "localhost")
            ? .local : Host(name: hostName, sshAlias: hostName)
        let service = registry.service(for: host)
        sidebarDidSelectSession(session, service: service)
        if sidebarVC?.selectSession(session, host: host) != true {
            sidebarVC?.selectSessionWhenReady(session, host: host)
        }
    }

    // MARK: - muxmaestro:// links

    /// How long a link waits for its target before it is reported unknown. At
    /// launch the local tree lands ~3s in (measured), and a thread started a
    /// moment ago reaches the tree within the status cache's 5s TTL. A wait
    /// counted in refreshes does not work: each host's load is its own refresh,
    /// and unreachable remotes report before the local tree does.
    private static let linkWait: TimeInterval = 6

    /// `muxmaestro://` URLs from LaunchServices: a link clicked in another app, or
    /// the one that launched this app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == ThreadLinks.scheme {
            if let link = ThreadLinks.parse(url.absoluteString) {
                openLink(link)
            } else {
                presentError(ThreadLinks.LinkError.malformed(url.absoluteString).message)
            }
        }
    }

    /// Go to the pane a link points at — from LaunchServices, a review row or a
    /// toast. A newer link replaces one still waiting.
    private func openLink(_ link: ThreadLink) {
        let deadline = Date().addingTimeInterval(Self.linkWait)
        pendingLink = (link, deadline)
        retryPendingLink()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkWait) { [weak self] in
            guard self?.pendingLink?.deadline == deadline else { return }
            self?.retryPendingLink(final: true)
        }
    }

    /// Try the waiting link against the tree — on arrival, after every refresh,
    /// and once more at its deadline, when a miss becomes the error.
    private func retryPendingLink(final: Bool = false) {
        guard let pending = pendingLink, let sidebarVC else { return }
        switch sidebarVC.resolveLink(pending.link) {
        case .success(let resolved):
            pendingLink = nil
            goToLinkTarget(resolved.target, host: resolved.host)
        case .failure(let error):
            guard final else { return }
            pendingLink = nil
            presentError(error.message)
        }
    }

    private func goToLinkTarget(_ target: ThreadLinks.Target, host: Host) {
        let service = registry.service(for: host)
        window?.makeKeyAndOrderFront(nil)
        if let index = target.window {
            focusNew(session: target.session, window: index, pane: target.pane, service: service)
        } else {
            sidebarDidSelectSession(target.session, service: service)
            sidebarVC?.selectSessionWhenReady(target.session, host: host)
            detailVC?.focusTerminal()
        }
    }

    // MARK: - Quick-open palette (⌘P)

    /// Menu "Go to File…" (⌘P) — open the floating quick-open palette over the main
    /// window, bound to the target session's repo. The file list is loaded once
    /// off-main; fuzzy filtering is then instant in the palette.
    @objc private func actionQuickOpen() {
        guard let window else { return }
        let vc = filePaletteVCOrCreate()
        vc.present(over: window)
        guard let target = openTarget() else {
            quickOpenService = nil
            quickOpenCwd = ""
            vc.setFiles([])
            vc.setStatus("Select a session to open files")
            return
        }
        let session = target.session
        let service = target.service
        quickOpenService = service
        vc.setStatus("Loading files…")
        service.driverQueue.async { [weak self] in
            let cwd = service.sessionCwd(session) ?? ""
            let files = cwd.isEmpty ? [] : service.repoFiles(cwd: cwd)
            DispatchQueue.main.async {
                guard let self, self.quickOpenService?.host == service.host else { return }
                self.quickOpenCwd = cwd
                self.filePaletteVC?.setFiles(files)
                if cwd.isEmpty { self.filePaletteVC?.setStatus("Couldn’t resolve the session directory") }
            }
        }
    }

    private func filePaletteVCOrCreate() -> FilePaletteViewController {
        if let filePaletteVC { return filePaletteVC }
        let vc = FilePaletteViewController()
        vc.delegate = self
        filePaletteVC = vc
        return vc
    }

    /// Menu "Go to Session…" (⌘K) — open the floating switcher over the main
    /// window. Fuzzy-matches every discovered tmux session, window and split-window
    /// pane across all hosts; picking one attaches the terminal to it (and
    /// highlights it in the sidebar). The session analog of ⌘P.
    @objc private func actionQuickSwitch() {
        guard let window else { return }
        let vc = sessionPaletteVCOrCreate()
        vc.present(over: window)
        let tree = sidebarVC?.switcherTree() ?? []
        let entries = SessionSwitcher.entries(tree)
        let items = entries.map { e in
            SessionPaletteViewController.Item(
                entry: e, service: registry.service(for: e.host),
                favicon: sidebarVC?.faviconForSession(e.session, host: e.host))
        }
        let generation = vc.beginScrollback()
        vc.setSessions(items)

        // Capture every pane's scrollback per host, each on that host's own queue
        // so a wedged remote only delays its own hits. Panes in sessions the
        // switcher hides (the manager's) are dropped, like their name rows.
        for (host, sessions) in tree where !sessions.isEmpty {
            let service = registry.service(for: host)
            let shown = Set(sessions.map(\.name))
            service.driverQueue.async { [weak vc] in
                guard let snapshot = service.capturePanes() else { return }
                let panes = snapshot.panes.filter { shown.contains($0.session) }
                DispatchQueue.main.async {
                    vc?.addScrollback(panes: panes, captures: snapshot.captures, generation: generation)
                }
            }
        }
    }

    private func sessionPaletteVCOrCreate() -> SessionPaletteViewController {
        if let sessionPaletteVC { return sessionPaletteVC }
        let vc = SessionPaletteViewController()
        vc.delegate = self
        sessionPaletteVC = vc
        return vc
    }

    // MARK: - ⌘` MRU window cycler

    /// ⌘` — a macOS Cmd+Tab-style switcher over the most-recently-visited
    /// *window* stack, flat across every session and host: the window you were
    /// just in is one press away even when it lives in another project. The menu
    /// item's key equivalent only reaches here to *start* a cycle (the local
    /// monitor swallows ⌘` while one is running), so this always begins: build the
    /// MRU order, show the overlay pre-selected on the previous window, and
    /// install the monitor that walks + commits it while ⌘ is held.
    @objc private func actionCycleWindows() {
        guard cycleMonitor == nil, let window else { return }
        let existing = sidebarVC?.switcherWindows() ?? []
        let order = SessionMRU.order(mru: windowMRU, existing: existing.map(\.ref))
        // Nothing to bounce between — no cycle.
        guard order.count >= 2 else { return }

        let items = order.map { ref in
            SessionCyclerOverlay.Item(
                ref: ref,
                title: existing.first { $0.ref == ref }?.name ?? "",
                favicon: sidebarVC?.faviconForSession(ref.session, host: ref.host))
        }
        let overlay = sessionCyclerOverlay ?? {
            let o = SessionCyclerOverlay(); sessionCyclerOverlay = o; return o
        }()
        // Clicking a row commits it through the same path as releasing ⌘.
        overlay.onCommit = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            self.commitCycle(overlay)
        }
        // Start on index 1 — the previous window, so a single ⌘` press-and-release
        // toggles to it (Cmd+Tab behavior).
        overlay.show(over: window, windows: items, selected: 1)
        installCycleMonitor()
    }

    private func installCycleMonitor() {
        // Local monitors run at the top of `sendEvent:`, before the terminal
        // responder and before menu key-equivalent dispatch — so this reliably
        // intercepts ⌘` (and arrows/Esc/↩) even while Ghostty is focused.
        cycleMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            self?.handleCycleEvent(event) ?? event
        }
    }

    /// Drive the running cycle. Returns nil to swallow an event, or the event to
    /// let it flow on. Grave steps (⇧ reverses); ⌘ release commits; Esc cancels;
    /// ↩ commits; arrows step.
    private func handleCycleEvent(_ event: NSEvent) -> NSEvent? {
        guard let overlay = sessionCyclerOverlay else { return event }
        switch event.type {
        case .flagsChanged:
            // ⌘ let go → commit the highlighted session.
            if !event.modifierFlags.contains(.command) {
                commitCycle(overlay)
            }
            return event
        case .leftMouseDown:
            // A click inside the picker is handled by the table (row select+commit),
            // so let it flow on; a click anywhere else dismisses, like Esc / Cmd+Tab.
            if overlay.containsMouseEvent(event) { return event }
            endCycle()
            return nil
        case .keyDown:
            switch event.keyCode {
            case 50:  // grave / backtick — swallow so no `\`` leaks to the shell.
                overlay.move(by: event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            case 53:  // Escape — cancel.
                endCycle()
                return nil
            case 36, 76:  // Return / keypad Enter — commit.
                commitCycle(overlay)
                return nil
            case 123, 126:  // ← / ↑ — step back.
                overlay.move(by: -1)
                return nil
            case 124, 125:  // → / ↓ — step forward.
                overlay.move(by: 1)
                return nil
            default:
                return event
            }
        default:
            return event
        }
    }

    /// Go to the overlay's highlighted window: attach its session (a no-op when
    /// it's already the attached one) and select the window inside it, then tear
    /// the cycle down. `noteWindowVisited` bumps it to MRU-front.
    private func commitCycle(_ overlay: SessionCyclerOverlay) {
        if let ref = overlay.selectedRef {
            let service = registry.service(for: ref.host)
            sidebarDidSelectSession(ref.session, service: service)
            sidebarVC?.selectSession(ref.session, host: ref.host)
            sidebarDidSelectWindow(session: ref.session, window: ref.window, service: service)
        }
        endCycle()
    }

    private func endCycle() {
        if let cycleMonitor { NSEvent.removeMonitor(cycleMonitor) }
        cycleMonitor = nil
        sessionCyclerOverlay?.hide()
    }

    // MARK: - PRs screen (⌥⌘P)

    /// Menu "Pull Requests" (⌥⌘P) / toolbar "PRs" click — open the PRs screen, or
    /// close it when it is already up.
    @objc private func actionShowPullRequests() {
        guard let content = window?.contentView else { return }
        let vc = pullRequestsVCOrCreate()
        if vc.isShown { closePullRequests(); return }
        vc.setEntries(sidebarVC?.pullRequestIndex() ?? [])
        vc.show(in: content)
    }

    private func pullRequestsVCOrCreate() -> PullRequestsViewController {
        if let pullRequestsVC { return pullRequestsVC }
        let vc = PullRequestsViewController()
        vc.onClose = { [weak self] in self?.closePullRequests() }
        vc.onFocusWindow = { [weak self] ref in self?.focusPullRequestWindow(ref) }
        vc.onSearch = { [weak self] number in self?.searchPullRequestSessions(number) }
        vc.onOpenSession = { [weak self] hit in self?.openPullRequestSession(hit) }
        pullRequestsVC = vc
        return vc
    }

    /// Find every Claude and Codex transcript about PR `number`, then ask gh for
    /// that PR's title and state in each repo found. Both off the main thread.
    private func searchPullRequestSessions(_ number: Int) {
        let service = registry.local
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = PRSessionSearch.search(number: number)
            var prs: [String: PullRequest] = [:]
            for slug in Set(hits.map(\.slug)) {
                prs[slug] = service.pullRequest(slug: slug, number: number)
            }
            DispatchQueue.main.async {
                self?.pullRequestsVC?.setSearchResults(number: number, hits: hits, prs: prs)
            }
        }
    }

    /// Open a session the PR search found: jump to its window when it is still
    /// running, else resume it in a new tmux session in its folder.
    private func openPullRequestSession(_ hit: PRSessionHit) {
        if let ref = sidebarVC?.windowRunning(agentSessionId: hit.sessionId) {
            focusPullRequestWindow(ref)
            return
        }
        pullRequestsVC?.hide()
        let service = registry.local
        let dir = PRSessionSearch.existingDirectory(hit.cwd)
        let name = ClaudeSessionRecovery.suggestedSessionName(forDirectory: hit.cwd)
        service.driverQueue.async { [weak self] in
            let created = service.recoverSession(
                name: name, dir: dir, claudeSessionId: hit.sessionId, autostart: true,
                agent: hit.agent)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let created else {
                    self.presentError("Couldn’t open a tmux session for \(hit.cwd).")
                    return
                }
                self.sidebarVC?.refresh()
                self.sidebarDidSelectSession(created, service: service)
                self.sidebarVC?.selectSessionWhenReady(created, host: .local)
                self.detailVC?.focusTerminal()
            }
        }
    }

    private func closePullRequests() {
        pullRequestsVC?.hide()
        detailVC?.focusTerminal()
    }

    /// Keep an open PRs screen current: PR sets change on the ~20s scan, window
    /// names and attention dots on every poll.
    private func reloadPullRequestsScreen() {
        guard let vc = pullRequestsVC, vc.isShown else { return }
        vc.setEntries(sidebarVC?.pullRequestIndex() ?? [])
    }

    /// Go to a window picked on the PRs screen: attach its session and select the
    /// window (the ⌘` commit path), reveal its sidebar row, then put the keyboard
    /// in its terminal.
    private func focusPullRequestWindow(_ ref: WindowRef) {
        pullRequestsVC?.hide()
        let service = registry.service(for: ref.host)
        sidebarDidSelectSession(ref.session, service: service)
        sidebarDidSelectWindow(session: ref.session, window: ref.window, service: service)
        sidebarVC?.selectWindow(ref.window, session: ref.session, host: ref.host)
        detailVC?.focusTerminal()
    }

    // MARK: - Commit panel (⌥⌘C)

    /// Menu "Commit…" (⌥⌘C) / toolbar — open the floating commit panel bound to the
    /// selected (or attached) session's repo, and load its changed files.
    @objc private func actionCommit() {
        guard let window else { return }
        guard let target = openTarget() else { return }
        let vc = commitPanelVCOrCreate()
        commitService = target.service
        vc.present(over: window)
        vc.setHeader(branch: "…", subtitle: "Loading changes…")
        vc.setFiles([])
        reloadCommitPanel(session: target.session, service: target.service)
    }

    private func commitPanelVCOrCreate() -> CommitPanelViewController {
        if let commitPanelVC { return commitPanelVC }
        let vc = CommitPanelViewController()
        vc.delegate = self
        commitPanelVC = vc
        return vc
    }

    /// Resolve the session's cwd + branch + changed files off-main, then render the
    /// panel. Mirrors `refreshDiff`'s data flow.
    private func reloadCommitPanel(session: String, service: TmuxService) {
        service.driverQueue.async { [weak self] in
            let cwd = service.sessionCwd(session) ?? ""
            let branch = cwd.isEmpty ? nil : service.currentBranch(cwd: cwd)
            let files = cwd.isEmpty ? [] : service.changedFiles(cwd: cwd)
            let prs = cwd.isEmpty ? [] : service.openPullRequests(cwd: cwd)
            DispatchQueue.main.async {
                guard let self, let vc = self.commitPanelVC,
                      self.commitService?.host == service.host else { return }
                self.commitCwd = cwd
                let staged = files.filter(\.staged).count
                let sub: String
                if cwd.isEmpty { sub = "Couldn’t resolve the session directory" }
                else if let pr = prs.first {
                    sub = "\(files.count) changed · \(staged) staged · PR #\(pr.number) open"
                } else {
                    sub = "\(files.count) changed · \(staged) staged · no PR yet"
                }
                vc.setHeader(branch: branch ?? "(detached)", subtitle: sub)
                vc.setFiles(files)
                if files.isEmpty && !cwd.isEmpty { vc.setStatus("Nothing to commit — working tree clean") }
                else { vc.setStatus("") }
            }
        }
    }

    /// Populate the Tree panel for the current selection, optionally focusing its
    /// search field. Respects whatever query is already typed (re-search vs list).
    private func openTreePanel(focusSearch: Bool) {
        if focusSearch { treeVC?.focusSearch() }
        refreshTreePanel()
    }

    /// Resolve the selected session's cwd off-main, then render the Tree panel:
    /// the full file tree when the search field is empty, or search results
    /// (matching files + lines) when it isn't. Same off-main discipline as
    /// `refreshDiff` so a slow/hung git/rg/ssh can't freeze the UI.
    private func refreshTreePanel() {
        // "All panes" needs no selected session — it sweeps every host.
        if treeVC?.scope == .panes, let query = treeVC?.currentQuery,
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runPaneSearch(query: query)
            return
        }
        guard let session = sidebarVC?.selectedSessionName,
              let service = sidebarVC?.selectedService else {
            treeVC?.renderTree(
                FileTreeResult(root: [], isRepo: false, truncated: false),
                status: "Select a session to see its files")
            return
        }
        let query = treeVC?.currentQuery ?? ""
        service.driverQueue.async { [weak self] in
            guard let cwd = service.sessionCwd(session), !cwd.isEmpty else {
                DispatchQueue.main.async {
                    self?.treeVC?.renderTree(
                        FileTreeResult(root: [], isRepo: false, truncated: false),
                        status: "Couldn’t resolve the session directory")
                }
                return
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = service.fileTree(cwd: cwd)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.bindTree(cwd: cwd, service: service)
                    self.lastFileTree = result
                    self.treeVC?.renderTree(result, status: Self.treeStatus(result))
                }
            } else {
                let result = service.search(cwd: cwd, query: query)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.bindTree(cwd: cwd, service: service)
                    self.treeVC?.renderSearch(
                        matches: result.matches, cwd: cwd,
                        status: Self.searchStatus(result, query: query, host: service.host))
                }
            }
        }
    }

    /// Bind the Tree panel to a (cwd, service), invalidating the preview cache when
    /// the directory changes so a stale preview can't show for a new repo.
    private func bindTree(cwd: String, service: TmuxService) {
        if treeCwd != cwd { previewPath = ""; previewContent = "" }
        treeCwd = cwd
        treeService = service
        treeVC?.hostIsLocal = service.host.isLocal  // gates "Open in Default App"
    }

    /// Run a repo search for `query` off-main against the bound session and render
    /// the results into the Tree panel. Empty query → show the (cached) file tree.
    private func runTreeSearch(query: String) {
        if treeVC?.scope == .panes,
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runPaneSearch(query: query)
            return
        }
        guard let service = treeService, !treeCwd.isEmpty else { refreshTreePanel(); return }
        let cwd = treeCwd
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let ft = lastFileTree {
                treeVC?.renderTree(ft, status: Self.treeStatus(ft))
            } else {
                refreshTreePanel()
            }
            return
        }
        service.driverQueue.async { [weak self] in
            let result = service.search(cwd: cwd, query: query)
            DispatchQueue.main.async {
                self?.treeVC?.renderSearch(
                    matches: result.matches, cwd: cwd,
                    status: Self.searchStatus(result, query: query, host: service.host))
            }
        }
    }

    /// Search every pane's scrollback on every host and render the hits into the
    /// Tree panel. One sweep per host, each on that host's own driver queue, so a
    /// wedged remote delays only its own results — the same discipline the poll
    /// uses. Results are merged in host order and gated on a token so a slow
    /// host's answer to an old query can't overwrite a newer one.
    private func runPaneSearch(query: String) {
        var seen = Set<String>()
        let services = (sidebarVC?.switcherSessions() ?? [])
            .filter { seen.insert($0.host.name).inserted }
            .map(\.service)
        guard !services.isEmpty else {
            treeVC?.renderPaneSearch(matches: [], status: "No sessions to search")
            return
        }
        paneSearchToken += 1
        let token = paneSearchToken
        treeVC?.renderPaneSearch(matches: [], status: "Searching \(services.count) host(s)…")

        let group = DispatchGroup()
        let lock = NSLock()
        var byHost: [String: PaneSearchResult] = [:]
        for service in services {
            group.enter()
            service.driverQueue.async {
                let result = service.searchPanes(query: query)
                lock.lock()
                byHost[service.host.name] = result
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.paneSearchToken == token else { return }
            let results = services.compactMap { byHost[$0.host.name] }
            let matches = results.flatMap(\.matches)
            let truncated = results.contains { $0.truncated }
            self.treeVC?.renderPaneSearch(
                matches: matches,
                status: Self.paneSearchStatus(matches: matches, truncated: truncated))
        }
    }

    /// The Tree panel's pane-search status line: match/pane counts, or a hint.
    private static func paneSearchStatus(matches: [PaneMatch], truncated: Bool) -> String {
        guard !matches.isEmpty else { return "No matches in any pane" }
        let panes = PaneSearch.group(matches).count
        var status = "\(matches.count) match\(matches.count == 1 ? "" : "es") "
            + "in \(panes) pane\(panes == 1 ? "" : "s")"
        if truncated { status += " (capped)" }
        return status
    }

    /// The Tree panel's file-list status line: "N files", "No files", or "Not a git
    /// repository", noting a capped count so a truncated view never reads complete.
    private static func treeStatus(_ result: FileTreeResult) -> String {
        guard result.isRepo else { return "Not a git repository" }
        let count = Self.fileCount(result.root)
        guard count > 0 else { return "No files" }
        var status = "\(count) file\(count == 1 ? "" : "s")"
        if result.truncated { status += " (capped at \(FileTree.maxFiles))" }
        return status
    }

    /// Total file (leaf) count across the tree, for the status line.
    private static func fileCount(_ nodes: [FileTreeNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.isDir ? fileCount($1.children) : 1) }
    }

    /// The Tree panel's search status line: a friendly note when rg is missing, the
    /// match/file counts otherwise (or a "no matches" hint).
    private static func searchStatus(
        _ result: CodeSearchResult, query: String, host: Host
    ) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.rgAvailable else {
            return host.isLocal
                ? "ripgrep (rg) not found — install it to search"
                : "ripgrep not found on \(host.name)"
        }
        guard !trimmed.isEmpty else { return "Type to search this repo" }
        guard !result.matches.isEmpty else { return "No matches" }
        let files = CodeSearch.group(result.matches).count
        var status = "\(result.matches.count) match\(result.matches.count == 1 ? "" : "es") "
            + "in \(files) file\(files == 1 ? "" : "s")"
        if result.truncated { status += " (capped at \(CodeSearch.maxMatches))" }
        return status
    }

    // MARK: - Open a file at a line in the editor

    /// Open `absPath` (optionally at `line`) on `host` in `editor`, reusing the
    /// same editor list + Remote-SSH machinery as `open(directory:host:in:)`.
    /// VS Code-family editors (those with a URL scheme) get a `file`/`vscode-remote`
    /// URL that can carry the line; other editors open the file (line ignored).
    /// A remote session needs a remote-capable editor (Remote-SSH scheme or Zed's
    /// ssh CLI), mirroring the dir path.
    private func open(file absPath: String, line: Int?, host: Host, in editor: Editor) {
        let lineSuffix = line.map { ":\($0)" } ?? ""
        let encodedPath = absPath.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? absPath

        if host.isLocal {
            if let scheme = editor.remoteScheme,
               let url = URL(string: "\(scheme)://file\(encodedPath)\(lineSuffix)") {
                NSWorkspace.shared.open(url)
                return
            }
            // Non-scheme editor (Zed, Xcode, Finder, …): open the file directly.
            let url = URL(fileURLWithPath: absPath)
            guard let appURL = appURL(for: editor) else {
                NSWorkspace.shared.open(url)  // system default
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) {
                [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    self?.presentError("Couldn’t open “\(editor.title)”: \(error.localizedDescription)")
                }
            }
            return
        }
        // Remote: a Zed-style editor opens the file over its SSH CLI (Zed doesn't
        // parse a :line suffix on ssh URLs, so the line is dropped); a VS
        // Code-family editor gets a Remote-SSH file URI carrying the line — same
        // shape as the remote-dir URL.
        if editor.sshCLI != nil {
            openViaSSHCLI(path: absPath, host: host, editor: editor)
            return
        }
        guard let scheme = editor.remoteScheme, let alias = host.sshAlias,
              let url = URL(string:
                "\(scheme)://vscode-remote/ssh-remote+\(alias)\(encodedPath)\(lineSuffix)") else {
            presentError("“\(editor.title)” can’t open a file on \(host.name) over SSH. "
                + "Use VS Code, Cursor, Zed, or Antigravity.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // Split the attached tmux session's active pane (tmux-native; persists on the
    // server). The attached surface redraws the new pane on its own.
    @objc private func actionSplitRight() { splitAttached(vertical: false) }
    @objc private func actionSplitDown() { splitAttached(vertical: true) }

    private func splitAttached(vertical: Bool) {
        // Only a tmux attach can split (herdr clears attachedService).
        guard let session = attachedSession, let service = attachedService else { return }
        createPane(on: service, session: session, failure: "Couldn’t split the pane.") {
            service.splitActivePane(session: session, vertical: vertical)
        }
    }

    /// ⌘T — add a new pane to the selected window by splitting its active pane.
    /// Targets the selected session, or the attached one when no row is selected.
    @objc private func actionNewPane() {
        guard let target = openTarget() else { return }
        createPane(
            on: target.service, session: target.session, failure: "Couldn’t create the pane."
        ) {
            target.service.splitActivePane(session: target.session, vertical: false)
        }
    }

    // MARK: Pane rearrange (⌘⇧-drag in the terminal)

    /// Push the attached session's active-window pane geometry to the terminal
    /// surface so a ⌘⇧-drag can map the cursor to a pane. Cleared when no tmux
    /// session is attached (herdr / plain shell).
    private func pushRearrangePanes() {
        guard let session = attachedSession, let service = attachedService,
              !session.hasPrefix("herdr:") else {
            terminalVC?.surfaceView?.rearrangePanes = []
            detailVC?.setTerminalColumns(1)
            return
        }
        let panes = sidebarVC?.activeWindowPanes(host: service.host, session: session) ?? []
        terminalVC?.surfaceView?.rearrangePanes = panes
        // Feed the live column count so the terminal caps at N × readable-width and
        // hands the freed space to the right sidebar at big window widths.
        detailVC?.setTerminalColumns(TmuxModel.columnCount(of: panes))
    }

    /// Perform a committed ⌘⇧-drag: center = swap the two panes, an edge = dock the
    /// source beside/above/below the target. Runs off-main against the attached
    /// service, then refreshes (which re-pushes the new geometry).
    private func performRearrange(source: String, target: String, zone: PaneDropZone) {
        guard let service = attachedService else { return }
        service.driverQueue.async {
            if zone == .center {
                service.swapPane(source: source, target: target)
            } else if let a = TmuxModel.joinArgs(for: zone) {
                service.joinPane(
                    source: source, target: target, horizontal: a.horizontal, before: a.before)
            }
            DispatchQueue.main.async { self.sidebarVC?.refresh() }
        }
    }

    /// Compute the selected session's git diff off-main (resolve its cwd, then
    /// `gitDiff` — over ssh automatically for a remote host) and render it in the
    /// Diff pane. `reveal` flips the detail area to the Diff pane (the menu/toolbar
    /// path); the in-pane Refresh button and the tab-switch path pass false since
    /// the pane is already showing. Same off-main discipline as `actionOpenPort`
    /// so a slow/hung git or ssh can't freeze the UI.
    private func refreshDiff(reveal: Bool) {
        guard let session = sidebarVC?.selectedSessionName,
              let service = sidebarVC?.selectedService else {
            if reveal { detailVC?.showDiff() }
            diffVC?.render("", header: "Select a session to see its diff")
            return
        }
        service.driverQueue.async { [weak self] in
            guard let cwd = service.sessionCwd(session), !cwd.isEmpty else {
                DispatchQueue.main.async {
                    if reveal { self?.detailVC?.showDiff() }
                    self?.diffVC?.render("", header: "Couldn’t resolve the session directory")
                }
                return
            }
            let result = service.gitDiff(cwd: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                if reveal { self.detailVC?.showDiff() }
                self.diffVC?.render(result.patch, header: Self.diffHeader(result, session: session))
            }
        }
    }

    /// The Diff pane's status line: "branch · N files", "branch · No changes", or
    /// "Not a git repository". Notes a capped untracked count so a truncated view
    /// never reads as complete.
    private static func diffHeader(_ result: GitDiffResult, session: String) -> String {
        guard result.isRepo else { return "Not a git repository" }
        let branch = result.branch.isEmpty
            ? (result.isEmptyRepo ? "no commits yet" : session)
            : result.branch
        let count = GitDiff.changedFileCount(in: result.patch)
        guard count > 0 else { return "\(branch) · No changes" }
        var header = "\(branch) · \(count) file\(count == 1 ? "" : "s")"
        if result.untrackedDropped > 0 {
            header += " (+\(result.untrackedDropped) untracked hidden)"
        }
        return header
    }

    // MARK: - Open directory in editor

    /// An app the "Open" toolbar item can hand the session's directory to. Order is
    /// the menu order; the primary button click uses the last-opened editor (or the
    /// first installed one until you pick one). `remoteScheme` is the URL scheme a
    /// VS Code-family editor uses to open a remote (SSH) folder; `sshCLI` is the
    /// bundle-relative path of a CLI that opens `ssh://` URLs (Zed's SSH remoting).
    /// Both nil for apps that can only open local directories.
    private struct Editor {
        let title: String
        let bundleID: String
        var remoteScheme: String?
        var sshCLI: String?

        var opensRemote: Bool { remoteScheme != nil || sshCLI != nil }
    }

    private static let editors: [Editor] = [
        Editor(title: "VS Code", bundleID: "com.microsoft.VSCode", remoteScheme: "vscode"),
        Editor(title: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", remoteScheme: "cursor"),
        Editor(title: "Zed", bundleID: "dev.zed.Zed", sshCLI: "Contents/MacOS/cli"),
        Editor(title: "Antigravity", bundleID: "com.google.antigravity", remoteScheme: "antigravity"),
        Editor(title: "Finder", bundleID: "com.apple.finder"),
        Editor(title: "Terminal", bundleID: "com.apple.Terminal"),
        Editor(title: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        Editor(title: "Xcode", bundleID: "com.apple.dt.Xcode"),
    ]

    /// The session + service the Open button acts on: the highlighted sidebar
    /// session when there is one, otherwise the session the terminal is attached
    /// to (so the button works even with focus in the terminal and no row selected).
    /// nil for a herdr attach (no tmux service) or when nothing is attached/selected.
    private func openTarget() -> (session: String, service: TmuxService)? {
        if let name = sidebarVC?.selectedSessionName, let service = sidebarVC?.selectedService {
            return (name, service)
        }
        if let name = attachedSession, let service = attachedService, !name.hasPrefix("herdr:") {
            return (name, service)
        }
        return nil
    }

    /// Whether `editor` can open the target session's directory: any editor for a
    /// local session; only remote-capable editors for a remote one.
    private func canOpen(_ editor: Editor) -> Bool {
        guard let host = openTarget()?.service.host else { return false }
        return host.isLocal || editor.opensRemote
    }

    /// Persisted title of the last editor the user opened a directory with — drives
    /// the primary-button default and its icon across launches.
    private static let lastEditorKey = "sidekick.lastEditorTitle"
    private var lastEditorTitle: String? {
        get { UserDefaults.standard.string(forKey: Self.lastEditorKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastEditorKey) }
    }

    /// The app URL for an editor, or nil if it isn't installed.
    private func appURL(for editor: Editor) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID)
    }

    private func isInstalled(_ editor: Editor) -> Bool { appURL(for: editor) != nil }

    /// The app icon for an editor at a toolbar/menu size.
    private func icon(for editor: Editor, size: CGFloat) -> NSImage? {
        guard let url = appURL(for: editor) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    /// Split button (button + chevron) mirroring how Codex offers "open in editor".
    /// The chevron menu lists every installed editor with its real icon; the button
    /// click opens in the default (last-used) editor and wears that editor's icon.
    private func openDirToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = "Open"
        item.target = self
        item.action = #selector(actionOpenDirInDefault)
        item.menu = makeOpenInMenu()
        openDirItem = item
        updateOpenDirIcon()
        return item
    }

    private func makeOpenInMenu() -> NSMenu {
        let menu = NSMenu()
        // Drive enabled state ourselves in menuNeedsUpdate (toolbar-item submenus
        // don't always route through validateMenuItem reliably).
        menu.autoenablesItems = false
        menu.delegate = self
        for editor in Self.editors where isInstalled(editor) {
            let menuItem = NSMenuItem(
                title: editor.title, action: #selector(actionOpenDirInEditor(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = editor.title
            menuItem.image = icon(for: editor, size: 16)
            menu.addItem(menuItem)
        }
        return menu
    }

    /// The default editor for the primary button: the last-opened one (when still
    /// installed), else the first installed entry.
    private var defaultEditor: Editor? {
        if let title = lastEditorTitle,
           let editor = Self.editors.first(where: { $0.title == title }), isInstalled(editor) {
            return editor
        }
        return Self.editors.first(where: isInstalled)
    }

    /// Make the toolbar button wear the default editor's icon (so it reflects what
    /// the primary click will do), falling back to a folder glyph.
    private func updateOpenDirIcon() {
        if let editor = defaultEditor, let image = icon(for: editor, size: 18) {
            openDirItem?.image = image
            openDirItem?.toolTip = "Open directory in \(editor.title)"
        } else {
            openDirItem?.image = NSImage(
                systemSymbolName: "folder", accessibilityDescription: "Open directory")
        }
    }

    @objc private func actionOpenDirInDefault() {
        guard let editor = defaultEditor else { return }
        openSelectedDir(in: editor)
    }

    @objc private func actionOpenDirInEditor(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let editor = Self.editors.first(where: { $0.title == title }) else { return }
        openSelectedDir(in: editor)
    }

    /// Toolbar 🐙 / menu "Open on GitHub" (⌘⌥G) — resolve the selected (or
    /// attached) session's repo slug off-main (`git remote get-url origin`, over
    /// ssh for a remote host) and open its GitHub page in the browser.
    @objc private func actionOpenGitHub() {
        guard let target = openTarget() else { return }
        let session = target.session
        let service = target.service
        service.driverQueue.async { [weak self] in
            guard let cwd = service.sessionCwd(session), !cwd.isEmpty,
                  let url = service.githubURL(cwd: cwd), let u = URL(string: url) else {
                DispatchQueue.main.async {
                    self?.presentError("Couldn’t find a GitHub remote for this session.")
                }
                return
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
        }
    }

    /// Resolve the selected session's working directory off-main (a tmux shell-out,
    /// same discipline as the Diff button) and open it in `editor` on main. Works
    /// for a local session (open the path directly) or a remote one (over Remote-SSH
    /// for VS Code-family editors, over Zed's ssh CLI for Zed). Remembers `editor`
    /// as the new default and updates the button icon.
    private func openSelectedDir(in editor: Editor) {
        guard let target = openTarget() else { return }
        let session = target.session
        let service = target.service
        let host = service.host
        guard host.isLocal || editor.opensRemote else {
            presentError("“\(editor.title)” can’t open a directory on \(host.name) over SSH. "
                + "Use VS Code, Cursor, Zed, or Antigravity.")
            return
        }
        lastEditorTitle = editor.title
        updateOpenDirIcon()
        service.driverQueue.async { [weak self] in
            guard let cwd = service.sessionCwd(session), !cwd.isEmpty else {
                DispatchQueue.main.async {
                    self?.presentError("Couldn’t resolve the session directory.")
                }
                return
            }
            DispatchQueue.main.async { self?.open(directory: cwd, host: host, in: editor) }
        }
    }

    private func open(directory: String, host: Host, in editor: Editor) {
        if host.isLocal {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            guard let appURL = appURL(for: editor) else {
                NSWorkspace.shared.open(url)  // fall back to the system default
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) {
                [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    self?.presentError("Couldn’t open “\(editor.title)”: \(error.localizedDescription)")
                }
            }
            return
        }
        // Remote: Zed-style editors open over SSH via their bundled CLI; VS
        // Code-family editors get a Remote-SSH folder URI,
        // `<scheme>://vscode-remote/ssh-remote+<alias><path>`.
        if editor.sshCLI != nil {
            openViaSSHCLI(path: directory, host: host, editor: editor)
            return
        }
        let encodedPath = directory.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? directory
        guard let scheme = editor.remoteScheme, let alias = host.sshAlias,
              let url = URL(string: "\(scheme)://vscode-remote/ssh-remote+\(alias)\(encodedPath)") else {
            presentError("Couldn’t build a Remote-SSH URL for “\(editor.title)”.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Open a remote path in an editor whose SSH remoting rides its bundled CLI
    /// (Zed): run `<app>/<sshCLI> ssh://<alias><path>`. The host alias comes from
    /// ~/.ssh/config, which Zed's remoting resolves through the system ssh, so the
    /// same alias that backs the tmux connection works here. The CLI hands the URL
    /// to the app and exits; no need to wait on it.
    private func openViaSSHCLI(path: String, host: Host, editor: Editor) {
        guard let cliPath = editor.sshCLI, let alias = host.sshAlias,
              let appURL = appURL(for: editor) else {
            presentError("Couldn’t open “\(editor.title)” on \(host.name) over SSH.")
            return
        }
        // Zed URL-decodes the path portion, so encode it the same way as the
        // Remote-SSH URLs above.
        let encodedPath = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? path
        let process = Process()
        process.executableURL = appURL.appendingPathComponent(cliPath)
        process.arguments = ["ssh://\(alias)\(encodedPath)"]
        do {
            try process.run()
        } catch {
            presentError("Couldn’t open “\(editor.title)”: \(error.localizedDescription)")
        }
    }

    // MARK: - Group sidebar by host / directory

    /// Split button to flip the sidebar between host grouping and directory
    /// grouping. The chevron menu offers both explicitly (with a checkmark on the
    /// active one); the primary click toggles.
    private func groupToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = "Group"
        item.image = NSImage(
            systemSymbolName: "rectangle.3.group", accessibilityDescription: "Group sidebar")
        item.target = self
        item.action = #selector(actionToggleGrouping)

        let menu = NSMenu()
        let byHost = NSMenuItem(
            title: "By Host", action: #selector(actionGroupByHost), keyEquivalent: "")
        byHost.target = self
        let byDir = NSMenuItem(
            title: "By Directory", action: #selector(actionGroupByDirectory), keyEquivalent: "")
        byDir.target = self
        let byRecent = NSMenuItem(
            title: "Most Recent", action: #selector(actionGroupByRecent), keyEquivalent: "")
        byRecent.target = self
        byRecent.state = .on
        menu.addItem(byHost)
        menu.addItem(byDir)
        menu.addItem(byRecent)
        item.menu = menu
        groupByHostItem = byHost
        groupByDirItem = byDir
        groupByRecentItem = byRecent
        return item
    }

    /// Toolbar "PRs": clicking opens the PRs screen; the dropdown indicator lists
    /// every session that currently has an open PR, each opening the PR on GitHub.
    /// The menu is rebuilt on open (menuNeedsUpdate) from the sidebar's detected set.
    private func prsToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = "PRs"
        item.image = NSImage(
            systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Open pull requests")
        item.toolTip = "Open pull requests for your sessions"
        item.showsIndicator = true
        item.target = self
        item.action = #selector(actionShowPullRequests)
        // Opt out of autovalidation and keep it always clickable — the screen
        // and the menu both say so when there are no PRs, so it stays useful
        // rather than a dead grayed button.
        item.autovalidates = false
        item.isEnabled = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        prsItem = item
        prsMenu = menu
        // Refresh the toolbar item's enabled state when the detected set changes.
        // A landed scan re-renders the rail in place (and can reveal it, if the
        // node just gained something that was not there before).
        sidebarVC?.onRunningChanged = { [weak self] in self?.refreshRunning() }
        sidebarVC?.onPullRequestsChanged = { [weak self] in
            self?.updatePRsItem()
            self?.reloadPullRequestsScreen()
            // The phone's threads carry their window's PRs.
            self?.pushMobileSnapshot()
        }
        updatePRsItem()
        return item
    }

    /// Reflect the detected PR count in the toolbar item's tooltip. The item stays
    /// enabled either way — the dropdown always opens (showing the PRs or a
    /// "No open PRs" note), so it's never a dead grayed button.
    private func updatePRsItem() {
        let all = sidebarVC?.sessionsWithPullRequests() ?? []
        let count = all.reduce(0) { $0 + $1.prs.count }
        prsItem?.isEnabled = true
        prsItem?.toolTip = count == 0
            ? "No open pull requests for your sessions"
            : "\(count) open pull request\(count == 1 ? "" : "s")"
    }

    /// Rebuild the PRs dropdown from the sidebar's current detection: one item per
    /// PR, grouped by session, opening the PR URL on GitHub.
    private func populatePRsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let groups = sidebarVC?.sessionsWithPullRequests() ?? []
        guard !groups.isEmpty else {
            let empty = NSMenuItem(title: "No open PRs", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for group in groups {
            let header = NSMenuItem(title: group.session, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for pr in group.prs {
                let title = pr.title.isEmpty ? "PR #\(pr.number)" : "#\(pr.number)  \(pr.title)"
                let mi = NSMenuItem(title: title, action: #selector(actionOpenPR(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = pr.url
                mi.indentationLevel = 1
                mi.image = NSImage(
                    systemSymbolName: pr.isDraft ? "circle.dashed" : "arrow.triangle.pull",
                    accessibilityDescription: nil)
                menu.addItem(mi)
            }
        }
    }

    @objc private func actionOpenPR(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc private func actionToggleGrouping() {
        // Cycle the button through the three modes; the menu picks a specific one.
        let order: [SidebarViewController.GroupMode] = [.host, .recent, .directory]
        let cur = sidebarVC?.groupMode ?? .recent
        let next = order[((order.firstIndex(of: cur) ?? 0) + 1) % order.count]
        applyGroupMode(next)
    }

    @objc private func actionGroupByHost() { applyGroupMode(.host) }
    @objc private func actionGroupByDirectory() { applyGroupMode(.directory) }
    @objc private func actionGroupByRecent() { applyGroupMode(.recent) }

    private func applyGroupMode(_ mode: SidebarViewController.GroupMode) {
        sidebarVC?.setGroupMode(mode)
        groupByHostItem?.state = mode == .host ? .on : .off
        groupByDirItem?.state = mode == .directory ? .on : .off
        groupByRecentItem?.state = mode == .recent ? .on : .off
    }

    @objc private func actionToggleZoom() {
        // Zoom the *exact* target the sidebar selection drives (pane id for a
        // selected pane, else session:window) so the button and the visible
        // surface always agree. Read the target on main, toggle off-main, then
        // refresh on main.
        guard let target = sidebarVC?.selectedZoomTarget,
              let service = sidebarVC?.selectedService else { return }
        service.driverQueue.async {
            service.toggleZoom(target: target)
            DispatchQueue.main.async { [weak self] in self?.sidebarVC?.refresh() }
        }
    }

    // MARK: - Action enablement

    /// True when a sidebar row is selected (any kind). Zoom/Kill/Rename require it.
    private var hasSelection: Bool { sidebarVC?.selectedSessionName != nil }

    /// Whether the action behind a toolbar/menu item should be enabled given the
    /// current selection. New is always available; selection-scoped actions are
    /// disabled with no selection.
    private func isActionEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(actionNewSession), #selector(actionNewRootSession),
             #selector(actionAddServer),
             #selector(NSApplication.terminate(_:)):
            return true
        case #selector(actionToggleZoom), #selector(actionKillSelected),
             #selector(actionRenameSelected), #selector(actionShowDiff):
            return hasSelection
        case #selector(actionOpenDirInDefault), #selector(actionOpenDirInEditor(_:)):
            // Enabled whenever there's a target tmux session (selected or attached).
            // Each menu item is refined per-editor in validateMenuItem (remote needs
            // a Remote-SSH-capable editor).
            return openTarget() != nil
        case #selector(actionSplitRight), #selector(actionSplitDown),
             #selector(actionFindInSession):
            // Splits and ⌘F act on the attached tmux session (not herdr /
            // plain shell — a herdr attach clears attachedService).
            return attachedSession != nil && attachedService != nil
        case #selector(actionNewPane), #selector(actionCommit), #selector(actionOpenGitHub):
            // New pane / commit / open-on-GitHub target the selected or attached
            // tmux session's repo.
            return openTarget() != nil
        default:
            return true
        }
    }

    // MARK: Helpers

    /// The selected session's cwd (shell-out) or home. Static + parameterized so
    /// it can run on the driver queue with the session name captured on main.
    private static func cwdOrHome(for sessionName: String?, service: TmuxService) -> String {
        if let sessionName, let cwd = service.sessionCwd(sessionName) {
            return cwd
        }
        return NSHomeDirectory()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MuxMaestro"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func presentInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MuxMaestro"
        alert.informativeText = message
        alert.alertStyle = .informational
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Self-tests

    /// M4 end-to-end self-test: create a session, send a multi-line prompt and
    /// read it back from the pane, rename it, toggle zoom, then kill it —
    /// printing pass/fail per action. Exits 0 only if every action passes.
    private func runM4SelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let tmux = self.tmuxService.tmuxPath else { exit(2) }
            var results: [(String, Bool)] = []
            let suffix = Int.random(in: 100000...999999)
            let name = "sk_m4_\(suffix)"
            let renamed = "sk_m4r_\(suffix)"

            func tmuxRun(_ args: [String]) -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tmux)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                try? p.run()
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(data: out, encoding: .utf8) ?? ""
            }

            // 1. New session.
            let created = self.tmuxService.newSession(name: name, dir: NSHomeDirectory(), launchClaude: false)
            let sessionsAfterCreate = tmuxRun(["list-sessions", "-F", "#{session_name}"])
                .split(separator: "\n").map(String.init)
            let newOK = created == name && sessionsAfterCreate.contains(name)
            results.append(("new-session", newOK))

            // 2. Rename.
            let r = self.tmuxService.renameSession(from: name, to: renamed)
            let afterRename = tmuxRun(["list-sessions", "-F", "#{session_name}"])
                .split(separator: "\n").map(String.init)
            let renameOK = r == renamed
                && afterRename.contains(renamed) && !afterRename.contains(name)
            results.append(("rename-session", renameOK))

            // 3. Zoom toggle (needs >1 pane to actually flag; split first).
            _ = tmuxRun(["split-window", "-t", renamed])
            let zoomedOn = self.tmuxService.toggleZoom(target: renamed)
            let zoomedOff = self.tmuxService.toggleZoom(target: renamed)
            let zoomOK = zoomedOn == true && zoomedOff == false
            results.append(("zoom toggle", zoomOK))

            // 4. Kill.
            let killed = self.tmuxService.killSession(name: renamed)
            let remaining = tmuxRun(["list-sessions", "-F", "#{session_name}"])
                .split(separator: "\n").map(String.init)
            let killOK = killed && !remaining.contains(renamed)
            results.append(("kill-session", killOK))

            var lines = ["M4 SELFTEST"]
            for (action, ok) in results {
                lines.append("  [\(ok ? "PASS" : "FAIL")] \(action)")
            }
            let allOK = results.allSatisfy { $0.1 }
            lines.append(allOK ? "ALL PASS" : "SOME FAILED")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            // Best-effort cleanup in case of partial failure.
            _ = tmuxRun(["kill-session", "-t", name])
            _ = tmuxRun(["kill-session", "-t", renamed])
            exit(allOK ? 0 : 1)
        }
    }

    /// M8 self-test: parse ssh-config hosts, probe each remote off-main, and for
    /// the first reachable remote, list its session→window→pane tree (built over
    /// ssh) and print its attach command. Confirms the remote transport works
    /// end-to-end against a real host. Exits 0 if a remote was listed, 5 if no
    /// remote host is reachable (so the harness can report "unit-tests only").
    private func runM8SelfTest() {
        Self.driverQueue.async { [registry] in
            let hosts = SshConfig.loadHosts()
            let remotes = hosts.filter { !$0.isLocal }
            var lines = ["M8 SELFTEST — \(remotes.count) remote host(s) in ssh-config:"]
            for h in remotes { lines.append("  \(h.name) → ssh \(h.sshAlias ?? h.name)") }

            // Probe + load each remote sequentially. Sequential (not concurrent)
            // mirrors the app's lazy load-on-expand and avoids racing the shared
            // ControlMaster socket when two aliases point at the same HostName.
            struct Probe { let host: Host; let service: TmuxService; let reachable: Bool; let tree: [TmuxSession] }
            var probes: [Probe] = []
            for h in remotes {
                let svc = registry.service(for: h)
                let r = svc.probeReachability() == .reachable
                let tree = r ? (svc.loadTree() ?? []) : []
                probes.append(Probe(host: h, service: svc, reachable: r, tree: tree))
            }

            for p in probes.sorted(by: { $0.host.name < $1.host.name }) {
                let note = p.reachable
                    ? "REACHABLE (\(p.tree.count) session(s))" : "unreachable"
                lines.append("  probe \(p.host.name): \(note)")
            }

            guard probes.contains(where: { $0.reachable }) else {
                lines.append("")
                lines.append("NO REMOTE HOST REACHABLE — relying on unit tests.")
                FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                exit(5)
            }

            // Prefer a reachable host that actually has tmux sessions (a real
            // end-to-end proof); else any reachable host (e.g. tmux not present).
            let target = probes.first(where: { $0.reachable && !$0.tree.isEmpty })
                ?? probes.first(where: { $0.reachable })!
            lines.append("")
            lines.append("Remote tree for \(target.host.name) — \(target.tree.count) session(s):")
            for s in target.tree {
                lines.append("  \(s.attention.dot) \(s.name)  attached=\(s.attached) windows=\(s.windows.count) attention=\(s.attention.rawValue)")
                for w in s.windows {
                    lines.append("      win \(w.index): \(w.name) (\(w.panes.count) panes)")
                }
            }
            if let first = target.tree.first {
                lines.append("")
                lines.append("attach command: \(target.service.attachCommand(session: first.name) ?? "nil")")
            }
            // OK if any reachable remote yielded a tree over ssh; a reachable
            // host without tmux is reported but doesn't fail the run.
            let listedReal = probes.contains { $0.reachable && !$0.tree.isEmpty }
            lines.append(listedReal
                ? "M8 OK (listed a real remote tmux host over ssh)"
                : "M8 PARTIAL (remote reachable over ssh, but none had tmux sessions)")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(0)
        }
    }

    /// M3 end-to-end self-test: build the tree from live tmux, pick a session
    /// (the first one, post-sort), attach the single terminal to it, then read
    /// back the rendered screen and confirm it shows that session's content.
    private func runM3SelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { exit(2) }
            let roots = self.sidebarVC?.loadOnce() ?? []
            // ACTIVE is flat now — loadOnce returns session nodes directly (+ herdr).
            let sessionNodes = roots.filter { $0.isSession }
            var lines: [String] = []
            lines.append("M3 SELFTEST — \(sessionNodes.count) session(s) in local tree:")
            for sessionNode in sessionNodes {
                guard case .session(_, let s) = sessionNode.kind else { continue }
                lines.append("  \(s.attention.dot) \(s.name)  attached=\(s.attached) windows=\(sessionNode.children.count) attention=\(s.attention.rawValue)")
                for win in sessionNode.children {
                    guard case .window(_, _, let w) = win.kind else { continue }
                    lines.append("      win \(w.index): \(w.name) (\(win.children.count) panes)")
                }
            }

            guard case .session(_, let target)? = sessionNodes.first?.kind else {
                lines.append("FAIL: no sessions to select")
                FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                exit(3)
            }

            let marker = "SIDEKICK_M3_\(Int.random(in: 100000...999999))"
            if let tmux = self.tmuxService.tmuxPath {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tmux)
                p.arguments = ["send-keys", "-t", target.name, "echo \(marker)", "Enter"]
                try? p.run(); p.waitUntilExit()
            }

            self.sidebarDidSelectSession(target.name, service: self.registry.local)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let screen = self.terminalVC?.surfaceView?.readScreenText() ?? ""
                let ok = screen.contains(marker)
                lines.append("")
                lines.append("Selected session: \(target.name)")
                lines.append("Marker \(marker) rendered in swapped terminal: \(ok)")
                lines.append("----- SCREEN -----")
                lines.append(screen)
                lines.append("------------------")
                FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                exit(ok ? 0 : 4)
            }
        }
    }

    /// M2 end-to-end self-test: type a unique marker into the live terminal,
    /// then read the rendered screen text back and print it.
    private func runSelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let surface = self?.terminalVC?.surfaceView else {
                FileHandle.standardError.write(Data("SELFTEST: no surface\n".utf8))
                exit(2)
            }
            let marker = "SIDEKICK_M2_\(Int.random(in: 100000...999999))"
            surface.sendText("echo \(marker)\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let screen = surface.readScreenText()
                let ok = screen.contains(marker)
                let report = "SELFTEST marker=\(marker) rendered=\(ok)\n----- SCREEN -----\n\(screen)\n------------------\n"
                FileHandle.standardError.write(Data(report.utf8))
                exit(ok ? 0 : 3)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        // Close any remote SSH masters so backgrounded `ssh -fN -L` forwards
        // (the browser-preview tunnels) don't linger after the app exits.
        registry.closeAllMasters()
        if Settings.phoneEnabled() { phoneLink.shutdown() }
        finishArchivesAtQuit()
    }

    /// Choose what the terminal runs: `tmux attach` if a tmux server is up,
    /// else fall back to the login shell.
    private static func startupCommand() -> String? {
        guard let tmux = tmuxPath(), tmuxServerRunning(tmux) else {
            return nil
        }
        return "\(tmux) attach"
    }

    private static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func tmuxServerRunning(_ tmux: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmux)
        proc.arguments = ["has-session"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let exited = exitSignal(for: proc)  // never waitUntilExit — see exitSignal
        do {
            try proc.run()
        } catch {
            return false
        }
        // Bounded: this runs on the main thread during launch, so a wedged tmux
        // must not hold the app hostage — no server beats no window.
        guard exited.wait(timeout: .now() + 4) == .success else {
            proc.terminate()
            return false
        }
        return proc.terminationStatus == 0
    }
}

// MARK: - Action validation (toolbar + menu enablement)

extension AppDelegate: NSToolbarItemValidation, NSMenuItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isActionEnabled(item.action)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // The per-editor "Open in…" items grey out when the chosen editor can't
        // open the current selection's directory (remote needs Remote-SSH).
        if item.action == #selector(actionOpenDirInEditor(_:)),
           let title = item.representedObject as? String,
           let editor = Self.editors.first(where: { $0.title == title }) {
            return canOpen(editor)
        }
        // ⌘W's label has to follow ⌘W's target — it closes the focused pane of a
        // multi-pane window and the window only when the pane *is* the window.
        // A fixed "Archive Window" would promise the wider blast radius on every
        // press. With nothing attached the label is "Archive Window".
        if item.action == #selector(actionCloseWindow) {
            var action = CloseWindowPrompt.Action.window
            if let session = attachedSession, let service = attachedService,
               !session.hasPrefix("herdr:") {
                action = CloseWindowPrompt.action(
                    for: closeTarget(session: session, window: nil, service: service))
            }
            item.title = CloseWindowPrompt.confirmTitle(action)
        }
        return isActionEnabled(item.action)
    }
}

// MARK: - NSMenuDelegate (Open-in editor menu enablement)

extension AppDelegate: NSMenuDelegate {
    /// Refresh each "Open in…" item's enabled state against the current target
    /// session just before the menu shows: enabled if that editor can open it
    /// (any editor for local; Remote-SSH editors only for a remote session).
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === prsMenu {
            populatePRsMenu(menu)
            return
        }
        for item in menu.items where item.action == #selector(actionOpenDirInEditor(_:)) {
            guard let title = item.representedObject as? String,
                  let editor = Self.editors.first(where: { $0.title == title }) else { continue }
            item.isEnabled = canOpen(editor)
        }
    }
}

// MARK: - NSToolbarDelegate

extension AppDelegate: NSToolbarDelegate {
    // Only the Diff toggle lives in the header (top-right). Everything else is in
    // the Session menu (and the per-row "+" buttons).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tbBreadcrumb, .flexibleSpace, Self.tbCommit, Self.tbPRs, Self.tbGitHub, Self.tbGroup, Self.tbOpenDir, Self.tbTree, Self.tbDiff, Self.tbArtifacts, Self.tbSidebar, Self.tbManager]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tbBreadcrumb, Self.tbCommit, Self.tbPRs, Self.tbGitHub, Self.tbGroup, Self.tbOpenDir, Self.tbTree, Self.tbDiff, Self.tbArtifacts, Self.tbSidebar, Self.tbManager, .flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.tbBreadcrumb:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = breadcrumb
            item.visibilityPriority = .high
            breadcrumbItem = item
            resizeBreadcrumbItem(to: breadcrumb.fittingSize.width)
            return item
        case Self.tbNew:
            return toolbarButton(itemIdentifier, label: "New", symbol: "plus", action: #selector(actionNewSession), shortcut: "⌘N")
        case Self.tbAddServer:
            return toolbarButton(itemIdentifier, label: "Add Server", symbol: "server.rack", action: #selector(actionAddServer))
        case Self.tbDiff:
            return toolbarButton(itemIdentifier, label: "Diff", symbol: "plusminus", action: #selector(actionToggleDiff))
        case Self.tbTree:
            return toolbarButton(itemIdentifier, label: "Tree", symbol: "sidebar.squares.left", action: #selector(actionToggleTree))
        case Self.tbArtifacts:
            return toolbarButton(itemIdentifier, label: "Artifacts", symbol: "photo.on.rectangle.angled", action: #selector(actionToggleArtifacts))
        case Self.tbSidebar:
            return toolbarButton(itemIdentifier, label: "Sidebar", symbol: "sidebar.right", action: #selector(actionToggleSidebar), shortcut: "⌘B")
        case Self.tbManager:
            let item = toolbarButton(itemIdentifier, label: "Maestro", symbol: "sidebar.right", action: #selector(actionToggleManager), shortcut: "⌘⇧M")
            item.image = Self.robotToolbarImage()
            return item
        case Self.tbOpenDir:
            return openDirToolbarItem(itemIdentifier)
        case Self.tbGroup:
            return groupToolbarItem(itemIdentifier)
        case Self.tbPRs:
            return prsToolbarItem(itemIdentifier)
        case Self.tbCommit:
            return toolbarButton(itemIdentifier, label: "Commit", symbol: "checkmark.seal", action: #selector(actionCommit), shortcut: "⌥⌘C")
        case Self.tbGitHub:
            return toolbarButton(itemIdentifier, label: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", action: #selector(actionOpenGitHub), shortcut: "⌥⌘G")
        case Self.tbZoom:
            return toolbarButton(itemIdentifier, label: "Zoom", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(actionToggleZoom), shortcut: "⌘↩")
        case Self.tbKill:
            return toolbarButton(itemIdentifier, label: "Kill", symbol: "xmark.circle", action: #selector(actionKillSelected))
        default:
            return nil
        }
    }
}

// MARK: - SidebarSelectionDelegate

extension AppDelegate: SidebarSelectionDelegate {
    func sidebarDidSelectSession(_ name: String, service: TmuxService) {
        // Every attach funnels through here (sidebar click, ⌘K, create, and the ⌘`
        // cycler's own commit) — so bump this session to the front of the MRU stack
        // here and the recency order is always correct without special-casing.
        noteSessionVisited(SessionRef(name: name, host: service.host))
        // The attach lands on the session's active window — that's the window
        // you're now in, so it heads the ⌘` stack too.
        if let index = sidebarVC?.activeWindow(session: name, host: service.host) {
            noteWindowVisited(WindowRef(session: name, window: index, host: service.host))
        }

        // Re-attach when the session OR the host changes (a remote and local
        // session can share a name; the surface must point at the right host).
        let hostChanged = attachedService?.host != service.host
        guard (attachedSession != name || hostChanged),
              let command = service.attachCommand(
                  session: name, useMosh: Settings.useMosh(host: service.host))
        else {
            if attachedSession == nil { attachedSession = name; attachedService = service }
            return
        }
        // An open ⌘F search belongs to the outgoing session — end it there
        // (leaving its pane's copy-mode) before the attach state moves on.
        closeFindBar()
        attachedSession = name
        attachedService = service
        terminalVC?.swap(command: command)
    }

    func sidebarDidSelectWindow(session: String, window: Int, service: TmuxService) {
        noteWindowVisited(WindowRef(session: session, window: window, host: service.host))
        // tmux select-window is a serial shell-out (and unzoom reads back state);
        // run it off-main so a hung tmux/ssh can't freeze the UI. No AppKit here.
        // On the host's own queue so a wedged remote can't block another host's switch.
        service.driverQueue.async {
            service.selectWindow(session: session, window: window)
            DispatchQueue.main.async { [weak self] in self?.claimWindowSize() }
        }
    }

    func sidebarDidSelectPane(session: String, window: Int, pane: TmuxPane, service: TmuxService) {
        noteWindowVisited(WindowRef(session: session, window: window, host: service.host))
        service.driverQueue.async {
            service.selectPane(session: session, window: window, pane: pane.id, zoom: true)
            DispatchQueue.main.async { [weak self] in self?.claimWindowSize() }
        }
    }

    /// Make tmux size the window just selected to this client. Runs after the
    /// select lands, so the focus event arrives on the new current window.
    private func claimWindowSize() {
        terminalVC?.surfaceView?.pulseFocus()
    }

    /// A host's tree finished reloading. When the attached session lives there,
    /// record its active window: a window switch made *inside* tmux (prefix + n,
    /// a script, another client) fires no selection callback, so the poll is the
    /// only place the app can see it — and without this ⌘` would forget every
    /// switch the user made from the keyboard.
    func sidebarDidRefreshTree(host: Host) {
        dropArchivesOfEndedSessions(host: host)
        reloadPullRequestsScreen()
        refreshHandoffCommands()
        guard let session = attachedSession, attachedService?.host == host,
              let index = sidebarVC?.activeWindow(session: session, host: host)
        else { return }
        noteWindowVisited(WindowRef(session: session, window: index, host: host))
    }

    /// Record a window as the one you are on now: the front of the ⌘` stack.
    /// Every visit funnels here — sidebar clicks, attaches, the cycler's own
    /// commit, and the poll observation above — so the recency order is always
    /// right without special-casing any one path.
    private func noteWindowVisited(_ ref: WindowRef) {
        // An ⌥-hover preview passes over many windows; only the one it ends on
        // is a visit (`sidebarDidEndHoverPreview`).
        guard sidebarVC?.isHoverPreviewing != true else { return }
        guard windowMRU.first != ref else { return }
        windowMRU.removeAll { $0 == ref }
        windowMRU.insert(ref, at: 0)
        if windowMRU.count > Self.windowMRUCap {
            windowMRU.removeLast(windowMRU.count - Self.windowMRUCap)
        }
    }

    private func noteSessionVisited(_ ref: SessionRef) {
        guard sidebarVC?.isHoverPreviewing != true else { return }
        sessionMRU.removeAll { $0 == ref }
        sessionMRU.insert(ref, at: 0)
    }

    func sidebarDidEndHoverPreview(session: String, window: Int?, service: TmuxService) {
        noteSessionVisited(SessionRef(name: session, host: service.host))
        if let index = window ?? sidebarVC?.activeWindow(session: session, host: service.host) {
            noteWindowVisited(WindowRef(session: session, window: index, host: service.host))
        }
    }

    // MARK: herdr selection (M13)

    /// Attach the single libghostty surface to a herdr session via
    /// `herdr session attach <name>`. Mirrors the tmux attach path — one surface,
    /// recreated only when the attached target changes. Marks the attach as herdr
    /// so a stale tmux `attachedService` doesn't suppress a re-attach.
    func sidebarDidSelectHerdrSession(_ name: String, service: HerdrService) {
        let target = "herdr:\(name)"
        guard attachedSession != target, let command = service.attachCommand(session: name)
        else { return }
        closeFindBar()  // end an open ⌘F search on the outgoing tmux session
        attachedSession = target
        attachedService = nil  // herdr isn't a TmuxService; clear tmux attach state
        terminalVC?.swap(command: command)
    }

    func sidebarDidClickTerminalRow() {
        detailVC?.focusTerminal()
    }

    func sidebarDidChangeTitle(_ title: String?) {
        // Structural rows pass nil — keep whatever's there. Empty falls back to
        // the app name so the titlebar is never blank.
        window?.title = title ?? window?.title ?? "MuxMaestro"
    }

    func sidebarDidChangeBreadcrumb(_ crumbs: [BreadcrumbCrumb]?, service: TmuxService) {
        breadcrumbService = service
        breadcrumb.setCrumbs(crumbs ?? [])
        // Fires exactly once per selection change, for every kind of row — so the
        // Running popover follows the selection from here rather than from the three
        // kind-specific callbacks, which would run it two or three times a click.
        refreshRunning()
        refreshArtifacts()
    }

    /// Commit an inline breadcrumb rename against the current selection's service.
    /// Session renames reuse the session-rename path (updates the attached name +
    /// reselects); window/pane renames run as plain mutations that refresh the tree.
    private func performBreadcrumbRename(_ target: BreadcrumbCrumb.Rename, _ name: String) {
        guard let service = breadcrumbService else { return }
        switch target {
        case .session(let old):
            let host = service.host
            service.driverQueue.async { [weak self] in
                let renamed = service.renameSession(from: old, to: name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let renamed {
                        if self.attachedSession == old { self.attachedSession = renamed }
                        self.sidebarVC?.selectSessionWhenReady(renamed, host: host)
                    } else {
                        self.presentError("Couldn’t rename the session.")
                    }
                }
            }
        case .window(let session, let window):
            performMutation(failure: "Couldn’t rename the window.", on: service) {
                service.renameWindow(session: session, window: window, to: name) != nil
            }
        case .pane(_, _, let paneId):
            performMutation(failure: "Couldn’t rename the pane.", on: service) {
                service.setPaneTitle(paneId: paneId, to: name) != nil
            }
        }
    }
}

// MARK: - SidebarActionDelegate

extension AppDelegate: SidebarActionDelegate {
    func sidebarRequestRename(session: String, service: TmuxService) {
        promptRename(session: session, service: service)
    }
    func sidebarRequestKill(session: String, service: TmuxService) {
        confirmKill(session: session, service: service, source: .contextMenu)
    }
    func sidebarRequestNewSession(host: Host, service: TmuxService) {
        newSession(host: host, service: service)
    }

    /// A directory row's "+": same quick prompt as the local new-session flow, but
    /// rooted in that directory and pre-named after the project folder. If the
    /// directory has since been deleted, `tmux new-session -c` fails and the usual
    /// "Couldn't create the session" error fires.
    func sidebarRequestNewSession(dir: String) {
        guard let result = NewSessionPrompt.runQuick(
            window: window, defaultName: (dir as NSString).lastPathComponent,
            defaultDir: dir)
        else { return }
        createSessionInstant(
            name: result.name, dir: result.dir, launchClaude: result.launchClaude,
            host: .local, service: registry.local)
    }

    /// A Servers-section button: start a new session on `host`. Local goes
    /// straight to the prompt; a remote is probed off-main first (the sidebar
    /// shows a spinner meanwhile) so a tmux-less host opens a plain shell
    /// (clearly marked) instead of failing the tmux new-session, and a dead host
    /// gets an error instead of a doomed prompt. The probe result is reported
    /// back to the sidebar so the button reflects it (spinner off, unreachable /
    /// no-tmux marked, healthy host promoted into Active).
    func sidebarRequestLaunchSession(host: Host, service: TmuxService) {
        guard !host.isLocal else {
            newSession(host: host, service: service)
            return
        }
        // `service.driverQueue` (per-host), not the shared one — a wedged remote
        // must not head-of-line block probes for every other host.
        service.driverQueue.async { [weak self] in
            var reach = service.probeReachability()
            if reach == .reachable, !service.hasTmux() { reach = .tmuxMissing }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sidebarVC?.launchProbeFinished(host: host, reach: reach)
                switch reach {
                case .reachable:
                    self.newSession(host: host, service: service)
                case .tmuxMissing:
                    self.sidebarRequestPlainShell(host: host)
                case .unreachable, .unknown:
                    self.presentError("\(host.name) is unreachable over ssh.")
                }
            }
        }
    }

    func sidebarRequestKillWindow(session: String, window: Int, service: TmuxService) {
        // The right-click menu item was the confirm; ⌘W keeps its sheet.
        confirmCloseWindow(
            session: session, window: window, service: service, source: .contextMenu)
    }
    func sidebarRequestRenameWindow(session: String, window: Int, service: TmuxService) {
        promptRenameWindow(session: session, window: window, service: service)
    }
    func sidebarRequestNewWindow(session: String, service: TmuxService) {
        newWindow(session: session, service: service)
    }
    func sidebarRequestKillPane(
        session: String, window: Int, pane: String, service: TmuxService
    ) {
        confirmKillPane(
            session: session, window: window, pane: pane, service: service, source: .contextMenu)
    }
    func sidebarRequestSplitPane(
        session: String, window: Int, pane: String, vertical: Bool, service: TmuxService
    ) {
        splitPane(session: session, window: window, pane: pane, vertical: vertical, service: service)
    }

    // MARK: Move / merge

    func sidebarRequestMoveWindow(
        session: String, window: Int, toSession destination: String, service: TmuxService
    ) {
        moveWindow(session: session, window: window, to: destination, service: service)
    }
    func sidebarRequestMoveWindowToNewSession(
        session: String, window: Int, service: TmuxService
    ) {
        moveWindowToNewSession(session: session, window: window, service: service)
    }
    func sidebarRequestMovePane(
        session: String, window: Int, pane: String, toSession destination: String,
        service: TmuxService
    ) {
        movePane(
            session: session, window: window, pane: pane, toSession: destination,
            service: service)
    }
    func sidebarRequestMovePane(
        session: String, window: Int, pane: String, toWindow destination: Int,
        service: TmuxService
    ) {
        movePane(
            session: session, window: window, pane: pane, toWindow: destination,
            service: service)
    }
    func sidebarRequestMovePaneToNewSession(
        session: String, window: Int, pane: String, service: TmuxService
    ) {
        movePaneToNewSession(session: session, window: window, pane: pane, service: service)
    }
    func sidebarRequestMergeSession(
        session: String, windows: [Int], into destination: String, service: TmuxService
    ) {
        confirmMergeSession(
            session: session, windows: windows, into: destination, service: service)
    }

    // MARK: File drop (M11)

    func sidebarRequestDropFile(
        localPath: String, session: String, service: TmuxService
    ) {
        dropFile(localPath: localPath, session: session, service: service)
    }

    // MARK: Beam (local↔server, server→server)

    /// Serial queue for beams — a beam is long (rsync + git + Claude-history sync
    /// over ssh), so it never rides `driverQueue` (add-server ops) or the poll.
    private static let beamQueue = DispatchQueue(label: "is.rebar.muxmaestro.beam")

    /// Route a beam request by direction: local→server (takeover), server→this Mac
    /// (pull + local resume), or server→server (relay: pull to the Mac, push on).
    func sidebarRequestBeam(
        source: Host, cwd: String, paneId: String,
        claudeSessionId: String?, attention: AttentionStatus, to destination: BeamDestination
    ) {
        guard let scriptURL = BeamTransfer.bundledScriptURL() else {
            presentError("Beam isn’t available — its scripts are missing from the app bundle.")
            return
        }
        if beamInFlight {
            presentError("A beam is already in progress — let it finish first.")
            return
        }
        switch destination {
        case .server(let target) where source.isLocal:
            beamPushTakeover(target: target, localDir: cwd, paneId: paneId,
                             sessionId: claudeSessionId, attention: attention, scriptURL: scriptURL)
        case .thisMac:
            beamPullHome(source: source, remoteCwd: cwd,
                         sessionId: claudeSessionId, attention: attention, scriptURL: scriptURL)
        case .server(let target):
            beamRelay(source: source, target: target, remoteCwd: cwd,
                      sessionId: claudeSessionId, attention: attention, scriptURL: scriptURL)
        }
    }

    /// local → server: transport + stand up the remote session + respawn the pane
    /// into it (the seamless takeover). On success the pane already became the
    /// remote session, so just refresh.
    private func beamPushTakeover(
        target: Host, localDir: String, paneId: String,
        sessionId: String?, attention: AttentionStatus, scriptURL: URL
    ) {
        let req = BeamTransfer.Request(
            mode: .pushTakeover(paneId: paneId), host: target,
            localDir: localDir, claudeSessionId: sessionId)
        if let rej = BeamTransfer.reject(req, home: NSHomeDirectory()) {
            presentError(BeamTransfer.rejectionMessage(rej, host: target)); return
        }
        confirmBeam(source: .local, destName: target.name,
                    attention: attention, hasSession: sessionId != nil) { [weak self] ok in
            guard ok, let self else { return }
            let (progress, runner) = self.beginBeam(title: target.name)
            Self.beamQueue.async { [weak self] in
                let result = runner.run(req: req, scriptPath: scriptURL.path)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishBeam(progress)
                    if result.ok { self.sidebarVC?.refresh() }
                    else if !runner.didCancel {
                        self.presentError("Beam to \(target.name) failed.\n\n"
                            + Self.tailLines(result.output, 8))
                    }
                }
            }
        }
    }

    /// server → this Mac: map the remote path to its same-relative path here, pull
    /// (bootstrap or converge) repo + Claude history home, then resume the session
    /// in a LOCAL tmux and reveal it.
    private func beamPullHome(
        source: Host, remoteCwd: String,
        sessionId: String?, attention: AttentionStatus, scriptURL: URL
    ) {
        confirmBeam(source: source, destName: "this Mac",
                    attention: attention, hasSession: sessionId != nil) { [weak self] ok in
            guard ok, let self else { return }
            let (progress, runner) = self.beginBeam(title: "this Mac")
            Self.beamQueue.async { [weak self] in
                guard let self else { return }
                guard let localDir = self.mapRemoteToLocal(source: source, remoteCwd: remoteCwd) else {
                    DispatchQueue.main.async {
                        self.finishBeam(progress)
                        self.presentError("Couldn’t map \(remoteCwd) on \(source.name) to a path on this Mac.")
                    }
                    return
                }
                try? FileManager.default.createDirectory(
                    atPath: localDir, withIntermediateDirectories: true)
                let req = BeamTransfer.Request(
                    mode: .pull, host: source, localDir: localDir, claudeSessionId: sessionId)
                let result = runner.run(req: req, scriptPath: scriptURL.path)
                var revealed: String?
                if result.ok, let sid = sessionId {
                    revealed = self.registry.local.recoverSession(
                        name: (localDir as NSString).lastPathComponent,
                        dir: localDir, claudeSessionId: sid, autostart: true)
                }
                DispatchQueue.main.async {
                    self.finishBeam(progress)
                    if !result.ok {
                        if !runner.didCancel {
                            self.presentError("Beam to this Mac failed.\n\n"
                                + Self.tailLines(result.output, 8))
                        }
                        return
                    }
                    if let revealed { self.sidebarVC?.selectSessionWhenReady(revealed, host: .local) }
                    else { self.sidebarVC?.refresh() }
                }
            }
        }
    }

    /// server A → server B: relay through this Mac — pull A → Mac (transport only),
    /// then push Mac → B detached, then reveal B's session. Reuses the same runner
    /// so Cancel stops whichever leg is in flight.
    private func beamRelay(
        source: Host, target: Host, remoteCwd: String,
        sessionId: String?, attention: AttentionStatus, scriptURL: URL
    ) {
        confirmBeam(source: source, destName: target.name,
                    attention: attention, hasSession: sessionId != nil) { [weak self] ok in
            guard ok, let self else { return }
            let (progress, runner) = self.beginBeam(title: target.name)
            Self.beamQueue.async { [weak self] in
                guard let self else { return }
                guard let localDir = self.mapRemoteToLocal(source: source, remoteCwd: remoteCwd) else {
                    DispatchQueue.main.async {
                        self.finishBeam(progress)
                        self.presentError("Couldn’t map \(remoteCwd) on \(source.name) to a path on this Mac.")
                    }
                    return
                }
                try? FileManager.default.createDirectory(
                    atPath: localDir, withIntermediateDirectories: true)
                // Leg 1: pull A → Mac (transport only).
                let pull = BeamTransfer.Request(
                    mode: .pull, host: source, localDir: localDir, claudeSessionId: sessionId)
                let r1 = runner.run(req: pull, scriptPath: scriptURL.path)
                if !r1.ok {
                    DispatchQueue.main.async {
                        self.finishBeam(progress)
                        if !runner.didCancel {
                            self.presentError("Beam \(source.name) → this Mac (step 1) failed.\n\n"
                                + Self.tailLines(r1.output, 8))
                        }
                    }
                    return
                }
                // Leg 2: push Mac → B, detached (the app reveals B's session).
                let push = BeamTransfer.Request(
                    mode: .pushDetach, host: target, localDir: localDir, claudeSessionId: sessionId)
                let r2 = runner.run(req: push, scriptPath: scriptURL.path)
                let revealName = "beam-" + Self.beamEnc(rel: localDir, home: NSHomeDirectory())
                DispatchQueue.main.async {
                    self.finishBeam(progress)
                    if !r2.ok {
                        if !runner.didCancel {
                            self.presentError("Beam this Mac → \(target.name) (step 2) failed.\n\n"
                                + Self.tailLines(r2.output, 8))
                        }
                        return
                    }
                    self.sidebarVC?.selectSessionWhenReady(revealName, host: target)
                }
            }
        }
    }

    /// Map a remote project path to its same-relative path on this Mac (beam keys
    /// projects by their path relative to `$HOME`). Resolves the source's remote
    /// `$HOME` (cached ssh). nil if the path isn't under the remote home, or maps
    /// to the whole home. Runs the ssh probe — call on the beam queue.
    private func mapRemoteToLocal(source: Host, remoteCwd: String) -> String? {
        guard let remoteHome = registry.service(for: source).resolveHome() else { return nil }
        let home = remoteHome.hasSuffix("/") ? String(remoteHome.dropLast()) : remoteHome
        let cwd = remoteCwd.hasSuffix("/") ? String(remoteCwd.dropLast()) : remoteCwd
        guard cwd.hasPrefix(home + "/") else { return nil }
        let rel = String(cwd.dropFirst(home.count + 1))
        guard !rel.isEmpty else { return nil }
        return (NSHomeDirectory() as NSString).appendingPathComponent(rel)
    }

    /// beam.sh's project key: a path relative to `$HOME` with `/` and `.` → `-`.
    /// Matches `enc "$rel"` in beam.sh, used to name the `beam-<enc(rel)>` session
    /// so a relayed session can be revealed on the target.
    private static func beamEnc(rel dir: String, home: String) -> String {
        var rel = dir
        if rel.hasPrefix(home + "/") { rel = String(rel.dropFirst(home.count + 1)) }
        return rel.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Begin a beam: mark in-flight, show a cancellable progress sheet. Main-thread.
    private func beginBeam(title: String) -> (progress: BeamProgressSheet, runner: BeamRunner) {
        beamInFlight = true
        let progress = BeamProgressSheet(host: title)
        let runner = BeamRunner()
        progress.onCancel = { runner.cancel() }
        if let window { progress.begin(over: window) }
        return (progress, runner)
    }

    /// End a beam: clear in-flight and dismiss the sheet. Main-thread.
    private func finishBeam(_ progress: BeamProgressSheet) {
        beamInFlight = false
        progress.end()
    }

    /// Warn before beaming a session that's mid-response (its transcript is
    /// snapshotted as-is and the local run stopped — the in-flight reply may be
    /// lost) or waiting on a prompt (the pending decision won't carry over). Idle
    /// / non-Claude rows beam straight away. `then(true)` proceeds; `then(false)`
    /// aborts.
    private func confirmBeam(
        source: Host, destName: String, attention: AttentionStatus, hasSession: Bool,
        then: @escaping (Bool) -> Void
    ) {
        guard hasSession, attention == .busy || attention == .waiting else {
            then(true); return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if attention == .busy {
            alert.messageText = "Claude is mid-response."
            alert.informativeText = "Beaming to \(destName) now snapshots the "
                + "conversation as it is on disk and stops the running turn — the "
                + "in-flight reply may be lost. Beam anyway, or wait for it to finish?"
        } else {
            alert.messageText = "Claude is waiting on a prompt."
            alert.informativeText = "Beaming to \(destName) won’t carry the pending "
                + "decision over; it resumes from the last saved point."
        }
        alert.addButton(withTitle: "Beam anyway")
        alert.addButton(withTitle: "Cancel")
        let decide: (NSApplication.ModalResponse) -> Void = {
            then($0 == .alertFirstButtonReturn)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: decide)
        } else {
            decide(alert.runModal())
        }
    }

    /// The last `n` non-empty lines of beam's output, for a compact error message.
    private static func tailLines(_ text: String, _ n: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(n).joined(separator: "\n")
    }

    // MARK: herdr lifecycle (M13)

    /// Stop a herdr session's server (non-destructive — the session can be
    /// re-attached). Off-main, then refresh.
    func sidebarRequestStopHerdr(session: String, service: HerdrService) {
        performMutation(failure: "Couldn’t stop the herdr session.") {
            service.stopSession(name: session)
        }
    }

    /// Delete a herdr session (destructive) — gated behind a confirm sheet.
    func sidebarRequestDeleteHerdr(session: String, service: HerdrService) {
        confirmDestructive(
            title: "Delete herdr session “\(session)”?",
            info: "This removes the session from herdr.",
            confirmTitle: "Delete",
            failure: "Couldn’t delete the herdr session.",
            perform: { service.deleteSession(name: session) })
    }

    func sidebarRequestAddServer() {
        actionAddServer()
    }

    func sidebarRequestConfirmKillWindow(
        session: String, window: Int, merged: Bool, service: TmuxService
    ) {
        confirmCloseWindow(
            session: session, window: window, service: service,
            source: merged ? .mergedTrash : .keyboard)
    }

    func sidebarRequestPlainShell(host: Host) {
        guard let command = Self.remotePlainShellCommand(host: host) else { return }
        attachedSession = nil
        attachedService = nil
        window?.title = "\(host.name) — plain shell (not tmux)"
        terminalVC?.swap(command: command)
    }

    func sidebarRequestRecoverSessions() {
        actionRecoverSessions()
    }

    func sidebarRequestInstallTmux(host: Host) {
        let alert = NSAlert()
        alert.messageText = "Install tmux on \(host.name)?"
        alert.informativeText = "Runs the host's package manager over ssh (it may prompt "
            + "for your sudo password in the terminal). Sessions appear here once it finishes."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let command = Self.remoteInstallTmuxCommand(host: host) else { return }
        attachedSession = nil
        attachedService = nil
        window?.title = "\(host.name) (installing tmux…)"
        terminalVC?.swap(command: command)
    }

    func sidebarRequestEditServer(alias: String) {
        editServer(alias: alias)
    }

    /// Drops `alias`'s block from `~/.ssh/sidekick_hosts` and its per-alias
    /// settings (mosh/watch/session order). Only ever touches the managed hosts
    /// file — never the user's hand-maintained `~/.ssh/config` (menu gating
    /// already restricts this to managed aliases) — and never the remote server
    /// or any key material.
    /// WORKTREES row → Remove Worktree…. The same spindown run as the close
    /// dialog's cleanup checkbox, so it keeps a tree that holds work even if the
    /// sidebar's classification was stale.
    func sidebarRequestRemoveWorktree(entry: WorktreeEntry, work: WorktreeWork) {
        let offer = Worktrees.removeOffer(entry: entry, work: work)
        if case .refuse = offer { return }
        guard FileTransfer.python3Path != nil,
              FileManager.default.fileExists(atPath: Worktrees.spindownScriptPath)
        else {
            presentError("Couldn’t remove the worktree: python3 or spindown is missing.")
            return
        }
        let sheet = Worktrees.removeConfirm(entry: entry, offer: offer)
        let alert = NSAlert()
        alert.messageText = sheet.title
        alert.informativeText = sheet.info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let go = { [weak self] in self?.cleanUpWorktree(entry.path) }
        if let window {
            alert.beginSheetModal(for: window) { resp in
                if resp == .alertFirstButtonReturn { go() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            go()
        }
    }

    func sidebarRequestRemoveServer(alias: String) {
        confirmDestructive(
            title: "Remove “\(alias)”?",
            info: "Removes this host from ~/.ssh/sidekick_hosts (and its mosh/watch "
                + "settings). Doesn’t touch the remote server or any keys — you can "
                + "always re-add it.",
            confirmTitle: "Remove",
            failure: "Couldn’t remove the server.",
            perform: {
                let path = AddServer.managedHostsPath
                let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                let cleaned = AddServer.removingHostBlock(alias: alias, from: existing)
                guard (try? cleaned.write(toFile: path, atomically: true, encoding: .utf8))
                    != nil
                else { return false }
                Settings.clearHost(Host(name: alias, sshAlias: alias))
                return true
            },
            onSuccess: { [weak self] _ in self?.dropArchives(ofHostAlias: alias) })
    }

    func sidebarRequestInstallMosh(host: Host) {
        let alert = NSAlert()
        alert.messageText = "Install mosh on \(host.name)?"
        alert.informativeText = "Installs mosh (incl. mosh-server) via the host's package "
            + "manager over ssh (it may prompt for your sudo password in the terminal). "
            + "Needed for the roaming mosh terminal attach; ssh attach works without it."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runInstallMosh(host: host)
    }

    /// Swap the terminal to the interactive mosh-install command (no confirm —
    /// the caller already confirmed). Shared by the context-menu action and the
    /// add-server "mosh-server missing" offer.
    private func runInstallMosh(host: Host) {
        guard let command = Self.remoteInstallMoshCommand(host: host) else { return }
        attachedSession = nil
        attachedService = nil
        window?.title = "\(host.name) (installing mosh…)"
        terminalVC?.swap(command: command)
    }

    /// A plain (non-tmux) interactive ssh login shell on `host`, with a portable
    /// TERM so the remote shell is happy. nil for the local host.
    private static func remotePlainShellCommand(host: Host) -> String? {
        guard let alias = host.sshAlias else { return nil }
        // Ssh.opts already ends with the host; don't repeat it.
        let opts = Ssh.opts(host: alias).joined(separator: " ")
        let remote = "TERM=xterm-256color exec \"$SHELL\" -l"
        return "\(Ssh.sshPath) -t \(opts) \(Ssh.shellQuote(remote))"
    }

    /// Interactive ssh that auto-detects the host's package manager, installs
    /// tmux, then drops into a login shell. `-t` gives a PTY so sudo can prompt.
    private static func remoteInstallTmuxCommand(host: Host) -> String? {
        guard let alias = host.sshAlias else { return nil }
        let opts = Ssh.opts(host: alias).joined(separator: " ")
        let install = [
            "TERM=xterm-256color",
            "if command -v brew >/dev/null 2>&1; then brew install tmux;",
            "elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y tmux;",
            "elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y tmux;",
            "elif command -v yum >/dev/null 2>&1; then sudo yum install -y tmux;",
            "elif command -v pacman >/dev/null 2>&1; then sudo pacman -S --noconfirm tmux;",
            "elif command -v apk >/dev/null 2>&1; then sudo apk add tmux;",
            "else echo 'No supported package manager found.'; fi;",
            "exec \"$SHELL\" -l",
        ].joined(separator: " ")
        return "\(Ssh.sshPath) -t \(opts) \(Ssh.shellQuote(install))"
    }

    /// Interactive ssh that installs mosh (incl. `mosh-server`) via the host's
    /// package manager, then drops into a login shell. Skips the install when
    /// mosh-server is already present. `-t` gives a PTY so sudo can prompt.
    private static func remoteInstallMoshCommand(host: Host) -> String? {
        guard let alias = host.sshAlias else { return nil }
        let opts = Ssh.opts(host: alias).joined(separator: " ")
        let install = [
            "TERM=xterm-256color",
            "if command -v mosh-server >/dev/null 2>&1; then echo 'mosh-server already installed.';",
            "elif command -v brew >/dev/null 2>&1; then brew install mosh;",
            "elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y mosh;",
            "elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y mosh;",
            "elif command -v yum >/dev/null 2>&1; then sudo yum install -y mosh;",
            "elif command -v pacman >/dev/null 2>&1; then sudo pacman -S --noconfirm mosh;",
            "elif command -v apk >/dev/null 2>&1; then sudo apk add mosh;",
            "else echo 'No supported package manager found.'; fi;",
            "exec \"$SHELL\" -l",
        ].joined(separator: " ")
        return "\(Ssh.sshPath) -t \(opts) \(Ssh.shellQuote(install))"
    }
}

// MARK: - DiffPaneDelegate (M14 — Refresh button)

extension AppDelegate: DiffPaneDelegate {
    /// The Diff pane's Refresh button — recompute for the currently selected
    /// session without re-revealing the (already visible) pane.
    func diffPaneDidRequestRefresh() {
        refreshDiff(reveal: false)
    }
}

// MARK: - RunningPaneDelegate (the Running drawer)

extension AppDelegate: RunningPaneDelegate {
    func runningPaneDidRequestRefresh() {
        // Force the cadence: the button means "ask now", not "ask when due".
        sidebarVC?.refreshRunning(force: true)
    }

    /// The primary verb: put the terminal on the pane this port or container came
    /// from. Unclaimed rows have nowhere to go and never reach here.
    func runningPaneDidSelect(_ resource: RunningResource) {
        guard let paneID = resource.paneID,
              let host = sidebarVC?.host(named: resource.host) else { return }
        sidebarVC?.selectPane(id: paneID, host: host)
    }

    /// Open the real browser, not an embedded web view: Chrome already has the
    /// session cookies, the devtools and the tabs, and a `WKWebView` would render
    /// the login page of every authed app.
    func runningPaneDidRequestOpen(_ resource: RunningResource) {
        guard let address = resource.url, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    func runningPaneDidRequestOpenLink(_ link: RunningLink) {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Stop, behind a confirm that lays out the evidence — host, every container
    /// it is about to stop, the ports, how long they have been up, and whether
    /// any session claims them. "Unclaimed" is not proof of abandonment: a
    /// detached script has no session anywhere, so a person decides.
    func runningPaneDidRequestStop(_ resource: RunningResource) {
        guard let sidebar = sidebarVC, let service = sidebar.service(hostNamed: resource.host)
        else { return }
        let targets = Running.stopTargets(for: resource, scans: sidebar.runningScanList)
        let confirm = Running.stopConfirm(
            for: resource, targets: targets,
            knownHosts: sidebar.runningScanList.map(\.host).sorted())

        switch resource.kind {
        case .container:
            guard !targets.isEmpty else { return }
            let names = targets.map(\.name)
            confirmDestructive(
                title: confirm.title, info: confirm.body, confirmTitle: "Stop",
                failure: "Couldn’t stop that container.", on: service,
                perform: { service.stopContainers(names).ok })
        case .server:
            guard let pid = resource.pid else { return }
            confirmDestructive(
                title: confirm.title, info: confirm.body, confirmTitle: "Stop",
                failure: "Couldn’t stop that server.", on: service,
                perform: { service.interrupt(pid: pid) })
        }
    }
}

// MARK: - TreePaneDelegate (Tree panel — search / list / preview / open)

extension AppDelegate: TreePaneDelegate {
    func treePaneDidRequestRefresh() {
        refreshTreePanel()
    }

    func treePaneDidChangeQuery(_ query: String, scope: TreeSearchScope) {
        runTreeSearch(query: query)
    }

    /// A pane hit was clicked: attach that pane's session, select the window and
    /// the pane, then open the find bar on the same needle and run the tmux
    /// copy-mode search — so the pane arrives scrolled to the line that was
    /// clicked, with the usual ⏎ / ⇧⏎ stepping and Esc to leave.
    func treePaneDidActivatePane(_ pane: PaneSearchTarget, needle: String) {
        let service = registry.service(for: pane.host)
        sidebarDidSelectSession(pane.session, service: service)
        sidebarVC?.selectSession(pane.session, host: pane.host)
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { detailVC?.showFindBar(needle: trimmed) }
        // One block on the host's queue keeps the order: select, then search in
        // the pane that is now active.
        service.driverQueue.async { [weak self] in
            service.selectWindow(session: pane.session, window: pane.window)
            service.selectPane(
                session: pane.session, window: pane.window, pane: pane.paneId, zoom: false)
            guard !trimmed.isEmpty else { return }
            let label = service.searchInPane(session: pane.session, needle: trimmed)
            DispatchQueue.main.async { self?.detailVC?.findBar.setCount(label) }
        }
    }

    /// Load a selected file/line into the preview. Reuses the cached content when
    /// the same file is re-selected (e.g. a different match line), only reading
    /// over the host when the file changes.
    func treePaneDidRequestPreview(file relativePath: String, line: Int?) {
        guard let service = treeService, !treeCwd.isEmpty else { return }
        let absPath = GitDiff.joinPath(cwd: treeCwd, relative: relativePath)
        let filename = (relativePath as NSString).lastPathComponent
        if absPath == previewPath {
            treeVC?.showPreview(content: previewContent, filename: filename, line: line)
            return
        }
        service.driverQueue.async { [weak self] in
            let content = service.readFile(path: absPath)
            DispatchQueue.main.async {
                guard let self else { return }
                if let content {
                    self.previewPath = absPath
                    self.previewContent = content
                    self.treeVC?.showPreview(content: content, filename: filename, line: line)
                } else {
                    self.treeVC?.previewMessage("Couldn’t read \(filename)")
                }
            }
        }
    }

    /// Open a file row in the editor — at `line` for a match row, at the top
    /// otherwise. `relativePath` is repo-relative; join it onto the cached cwd.
    func treePaneDidActivate(file relativePath: String, line: Int?) {
        guard let editor = defaultEditor, let host = treeService?.host,
              !treeCwd.isEmpty else { return }
        let absPath = GitDiff.joinPath(cwd: treeCwd, relative: relativePath)
        open(file: absPath, line: line, host: host, in: editor)
    }

    /// Open a file in the OS-default app for its type (Preview for png/pdf, the
    /// browser for html, Excel for xlsx, …). Local sessions only — the TreeVC
    /// only offers this when the host is local, so the file is readable here.
    func treePaneDidOpenInDefaultApp(file relativePath: String) {
        guard let host = treeService?.host, host.isLocal, !treeCwd.isEmpty else { return }
        let absPath = GitDiff.joinPath(cwd: treeCwd, relative: relativePath)
        NSWorkspace.shared.open(URL(fileURLWithPath: absPath))
    }
}

// MARK: - ArtifactsPaneDelegate (double-click → open)

extension AppDelegate: ArtifactsPaneDelegate {
    /// Text and code open in the default editor; everything else (images, PDFs,
    /// HTML reports) in the OS-default app for its type.
    func artifactsPaneDidActivate(_ artifact: Artifact) {
        let type = UTType(filenameExtension: (artifact.path as NSString).pathExtension)
        let isText = type.map { $0.conforms(to: .text) && !$0.conforms(to: .html) } ?? false
        if isText, let editor = defaultEditor {
            open(file: artifact.path, line: nil, host: .local, in: editor)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: artifact.path))
        }
    }

    /// Servers and links open in the real browser, for the reason given on
    /// `runningPaneDidRequestOpen`: it has the session cookies.
    func artifactsPaneDidOpenURL(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

// MARK: - FilePaletteDelegate (⌘P quick-open → open file)

extension AppDelegate: FilePaletteDelegate {
    /// Open the picked file at its top in the default editor. `relativePath` is
    /// repo-relative; join it onto the cached quick-open cwd.
    func filePaletteDidActivate(relativePath: String) {
        guard let editor = defaultEditor, let host = quickOpenService?.host,
              !quickOpenCwd.isEmpty else { return }
        let absPath = GitDiff.joinPath(cwd: quickOpenCwd, relative: relativePath)
        open(file: absPath, line: nil, host: host, in: editor)
    }
}

// MARK: - SessionPaletteDelegate (⌘K switcher → attach)

extension AppDelegate: SessionPaletteDelegate {
    /// Attach the terminal to the picked session, switch to the picked window or
    /// pane, and highlight its sidebar row — mirroring a click on that row.
    /// A scrollback hit: the same jump as a pane hit in ⇧⌘F — attach, select the
    /// pane, and open the find bar on the query so the pane lands on the line.
    func sessionPaletteDidActivateScrollback(_ hit: PaneMatch, needle: String) {
        treePaneDidActivatePane(hit.pane, needle: needle)
    }

    func sessionPaletteDidActivate(_ entry: SwitcherEntry, service: TmuxService) {
        sidebarDidSelectSession(entry.session, service: service)
        switch entry.target {
        case .session:
            sidebarVC?.selectSession(entry.session, host: entry.host)
        case .window(let index):
            sidebarDidSelectWindow(session: entry.session, window: index, service: service)
            sidebarVC?.selectWindow(index, session: entry.session, host: entry.host)
        case .pane(let window, let pane):
            sidebarDidSelectPane(session: entry.session, window: window, pane: pane, service: service)
            sidebarVC?.selectPane(id: pane.id, host: entry.host)
        }
    }

    /// No session matched what was typed → create a new local tmux session by that
    /// name (at home) and attach, reusing the instant-create flow. Sanitizes for
    /// tmux, which forbids "." and ":" (and whitespace) in session names.
    func sessionPaletteDidRequestNewSession(name: String) {
        let clean = name
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        guard !clean.isEmpty else { return }
        createSessionInstant(
            name: clean, dir: NSHomeDirectory(), launchClaude: false,
            host: .local, service: registry.local)
    }
}

// MARK: - CommitPanelDelegate (⌥⌘C stage → commit → push → PR)

extension AppDelegate: CommitPanelDelegate {
    func commitPanel(_ vc: CommitPanelViewController, toggleStage path: String, staged: Bool) {
        guard let service = commitService, !commitCwd.isEmpty else { return }
        let cwd = commitCwd
        vc.setBusy(true)
        service.driverQueue.async { [weak self] in
            if staged { service.stage(cwd: cwd, path: path) }
            else { service.unstage(cwd: cwd, path: path) }
            let files = service.changedFiles(cwd: cwd)
            DispatchQueue.main.async {
                guard let self, self.commitPanelVC === vc else { return }
                vc.setBusy(false)
                vc.setFiles(files)
                let staged = files.filter(\.staged).count
                vc.setStatus("\(files.count) changed · \(staged) staged")
            }
        }
    }

    func commitPanelReload(_ vc: CommitPanelViewController) {
        guard let service = commitService else { return }
        // Re-resolve from the bound session by reloading via cwd we already have.
        let cwd = commitCwd
        guard !cwd.isEmpty else { return }
        service.driverQueue.async { [weak self] in
            let files = service.changedFiles(cwd: cwd)
            DispatchQueue.main.async {
                guard let self, self.commitPanelVC === vc else { return }
                vc.setFiles(files)
            }
        }
    }

    /// The full flow: commit the staged index, push (setting upstream if needed),
    /// then open a PR. Each step reports success/failure; a failed step stops the
    /// chain and shows the git/gh error text.
    func commitPanel(_ vc: CommitPanelViewController, submitSubject subject: String, body: String) {
        guard let service = commitService, !commitCwd.isEmpty else { return }
        let cwd = commitCwd
        vc.setBusy(true)
        vc.setStatus("Committing…")
        service.driverQueue.async { [weak self] in
            let commit = service.commit(cwd: cwd, subject: subject, body: body)
            guard commit.ok else {
                self?.finishCommit(vc, ok: false, status: "Commit failed: \(Self.firstLine(commit.text))")
                return
            }
            DispatchQueue.main.async { vc.setStatus("Pushing…") }
            let push = service.push(cwd: cwd)
            guard push.ok else {
                self?.finishCommit(vc, ok: false,
                    status: "Committed, but push failed: \(Self.firstLine(push.text))")
                return
            }
            DispatchQueue.main.async { vc.setStatus("Opening PR…") }
            let pr = service.createPullRequest(cwd: cwd, title: subject, body: body)
            // gh fails when a PR already exists — that's fine (pushed anyway).
            if pr.ok, let url = Self.firstURL(in: pr.text) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                self?.finishCommit(vc, ok: true, status: "Done ✓ — opened \(url.lastPathComponent)")
            } else if pr.text.lowercased().contains("already exists") {
                self?.finishCommit(vc, ok: true, status: "Committed & pushed ✓ — PR already open")
            } else {
                self?.finishCommit(vc, ok: true,
                    status: "Committed & pushed ✓ — PR step: \(Self.firstLine(pr.text))")
            }
        }
    }

    /// Land a flow result on main: stop the spinner, refresh the file list, and set
    /// the status line. On full success the tree is clean so the list empties.
    private func finishCommit(_ vc: CommitPanelViewController, ok: Bool, status: String) {
        let service = commitService
        let cwd = commitCwd
        let files = (service != nil && !cwd.isEmpty) ? service!.changedFiles(cwd: cwd) : []
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commitPanelVC === vc else { return }
            vc.setBusy(false)
            vc.setFiles(files)
            vc.setStatus(status, error: !ok)
            if ok { self.sidebarVC?.refreshPullRequests(force: true) }
        }
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n").first.map(String.init) ?? s
    }
    private static func firstURL(in s: String) -> URL? {
        for token in s.split(whereSeparator: { $0.isWhitespace }) {
            if token.hasPrefix("https://"), let u = URL(string: String(token)) { return u }
        }
        return nil
    }
}

// MARK: - Archive Window / Undo

extension AppDelegate {
    /// A window was archived. Keep what undo needs, put Undo Archive Window on
    /// the Edit menu, and offer the same undo in a toast.
    ///
    /// `worktree` is the worktree the close flow would clean up. It stays until
    /// the archive leaves the undo history (pushed out by newer archives, dropped,
    /// or the app quits): undo needs the directory for as long as it is offered.
    ///
    /// `archived` is nil when the window could not be read before the kill. Then
    /// nothing can be undone: the toast says so and the worktree is cleaned up now.
    ///
    /// ⌘Z reaches the undo even while the terminal has focus: the terminal view
    /// does not answer `undo:`, so the window does, and Edit > Undo is enabled
    /// while an archive is on its undo stack. With nothing to undo the item is
    /// disabled and ⌘Z goes to the terminal as a key press, as before. A text
    /// field's own edits sit above the archive on the stack and are undone first.
    private func didArchive(_ archived: ArchivedWindow?, service: TmuxService, worktree: String?) {
        guard let archived else {
            if let worktree { cleanUpWorktree(worktree) }
            if let window {
                toast.show(
                    over: window, glyph: "🗃", title: "Archived window",
                    text: WindowArchive.notUndoableNote)
            }
            return
        }
        registerArchiveUndo(archiveHistory.push(archived, worktree: worktree), service: service)
        savePendingCleanups()
        showArchivedToast(archived)
    }

    private func registerArchiveUndo(_ entry: WindowArchiveHistory.Entry, service: TmuxService) {
        guard let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: entry) { [weak self] entry in
            self?.undoArchive(entry, service: service)
        }
        undoManager.setActionName(WindowArchive.actionName)
    }

    private func showArchivedToast(_ archived: ArchivedWindow) {
        guard let window else { return }
        toast.show(
            over: window, glyph: "🗃", title: WindowArchive.archivedTitle(archived), text: "",
            actionTitle: "Undo"
        ) { [weak self] in
            // Only when the archive is still what Edit > Undo would undo.
            guard let undoManager = self?.window?.undoManager, undoManager.canUndo,
                  undoManager.undoActionName == WindowArchive.actionName else { return }
            undoManager.undo()
        }
    }

    /// Edit > Undo Archive Window: create the window again, resume its agents and
    /// select its row. Runs inside the undo, so the registration below is the redo.
    private func undoArchive(_ entry: WindowArchiveHistory.Entry, service: TmuxService) {
        if let undoManager = window?.undoManager {
            undoManager.registerUndo(withTarget: entry) { [weak self] entry in
                self?.redoArchive(entry, service: service)
            }
            undoManager.setActionName(WindowArchive.actionName)
        }
        toast.hide()
        service.driverQueue.async { [weak self] in
            let archived = entry.archived
            let result = service.restoreArchivedWindow(archived)
            if case .success(let restored) = result { entry.restoredIndex = restored.index }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let restored):
                    entry.isArchived = false
                    self.savePendingCleanups()
                    self.focusNew(
                        session: archived.session, window: restored.index, pane: nil,
                        service: service)
                    if let window = self.window {
                        self.toast.show(
                            over: window, glyph: "🗃",
                            title: WindowArchive.restoredTitle(archived),
                            text: WindowArchive.restoredNote(restored))
                    }
                case .failure(let failure):
                    // Nothing came back, so there is nothing to redo.
                    self.window?.undoManager?.removeAllActions(withTarget: entry)
                    if failure.isRetryable {
                        // An ssh timeout or a busy tmux: the undo goes back on the
                        // stack, so ⌘Z tries again.
                        self.registerArchiveUndo(entry, service: service)
                    } else {
                        self.archiveHistory.remove(entry)
                    }
                    self.presentError(WindowArchive.failureMessage(archived, failure))
                }
            }
        }
    }

    /// Edit > Redo Archive Window: archive the restored window again. No confirm
    /// sheet: the archive was confirmed the first time.
    private func redoArchive(_ entry: WindowArchiveHistory.Entry, service: TmuxService) {
        registerArchiveUndo(entry, service: service)
        service.driverQueue.async { [weak self] in
            let before = entry.archived
            guard let index = entry.restoredIndex else { return }
            // Only the window undo made: an index can belong to another window by now.
            let result = service.archiveWindow(
                session: before.session, window: index, onlyIfNamed: before.name)
            if let again = result.archived { entry.archived = again }
            if result.killed { entry.restoredIndex = nil }
            DispatchQueue.main.async {
                guard let self else { return }
                guard result.killed else {
                    // The window is still there, so the entry has nothing to undo.
                    self.archiveHistory.remove(entry)
                    self.presentError("Couldn’t archive the window.")
                    return
                }
                entry.isArchived = true
                if let again = result.archived { entry.adopt(again) }
                self.savePendingCleanups()
                self.sidebarVC?.refresh()
                self.showArchivedToast(result.archived ?? before)
            }
        }
    }

    /// A host's tree reloaded: drop its archives whose session is no longer there.
    func dropArchivesOfEndedSessions(host: Host) {
        guard !archiveHistory.entries.isEmpty, let sidebarVC else { return }
        archiveHistory.dropEndedSessions(
            host: host, live: Set(sidebarVC.cachedSessions(host: host).map(\.name)))
    }

    func dropArchives(ofHostAlias alias: String) {
        archiveHistory.dropHost(alias: alias)
    }

    /// Keep the list of waiting worktree cleanups on disk, so a crash or a kill
    /// (`make install` stops the app with a signal) does not forget them.
    private func savePendingCleanups() {
        PendingWorktreeCleanups.save(archiveHistory.pendingWorktrees)
    }

    /// At launch: cleanups a previous run was killed before it could do. They are
    /// offered, never run unasked: those archives can no longer be undone, but
    /// the choice to delete a worktree was made in another run.
    func offerPendingWorktreeCleanups() {
        // A second instance must not take the list the first one is still using.
        let instances = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).count
        } ?? 1
        let pending = PendingWorktreeCleanups.load().filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard instances <= 1 else { return }
        PendingWorktreeCleanups.save([])
        guard !pending.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = PendingWorktreeCleanups.offerTitle(pending)
        alert.informativeText = pending.joined(separator: "\n")
        alert.addButton(withTitle: "Clean Up")
        alert.addButton(withTitle: "Keep")
        let go = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            pending.forEach { self?.cleanUpWorktreeUnlessInUse($0) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: go) }
        else { go(alert.runModal()) }
    }

    /// A deferred worktree cleanup, now due. Skipped when a pane sits in the
    /// worktree again (an undone archive, or a window opened there since).
    private func cleanUpWorktreeUnlessInUse(_ worktree: String) {
        guard !worktreeIsInUse(worktree) else { return }
        cleanUpWorktree(worktree)
    }

    private func worktreeIsInUse(_ worktree: String) -> Bool {
        (sidebarVC?.cachedSessions(host: .local) ?? []).contains { session in
            session.windows.contains { window in
                window.panes.contains { Worktrees.isInside(path: $0.path, root: worktree) }
            }
        }
    }

    /// Quitting ends every undo offer, so the deferred cleanups run now. spindown
    /// can take minutes; it is started on its own and not waited for.
    func finishArchivesAtQuit() {
        // Without python nothing can run: the list stays on disk for the next launch.
        guard let python = FileTransfer.python3Path else { return }
        let path = NSHomeDirectory() + "/go/bin:"
            + (ProcessCommandRunner.childEnvironment["PATH"] ?? "")
        let due = archiveHistory.drain()
        savePendingCleanups()
        for worktree in due where !worktreeIsInUse(worktree) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["PATH=\(path)"] + Worktrees.spindownArgv(
                python: python, script: Worktrees.spindownScriptPath, worktree: worktree)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}

// MARK: - Archive Window self-test

extension AppDelegate {
    /// Archive Window end to end in the real app: the row button, the archive,
    /// the toast, Edit > Undo and Redo, and the row selected again. Run it through
    /// `scripts/archive-selftest.sh`, which builds the `acme-app` fixture on a
    /// private tmux server; it refuses any other socket because it kills a window.
    /// `SIDEKICK_ARCHIVE_SHOTS` names a directory for PNGs of each step.
    private func runArchiveSelfTest() {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "archive self-test")
        let service = registry.local
        let session = "acme-app", name = "api"
        let shots = ProcessInfo.processInfo.environment["SIDEKICK_ARCHIVE_SHOTS"]
        var lines = ["ARCHIVE SELFTEST"]
        var ok = true
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            ok = ok && passed
            lines.append("  \(passed ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  \(detail)")")
        }
        func finish() -> Never {
            print(lines.joined(separator: "\n"))
            ProcessInfo.processInfo.endActivity(activity)
            exit(ok ? 0 : 1)
        }
        func shot(_ view: NSView?, _ file: String) {
            guard let shots, let view,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: shots).appendingPathComponent(file))
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func outline() -> NSOutlineView? {
            window?.contentView.flatMap(all)?.first { $0 is NSOutlineView } as? NSOutlineView
        }
        /// The sidebar row of the fixture window, and its tmux index.
        func row() -> (row: Int, index: Int)? {
            guard let outline = outline() else { return nil }
            for row in 0..<outline.numberOfRows {
                if case .window(_, session, let w)? = (outline.item(atRow: row) as? SidebarNode)?.kind,
                   w.name == name { return (row, w.index) }
            }
            return nil
        }
        /// The fixture window as tmux has it now; nil once archived.
        func live() -> TmuxWindow? {
            service.loadTree()?.first { $0.name == session }?.windows.first { $0.name == name }
        }
        func after(_ seconds: TimeInterval, _ step: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: step)
        }
        func editItem(_ index: Int) -> NSMenuItem? {
            // A self-test launched from a shell is never the active app, so the
            // menu has no key window to validate against: ask the window, which
            // is what AppKit does for Undo and Redo when it is key.
            guard let item = Self.editMenu?.item(at: index) else { return nil }
            item.isEnabled = window?.validateMenuItem(item) ?? false
            return item
        }

        /// The first poll can take a while on a busy machine: wait for the row.
        func whenFixtureShows(_ tries: Int, _ step: @escaping () -> Void) {
            if row() != nil || tries == 0 { return step() }
            after(1) { whenFixtureShows(tries - 1, step) }
        }

        after(3) { whenFixtureShows(30) { [weak self] in
            guard let self else { return }
            guard (service.socketPath() ?? "").contains("muxmaestro-archive-selftest") else {
                lines.append("  FAIL  not a scratch socket. Run via scripts/archive-selftest.sh.")
                ok = false
                finish()
            }
            guard let found = row(), let before = live(),
                  let cell = outline()?.view(atColumn: 0, row: found.row, makeIfNecessary: true)
                    as? RowCell
            else {
                check("fixture window is in the sidebar", false)
                finish()
            }
            cell.isRowHovered = true
            // ⌘Z with the terminal focused, which is where focus nearly always is.
            let surface = self.terminalVC?.surfaceView
            self.window?.makeFirstResponder(surface)
            let commandZ = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: self.window?.windowNumber ?? 0, context: nil, characters: "z",
                charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)
            /// Who gets ⌘Z now: "menu" when Edit > Undo is enabled and the window
            /// answers it from the terminal's responder chain, else "terminal" (a
            /// disabled item claims no key, so AppKit sends the terminal a keyDown).
            func commandZTarget() -> String {
                guard let surface, self.window?.firstResponder === surface,
                      let commandZ, !surface.performKeyEquivalent(with: commandZ)
                else { return "terminal view took the key equivalent" }
                var responder: NSResponder? = surface
                while let next = responder, !next.responds(to: Selector(("undo:"))) {
                    responder = next.nextResponder
                }
                guard responder === self.window else { return "undo: answered by \(String(describing: responder))" }
                return editItem(0)?.isEnabled == true ? "menu" : "terminal"
            }
            check("⌘Z goes to the terminal when there is nothing to undo",
                  commandZTarget() == "terminal", commandZTarget())
            check("row button says Archive Window", cell.trashButton.toolTip == "Archive Window"
                && cell.trashButton.image?.accessibilityDescription == "Archive Window")
            check("nothing to undo yet", editItem(0)?.isEnabled == false)
            shot(self.sidebarVC?.view, "1-row.png")

            // The right-click Archive Window: the same archive, with no sheet to answer.
            self.sidebarRequestKillWindow(session: session, window: found.index, service: service)
            after(3) {
                check("window is archived", live() == nil)
                check("the archive is in the undo history",
                      self.archiveHistory.entries.count == 1
                        && self.archiveHistory.entries.first?.isArchived == true)
                check("Edit menu offers the undo",
                      editItem(0)?.title == "Undo Archive Window" && editItem(0)?.isEnabled == true,
                      editItem(0)?.title ?? "")
                check("⌘Z undoes the archive while the terminal has focus",
                      commandZTarget() == "menu", commandZTarget())
                shot(self.toast.view, "2-toast.png")
                do {
                    self.window?.undoManager?.undo()
                    after(6) {
                        let restored = live()
                        check("undo brings the window back", restored?.index == before.index,
                              "index \(restored?.index ?? -1)")
                        check("with its panes in their directories",
                              restored?.panes.map(\.path) == before.panes.map(\.path))
                        check("its row is selected", row()?.row == outline()?.selectedRow)
                        check("the history knows the window is back",
                              self.archiveHistory.entries.first?.isArchived == false
                                && self.archiveHistory.pendingWorktrees.isEmpty)
                        check("Edit menu offers the redo",
                              editItem(1)?.title == "Redo Archive Window" && editItem(1)?.isEnabled == true,
                              editItem(1)?.title ?? "")
                        shot(self.toast.view, "4-restored-toast.png")
                        shot(self.sidebarVC?.view, "5-restored-row.png")
                        self.window?.undoManager?.redo()
                        after(3) {
                            check("redo archives it again", live() == nil)
                            check("the history knows it is archived again",
                                  self.archiveHistory.entries.first?.isArchived == true)
                            check("and it can be undone again",
                                  editItem(0)?.title == "Undo Archive Window")
                            finish()
                        }
                    }
                }
            }
        } }
    }

    private static var editMenu: NSMenu? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
    }
}
