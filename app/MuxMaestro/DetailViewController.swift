import Cocoa

/// The detail (right) side. The terminal is ALWAYS visible; the right sidebar opens
/// as a collapsible split to the RIGHT of the terminal rather than replacing it.
/// The sidebar (`RightSidebarViewController`) hosts the Diff and/or the Tree — one
/// or both at once, arranged as columns or rows. When the sidebar is empty it's
/// removed from the split so the terminal fills the detail area. The terminal and
/// sidebar view controllers are children, so toggling never disturbs their state.
final class DetailViewController: NSViewController {
    let terminal: TerminalViewController
    let rightSidebar: RightSidebarViewController
    /// What this selection has running — a pill over the pane's top-right
    /// corner that drops its list open beneath it.
    let runningDrawer: RunningDrawer
    /// Commands for carrying the current agent turn into a fresh conversation.
    let handoffCommands = HandoffCommandButton()

    /// Names the two side contents. Kept as a stable enum so the toolbar/menu call
    /// sites (`toggle(.diff)`, `show(.tree)`, …) read the same as before, even
    /// though each shows/hides independently instead of swapping one slot.
    enum SidePanel { case diff, tree, artifacts }

    private let split = NSSplitView()
    private let terminalPane = NSView()  // holds the terminal (left, always shown)

    /// The ⌘F find bar, floated over the terminal's top-right corner. Hidden
    /// until presented; its callbacks are wired by the AppDelegate (which owns
    /// the attached session + service the search runs against).
    let findBar = FindBarView()

    /// Readable-line cap: one tmux column is never stretched wider than this. A
    /// window split into N side-by-side columns is capped at N × this, so text
    /// stays readable even when MuxMaestro is full-width — the freed space becomes
    /// the right sidebar instead of an over-wide terminal.
    private let maxColumnWidth: CGFloat = 800
    /// The floor the sidebar divider stops at while dragging — a floor, not a
    /// target width.
    private let minRailWidth: CGFloat = 170
    /// Live count of side-by-side tmux columns in the attached window (≥1), fed
    /// from the pane geometry on each refresh.
    private var terminalColumns = 1
    /// Tracks whether we were last laid out wide enough to pin the terminal to its
    /// cap, so that re-pin fires on the narrow→wide transition, not every layout.
    private var wasWide = false

    /// What was shown when the rail was last collapsed, so re-expanding restores it.
    private var rememberedItems: [RightSidebarViewController.Item] = []

    /// Caps the terminal's width at `terminalCap`; its constant is re-set when the
    /// column count changes so a single column never stretches past `maxColumnWidth`
    /// even when the sidebar is closed and the window is wide.
    private var terminalWidthCap: NSLayoutConstraint!

    /// The terminal's max width: columns × the per-column cap.
    private var terminalCap: CGFloat { CGFloat(max(1, terminalColumns)) * maxColumnWidth }

    init(terminal: TerminalViewController, rightSidebar: RightSidebarViewController,
         runningDrawer: RunningDrawer) {
        self.terminal = terminal
        self.rightSidebar = rightSidebar
        self.runningDrawer = runningDrawer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let container = NSView()

        buildTerminalPane()
        addChild(rightSidebar)

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.autosaveName = "SidekickDetailSplit"
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(terminalPane)  // sidebar added when shown
        // The terminal holds its width; extra window width flows to the sidebar
        // (when open) or to empty gutters rather than over-widening the terminal
        // past its readable cap.
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        container.addSubview(split)

        // Pin the top to the safe area, not the raw container top: the window uses
        // .fullSizeContentView, so container.topAnchor is UNDER the titlebar and
        // would clip the terminal's first line behind the header. The safe-area
        // guide excludes the titlebar height. The clickable breadcrumb lives in the
        // titlebar itself (a titlebar accessory owned by the AppDelegate), not here.
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    /// Build the terminal surface into `terminalPane`, capped at its readable
    /// column width and centered. Width resolves to `min(paneWidth, terminalCap)`,
    /// so a single column never stretches past `maxColumnWidth` — even when the
    /// sidebar is closed and the window is wide (the surplus becomes empty gutters).
    private func buildTerminalPane() {
        addChild(terminal)
        let term = terminal.view
        term.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.addSubview(term)

        terminalWidthCap = term.widthAnchor.constraint(lessThanOrEqualToConstant: terminalCap)
        // Grow to fill the pane, but yield to the required cap/pane-width limits.
        let fill = term.widthAnchor.constraint(equalTo: terminalPane.widthAnchor)
        fill.priority = .defaultHigh

        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: terminalPane.topAnchor),
            term.bottomAnchor.constraint(equalTo: terminalPane.bottomAnchor),
            term.centerXAnchor.constraint(equalTo: terminalPane.centerXAnchor),
            term.widthAnchor.constraint(lessThanOrEqualTo: terminalPane.widthAnchor),
            terminalWidthCap,
            fill,
        ])

        // The Running drawer floats over the pane's top-right corner, above the
        // surface. Absolute: it covers the terminal rather than pushing it, and
        // never grows past the pane's bottom — its list scrolls instead.
        addChild(runningDrawer.content)
        runningDrawer.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.addSubview(runningDrawer)
        NSLayoutConstraint.activate([
            runningDrawer.topAnchor.constraint(equalTo: terminalPane.topAnchor, constant: 8),
            runningDrawer.trailingAnchor.constraint(equalTo: terminalPane.trailingAnchor, constant: -16),
            runningDrawer.bottomAnchor.constraint(
                lessThanOrEqualTo: terminalPane.bottomAnchor, constant: -8),
        ])

        handoffCommands.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.addSubview(handoffCommands)
        let handoffAtRight = handoffCommands.trailingAnchor.constraint(
            equalTo: term.trailingAnchor, constant: -16)
        let handoffBesideRunning = handoffCommands.trailingAnchor.constraint(
            equalTo: runningDrawer.leadingAnchor, constant: -8)
        handoffAtRight.isActive = true
        NSLayoutConstraint.activate([
            handoffCommands.topAnchor.constraint(equalTo: term.topAnchor, constant: 8),
        ])

        // The find bar floats in the same corner, so it sits to the drawer's
        // left. Hidden until ⌘F presents it.
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.addSubview(findBar, positioned: .below, relativeTo: runningDrawer)
        // A hidden drawer still has a frame, so the find bar only steps left of
        // it while it is shown; otherwise it takes the corner itself.
        let besideDrawer = findBar.trailingAnchor.constraint(
            equalTo: runningDrawer.leadingAnchor, constant: -8)
        let besideHandoff = findBar.trailingAnchor.constraint(
            equalTo: handoffCommands.leadingAnchor, constant: -8)
        let inCorner = findBar.trailingAnchor.constraint(equalTo: term.trailingAnchor, constant: -16)
        let positionFloaters = { [weak self] in
            guard let self else { return }
            let showHandoff = !self.handoffCommands.isHidden
            let showRunning = !self.runningDrawer.isHidden
            handoffBesideRunning.isActive = showHandoff && showRunning
            handoffAtRight.isActive = !showHandoff || !showRunning
            besideDrawer.isActive = !showHandoff && showRunning
            besideHandoff.isActive = showHandoff
            inCorner.isActive = !showHandoff && !showRunning
        }
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: term.topAnchor, constant: 8),
        ])
        positionFloaters()
        runningDrawer.onVisibilityChange = { _ in positionFloaters() }
        handoffCommands.onVisibilityChange = { _ in positionFloaters() }
    }

    // MARK: Find bar (⌘F)

    /// Reveal + focus the find bar (idempotent — re-⌘F just refocuses). `needle`
    /// pre-fills the field, for the pane-search jump that already knows what it
    /// is looking for.
    func showFindBar(needle: String? = nil) {
        if let needle { findBar.setNeedle(needle) }
        findBar.present()
    }

    /// Hand keyboard focus to the terminal surface. Used after creating a window
    /// or pane from the sidebar, where first responder is still the outline view
    /// and the user's next keystroke would otherwise go nowhere useful.
    func focusTerminal() {
        if let surface = terminal.surfaceView { view.window?.makeFirstResponder(surface) }
    }

    /// Hide the bar and hand keyboard focus back to the terminal surface.
    func hideFindBar() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        if let surface = terminal.surfaceView { view.window?.makeFirstResponder(surface) }
    }

    /// Whether the find bar is currently presented.
    var isFindBarShown: Bool { !findBar.isHidden }

    // MARK: Sidebar toggle (driven by the toolbar Diff / Tree buttons)

    /// Whether the right sidebar rail is currently showing (either content).
    var isSidePanelShown: Bool { rightSidebar.view.superview != nil }

    /// Whether `side` is on screen: its pane is shown and the rail is open.
    func isShown(_ side: SidePanel) -> Bool {
        isSidePanelShown && rightSidebar.isShown(item(side))
    }

    private func item(_ side: SidePanel) -> RightSidebarViewController.Item {
        switch side {
        case .diff: return .diff
        case .tree: return .tree
        case .artifacts: return .artifacts
        }
    }

    /// Toggle a specific side content on/off (independently of the other). Returns
    /// whether *that* content is shown afterward, so the caller knows to populate
    /// it. The rail collapses when the last content is hidden.
    @discardableResult
    func toggle(_ side: SidePanel) -> Bool {
        let shown = rightSidebar.toggle(item(side))
        reconcileRail()
        if shown { focus(side) }
        return shown
    }

    /// Open `side` (if not already shown) and focus it.
    func show(_ side: SidePanel) {
        rightSidebar.show(item(side))
        reconcileRail()
        focus(side)
    }

    /// Master collapse/expand for the whole right sidebar (⌘B / the toolbar
    /// Sidebar button), VS Code style. Collapsing remembers what was shown;
    /// re-expanding restores the remembered panes, defaulting to the Diff.
    func toggleSidebar() {
        if isSidePanelShown {
            rememberedItems = rightSidebar.shownItems
            rightSidebar.hideAll()
            reconcileRail()
        } else {
            let items = rememberedItems.isEmpty ? [.diff] : rememberedItems
            items.forEach { rightSidebar.show($0) }
            reconcileRail()
        }
    }

    /// Flip the sidebar's tree/diff layout between columns and rows.
    func toggleOrientation() { rightSidebar.toggleOrientation() }

    /// Back-compat thin wrappers so existing Diff call sites keep working.
    @discardableResult
    func toggleDiff() -> Bool { toggle(.diff) }
    func showDiff() { show(.diff) }

    private func focus(_ side: SidePanel) {
        view.window?.makeFirstResponder(rightSidebar.controller(for: item(side)).view)
    }

    /// Update the live column count (side-by-side tmux panes in the attached
    /// window). A change re-caps the terminal and re-pins the divider so each
    /// column keeps its readable width.
    func setTerminalColumns(_ count: Int) {
        let clamped = max(1, count)
        guard clamped != terminalColumns else { return }
        terminalColumns = clamped
        terminalWidthCap.constant = terminalCap
        applyWidthCap(reposition: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyWidthCap(reposition: false)
    }

    /// Keep the terminal ≤ its column cap. When the sidebar is already open and the
    /// detail area is wide enough to fit both at full size, pin the divider so the
    /// terminal sits at exactly the cap and the surplus flows to the sidebar. Only
    /// repositions on the narrow→wide transition or an explicit column change, so it
    /// never fights a divider the user has dragged while already wide. With the
    /// sidebar closed the terminal caps the same way — it letterboxes itself via its
    /// width constraint (centered, empty gutters). The width cap never opens the
    /// sidebar: revealing it is always an explicit user action.
    private func applyWidthCap(reposition: Bool) {
        let total = split.bounds.width
        guard total > 0 else { return }
        let isWide = total >= terminalCap + minRailWidth
        if isWide, reposition || !wasWide, !rightSidebar.isEmpty {
            split.setPosition(terminalCap, ofDividerAt: 0)
        }
        wasWide = isWide
    }

    /// Add the rail to the detail split when it has content, remove it when empty
    /// (so the terminal reclaims the full width). Giving it ~45% on first reveal.
    private func reconcileRail() {
        let rail = rightSidebar.view
        if rightSidebar.isEmpty {
            guard rail.superview != nil else { return }
            split.removeArrangedSubview(rail)
            rail.removeFromSuperview()
            if let surface = terminal.surfaceView { view.window?.makeFirstResponder(surface) }
        } else {
            guard rail.superview == nil else { return }
            split.addArrangedSubview(rail)
            split.layoutSubtreeIfNeeded()
            let total = split.bounds.width
            if total > 0 { split.setPosition(total * 0.55, ofDividerAt: 0) }
        }
    }
}

/// The compact floating command menu beside the Running drawer. The first
/// pull-down item supplies the button label; its menu holds the handoff actions.
final class HandoffCommandButton: NSView {
    var onCopyContext: (() -> Void)?
    var onHandoff: (() -> Void)?
    var onHandoffNewWindow: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    private let popup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var titleItem: NSMenuItem?
    private var feedbackWork: DispatchWorkItem?

    override var isHidden: Bool {
        didSet {
            if oldValue != isHidden { onVisibilityChange?(!isHidden) }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.bezelStyle = .rounded
        popup.font = .systemFont(ofSize: 12, weight: .medium)
        popup.toolTip = "Copy the latest exchange, or continue it in a fresh agent conversation"
            + " (new window, or replacing this one)"
        popup.setAccessibilityLabel("Handoff commands")
        addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.topAnchor.constraint(equalTo: topAnchor),
            popup.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rebuildMenu()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setAvailable(_ available: Bool) {
        isHidden = !available
        popup.isEnabled = available
    }

    func flashStatus(_ text: String) {
        feedbackWork?.cancel()
        titleItem?.title = text
        let work = DispatchWorkItem { [weak self] in self?.titleItem?.title = "Handoff" }
        feedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Handoff", action: nil, keyEquivalent: "")
        title.image = NSImage(
            systemSymbolName: "arrowshape.turn.up.right",
            accessibilityDescription: "Handoff")
        menu.addItem(title)
        titleItem = title
        menu.addItem(.separator())

        let copy = menu.addItem(withTitle: "Copy Handoff Context", action: #selector(copyContext), keyEquivalent: "")
        copy.target = self
        let newWindow = menu.addItem(withTitle: "Handoff to New Window", action: #selector(handoffNewWindow), keyEquivalent: "")
        newWindow.target = self
        let handoff = menu.addItem(withTitle: "Replace with Handoff", action: #selector(handoff), keyEquivalent: "")
        handoff.target = self
        popup.menu = menu
    }

    @objc private func copyContext() {
        popup.selectItem(at: 0)
        onCopyContext?()
    }

    @objc private func handoff() {
        popup.selectItem(at: 0)
        onHandoff?()
    }

    @objc private func handoffNewWindow() {
        popup.selectItem(at: 0)
        onHandoffNewWindow?()
    }
}

// MARK: - NSSplitViewDelegate (keep both sides usable)

extension DetailViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMin, 320)  // terminal never narrower than this
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Rail keeps ≥ its min, AND the terminal never exceeds its column cap (so
        // dragging can only give width to the sidebar, not over-widen the terminal).
        min(proposedMax, splitView.bounds.width - minRailWidth, terminalCap)
    }
}

// MARK: - Breadcrumb (clickable top header)

/// One segment of the top breadcrumb. When `rename` is non-nil the segment is
/// clickable and opens an inline rename field; `editText` is what that field is
/// pre-filled with (may differ from the displayed `text` — e.g. a window shows
/// "1: name" but edits just "name").
struct BreadcrumbCrumb {
    enum Rename {
        case session(name: String)
        case window(session: String, window: Int)
        case pane(session: String, window: Int, paneId: String)
    }
    let text: String
    let editText: String
    let rename: Rename?
    /// Set for a status chip (e.g. "⑂ worktree") rather than a path segment: drawn
    /// as a pill with no "/" before it, and this is its tooltip.
    var chipTooltip: String?
    init(_ text: String, editText: String? = nil, rename: Rename? = nil) {
        self.text = text
        self.editText = editText ?? text
        self.rename = rename
    }

    static func chip(_ text: String, tooltip: String) -> BreadcrumbCrumb {
        var c = BreadcrumbCrumb(text)
        c.chipTooltip = tooltip
        return c
    }
}

/// The clickable breadcrumb shown in the window titlebar (hosted as the leading
/// toolbar item, so it shares the toolbar's row instead of adding a second one).
/// It shows the selected node's path as crumbs; clicking a renamable crumb
/// (session / window / pane) swaps it for an inline text field — Enter or
/// focus-loss commits via `onRename`, Esc cancels. Transparent so the titlebar
/// chrome shows through; a fixed height keeps the chrome from jumping as the
/// selection changes.
final class BreadcrumbHeaderView: NSView {
    static let barHeight: CGFloat = 28
    /// Ceiling on the crumb strip so a deep path truncates instead of pushing the
    /// toolbar buttons off the right edge.
    private static let maxWidth: CGFloat = 560
    var onRename: ((BreadcrumbCrumb.Rename, String) -> Void)?
    /// Fires with the strip's measured width whenever the crumbs change. The
    /// toolbar sizes a custom-view item once, when it inserts it, so the hosting
    /// item has to be resized by hand as the selection changes.
    var onWidthChange: ((CGFloat) -> Void)?

    private var crumbs: [BreadcrumbCrumb] = []
    private var editingIndex: Int?
    private var isCancelling = false
    private let stack = NSStackView()
    /// The strip's own width. A toolbar item view gets no width from the toolbar,
    /// so the crumbs' fitting width is pinned here and re-measured on every
    /// selection change.
    private var widthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        widthConstraint = widthAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.barHeight),
            widthConstraint,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setCrumbs(_ c: [BreadcrumbCrumb]) {
        crumbs = c
        editingIndex = nil
        rebuild()
    }

    /// Re-measure the crumbs and resize the strip to fit them (capped), then let
    /// the toolbar re-lay-out around the new width.
    private func resizeToFit() {
        let width = max(1, min(stack.fittingSize.width, Self.maxWidth))
        widthConstraint.constant = width
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
        onWidthChange?(width)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, crumb) in crumbs.enumerated() {
            if let tip = crumb.chipTooltip {
                stack.addArrangedSubview(makeChip(crumb.text, tooltip: tip))
                continue
            }
            if i > 0 { stack.addArrangedSubview(makeLabel("/", dim: true, resistance: .required)) }
            if editingIndex == i, crumb.rename != nil {
                stack.addArrangedSubview(makeField(index: i, text: crumb.editText))
            } else if crumb.rename != nil {
                stack.addArrangedSubview(makeButton(index: i, text: crumb.text))
            } else {
                stack.addArrangedSubview(
                    makeLabel(crumb.text, dim: true, resistance: Self.crumbResistance(i)))
            }
        }
        resizeToFit()
    }

    /// Crumbs resist compression hard enough that the toolbar's flexible space
    /// can't squeeze the strip to nothing, but stay under the required width cap
    /// so a long path truncates. Later crumbs (the selection) resist more, so the
    /// leading ones give way first.
    private static func crumbResistance(_ index: Int) -> NSLayoutConstraint.Priority {
        NSLayoutConstraint.Priority(Float(600 + min(index, 20)))
    }

    private func makeLabel(
        _ text: String, dim: Bool, resistance: NSLayoutConstraint.Priority
    ) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = dim ? .secondaryLabelColor : .labelColor
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(resistance, for: .horizontal)
        return l
    }

    /// A small pill that never shrinks: a chip that truncates says nothing.
    private func makeChip(_ text: String, tooltip: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4
        pill.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        pill.toolTip = tooltip
        pill.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            l.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            l.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            l.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
        ])
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return pill
    }

    private func makeButton(index: Int, text: String) -> NSButton {
        let b = NSButton(title: text, target: self, action: #selector(beginEdit(_:)))
        b.isBordered = false
        b.tag = index
        b.font = .systemFont(ofSize: 12)
        b.contentTintColor = .labelColor
        b.setButtonType(.momentaryChange)
        b.toolTip = "Click to rename"
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.lineBreakMode = .byTruncatingTail
        b.setContentCompressionResistancePriority(Self.crumbResistance(index), for: .horizontal)
        return b
    }

    private func makeField(index: Int, text: String) -> NSTextField {
        let f = NSTextField(string: text)
        f.font = .systemFont(ofSize: 12)
        f.tag = index
        f.delegate = self
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        DispatchQueue.main.async { [weak self, weak f] in
            guard let f else { return }
            self?.window?.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }

    @objc private func beginEdit(_ sender: NSButton) {
        editingIndex = sender.tag
        rebuild()
    }
}

extension BreadcrumbHeaderView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if isCancelling { isCancelling = false; return }
        let idx = field.tag
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editingIndex = nil
        let target = (idx < crumbs.count) ? crumbs[idx].rename : nil
        let changed = idx < crumbs.count && !newName.isEmpty && newName != crumbs[idx].editText
        // Rebuild after the notification settles (don't tear down the field mid-edit).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuild()
            if changed, let target { self.onRename?(target, newName) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            isCancelling = true
            editingIndex = nil
            window?.makeFirstResponder(nil)
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
            return true
        }
        return false
    }
}
