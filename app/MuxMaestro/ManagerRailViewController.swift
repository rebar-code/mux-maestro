import Cocoa

/// The 🤖 Manager: a tab in the right sidebar (`RightSidebarViewController`),
/// beside the Tree, the Diff and the Artifacts.
/// Two cards. One lists the agent's read of the fleet (what needs you, what the
/// agents have been doing, what they said); the other is the chat with the
/// `mux-manager` pane. The divider between them drags.
///
/// The rail hands this pane whatever width is left beside the other tabs, so
/// the cards stack by default and whenever the pane is under
/// `sideBySideMinWidth`. Side by side is a choice only a wider pane offers.
///
/// The pane's terminal lives behind the chat header's toggle. It is installed
/// once (lazily, on first reveal) and never torn down, so the agent's scrollback
/// survives every toggle, and every time the tab or the whole rail is hidden.
final class ManagerRailViewController: NSViewController, NSTextFieldDelegate, NSSplitViewDelegate {
    private let split = RailSplitView()
    private let listScroll = NSScrollView()
    private let sections = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing needs you")
    private let chatScroll = NSScrollView()
    private let chatLog = FlippedStackView()
    private let terminalHost = NSView()
    private let terminalToggle = NSButton()
    private let layoutToggle = NSButton()
    private let input = NSTextField()

    /// The header's push-to-talk slot and the button in it.
    let talkButtonSlot = NSView()
    private let talkButton = NSButton()
    /// Spins around the talk button while a take is transcribing or replying.
    private let talkSpinner = NSProgressIndicator()
    /// Spins under the reply while a turn is in flight.
    private var workingSpinner: NSView?

    private var snapshot = ManagerSnapshot.empty
    /// The prompt of the turn in flight, so a refused or unreachable turn can
    /// hand it back to the input instead of making the human retype it.
    private var pendingPrompt = ""
    /// The reply of the turn in flight: its message view and the text so far.
    private var replyMessage: ChatMessageView?
    private var replyText = ""
    /// The split's size when the cards were last fitted to it. Zero until the
    /// tab is first shown and laid out, because fitting needs real bounds.
    private var fittedSize = NSSize.zero
    /// The talk button's trailing edge: against the layout toggle, or against
    /// the terminal toggle while the layout toggle is hidden.
    private var talkBesideLayoutToggle: NSLayoutConstraint?
    private var talkBesideTerminalToggle: NSLayoutConstraint?

    /// The terminal, once installed. Owned here so hiding the tab never tears
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
    /// The header's restart button — kill + recreate the manager session.
    var onRestart: (() -> Void)?
    /// ⏎ in the input: send this text to the manager pane.
    var onSend: ((String) -> Void)?
    /// The talk button: start, send, or stop a voice take.
    var onTalk: (() -> Void)?
    /// The terminal is being shown for the first time; install the surface now.
    var onShowTerminal: (() -> Void)?

    /// The list card's height when stacked, until the divider is dragged.
    private static let defaultListHeight: CGFloat = 400
    /// What that default leaves the chat at least. A pane too short to give
    /// both splits in half instead (a rail in rows shares its height).
    private static let defaultChatHeight: CGFloat = 240
    /// Neither card can be dragged narrower than this when side by side.
    private static let minCardSize: CGFloat = 120
    /// The floors when stacked. The list reads down to a heading and one row.
    /// The chat spends 84pt on its header and its input before the first
    /// message, so its floor is the taller one: four lines of messages or
    /// terminal. The rail in rows shares its height between the open tabs, so a
    /// short pane is the normal case here, not a corner.
    private static let minListHeight: CGFloat = 80
    private static let minChatHeight: CGFloat = 160
    /// Below this pane width the cards always stack and the layout toggle is
    /// hidden: side by side, each card would be under 290pt, where a row's
    /// title is squeezed out by its PR numbers and time and the chat wraps to a
    /// few words a line.
    static let sideBySideMinWidth: CGFloat = 600

    override func loadView() {
        // Stacked until the pane is laid out and known to be wide enough.
        split.isVertical = false
        split.delegate = self
        split.addArrangedSubview(buildListCard())
        split.addArrangedSubview(buildChatCard())
        split.translatesAutoresizingMaskIntoConstraints = false
        updateLayoutToggle()

        // The cards sit inset from the pane's edges; the rail draws the dividers
        // between this pane, its neighbours and the terminal.
        let container = NSView()
        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            split.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        self.view = container
    }

    /// The rail resizes this pane whenever a neighbouring tab opens or closes,
    /// the rail's layout flips or a divider drags, so the cards are refitted on
    /// every change of size, not once.
    override func viewDidLayout() {
        super.viewDidLayout()
        let size = split.bounds.size
        guard size.width > 1, size.height > 1, size != fittedSize else { return }
        fittedSize = size
        fitCards()
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

        let card = Self.makeCard()
        card.addSubview(listScroll)
        card.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            sections.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            sections.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            sections.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),

            listScroll.topAnchor.constraint(equalTo: card.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
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
            input.heightAnchor.constraint(equalToConstant: 28),
        ])
        return card
    }

    private func buildHeader() -> NSView {
        let header = NSView()
        let title = NSTextField(labelWithString: "MANAGER")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = SidebarPalette.muted
        // In a narrow pane the title gives way to the buttons.
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "Restart manager agent")
        restart.isBordered = false
        restart.bezelStyle = .regularSquare
        restart.toolTip = "Restart manager agent"
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
        talkBesideLayoutToggle = talkButtonSlot.trailingAnchor.constraint(
            equalTo: layoutToggle.leadingAnchor, constant: -6)
        talkBesideTerminalToggle = talkButtonSlot.trailingAnchor.constraint(
            equalTo: terminalToggle.leadingAnchor, constant: -6)
        talkBesideLayoutToggle?.isActive = true
        return header
    }

    /// The chat card's content: the messages and the terminal, both pinned to the
    /// same rectangle, one of them hidden. The terminal keeps its constraints (and
    /// so its surface) while hidden, because swapping views must never detach it.
    private func buildChatContent() -> NSView {
        chatLog.orientation = .vertical
        chatLog.alignment = .centerX
        chatLog.spacing = 8
        chatLog.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 4, right: 0)
        chatLog.translatesAutoresizingMaskIntoConstraints = false

        chatScroll.documentView = chatLog
        chatScroll.hasVerticalScroller = true
        chatScroll.drawsBackground = false
        chatScroll.translatesAutoresizingMaskIntoConstraints = false

        terminalHost.wantsLayer = true
        terminalHost.layer?.backgroundColor = SidebarPalette.managerSurface.cgColor
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.isHidden = true

        let content = NSView()
        content.addSubview(chatScroll)
        content.addSubview(terminalHost)
        NSLayoutConstraint.activate([
            chatLog.topAnchor.constraint(equalTo: chatScroll.contentView.topAnchor),
            chatLog.leadingAnchor.constraint(equalTo: chatScroll.contentView.leadingAnchor),
            chatLog.trailingAnchor.constraint(equalTo: chatScroll.contentView.trailingAnchor),

            chatScroll.topAnchor.constraint(equalTo: content.topAnchor),
            chatScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chatScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chatScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            terminalHost.topAnchor.constraint(equalTo: content.topAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    private func buildInput() {
        input.placeholderString = "Message"
        input.font = .systemFont(ofSize: 13)
        input.isBezeled = true
        input.bezelStyle = .roundedBezel
        input.focusRingType = .none
        input.delegate = self
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

    /// Fit the cards to the pane's current size: side by side only when the
    /// human chose it AND the pane is wide enough, stacked otherwise. The choice
    /// is kept while the pane is narrow, so widening the rail brings it back.
    private func fitCards() {
        let roomy = view.bounds.width >= Self.sideBySideMinWidth
        let sideBySide = roomy && Settings.managerRailSideBySide()
        layoutToggle.isHidden = !roomy
        // Off before on: both at once would pin the talk button to two places.
        (roomy ? talkBesideTerminalToggle : talkBesideLayoutToggle)?.isActive = false
        (roomy ? talkBesideLayoutToggle : talkBesideTerminalToggle)?.isActive = true
        if split.isVertical != sideBySide {
            split.isVertical = sideBySide
            split.adjustSubviews()
            split.layoutSubtreeIfNeeded()
        }
        updateLayoutToggle()
        applyListSize()
    }

    /// The room the two cards share along the split's axis.
    private var cardRoom: CGFloat {
        (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
    }

    /// The least each card keeps along the split's axis. A pane too small to
    /// give both their floor shrinks the two floors in proportion, so the
    /// floors never ask for more room than there is (see
    /// `RightSidebarViewController.paneFloor`).
    private var cardFloors: (list: CGFloat, chat: CGFloat) {
        let list = split.isVertical ? Self.minCardSize : Self.minListHeight
        let chat = split.isVertical ? Self.minCardSize : Self.minChatHeight
        let scale = max(0, min(1, cardRoom / (list + chat)))
        return (list * scale, chat * scale)
    }

    /// Put the divider where the human last dragged it for this layout, as far
    /// as the pane allows. Until they drag it: half and half side by side; when
    /// stacked, 400pt of list if that leaves the chat 240pt, else half and half.
    private func applyListSize() {
        let room = cardRoom
        let wanted: CGFloat
        if let saved = Settings.managerRailListSize(sideBySide: split.isVertical) {
            wanted = saved
        } else if split.isVertical {
            wanted = room / 2
        } else {
            wanted = min(Self.defaultListHeight, max(room / 2, room - Self.defaultChatHeight))
        }
        let floors = cardFloors
        split.setPosition(min(max(wanted, floors.list), room - floors.chat), ofDividerAt: 0)
    }

    @objc private func layoutToggled() {
        Settings.setManagerRailSideBySide(!split.isVertical)
        fitCards()
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, cardFloors.list)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, cardRoom - cardFloors.chat)
    }

    /// The list keeps its size when the pane resizes; the chat takes the rest.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== splitView.arrangedSubviews.first
    }

    /// Remember a drag of the divider between the cards. Only that drag: a
    /// window resize, a rail divider, or a neighbouring tab opening also resizes
    /// the cards, and none of those is the human choosing a size.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard split.isDraggingDivider, let list = split.arrangedSubviews.first else { return }
        let size = split.isVertical ? list.frame.width : list.frame.height
        Settings.setManagerRailListSize(size, sideBySide: split.isVertical)
    }

    // MARK: Data

    /// Replace what the list renders (no-op when unchanged, so the 1.5s DB poll
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
        emptyLabel.isHidden = !sections.arrangedSubviews.isEmpty
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
            add(view)
        }
    }

    private func add(_ view: NSView) {
        sections.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
    }

    private static func sectionHeader(_ title: String) -> NSView {
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
                time: review.updatedAt, link: item.link, review: review)
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
            title: update.kind == .done ? "Done" : "Manager",
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

    /// Install the manager terminal (once). Kept as a child so hiding and
    /// re-showing the tab never disturbs the surface.
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
        chatScroll.isHidden = on
        if on && !hasTerminal { onShowTerminal?() }
    }

    // MARK: Chat

    /// A turn is starting: show the message, hold a place for the reply, and hold
    /// the input until the turn ends.
    func beginTurn(_ prompt: String) {
        loadViewIfNeeded()
        pendingPrompt = prompt
        addMessage(.you, prompt)
        replyText = ""
        replyMessage = addMessage(.manager, "")
        showWorking(true)
        input.isEnabled = false
    }

    /// Stream more reply text in.
    func appendReply(_ delta: String) {
        guard !delta.isEmpty else { return }
        replyText += delta
        replyMessage?.setText(replyText, streaming: true)
        scrollChatToEnd()
    }

    /// The turn settled. A permission prompt is the one outcome the human has to
    /// act on, and only the terminal can take that answer, so it comes forward.
    func endTurn(_ outcome: ManagerTurnOutcome) {
        var reply = ""
        var note: String?
        switch outcome {
        case .done(let text):
            reply = text
        case .permission(let text):
            reply = text
            note = "Waiting at the keyboard"
            showTerminal(true)
        case .timeout(let text):
            reply = text
            note = "Still working"
        case .refused(let message), .unreachable(let message):
            note = message
            if input.stringValue.isEmpty { input.stringValue = pendingPrompt }
        }
        if replyText.isEmpty { replyText = reply }
        if replyText.isEmpty {
            replyMessage?.removeFromSuperview()
        } else {
            replyMessage?.setText(replyText)
        }
        showWorking(false)
        if let note { addMessage(.note, note) }
        replyMessage = nil
        pendingPrompt = ""
        input.isEnabled = true
        view.window?.makeFirstResponder(input)
    }

    /// A one-line note in the chat, for a voice take that went nowhere.
    func addNote(_ text: String) {
        loadViewIfNeeded()
        addMessage(.note, text)
    }

    /// The reply could not be spoken: bring the messages forward, where the
    /// reply has been streaming in as text all along.
    func showReplyAsText() {
        loadViewIfNeeded()
        showTerminal(false)
        addMessage(.note, "Voice failed")
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

    /// A small spinner under the reply while the manager's turn runs.
    private func showWorking(_ on: Bool) {
        workingSpinner?.removeFromSuperview()
        workingSpinner = nil
        guard on else { return }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(spinner)
        chatLog.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: chatLog.widthAnchor, constant: -16),
            row.heightAnchor.constraint(equalToConstant: 16),
            spinner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        workingSpinner = row
        scrollChatToEnd()
    }

    @discardableResult
    private func addMessage(_ role: ChatMessageView.Role, _ text: String) -> ChatMessageView {
        let message = ChatMessageView(role: role)
        message.setText(text)
        message.onOpenLink = { [weak self] link in self?.onOpenLink?(link) }
        chatLog.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: chatLog.widthAnchor, constant: -16).isActive = true
        scrollChatToEnd()
        return message
    }

    /// Keep the newest message in view. A message only knows its height after a
    /// layout pass, so the scroll waits for one.
    private func scrollChatToEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            let clip = self.chatScroll.contentView
            let bottom = max(0, self.chatLog.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: bottom))
            self.chatScroll.reflectScrolledClipView(clip)
        }
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

    /// ⏎ sends. Handled here rather than through the field's action so the field
    /// keeps focus for the next message and never ends editing mid-turn.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        sendInput()
        return true
    }

    private func sendInput() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""
        onSend?(text)
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
}

/// A scroll view's document: flipped, so the content starts at the top of the
/// scroller rather than the bottom.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// The cards' split: the gap between the cards is the divider, and it draws
/// nothing, so the two cards read as two cards.
private final class RailSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 10 }
    override func drawDivider(in rect: NSRect) {}

    /// True while the human drags this split's own divider. AppKit tracks that
    /// drag inside `mouseDown`, so it brackets exactly the drag.
    private(set) var isDraggingDivider = false

    override func mouseDown(with event: NSEvent) {
        isDraggingDivider = true
        defer { isDraggingDivider = false }
        super.mouseDown(with: event)
    }
}

/// One chat message. Yours sits on a tinted block; the manager's reply is
/// rendered markdown; a note (a turn that failed or is still going) is muted.
/// The height follows the wrapped text, and a click on a link opens it.
private final class ChatMessageView: NSView {
    enum Role { case you, manager, note }

    private let role: Role
    private let label: LinkLabel
    private var labelHeight: NSLayoutConstraint?

    var onOpenLink: ((ThreadLink) -> Void)?

    init(role: Role) {
        self.role = role
        label = LinkLabel(
            font: .systemFont(ofSize: role == .note ? 11 : 12),
            color: role == .note ? SidebarPalette.muted : SidebarPalette.text,
            maxLines: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if role == .you {
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.backgroundColor = SidebarPalette.surface.cgColor
        }

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let vertical: CGFloat = role == .you ? 6 : 0
        let height = label.heightAnchor.constraint(equalToConstant: 0)
        labelHeight = height
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            height,
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `streaming`: the reply is still arriving (see `ChatMarkdown.settle`).
    func setText(_ text: String, streaming: Bool = false) {
        if role == .manager {
            label.setAttributedText(
                ChatMarkdown.render(text, style: Self.markdownStyle, streaming: streaming))
        } else {
            label.setText(text)
        }
        updateHeight()
    }

    private static var markdownStyle: ChatMarkdown.Style {
        ChatMarkdown.Style(
            font: .systemFont(ofSize: 12),
            color: SidebarPalette.text,
            muted: SidebarPalette.muted,
            link: SidebarPalette.accent,
            codeBackground: SidebarPalette.bg)
    }

    override func layout() {
        super.layout()
        updateHeight()
    }

    /// The label reports a fixed-lines intrinsic height, so the real height is
    /// measured from the laid-out glyphs at the label's current width.
    private func updateHeight() {
        guard let labelHeight, let layout = label.layoutManager,
              let container = label.textContainer, label.bounds.width > 1
        else { return }
        container.size = NSSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        guard labelHeight.constant != height else { return }
        labelHeight.constant = height
    }

    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        guard let target = label.linkTarget(at: gesture.location(in: label)) else { return }
        if let link = ThreadLinks.parse(target) {
            onOpenLink?(link)
        } else if let url = URL(string: target), ["http", "https", "mailto"].contains(url.scheme) {
            NSWorkspace.shared.open(url)
        }
    }
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
    private var checkWidth: NSLayoutConstraint?
    private var tracking: NSTrackingArea?
    private var row: ManagerRow?

    var onActivate: ((ManagerRow, ThreadLink?) -> Void)?
    var onDismiss: ((String) -> Void)?

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
        check.translatesAutoresizingMaskIntoConstraints = false

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
        addSubview(check)
        let checkW = check.widthAnchor.constraint(equalToConstant: 0)
        checkWidth = checkW
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            top.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),

            time.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -6),
            time.centerYAnchor.constraint(equalTo: top.centerYAnchor),

            // Aligned with the title, not the dot: the detail is a second line of
            // the same thought.
            detail.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            detail.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -6),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkW,
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
        checkWidth?.constant = row.review == nil ? 0 : 16
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
    /// that lands on the checkbox, and the button tracks that click itself.
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        check.isHidden || !check.bounds.contains(check.convert(event.locationInWindow, from: nil))
    }

    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        guard let row else { return }
        onActivate?(row, detail.link(at: gesture.location(in: detail)))
    }

    @objc private func checkClicked() {
        guard let key = row?.review?.key else { return }
        onDismiss?(key)
    }
}
