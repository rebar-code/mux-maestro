import Cocoa

/// A table that reports the keys the PRs screen navigates with instead of
/// beeping on them: ↩ acts on the row, Esc closes, ← / → move between panes.
private final class PRScreenTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        case 123 where onLeft != nil: onLeft?()
        case 124 where onRight != nil: onRight?()
        default: super.keyDown(with: event)
        }
    }
}

/// The overlay's backdrop. Opaque, and an arrow cursor everywhere, so the
/// terminal underneath neither shows through nor leaks its I-beam.
private final class PRScreenBackdrop: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        SidebarPalette.bg.setFill()
        dirtyRect.fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// The PRs screen: every pull request a window is about, grouped by repo, and
/// the windows about the selected one. It starts from the PR and jumps to the
/// window — the sidebar's chips go the other way.
///
/// Shown as a full-bleed overlay on the main window's content view, never by
/// swapping `window.contentViewController`: detaching the split view would tear
/// down every live Ghostty surface (`TerminalSurfaceView` frees its surface when
/// it leaves the window). The terminals stay mounted and running underneath.
final class PullRequestsViewController: NSViewController {
    /// One window about a PR: what the right pane lists and what focusing jumps to.
    struct WindowRow: Equatable {
        let ref: WindowRef
        let name: String
        let attention: AttentionStatus
    }

    /// One PR and the windows about it. `slug` is the repo it groups under.
    /// `sessions` are the transcripts a PR-number search found for it.
    struct Entry: Equatable {
        let slug: String
        let pr: PullRequest
        let windows: [WindowRow]
        var sessions: [PRSessionHit] = []
    }

    /// ↩ / double-click on a window row.
    var onFocusWindow: ((WindowRef) -> Void)?
    /// Esc or the close button.
    var onClose: (() -> Void)?
    /// ↩ in the search field with a PR number: find every session about it.
    var onSearch: ((Int) -> Void)?
    /// ↩ / double-click on a session the search found.
    var onOpenSession: ((PRSessionHit) -> Void)?

    private enum ListRow {
        case repo(String)
        case pr(Entry)
    }

    /// A right-pane row: a live window, or a transcript found by search.
    private enum DetailRow: Equatable {
        case window(WindowRow)
        case session(PRSessionHit)
    }

    /// A PR-number search. `hits` is nil while the grep runs; `prs` holds the
    /// title and state gh reported per repo.
    private struct Search {
        let number: Int
        var hits: [PRSessionHit]?
        var prs: [String: PullRequest]
    }

    /// Every PR the sidebar knows, as last handed in by the poll.
    private var liveEntries: [Entry] = []
    private var search: Search?
    private var entries: [Entry] = []
    private var listRows: [ListRow] = []
    private var shownRows: [DetailRow] = []

    private let prTable = PRScreenTableView()
    private let windowTable = PRScreenTableView()
    private let prScroll = NSScrollView()
    private let windowScroll = NSScrollView()
    private let divider = NSBox()
    private let emptyLabel = NSTextField(labelWithString: "No pull requests")
    private let searchField = NSSearchField()
    private let spinner = NSProgressIndicator()

    private static let prRowHeight: CGFloat = 28
    private static let repoRowHeight: CGFloat = 26
    private static let windowRowHeight: CGFloat = 28

    var isShown: Bool { isViewLoaded && view.superview != nil }

    override func loadView() {
        let root = PRScreenBackdrop()

        let title = NSTextField(labelWithString: "Pull Requests")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = SidebarPalette.text
        title.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
            target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = SidebarPalette.muted
        close.toolTip = "Close (Esc)"
        close.translatesAutoresizingMaskIntoConstraints = false

        configure(prTable, scroll: prScroll, column: "pr")
        // The right pane is always "the windows about the selected PR".
        prTable.allowsEmptySelection = false
        prTable.doubleAction = #selector(prDoubleClicked)
        prTable.onReturn = { [weak self] in self?.moveToWindows() }
        prTable.onRight = { [weak self] in self?.moveToWindows() }
        prTable.onEscape = { [weak self] in self?.onClose?() }

        configure(windowTable, scroll: windowScroll, column: "window")
        windowTable.doubleAction = #selector(windowDoubleClicked)
        windowTable.onReturn = { [weak self] in self?.focusSelectedWindow() }
        windowTable.onLeft = { [weak self] in self?.view.window?.makeFirstResponder(self?.prTable) }
        windowTable.onEscape = { [weak self] in self?.onClose?() }

        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = SidebarPalette.border
        divider.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = SidebarPalette.muted
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "PR #"
        searchField.toolTip = "Find every Claude and Codex session about a PR number"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        for v in [title, close, searchField, spinner, prScroll, divider, windowScroll, emptyLabel] {
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -12),
            searchField.widthAnchor.constraint(equalToConstant: 180),
            spinner.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8),

            prScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            prScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            prScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            prScroll.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.55, constant: -8),

            divider.topAnchor.constraint(equalTo: prScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: prScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            windowScroll.topAnchor.constraint(equalTo: prScroll.topAnchor),
            windowScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            windowScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            windowScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    private func configure(_ table: NSTableView, scroll: NSScrollView, column: String) {
        let col = NSTableColumn(identifier: .init(column))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = SidebarPalette.bg
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.floatsGroupRows = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = SidebarPalette.bg
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Presentation

    /// Cover `container` edge to edge and take the keyboard.
    func show(in container: NSView) {
        guard !isShown else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view.window?.makeFirstResponder(searchField)
    }

    func hide() { view.removeFromSuperview() }

    // MARK: Data in

    /// Take the poll's PR list. During a search the screen shows only the
    /// searched number, rebuilt from this list plus the search's hits.
    func setEntries(_ new: [Entry]) {
        loadViewIfNeeded()
        liveEntries = new
        display(search.map { Self.searchEntries(live: new, search: $0) } ?? new)
    }

    /// The search's result: every session about PR `number`, and gh's view of
    /// the PR per repo. Dropped when the user has searched for something else.
    func setSearchResults(number: Int, hits: [PRSessionHit], prs: [String: PullRequest]) {
        guard search?.number == number else { return }
        search?.hits = hits
        search?.prs = prs
        spinner.stopAnimation(nil)
        setEntries(liveEntries)
    }

    /// The searched PR in every repo that has it: live entries with that number,
    /// plus one entry per repo only a transcript knows about. Each carries the
    /// sessions found for its repo.
    private static func searchEntries(live: [Entry], search: Search) -> [Entry] {
        let hits = search.hits ?? []
        func sessions(_ slug: String) -> [PRSessionHit] {
            hits.filter { $0.slug.lowercased() == slug.lowercased() }
        }
        var out = live.filter { $0.pr.number == search.number }
        for i in out.indices { out[i].sessions = sessions(out[i].slug) }
        var known = Set(out.map { $0.slug.lowercased() })
        for hit in hits where !known.contains(hit.slug.lowercased()) {
            known.insert(hit.slug.lowercased())
            let pr = search.prs[hit.slug] ?? PullRequest(
                number: search.number, title: "",
                url: "https://github.com/\(hit.slug)/pull/\(search.number)", isDraft: false)
            out.append(Entry(slug: hit.slug, pr: pr, windows: [], sessions: sessions(hit.slug)))
        }
        return out.sorted { $0.slug.lowercased() < $1.slug.lowercased() }
    }

    /// Replace the list, keeping the selected PR (by URL) and right-pane row
    /// selected across the poll's refreshes. A no-op when nothing changed, so a
    /// 1.5s poll doesn't reset type-select or scroll.
    private func display(_ new: [Entry]) {
        let empty = new.isEmpty
        emptyLabel.stringValue = switch search {
        case .some(let s) where s.hits == nil: "Searching…"
        case .some(let s): "No sessions for #\(s.number)"
        case .none: "No pull requests"
        }
        emptyLabel.isHidden = !empty
        for v in [prScroll, windowScroll, divider] as [NSView] { v.isHidden = empty }
        guard new != entries || listRows.isEmpty else { return }
        let keepPR = selectedEntry?.pr.url
        let keepRow = windowTable.selectedRow >= 0 && windowTable.selectedRow < shownRows.count
            ? shownRows[windowTable.selectedRow] : nil

        entries = new
        listRows = []
        var lastSlug: String?
        for e in new {
            if e.slug != lastSlug { listRows.append(.repo(e.slug)); lastSlug = e.slug }
            listRows.append(.pr(e))
        }

        prTable.reloadData()
        let row = listRows.firstIndex { if case .pr(let e) = $0 { return e.pr.url == keepPR } else { return false } }
            ?? listRows.firstIndex { if case .pr = $0 { return true } else { return false } }
        if let row {
            prTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        reloadWindows(keeping: keepRow)
    }

    private var selectedEntry: Entry? {
        let row = prTable.selectedRow
        guard row >= 0, row < listRows.count, case .pr(let e) = listRows[row] else { return nil }
        return e
    }

    private func reloadWindows(keeping kept: DetailRow?) {
        let entry = selectedEntry
        shownRows = (entry?.windows ?? []).map(DetailRow.window)
            + (entry?.sessions ?? []).map(DetailRow.session)
        windowTable.reloadData()
        let i = shownRows.firstIndex { row in
            switch (row, kept) {
            case (.window(let a), .window(let b)?): return a.ref == b.ref
            case (.session(let a), .session(let b)?): return a.sessionId == b.sessionId
            default: return false
            }
        }
        if let i {
            windowTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
    }

    // MARK: Actions

    @objc private func searchSubmitted() {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            search = nil
            spinner.stopAnimation(nil)
            setEntries(liveEntries)
            return
        }
        guard let number = PRSessionSearch.number(fromQuery: text) else { NSSound.beep(); return }
        search = Search(number: number, hits: nil, prs: [:])
        spinner.startAnimation(nil)
        setEntries(liveEntries)
        onSearch?(number)
    }

    private func moveToWindows() {
        guard !shownRows.isEmpty else { return }
        if windowTable.selectedRow < 0 {
            windowTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(windowTable)
    }

    private func focusSelectedWindow() {
        let row = windowTable.selectedRow
        guard row >= 0, row < shownRows.count else { return }
        switch shownRows[row] {
        case .window(let w): onFocusWindow?(w.ref)
        case .session(let hit): onOpenSession?(hit)
        }
    }

    @objc private func windowDoubleClicked() {
        guard windowTable.clickedRow >= 0 else { return }
        focusSelectedWindow()
    }

    /// Double-clicking a PR opens it on GitHub, like clicking its sidebar chip.
    @objc private func prDoubleClicked() {
        guard prTable.clickedRow >= 0, let url = URL(string: selectedEntry?.pr.url ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closeClicked() { onClose?() }
}

// MARK: - Search field

extension PullRequestsViewController: NSSearchFieldDelegate {
    /// ↓ leaves the field for the PR list; Esc on an empty field closes the screen.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            view.window?.makeFirstResponder(prTable)
            return true
        case #selector(NSResponder.cancelOperation(_:)) where searchField.stringValue.isEmpty:
            onClose?()
            return true
        default:
            return false
        }
    }
}

// MARK: - Tables

extension PullRequestsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === prTable ? listRows.count : shownRows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === prTable else { return Self.windowRowHeight }
        if case .repo = listRows[row] { return Self.repoRowHeight }
        return Self.prRowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === prTable, case .repo = listRows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === prTable, case .repo = listRows[row] else { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === prTable else { return }
        reloadWindows(keeping: nil)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === windowTable {
            switch shownRows[row] {
            case .window(let w):
                let cell = tableView.makeView(withIdentifier: WindowCell.id, owner: self) as? WindowCell ?? WindowCell()
                cell.configure(w)
                return cell
            case .session(let hit):
                let cell = tableView.makeView(withIdentifier: SessionCell.id, owner: self) as? SessionCell ?? SessionCell()
                cell.configure(hit)
                return cell
            }
        }
        switch listRows[row] {
        case .repo(let slug):
            let cell = tableView.makeView(withIdentifier: RepoCell.id, owner: self) as? RepoCell ?? RepoCell()
            cell.label.stringValue = slug.isEmpty ? "—" : slug
            return cell
        case .pr(let entry):
            let cell = tableView.makeView(withIdentifier: PRCell.id, owner: self) as? PRCell ?? PRCell()
            cell.configure(entry)
            return cell
        }
    }
}

/// A repo heading in the PR list.
private final class RepoCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("prRepo")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = SidebarPalette.muted
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// A PR row: state glyph, number and title, and how many windows are about it.
/// Glyph and tint come from `PRChipButton` so a merged PR reads the same here as
/// on its sidebar chip.
private final class PRCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("prRow")
    private let glyph = NSImageView()
    private let number = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        glyph.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        // A clipped number is a different number — it never yields.
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        number.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .systemFont(ofSize: 13)
        title.textColor = SidebarPalette.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = SidebarPalette.muted
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [glyph, number, title, NSView(), count])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(8, after: number)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = title
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ entry: PullRequestsViewController.Entry) {
        let pr = entry.pr
        let tint = PRChipButton.tint(pr)
        glyph.image = NSImage(systemSymbolName: PRChipButton.symbolName(pr),
                              accessibilityDescription: pr.stateWord)
        glyph.contentTintColor = tint
        number.stringValue = "#\(pr.number)"
        number.textColor = tint
        title.stringValue = pr.title
        count.stringValue = "\(entry.windows.count + entry.sessions.count)"
        toolTip = pr.chipTooltip
        count.toolTip = [
            entry.windows.count == 1 ? "1 window" : "\(entry.windows.count) windows",
            entry.sessions.isEmpty ? nil
                : entry.sessions.count == 1 ? "1 session" : "\(entry.sessions.count) sessions",
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A window row: attention dot, window name, and where it lives.
private final class WindowCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("prWindow")
    private let dot = AttentionDotView()
    private let name = NSTextField(labelWithString: "")
    private let place = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.font = .systemFont(ofSize: 13)
        name.textColor = SidebarPalette.text
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        place.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        place.textColor = SidebarPalette.muted
        place.lineBreakMode = .byTruncatingHead
        place.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [dot, name, NSView(), place])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ row: PullRequestsViewController.WindowRow) {
        dot.status = row.attention
        name.stringValue = row.name
        let target = "\(row.ref.session):\(row.ref.window)"
        place.stringValue = row.ref.host.isLocal ? target : "\(row.ref.host.name) › \(target)"
    }
}

/// A session a PR-number search found: agent, folder, and how long ago it last
/// did work. ↩ resumes it, or jumps to it when it is still running.
private final class SessionCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("prSession")
    private let agent = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        agent.font = .systemFont(ofSize: 11, weight: .semibold)
        agent.textColor = SidebarPalette.muted
        agent.setContentHuggingPriority(.required, for: .horizontal)
        agent.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.font = .systemFont(ofSize: 13)
        name.textColor = SidebarPalette.text
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        age.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        age.textColor = SidebarPalette.muted
        age.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [agent, name, NSView(), age])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        NSLayoutConstraint.activate([
            agent.widthAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ hit: PRSessionHit) {
        agent.stringValue = hit.agent == .claude ? "Claude" : "Codex"
        name.stringValue = ClaudeSessionRecovery.suggestedSessionName(forDirectory: hit.cwd)
        age.stringValue = WorktreeMetrics.ageLabel(hit.lastActive, now: Date())
        toolTip = "\(hit.cwd)\n\(hit.agent.resumeCommand(sessionId: hit.sessionId))"
    }
}
