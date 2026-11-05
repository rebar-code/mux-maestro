import Cocoa

/// The 🤖 Manager rail: a far-right collapsible column that IS the manager view.
/// Two cards. One lists the agent's read of the fleet (what needs you, what the
/// agents have been doing, what they said), or the request list in its place;
/// the other is the chat with the `mux-manager` pane, read from its transcript
/// the way the phone reads it. The cards stack or sit side by side, and the
/// divider between them drags.
///
/// The pane's terminal lives behind the chat header's toggle. It is installed
/// once (lazily, on first reveal) and never torn down, so the agent's scrollback
/// survives every toggle and every collapse of the rail.
final class ManagerRailViewController: NSViewController, NSSplitViewDelegate {
    private let split = RailSplitView()
    private let listScroll = NSScrollView()
    private let sections = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing needs you")
    /// The list card's header: the board, or the request list in its place.
    private let listSwitch = NSSegmentedControl(
        labels: ["Board", "Requests"], trackingMode: .selectOne, target: nil, action: nil)
    private let requestList = RequestListView()
    private let chat = ChatTranscriptView()
    private let terminalHost = NSView()
    private let terminalToggle = NSButton()
    private let layoutToggle = NSButton()
    private let input = ChatComposer()

    /// The header's push-to-talk slot and the button in it.
    let talkButtonSlot = NSView()
    private let talkButton = NSButton()
    /// Spins around the talk button while a take is transcribing or replying.
    private let talkSpinner = NSProgressIndicator()

    private var snapshot = ManagerSnapshot.empty
    /// The prompt of the turn in flight, so a refused or unreachable turn can
    /// hand it back to the input instead of making the human retype it.
    private var pendingPrompt = ""
    /// Whether the saved divider position has been applied. It needs real
    /// bounds, which the rail only has once it is shown and laid out.
    private var positionApplied = false

    /// Whether the list card shows the request list rather than the board.
    private(set) var showsRequests = false

    /// The request list's file. The AppDelegate hands over the one in the
    /// agent's home.
    var requests: RequestTracker? {
        get { requestList.tracker }
        set { requestList.tracker = newValue }
    }

    /// The terminal, once installed. Owned here so collapse/expand never tears
    /// down the surface; the AppDelegate swaps its attach command on restart.
    private(set) var terminal: TerminalViewController?

    /// Whether the chat card is showing the terminal rather than the messages.
    /// The AppDelegate reads it to decide when the surface is worth building.
    private(set) var isTerminalShown = false

    /// Tick a checkbox → dismiss that review key (writes dismissed=1 to the DB).
    var onDismiss: ((String) -> Void)?
    /// Click a review row that points nowhere → open the session behind it.
    var onOpen: ((ManagerReviewItem) -> Void)?
    /// Click a row, or a `muxmaestro://` link inside one → open what it points at.
    var onOpenLink: ((ThreadLink) -> Void)?
    /// Approve on a keygate row: the request id, already checked, and what to
    /// call on the main thread when keygate is done (or did not start).
    var onApproveKeygate: ((String, @escaping () -> Void) -> Void)?
    /// Whether keygate passes its binary check. A seam for the click self-test,
    /// which has no keygate to check.
    static var keygateTrusted: () -> Bool = { Keygate.binaryIsTrusted() }
    /// The header's restart button — kill + recreate the manager session.
    var onRestart: (() -> Void)?
    /// ⏎ in the input: send this text to the manager pane.
    var onSend: ((String) -> Void)?
    /// Where the chat reads the Maestro's transcript, spinner and prompt.
    var chatSource: ChatSource? {
        get { chat.source }
        set { chat.source = newValue }
    }
    /// The talk button: start, send, or stop a voice take.
    var onTalk: (() -> Void)?
    /// The terminal is being shown for the first time; install the surface now.
    var onShowTerminal: (() -> Void)?

    /// The list card's height when stacked, until the divider is dragged.
    private static let defaultListHeight: CGFloat = 400
    /// Neither card can be dragged smaller than this.
    private static let minCardSize: CGFloat = 120

    override func loadView() {
        split.isVertical = Settings.managerRailSideBySide()
        split.delegate = self
        split.addArrangedSubview(buildListCard())
        split.addArrangedSubview(buildChatCard())
        split.translatesAutoresizingMaskIntoConstraints = false
        updateLayoutToggle()
        showRequests(Settings.managerRailShowsRequests())

        // A full-height hairline on the leading edge separates the rail from the
        // main terminal; the cards sit inset from it.
        let container = NSView()
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = SidebarPalette.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(divider)
        container.addSubview(split)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // Pin the top below the titlebar (fullSizeContentView).
            split.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 10),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            split.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        self.view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !positionApplied, split.bounds.width > 1, split.bounds.height > 1 else { return }
        positionApplied = true
        applyListSize()
    }

    // MARK: Build

    private static func makeCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = SidebarPalette.border.cgColor
        card.layer?.backgroundColor = SidebarPalette.managerSurface.cgColor
        card.layer?.masksToBounds = true
        return card
    }

    private func buildListCard() -> NSView {
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 2
        sections.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        sections.translatesAutoresizingMaskIntoConstraints = false

        listScroll.documentView = sections
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = SidebarPalette.muted
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        listSwitch.segmentStyle = .roundRect
        listSwitch.controlSize = .small
        listSwitch.font = .systemFont(ofSize: 11)
        listSwitch.target = self
        listSwitch.action = #selector(listSwitched)
        listSwitch.translatesAutoresizingMaskIntoConstraints = false

        let card = Self.makeCard()
        card.addSubview(listSwitch)
        card.addSubview(listScroll)
        card.addSubview(requestList)
        card.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            sections.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            sections.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            sections.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),

            listSwitch.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            listSwitch.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),

            listScroll.topAnchor.constraint(equalTo: listSwitch.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            // The request list takes the board's place, under the same header.
            requestList.topAnchor.constraint(equalTo: listSwitch.bottomAnchor, constant: 8),
            requestList.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            requestList.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            requestList.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func buildChatCard() -> NSView {
        let header = buildHeader()
        let content = buildChatContent()
        buildInput()

        let card = Self.makeCard()
        for child in [header, content, input] {
            child.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 22),

            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),

            input.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            input.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            input.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    private func buildHeader() -> NSView {
        let header = NSView()
        let title = NSTextField(labelWithString: "MAESTRO")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = SidebarPalette.muted

        layoutToggle.isBordered = false
        layoutToggle.bezelStyle = .regularSquare
        layoutToggle.contentTintColor = SidebarPalette.muted
        layoutToggle.target = self
        layoutToggle.action = #selector(layoutToggled)

        terminalToggle.image = NSImage(
            systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        terminalToggle.setButtonType(.pushOnPushOff)
        terminalToggle.isBordered = false
        terminalToggle.bezelStyle = .regularSquare
        terminalToggle.toolTip = "Terminal"
        terminalToggle.contentTintColor = SidebarPalette.muted
        terminalToggle.target = self
        terminalToggle.action = #selector(terminalToggled)

        let restart = NSButton()
        restart.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "Restart Maestro agent")
        restart.isBordered = false
        restart.bezelStyle = .regularSquare
        restart.toolTip = "Restart Maestro agent"
        restart.contentTintColor = SidebarPalette.muted
        restart.target = self
        restart.action = #selector(restartClicked)

        talkButton.isBordered = false
        talkButton.bezelStyle = .regularSquare
        talkButton.target = self
        talkButton.action = #selector(talkClicked)
        talkButton.translatesAutoresizingMaskIntoConstraints = false
        talkSpinner.style = .spinning
        talkSpinner.controlSize = .small
        talkSpinner.isDisplayedWhenStopped = false
        talkSpinner.translatesAutoresizingMaskIntoConstraints = false
        talkButtonSlot.addSubview(talkSpinner)
        talkButtonSlot.addSubview(talkButton)
        setVoiceState(.idle)

        for child in [title, talkButtonSlot, layoutToggle, terminalToggle, restart] {
            child.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: talkButtonSlot.leadingAnchor, constant: -6),

            talkButtonSlot.trailingAnchor.constraint(
                equalTo: layoutToggle.leadingAnchor, constant: -6),
            talkButtonSlot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            talkButtonSlot.widthAnchor.constraint(equalToConstant: 22),
            talkButtonSlot.heightAnchor.constraint(equalToConstant: 22),
            talkButton.centerXAnchor.constraint(equalTo: talkButtonSlot.centerXAnchor),
            talkButton.centerYAnchor.constraint(equalTo: talkButtonSlot.centerYAnchor),
            talkButton.widthAnchor.constraint(equalToConstant: 18),
            talkButton.heightAnchor.constraint(equalToConstant: 18),
            talkSpinner.centerXAnchor.constraint(equalTo: talkButtonSlot.centerXAnchor),
            talkSpinner.centerYAnchor.constraint(equalTo: talkButtonSlot.centerYAnchor),
            talkSpinner.widthAnchor.constraint(equalToConstant: 20),
            talkSpinner.heightAnchor.constraint(equalToConstant: 20),

            layoutToggle.trailingAnchor.constraint(equalTo: terminalToggle.leadingAnchor, constant: -8),
            layoutToggle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            layoutToggle.widthAnchor.constraint(equalToConstant: 18),
            layoutToggle.heightAnchor.constraint(equalToConstant: 18),

            terminalToggle.trailingAnchor.constraint(equalTo: restart.leadingAnchor, constant: -8),
            terminalToggle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            terminalToggle.widthAnchor.constraint(equalToConstant: 18),
            terminalToggle.heightAnchor.constraint(equalToConstant: 18),

            restart.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            restart.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            restart.widthAnchor.constraint(equalToConstant: 18),
            restart.heightAnchor.constraint(equalToConstant: 18),
        ])
        return header
    }

    /// The chat card's content: the messages and the terminal, both pinned to the
    /// same rectangle, one of them hidden. The terminal keeps its constraints (and
    /// so its surface) while hidden, because swapping views must never detach it.
    private func buildChatContent() -> NSView {
        chat.translatesAutoresizingMaskIntoConstraints = false
        chat.onOpenLink = { [weak self] link in self?.onOpenLink?(link) }
        chat.onShowTerminal = { [weak self] in self?.showTerminal(true) }

        terminalHost.wantsLayer = true
        terminalHost.layer?.backgroundColor = SidebarPalette.managerSurface.cgColor
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.isHidden = true

        let content = NSView()
        content.addSubview(chat)
        content.addSubview(terminalHost)
        NSLayoutConstraint.activate([
            chat.topAnchor.constraint(equalTo: content.topAnchor),
            chat.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chat.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            terminalHost.topAnchor.constraint(equalTo: content.topAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    private func buildInput() {
        input.placeholder = "Message"
        input.onSend = { [weak self] text in self?.onSend?(text) }
    }

    // MARK: Layout

    /// The toggle shows the layout a click switches to.
    private func updateLayoutToggle() {
        let sideBySide = split.isVertical
        let name = sideBySide ? "Stack" : "Side by side"
        layoutToggle.image = NSImage(
            systemSymbolName: sideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1",
            accessibilityDescription: name)
        layoutToggle.toolTip = name
    }

    /// Put the divider where the human last dragged it for this layout: 400pt of
    /// list when stacked, half and half side by side, until they drag it.
    private func applyListSize() {
        let length = split.isVertical ? split.bounds.width : split.bounds.height
        let available = length - split.dividerThickness
        let saved = Settings.managerRailListSize(sideBySide: split.isVertical)
        let wanted = saved ?? (split.isVertical ? available / 2 : Self.defaultListHeight)
        let position = min(max(wanted, Self.minCardSize), available - Self.minCardSize)
        split.setPosition(position, ofDividerAt: 0)
    }

    @objc private func layoutToggled() {
        split.isVertical.toggle()
        Settings.setManagerRailSideBySide(split.isVertical)
        updateLayoutToggle()
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        applyListSize()
    }

    /// Swap the list card between the board and the request list. Both stay in
    /// the hierarchy; only visibility moves. The request list reads its file
    /// only while it is the one showing.
    func showRequests(_ on: Bool) {
        showsRequests = on
        listSwitch.selectedSegment = on ? 1 : 0
        listScroll.isHidden = on
        requestList.isHidden = !on
        emptyLabel.isHidden = on || !sections.arrangedSubviews.isEmpty
    }

    @objc private func listSwitched() {
        showRequests(listSwitch.selectedSegment == 1)
        Settings.setManagerRailShowsRequests(showsRequests)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, Self.minCardSize)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMaximumPosition, length - splitView.dividerThickness - Self.minCardSize)
    }

    /// The list keeps its size when the window resizes; the chat takes the rest.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== splitView.arrangedSubviews.first
    }

    /// Remember a drag of the divider. Only a drag: a window resize or a rail
    /// collapse also resizes the cards, and that is not the human choosing a size.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard positionApplied, NSApp.currentEvent?.type == .leftMouseDragged,
              let list = split.arrangedSubviews.first
        else { return }
        let size = split.isVertical ? list.frame.width : list.frame.height
        Settings.setManagerRailListSize(size, sideBySide: split.isVertical)
    }

    // MARK: Data

    /// Replace what the rail renders (no-op when unchanged, so the 1.5s DB poll
    /// doesn't churn the view).
    func setSnapshot(_ new: ManagerSnapshot) {
        guard new != snapshot else { return }
        snapshot = new
        loadViewIfNeeded()
        rebuildSections()
    }

    private func rebuildSections() {
        for view in sections.arrangedSubviews { view.removeFromSuperview() }
        let now = Int(Date().timeIntervalSince1970)
        addSection("NEEDS YOU", rows: snapshot.needsYou.map(Self.row(needsYou:)), now: now)
        addSection("RECENT WORK", rows: snapshot.recentWork.map(Self.row(work:)), now: now)
        addSection("UPDATES", rows: snapshot.updates.map(Self.row(update:)), now: now)
        emptyLabel.isHidden = showsRequests || !sections.arrangedSubviews.isEmpty
    }

    /// A section with no rows is not rendered at all, because an empty heading says
    /// nothing the missing rows don't already say.
    private func addSection(_ title: String, rows: [ManagerRow], now: Int) {
        guard !rows.isEmpty else { return }
        add(Self.sectionHeader(title))
        for row in rows {
            let view = ManagerRowView()
            view.configure(row, now: now)
            view.onActivate = { [weak self] row, textLink in
                self?.activate(row, textLink: textLink)
            }
            view.onDismiss = { [weak self] key in self?.dismissClicked(key: key) }
            view.onApprove = { [weak self] id, done in self?.onApproveKeygate?(id, done) }
            add(view)
        }
    }

    private func add(_ view: NSView) {
        sections.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
    }

    static func sectionHeader(_ title: String) -> NSView {
        let host = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = SidebarPalette.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -3),
        ])
        return host
    }

    // MARK: Row builders

    private static func row(needsYou item: NeedsYouItem) -> ManagerRow {
        switch item.kind {
        case .agent(let agent):
            return ManagerRow(
                color: SidebarPalette.red, title: item.title, prs: "", detail: item.detail,
                time: agent.since, link: item.link, review: nil)
        case .review(let review):
            let color: NSColor
            switch review.severity {
            case .blocked: color = SidebarPalette.red
            case .warn: color = SidebarPalette.amber
            case .info: color = SidebarPalette.muted
            }
            return ManagerRow(
                color: color, title: item.title, prs: "", detail: item.detail,
                time: review.updatedAt, link: item.link, review: review,
                keygateID: review.keygateID.flatMap { keygateTrusted() ? $0 : nil })
        }
    }

    private static func row(work: WorkLogRow) -> ManagerRow {
        let name = [work.repo, work.branch].filter { !$0.isEmpty }.joined(separator: " · ")
        let address = work.window.map { "\(work.session):\($0)" } ?? work.session
        let title: String
        if !name.isEmpty {
            title = name
        } else if !address.isEmpty {
            title = address
        } else {
            title = "thread \(TmuxCommands.abbreviatedSessionId(work.sessionId))"
        }
        let color: NSColor
        switch work.lastState {
        case "waiting": color = SidebarPalette.red
        case "busy": color = SidebarPalette.accent
        case "done": color = SidebarPalette.green
        default: color = SidebarPalette.muted
        }
        return ManagerRow(
            color: color,
            title: title,
            prs: work.prs.map { "#\($0)" }.joined(separator: " "),
            detail: [address, work.lastState].filter { !$0.isEmpty }.joined(separator: " · "),
            time: work.lastSeen,
            link: link(sessionId: work.sessionId, session: work.session,
                       window: work.window, host: work.host),
            review: nil)
    }

    private static func row(update: ManagerUpdate) -> ManagerRow {
        ManagerRow(
            color: update.kind == .done ? SidebarPalette.green : SidebarPalette.muted,
            title: update.kind == .done ? "Done" : "Maestro",
            prs: "",
            detail: update.text,
            time: update.at,
            link: link(sessionId: update.sessionId, session: update.session,
                       window: update.window, host: update.host),
            review: nil)
    }

    /// A thread link when the row knows which conversation it is (it survives the
    /// thread moving panes), its tmux address otherwise, nothing when neither.
    private static func link(
        sessionId: String, session: String, window: Int?, host: String
    ) -> ThreadLink? {
        if !sessionId.isEmpty { return .thread(id: sessionId) }
        guard !session.isEmpty else { return nil }
        return .open(session: session, window: window, pane: nil,
                     host: host.isEmpty ? Host.local.name : host)
    }

    // MARK: Terminal

    var hasTerminal: Bool { terminal != nil }

    /// Install the manager terminal (once). Kept as a child so collapse/expand
    /// never disturbs the surface.
    func installTerminal(_ vc: TerminalViewController) {
        guard terminal == nil else { return }
        loadViewIfNeeded()
        terminal = vc
        addChild(vc)
        let content = vc.view
        content.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
        ])
    }

    /// Swap the chat card between the messages and the terminal. Both views stay
    /// in the hierarchy; only visibility moves.
    func showTerminal(_ on: Bool) {
        loadViewIfNeeded()
        isTerminalShown = on
        terminalToggle.state = on ? .on : .off
        terminalToggle.contentTintColor = on ? SidebarPalette.accent : SidebarPalette.muted
        terminalHost.isHidden = !on
        chat.isHidden = on
        if on && !hasTerminal { onShowTerminal?() }
        if !on { chat.refresh() }
    }

    // MARK: Chat

    /// A turn is starting: its text shows until the transcript has it. The
    /// reply, the agent's tools and its spinner come from the transcript and
    /// the pane, so the input stays open: text sent mid-turn queues.
    func beginTurn(_ prompt: String) {
        loadViewIfNeeded()
        pendingPrompt = prompt
        chat.addPending(prompt)
        chat.refreshSoon()
    }

    /// Text queued into a busy Maestro: shown until the transcript has it.
    func showQueued(_ text: String) {
        loadViewIfNeeded()
        chat.addPending(text)
    }

    /// Text that did not reach the pane: back into the input, with the reason.
    func notSent(_ text: String, reason: String) {
        chat.dropPending(text)
        chat.addNote(reason)
        if input.text.isEmpty { input.text = text }
    }

    /// The turn settled. A permission prompt shows in the chat with its
    /// choices, read from the pane on the next refresh.
    func endTurn(_ outcome: ManagerTurnOutcome) {
        switch outcome {
        case .done, .permission:
            break
        case .timeout:
            chat.addNote("Still working")
        case .refused(let message), .unreachable(let message):
            notSent(pendingPrompt, reason: message)
        }
        pendingPrompt = ""
        chat.refreshSoon()
    }

    /// A one-line note in the chat, for a voice take that went nowhere.
    func addNote(_ text: String) {
        loadViewIfNeeded()
        chat.addNote(text)
    }

    /// The reply could not be spoken: bring the messages forward, where the
    /// reply shows as text.
    func showReplyAsText() {
        loadViewIfNeeded()
        showTerminal(false)
        chat.addNote("Voice failed")
    }

    /// The talk button shows what a press does next; the spinner around it
    /// shows a take is still working.
    func setVoiceState(_ state: VoiceController.State) {
        var symbol: String?
        let label: String
        var tint = SidebarPalette.muted
        var spinning = false
        switch state {
        case .idle, .starting:
            symbol = "mic"
            label = "Talk"
        case .listening:
            symbol = "mic.fill"
            label = "Send"
            tint = .systemRed
        case .transcribing:
            label = "Transcribing"
            spinning = true
        case .replying:
            symbol = "stop.fill"
            label = "Stop reading"
            spinning = true
        }
        talkButton.image = symbol.map {
            NSImage(systemSymbolName: $0, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: spinning ? 7 : 13, weight: .regular))
        } ?? nil
        talkButton.toolTip = label
        talkButton.contentTintColor = tint
        if spinning { talkSpinner.startAnimation(nil) } else { talkSpinner.stopAnimation(nil) }
    }

    // MARK: Actions

    @objc private func restartClicked() { onRestart?() }

    @objc private func talkClicked() { onTalk?() }

    @objc private func terminalToggled() {
        showTerminal(terminalToggle.state == .on)
    }

    private func activate(_ row: ManagerRow, textLink: ThreadLink?) {
        if let textLink {
            onOpenLink?(textLink)
        } else if let link = row.link {
            onOpenLink?(link)
        } else if let review = row.review {
            onOpen?(review)
        }
    }

    private func dismissClicked(key: String) {
        // Optimistic: drop the row now; the DB write + next poll confirm it.
        snapshot = ManagerSnapshot(
            needsYou: snapshot.needsYou.filter { item in
                guard case .review(let review) = item.kind else { return true }
                return review.key != key
            },
            recentWork: snapshot.recentWork,
            updates: snapshot.updates)
        rebuildSections()
        onDismiss?(key)
    }
}

/// What one rendered row draws and what a click on it does.
private struct ManagerRow {
    let color: NSColor
    let title: String
    /// PR numbers as "#12 #34", empty when there are none.
    let prs: String
    let detail: String
    /// Epoch seconds, nil for a row with nothing to date.
    let time: Int?
    let link: ThreadLink?
    /// Set on a review row: it gets a dismiss checkbox, and a click with no link
    /// falls back to opening the item.
    let review: ManagerReviewItem?
    /// A keygate request id, set only when keygate passes its binary check: the
    /// row gets an Approve button.
    var keygateID: String? = nil
}

/// A scroll view's document: flipped, so the content starts at the top of the
/// scroller rather than the bottom.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// The rail's split: the gap between the cards is the divider, and it draws
/// nothing, so the two cards read as two cards.
private final class RailSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 10 }
    override func drawDivider(in rect: NSRect) {}
}

/// One row: status dot, title (+ PR numbers), a detail line that may carry
/// links, a relative time, and (for a review item) its dismiss checkbox.
///
/// The whole row is one click target. A click on a link inside the detail opens
/// that link; anywhere else opens the row's own target.
private final class ManagerRowView: NSView, NSGestureRecognizerDelegate {
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let prs = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let detail = LinkLabel(
        font: .systemFont(ofSize: 11), color: SidebarPalette.muted, maxLines: 2)
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let approve = NSButton(title: "Approve", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var row: ManagerRow?

    var onActivate: ((ManagerRow, ThreadLink?) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onApprove: ((String, @escaping () -> Void) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = SidebarPalette.text
        title.lineBreakMode = .byTruncatingTail
        // The title is the one thing on this line that may shrink: a clipped name
        // still reads, a clipped number lies (see tasks/lessons.md).
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for numeric in [prs, time] {
            numeric.font = .systemFont(ofSize: 11)
            numeric.textColor = SidebarPalette.muted
            numeric.setContentCompressionResistancePriority(.required, for: .horizontal)
            numeric.setContentHuggingPriority(.required, for: .horizontal)
        }
        prs.textColor = SidebarPalette.textRemote

        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false

        check.target = self
        check.action = #selector(checkClicked)

        approve.target = self
        approve.action = #selector(approveClicked)
        approve.bezelStyle = .rounded
        approve.controlSize = .small
        approve.font = .systemFont(ofSize: 11)

        // A hidden button leaves the stack, so a plain row's text runs to the edge.
        let trail = NSStackView(views: [approve, check])
        trail.orientation = .horizontal
        trail.alignment = .centerY
        trail.spacing = 6
        trail.translatesAutoresizingMaskIntoConstraints = false

        // The time is pinned to the row's trailing edge rather than packed into
        // the stack, so every row's time reads down one column.
        time.translatesAutoresizingMaskIntoConstraints = false
        let top = NSStackView(views: [dot, title, prs])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false

        addSubview(top)
        addSubview(time)
        addSubview(detail)
        addSubview(trail)
        NSLayoutConstraint.activate([
            check.widthAnchor.constraint(equalToConstant: 16),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            top.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),

            time.trailingAnchor.constraint(equalTo: trail.leadingAnchor, constant: -6),
            time.centerYAnchor.constraint(equalTo: top.centerYAnchor),

            // Aligned with the title, not the dot: the detail is a second line of
            // the same thought.
            detail.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            detail.trailingAnchor.constraint(equalTo: trail.leadingAnchor, constant: -6),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            trail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        click.delegate = self
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ row: ManagerRow, now: Int) {
        self.row = row
        dot.layer?.backgroundColor = row.color.cgColor
        title.stringValue = row.title
        prs.stringValue = row.prs
        prs.isHidden = row.prs.isEmpty
        time.stringValue = row.time.map { Self.relative($0, now: now) } ?? ""
        time.isHidden = row.time == nil
        detail.setText(row.detail)
        check.state = .off
        check.isHidden = row.review == nil
        approve.isHidden = row.keygateID == nil
        approve.isEnabled = true
        toolTip = row.detail.isEmpty ? row.title : row.detail
    }

    /// "now", "4m", "2h", "3d": the age, at the coarsest unit that still says
    /// something.
    static func relative(_ at: Int, now: Int) -> String {
        let age = max(0, now - at)
        switch age {
        case ..<60: return "now"
        case ..<3_600: return "\(age / 60)m"
        case ..<86_400: return "\(age / 3_600)h"
        default: return "\(age / 86_400)d"
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = SidebarPalette.surface.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// The recognizer delays the mouse-down, so a click it attempts never reaches
    /// the checkbox: the row opened instead of dismissing. It sits out any click
    /// that lands on the checkbox or the Approve button, and the button tracks
    /// that click itself.
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        ![check, approve].contains { button in
            !button.isHidden && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
    }

    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        guard let row else { return }
        onActivate?(row, detail.link(at: gesture.location(in: detail)))
    }

    @objc private func checkClicked() {
        guard let key = row?.review?.key else { return }
        onDismiss?(key)
    }

    /// keygate opens its own dialog. The button stays off while keygate runs,
    /// so a second click does not open a second dialog.
    @objc private func approveClicked() {
        guard let id = Keygate.validID(row?.keygateID) else { return }
        approve.isEnabled = false
        onApprove?(id) { [weak self] in self?.approve.isEnabled = true }
    }
}
