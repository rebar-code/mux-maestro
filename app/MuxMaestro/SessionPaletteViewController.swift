import Cocoa

/// Raised by the ⌘K switcher when the user picks a session, window or pane.
protocol SessionPaletteDelegate: AnyObject {
    func sessionPaletteDidActivate(_ entry: SwitcherEntry, service: TmuxService)
    /// A scrollback hit was picked: go to its pane and find `needle` there.
    func sessionPaletteDidActivateScrollback(_ hit: PaneMatch, needle: String)
    /// Nothing matched the typed text — create a new tmux session named `name`.
    func sessionPaletteDidRequestNewSession(name: String)
}

/// An NSPanel that can become key so its field accepts typing.
private final class FloatingSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Build the muted footer line shown at the bottom of the ⌘K / ⌘P palettes:
/// each `(combo, label)` pair with the chord emphasized in text color and the
/// label muted. Shared by both palettes for a consistent, discoverable footer.
func paletteFooterString(_ pairs: [(combo: String, label: String)]) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (i, pair) in pairs.enumerated() {
        if i > 0 {
            out.append(NSAttributedString(
                string: "     ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        }
        out.append(NSAttributedString(string: pair.combo + " ", attributes: [
            .foregroundColor: SidebarPalette.text,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]))
        out.append(NSAttributedString(string: pair.label, attributes: [
            .foregroundColor: SidebarPalette.muted,
            .font: NSFont.systemFont(ofSize: 11),
        ]))
    }
    return out
}

/// The ⌘K switcher: a Zed/VS-Code-style floating palette that fuzzy-matches
/// tmux sessions, windows and panes across every host and jumps to the chosen
/// one — the session analog of the ⌘P quick-open file palette
/// (`FilePaletteViewController`). Matching is `SessionSwitcher.rank` over an
/// in-memory list captured when the palette opens, so filtering is instant per
/// keystroke. Below the name matches come scrollback hits — one per pane whose
/// captured scrollback contains the query — matched off-main as each host's
/// capture arrives.
final class SessionPaletteViewController: NSViewController {
    weak var delegate: SessionPaletteDelegate?

    /// A switchable row: the session/window/pane entry (candidate string, name
    /// offset, jump target) plus the service that owns it.
    struct Item {
        let entry: SwitcherEntry
        let service: TmuxService
        /// The session's repo favicon, when resolved — shown as the row's leading
        /// icon (host glyph fallback otherwise), matching the sidebar + ⌘` cycler.
        let favicon: NSImage?
    }

    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scroll = NSScrollView()

    /// The full candidate list set by the AppDelegate when the palette opens.
    private var items: [Item] = []
    /// The current ranked rows (item + matched char indices) shown in the table.
    private var rows: [(item: Item, indices: [Int])] = []
    /// Scrollback hits shown below the name matches, and the query that found
    /// them — the needle handed to the find bar when one is picked. They can lag
    /// the field by one match pass while typing.
    private var hits: [PaneMatch] = []
    private var hitsQuery = ""

    /// Every captured pane and its scrollback, filled per host as captures land.
    private var scrollbackPanes: [PaneSearchTarget] = []
    private var scrollbackCaptures: [String: [String]] = [:]
    /// Bumped per palette open, so a slow host's capture from an earlier open is
    /// dropped instead of joining this one.
    private var scrollbackGeneration = 0
    /// Bumped per match pass, so only the newest pass's hits are shown.
    private var hitsToken = 0
    private let matchQueue = DispatchQueue(label: "muxmaestro.switcher.scrollback", qos: .userInitiated)

    /// The trimmed query, usable as a new session name (empty → no create row).
    private var createName: String { currentQuery.trimmingCharacters(in: .whitespaces) }
    /// Show a "create session" action row when no name matched what was typed, so
    /// typing a fresh name and hitting ↩ makes that session.
    private var showsCreateRow: Bool { rows.isEmpty && !createName.isEmpty }
    /// Total table rows = name matches, then scrollback hits, then the trailing
    /// create row when shown.
    private var totalRows: Int { rows.count + hits.count + (showsCreateRow ? 1 : 0) }

    /// Cap on how many ranked results to show — the rest are off-screen anyway.
    private static let resultCap = 200

    private let rowFont = NSFont.systemFont(ofSize: 13)
    private let rowBold = NSFont.systemFont(ofSize: 13, weight: .semibold)

    var currentQuery: String { searchField.stringValue }

    private lazy var panel: FloatingSwitcherPanel = {
        let p = FloatingSwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.contentViewController = self
        p.delegate = self
        return p
    }()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = SidebarPalette.bg.cgColor

        searchField.placeholderString = "Go to session, window or pane  (⌘K)"
        searchField.font = .systemFont(ofSize: 15)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = SidebarPalette.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Footer: the sibling pickers' shortcuts, so ⌘P/⇧⌘F stay discoverable
        // without cramming them into this palette as tabs.
        footerLabel.attributedStringValue = paletteFooterString(
            [(combo: "⌘P", label: "Files"), (combo: "⇧⌘F", label: "Search")])
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = SidebarPalette.bg
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick)

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = SidebarPalette.bg
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(statusLabel)
        container.addSubview(scroll)
        container.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),

            footerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        self.view = container
        // Assigning an Auto Layout view as the panel's contentViewController makes
        // the window adopt the view's fitting size; without a fixed preferred size
        // the results scroll view collapses to 0 height (see FilePaletteViewController).
        preferredContentSize = NSSize(width: 620, height: 420)
    }

    // MARK: Presentation

    /// Show the palette over `parent`, near top-center, and focus the field.
    func present(over parent: NSWindow) {
        let p = panel
        let size = p.frame.size
        let pf = parent.frame
        p.setFrameOrigin(NSPoint(x: pf.midX - size.width / 2, y: pf.maxY - size.height - 80))
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(location: currentQuery.count, length: 0)
    }

    private func close() { panel.close() }

    /// Set the candidate session list and re-filter for the current query.
    func setSessions(_ items: [Item]) {
        self.items = items
        refilter()
    }

    /// Drop the previous open's scrollback and return the generation that
    /// `addScrollback` must quote for this open.
    func beginScrollback() -> Int {
        scrollbackGeneration += 1
        hitsToken += 1
        scrollbackPanes = []
        scrollbackCaptures = [:]
        hits = []
        return scrollbackGeneration
    }

    /// One host's captured panes landed: add them to the corpus and re-match.
    func addScrollback(panes: [PaneSearchTarget], captures: [String: [String]], generation: Int) {
        guard generation == scrollbackGeneration else { return }
        scrollbackPanes += panes
        scrollbackCaptures.merge(captures) { _, new in new }
        matchScrollback()
    }

    // MARK: Filtering

    private func refilter() {
        rows = SessionSwitcher.rank(items, query: currentQuery, limit: Self.resultCap, entry: \.entry)
        matchScrollback()
        reloadRows(selectFirst: true)
    }

    /// Match the current query against the captured scrollback off-main. A query
    /// too short to search clears the hits at once; otherwise the old hits stay
    /// until the new pass lands, so the list doesn't flicker per keystroke.
    private func matchScrollback() {
        hitsToken += 1
        let query = currentQuery
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count
                >= SessionSwitcher.minScrollbackQuery,
              !scrollbackPanes.isEmpty
        else {
            hits = []
            return
        }
        let token = hitsToken
        let panes = scrollbackPanes, captures = scrollbackCaptures
        matchQueue.async { [weak self] in
            let found = SessionSwitcher.scrollbackHits(query: query, captures: captures, panes: panes)
            DispatchQueue.main.async {
                guard let self, self.hitsToken == token else { return }
                self.hits = Array(found.prefix(Self.resultCap))
                self.hitsQuery = query
                self.reloadRows(selectFirst: false)
            }
        }
    }

    /// Reload the table and status line. `selectFirst` pre-selects row 0 (the top
    /// match, or the create row when nothing matched); otherwise a selected name
    /// row keeps its place, since scrollback hits only ever change below it.
    private func reloadRows(selectFirst: Bool) {
        let kept = tableView.selectedRow
        tableView.reloadData()
        let row = !selectFirst && kept >= 0 && kept < rows.count ? kept : 0
        if totalRows > 0 {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let q = currentQuery.trimmingCharacters(in: .whitespaces)
        let sessionCount = items.filter { $0.entry.target == .session }.count
        let matches = rows.count + hits.count
        if items.isEmpty && !showsCreateRow {
            statusLabel.stringValue = "No sessions"
        } else if q.isEmpty {
            statusLabel.stringValue = "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
        } else if matches == 0 {
            statusLabel.stringValue = "No matches — ↩ to create"
        } else {
            statusLabel.stringValue = "\(matches) match\(matches == 1 ? "" : "es")"
        }
    }

    // MARK: Activation + navigation

    @objc private func handleClick() { activateSelected() }

    private func activateSelected() {
        let r = tableView.selectedRow
        guard r >= 0 else { return }
        if r < rows.count {
            let item = rows[r].item
            delegate?.sessionPaletteDidActivate(item.entry, service: item.service)
        } else if r < rows.count + hits.count {
            delegate?.sessionPaletteDidActivateScrollback(hits[r - rows.count], needle: hitsQuery)
        } else if showsCreateRow {
            delegate?.sessionPaletteDidRequestNewSession(name: createName)
        } else {
            return
        }
        close()
    }

    private func moveSelection(by delta: Int) {
        guard totalRows > 0 else { return }
        let current = tableView.selectedRow
        let next = min(max((current < 0 ? -1 : current) + delta, 0), totalRows - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

// MARK: - NSSearchFieldDelegate (instant filter + key routing)

extension SessionPaletteViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        // Tab cycles the list too, so the user can Tab between matches (⇧Tab up).
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); return true
        default:
            return false
        }
    }
}

// MARK: - NSWindowDelegate (close on losing key)

extension SessionPaletteViewController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) { close() }
}

// MARK: - Table data source / delegate

extension SessionPaletteViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { totalRows }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sessionRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id: id)
        if row < rows.count {
            let (item, indices) = rows[row]
            cell.textField?.attributedStringValue = display(item: item, indices: indices)
            applyIcon(cell, item: item)
        } else if row < rows.count + hits.count {
            cell.textField?.attributedStringValue = display(hit: hits[row - rows.count])
            cell.imageView?.image = NSImage(
                systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Scrollback")
            cell.imageView?.contentTintColor = SidebarPalette.muted
        } else {
            cell.textField?.attributedStringValue = displayCreate(name: createName)
            cell.imageView?.image = NSImage(
                systemSymbolName: "plus.circle", accessibilityDescription: nil)
            cell.imageView?.contentTintColor = SidebarPalette.accent
        }
        return cell
    }

    /// The row's leading icon: the session's favicon when resolved, else the muted
    /// host glyph (matching the sidebar row + ⌘` cycler HUD).
    private func applyIcon(_ cell: NSTableCellView, item: Item) {
        if let fav = item.favicon {
            cell.imageView?.image = fav
            cell.imageView?.contentTintColor = nil
        } else {
            cell.imageView?.image = NSImage(
                systemSymbolName: item.entry.host.isLocal ? "laptopcomputer" : "server.rack",
                accessibilityDescription: nil)
            cell.imageView?.contentTintColor = SidebarPalette.muted
        }
    }

    /// A scrollback hit: the pane's "host/session/window" dimmed, then the matched
    /// line (leading indent dropped) with the query accented + bold.
    private func display(hit: PaneMatch) -> NSAttributedString {
        let pane = hit.pane
        let place = (pane.host.isLocal ? "" : "\(pane.host.name)/") + "\(pane.session)/\(pane.windowName)"
        let out = NSMutableAttributedString(string: place + "   ",
            attributes: [.foregroundColor: SidebarPalette.muted, .font: rowFont])
        let indent = hit.lineText.prefix { $0.isWhitespace }
        let text = String(hit.lineText.dropFirst(indent.count))
        let shift = indent.utf8.count
        let line = NSMutableAttributedString(string: text,
            attributes: [.foregroundColor: SidebarPalette.text, .font: rowFont])
        for r in hit.highlights where r.lowerBound >= shift {
            guard let ns = TreeViewController.nsRange(
                byteRange: (r.lowerBound - shift)..<(r.upperBound - shift), in: text) else { continue }
            line.addAttributes([.foregroundColor: SidebarPalette.accent, .font: rowBold], range: ns)
        }
        out.append(line)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The trailing "create session" row: a "+" and the typed name, both accented.
    private func displayCreate(name: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "＋  ",
            attributes: [.foregroundColor: SidebarPalette.accent, .font: rowBold]))
        out.append(NSAttributedString(string: "Create session ",
            attributes: [.foregroundColor: SidebarPalette.muted, .font: rowFont]))
        out.append(NSAttributedString(string: "“\(name)”",
            attributes: [.foregroundColor: SidebarPalette.accent, .font: rowBold]))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        cell.addSubview(icon)
        cell.imageView = icon
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        // Force a single line: a long candidate must truncate, never wrap into a
        // second line that would overflow the fixed row height and overlap the next.
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The candidate with its prefix (host, session, window) dimmed, the row name in
    /// text color, and the fuzzy-matched characters accented + bold.
    private func display(item: Item, indices: [Int]) -> NSAttributedString {
        let chars = Array(item.entry.candidate)
        let matched = Set(indices)
        let out = NSMutableAttributedString()
        for (i, ch) in chars.enumerated() {
            let attrs: [NSAttributedString.Key: Any]
            if matched.contains(i) {
                attrs = [.foregroundColor: SidebarPalette.accent, .font: rowBold]
            } else {
                attrs = [.foregroundColor: i >= item.entry.nameStart ? SidebarPalette.text : SidebarPalette.muted,
                         .font: rowFont]
            }
            out.append(NSAttributedString(string: String(ch), attributes: attrs))
        }
        // Carry the truncation mode in the string itself — setting
        // `attributedStringValue` otherwise ignores the field's lineBreakMode and
        // word-wraps a long candidate onto a second (overlapping) line.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }
}
