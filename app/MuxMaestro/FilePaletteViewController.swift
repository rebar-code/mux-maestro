import Cocoa

/// Raised by the ⌘P quick-open palette when the user picks a file.
protocol FilePaletteDelegate: AnyObject {
    func filePaletteDidActivate(relativePath: String)
}

/// An NSPanel that can become key so its field accepts typing.
private final class FloatingPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The ⌘P quick-open palette: a Zed/VS-Code-style floating command menu that
/// fuzzy-matches the selected session's repo file *names* and opens the chosen
/// file in the editor. Distinct from the ⌘⇧F in-tree content search — this is a
/// fast "go to file" by name. Matching is `FuzzyMatch` over an in-memory file
/// list (loaded once when the palette opens), so filtering is instant per
/// keystroke with no debounce.
final class FilePaletteViewController: NSViewController {
    weak var delegate: FilePaletteDelegate?

    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scroll = NSScrollView()

    /// The full candidate list (repo-relative paths) set by the AppDelegate.
    private var files: [String] = []
    /// The current ranked rows (path + matched char indices) shown in the table.
    private var rows: [(path: String, indices: [Int])] = []

    /// Cap on how many ranked results to show — the rest are off-screen anyway.
    private static let resultCap = 200

    private let rowFont = NSFont.systemFont(ofSize: 13)
    private let rowBold = NSFont.systemFont(ofSize: 13, weight: .semibold)

    var currentQuery: String { searchField.stringValue }

    private lazy var panel: FloatingPalettePanel = {
        let p = FloatingPalettePanel(
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

        searchField.placeholderString = "Go to file  (⌘P)"
        searchField.font = .systemFont(ofSize: 15)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = SidebarPalette.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Footer: the sibling pickers' shortcuts, mirroring the ⌘K palette.
        footerLabel.attributedStringValue = paletteFooterString(
            [(combo: "⌘K", label: "Sessions"), (combo: "⇧⌘F", label: "Search")])
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("file"))
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
        // the window adopt the view's fitting size. Nothing pins a height for the
        // results scroll view, so without this the window collapses to just the
        // search field + status label and the file list gets 0 height (invisible).
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

    /// Set the candidate file list (repo-relative paths) and re-filter for the
    /// current query. Called by the AppDelegate once the list is loaded.
    func setFiles(_ files: [String]) {
        self.files = files
        refilter()
    }

    /// Set a transient status line (e.g. "Resolving repo…" / "Not a git repo").
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: Filtering

    private func refilter() {
        rows = FuzzyMatch.rank(query: currentQuery, candidates: files, limit: Self.resultCap)
        tableView.reloadData()
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        let q = currentQuery.trimmingCharacters(in: .whitespaces)
        if files.isEmpty {
            statusLabel.stringValue = "No files"
        } else if q.isEmpty {
            statusLabel.stringValue = "\(files.count) file\(files.count == 1 ? "" : "s")"
        } else {
            statusLabel.stringValue = rows.isEmpty ? "No matches" : "\(rows.count) match\(rows.count == 1 ? "" : "es")"
        }
    }

    // MARK: Activation + navigation

    @objc private func handleClick() { activateSelected() }

    private func activateSelected() {
        let r = tableView.selectedRow
        guard r >= 0, r < rows.count else { return }
        delegate?.filePaletteDidActivate(relativePath: rows[r].path)
        close()
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max((current < 0 ? -1 : current) + delta, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

// MARK: - NSSearchFieldDelegate (instant filter + key routing)

extension FilePaletteViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
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

extension FilePaletteViewController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) { close() }
}

// MARK: - Table data source / delegate

extension FilePaletteViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("fileRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id: id)
        let (path, indices) = rows[row]
        cell.textField?.attributedStringValue = display(path: path, indices: indices)
        return cell
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        // Force a single line: a long path must truncate, never wrap into a second
        // line that would overflow the fixed row height and overlap the next row.
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The path with the directory prefix dimmed, the basename in text color, and
    /// the fuzzy-matched characters accented + bold.
    private func display(path: String, indices: [Int]) -> NSAttributedString {
        let chars = Array(path)
        let lastSlash = chars.lastIndex(of: "/") ?? -1
        let matched = Set(indices)
        let out = NSMutableAttributedString()
        for (i, ch) in chars.enumerated() {
            let attrs: [NSAttributedString.Key: Any]
            if matched.contains(i) {
                attrs = [.foregroundColor: SidebarPalette.accent, .font: rowBold]
            } else {
                attrs = [.foregroundColor: i > lastSlash ? SidebarPalette.text : SidebarPalette.muted,
                         .font: rowFont]
            }
            out.append(NSAttributedString(string: String(ch), attributes: attrs))
        }
        // Carry the truncation mode in the string itself — setting
        // `attributedStringValue` otherwise ignores the field's lineBreakMode and
        // word-wraps a long path onto a second (overlapping) line.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }
}
