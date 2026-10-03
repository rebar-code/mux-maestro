import Cocoa

/// A borderless floating panel that never becomes key — so it can't steal first
/// responder from the terminal while the ⌘` cycler is open. The AppDelegate's
/// local event monitor drives selection and detects the ⌘ release; this panel is
/// purely a display surface.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The cycler's table. The panel never becomes key, so without this a click would
/// be swallowed as a window-activation attempt instead of hitting a row — accept
/// the first mouse so a single click selects and commits.
private final class CyclerTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The ⌘` most-recently-used window cycler HUD: a compact, centered list of
/// recent windows — flat across every session — with the current pick
/// highlighted, Cmd+Tab-style. Modeled on the ⌘K palette's floating panel, but
/// non-activating — see `NonKeyPanel`.
final class SessionCyclerOverlay: NSViewController {
    /// One cycler entry: the window it points at, that window's name, and the
    /// session's resolved favicon (nil → the generic host glyph is shown
    /// instead, matching the sidebar row).
    struct Item {
        let ref: WindowRef
        let title: String
        let favicon: NSImage?
    }

    private var items: [Item] = []
    private var selected = 0
    /// Screen pointer position at show time / last accepted hover — see `hover(row:)`.
    private var lastMouseLocation: NSPoint = .zero
    private let tableView = CyclerTableView()
    private let scroll = NSScrollView()

    /// Invoked when a row is clicked (mouse commit) — the AppDelegate wires this to
    /// the same commit path as the keyboard ⌘-release, reusing `selectedRef`.
    var onCommit: (() -> Void)?

    private static let rowHeight: CGFloat = 26
    private static let panelWidth: CGFloat = 420
    /// Cap the visible height so a long MRU list scrolls instead of covering the
    /// window; the selected row is always scrolled into view.
    private static let maxVisibleRows = 12

    /// The currently highlighted window, or nil when the overlay is empty.
    var selectedRef: WindowRef? {
        items.indices.contains(selected) ? items[selected].ref : nil
    }

    private lazy var panel: NonKeyPanel = {
        let p = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentViewController = self
        return p
    }()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = SidebarPalette.bg.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = SidebarPalette.border.cgColor

        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none  // we draw the highlight ourselves
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scroll.documentView = tableView
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        self.view = container
    }

    // MARK: Presentation

    /// Show the HUD centered over `parent` with `windows`, highlighting index
    /// `selected` (Cmd+Tab-style: index 1, the previous window, when ≥2 exist).
    func show(over parent: NSWindow, windows: [Item], selected: Int) {
        self.items = windows
        self.selected = windows.indices.contains(selected) ? selected : 0
        lastMouseLocation = NSEvent.mouseLocation
        loadViewIfNeeded()
        tableView.reloadData()

        let visible = min(windows.count, Self.maxVisibleRows)
        let height = CGFloat(visible) * (Self.rowHeight + 2) + 16
        let p = panel
        p.setContentSize(NSSize(width: Self.panelWidth, height: height))
        let pf = parent.frame
        p.setFrameOrigin(NSPoint(
            x: pf.midX - Self.panelWidth / 2,
            y: pf.midY - height / 2))
        p.orderFrontRegardless()
        scrollSelectedToVisible()
    }

    /// Step the selection by `delta`, wrapping around the ends (Cmd+Tab-style).
    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selected = ((selected + delta) % count + count) % count
        tableView.reloadData()
        scrollSelectedToVisible()
    }

    func hide() { panel.orderOut(nil) }

    /// A mouse hover moved onto `row` — track the highlight to it so the keyboard
    /// selection and the pointer stay in sync (Cmd+Tab-with-mouse behavior).
    /// Only a pointer that actually moved counts as hover. The panel can appear (or
    /// scroll) under a resting cursor, which fires `mouseEntered` with no movement.
    func hover(row: Int) {
        let loc = NSEvent.mouseLocation
        guard loc != lastMouseLocation else { return }
        lastMouseLocation = loc
        guard items.indices.contains(row), selected != row else { return }
        selected = row
        tableView.reloadData()
    }

    /// True when `event` was dispatched to the cycler's own panel — lets the
    /// AppDelegate tell an in-picker click (commit) from a click-away (dismiss).
    func containsMouseEvent(_ event: NSEvent) -> Bool {
        panel.isVisible && event.window === panel
    }

    /// Table single-click: commit the clicked row (mirrors the ⌘-release commit).
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        selected = row
        onCommit?()
    }

    private func scrollSelectedToVisible() {
        guard items.indices.contains(selected) else { return }
        tableView.scrollRowToVisible(selected)
    }
}

// MARK: - Table data source / delegate

extension SessionCyclerOverlay: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cyclerRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? CyclerRowView
            ?? CyclerRowView(id: id)
        cell.configure(items[row], highlighted: row == selected)
        cell.onHover = { [weak self] in self?.hover(row: row) }
        return cell
    }
}

/// A single cycler row: leading favicon (or host glyph), then a dimmed
/// `host/session ›` prefix and the window's own name — so two same-named windows
/// in different projects stay tellable apart. Draws its own rounded highlight
/// since the panel is non-key (no system selection).
private final class CyclerRowView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let highlight = NSView()

    /// Called when the pointer enters this row, so the overlay can move the
    /// highlight to it. Rebound per row on each `configure`/reload.
    var onHover: (() -> Void)?

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.imageScaling = .scaleProportionallyUpOrDown

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlight)
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways` so hover works while the non-key panel is up; `.inVisibleRect`
        // keeps the area sized to the row without manual rect bookkeeping.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }

    func configure(_ item: SessionCyclerOverlay.Item, highlighted: Bool) {
        if let fav = item.favicon {
            icon.image = fav
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(
                systemSymbolName: item.ref.host.isLocal ? "laptopcomputer" : "server.rack",
                accessibilityDescription: nil)
            icon.contentTintColor = SidebarPalette.muted
        }

        let out = NSMutableAttributedString()
        let prefix = item.ref.host.isLocal
            ? "\(item.ref.session) › " : "\(item.ref.host.name)/\(item.ref.session) › "
        out.append(NSAttributedString(
            string: prefix, attributes: [.foregroundColor: SidebarPalette.muted]))
        out.append(NSAttributedString(
            string: item.title.isEmpty ? "\(item.ref.window)" : item.title,
            attributes: [.foregroundColor: SidebarPalette.text]))
        label.attributedStringValue = out

        highlight.layer?.backgroundColor =
            highlighted ? SidebarPalette.accent.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
    }
}
