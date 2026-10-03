import Cocoa

/// Raised by the Running popover so the AppDelegate — which owns the selection,
/// the services and the scan caches — can act. The popover itself parses nothing
/// and runs nothing; it renders what `render(_:)` hands it.
protocol RunningPaneDelegate: AnyObject {
    func runningPaneDidRequestRefresh()
    /// Primary verb: put the terminal on the pane that owns this row. The one
    /// thing only MuxMaestro can do with a stray port.
    func runningPaneDidSelect(_ resource: RunningResource)
    func runningPaneDidRequestOpen(_ resource: RunningResource)
    func runningPaneDidRequestOpenLink(_ link: RunningLink)
    func runningPaneDidRequestStop(_ resource: RunningResource)
}

/// The Running popover: what is running because of the node you have selected,
/// filed by what it IS — dev servers, Supabase stacks, other containers — and
/// then what nothing claims (see `Running.sections`).
///
/// Each row is its name plus the addresses it offers, spelled out in full
/// (`https://localhost:5173/`, `Studio http://…:54723`), so you can tell what a
/// port is without opening it. Clicking a name focuses the owning pane; clicking
/// an address opens it; a database address is copied instead.
///
/// Rows carry the project's favicon, resolved once per directory off the main
/// thread and cached for the life of the process.
final class RunningViewController: NSViewController {
    weak var delegate: RunningPaneDelegate?

    static let width: CGFloat = 380
    /// Past this the list scrolls; a session header on a busy day has thirty rows.
    static let maxHeight: CGFloat = 560

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let refreshButton = NSButton()
    private var groups: [RunningGroup] = []

    private var faviconByDir: [String: NSImage] = [:]
    private var faviconMisses = Set<String>()
    private var faviconScanning = Set<String>()

    override func loadView() {
        let container = NSView()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Rescan ports and containers"
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            refreshButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        self.view = container
        preferredContentSize = NSSize(width: Self.width, height: 80)
        rebuild()
    }

    // MARK: Rendering

    func render(_ groups: [RunningGroup]) {
        self.groups = groups
        guard isViewLoaded else { return }
        rebuild()
        loadMissingFavicons()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let sections = Running.sections(groups)
        var seen = Set<String>()
        let unknowns = groups.flatMap(\.set.unknowns).filter { seen.insert($0).inserted }.sorted()

        for (index, section) in sections.enumerated() {
            stack.addArrangedSubview(label(
                section.title.uppercased(), font: .systemFont(ofSize: 10, weight: .semibold),
                top: index == 0 ? 6 : 14))
            for resource in section.resources {
                let row = RunningResourceView(
                    resource, icon: faviconByDir[resource.dir], delegate: delegate)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
        }
        if sections.isEmpty && unknowns.isEmpty {
            stack.addArrangedSubview(label("nothing running", font: .systemFont(ofSize: 12), top: 8))
        }
        // What we could not see is said once, at the bottom: a property of the
        // scan, not of any one row. Never a silently shorter list.
        for line in unknowns {
            stack.addArrangedSubview(label(line, font: .systemFont(ofSize: 11), top: 8))
        }

        stack.layoutSubtreeIfNeeded()
        let height = min(Self.maxHeight, stack.fittingSize.height + 8)
        preferredContentSize = NSSize(width: Self.width, height: max(40, height))
    }

    /// A section header, the empty line, or a "could not see" note: muted text.
    private func label(_ text: String, font: NSFont, top: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .secondaryLabelColor
        let box = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
        ])
        return box
    }

    @objc private func refresh() { delegate?.runningPaneDidRequestRefresh() }

    // MARK: Favicons (cached per directory, loaded off-main)

    private func loadMissingFavicons() {
        let dirs = Set(groups.flatMap(\.set.resources).map(\.dir).filter { !$0.isEmpty })
        for dir in dirs where faviconByDir[dir] == nil
            && !faviconMisses.contains(dir) && !faviconScanning.contains(dir) {
            faviconScanning.insert(dir)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let image = Favicon.load(dir: dir)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.faviconScanning.remove(dir)
                    if let image {
                        self.faviconByDir[dir] = image
                        self.rebuild()
                    } else {
                        self.faviconMisses.insert(dir)
                    }
                }
            }
        }
    }
}

/// Top-down document view, so a short list sits at the top of the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One entry: favicon (or a kind glyph), name, host chip, then one line per
/// address it offers.
final class RunningResourceView: NSView {
    private let resource: RunningResource
    private weak var delegate: RunningPaneDelegate?

    init(_ resource: RunningResource, icon: NSImage?, delegate: RunningPaneDelegate?) {
        self.resource = resource
        self.delegate = delegate
        super.init(frame: .zero)
        toolTip = resource.tooltip

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let title = titleLine(icon: icon)
        rows.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        for link in resource.links {
            let line = RunningLinkLine(link) { [weak self] link in
                self?.delegate?.runningPaneDidRequestOpenLink(link)
            }
            rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        menu = makeContextMenu()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func titleLine(icon: NSImage?) -> NSView {
        let glyph = NSImageView()
        glyph.image = icon ?? {
            switch resource.kind {
            case .server:
                return NSImage(systemSymbolName: "network", accessibilityDescription: "Dev server")
            case .container:
                return NSImage(
                    systemSymbolName: resource.isSupabaseStack ? "cylinder.split.1x2" : "shippingbox",
                    accessibilityDescription: resource.isSupabaseStack ? "Supabase" : "Container")
            }
        }()
        glyph.contentTintColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: resource.label)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = resource.paneID == nil ? .secondaryLabelColor : .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chips = WorktreeChipStrip()
        chips.configure(Running.chips(for: resource))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [glyph, name, chips, spacer])
        line.orientation = .horizontal
        line.spacing = 6
        line.alignment = .centerY
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),
        ])

        if resource.paneID != nil {
            line.addGestureRecognizer(NSClickGestureRecognizer(
                target: self, action: #selector(focusPane)))
            name.toolTip = "Go to the pane"
        }
        return line
    }

    @objc private func focusPane() { delegate?.runningPaneDidSelect(resource) }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let focus = NSMenuItem(title: "Focus Pane", action: #selector(focusPane), keyEquivalent: "")
        focus.isEnabled = resource.paneID != nil
        menu.addItem(focus)
        let open = NSMenuItem(title: "Open in Browser", action: #selector(open), keyEquivalent: "")
        open.isEnabled = resource.url != nil
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stop…", action: #selector(stop), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func open() { delegate?.runningPaneDidRequestOpen(resource) }
    @objc private func stop() { delegate?.runningPaneDidRequestStop(resource) }
}

/// `Studio  http://devbox1…:54723   ⧉` — an optional service name, the
/// address as a link, and a copy button. A `.copy` link (a database) copies on
/// click too: there is nothing to open.
final class RunningLinkLine: NSView {
    private let link: RunningLink
    private let onOpen: (RunningLink) -> Void
    private let copyButton = NSButton()

    init(_ link: RunningLink, onOpen: @escaping (RunningLink) -> Void) {
        self.link = link
        self.onOpen = onOpen
        super.init(frame: .zero)

        let service = NSTextField(labelWithString: link.label)
        service.font = .systemFont(ofSize: 11)
        service.textColor = .secondaryLabelColor

        let address = NSButton(title: "", target: self, action: #selector(activate))
        address.isBordered = false
        address.attributedTitle = NSAttributedString(string: link.url, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: link.action == .open ? NSColor.linkColor : NSColor.labelColor,
        ])
        address.lineBreakMode = .byTruncatingMiddle
        address.alignment = .left
        address.toolTip = link.action == .open ? "Open \(link.url)" : "Copy \(link.url)"
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.target = self
        copyButton.action = #selector(copyAddress)
        copyButton.toolTip = "Copy"
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [service, address, spacer, copyButton])
        line.orientation = .horizontal
        line.spacing = 6
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Under the name, past the 14pt glyph and its gap.
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 16),
        ])
        if link.label.isEmpty {
            service.isHidden = true
        } else {
            // Service names line up so the addresses start in one column.
            service.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func activate() {
        switch link.action {
        case .open: onOpen(link)
        case .copy: copyAddress()
        }
    }

    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        }
    }
}

/// The Running drawer: a pill pinned to the terminal pane's top-right corner
/// that carries the count (`3 running`), and drops the list open beneath it.
/// It floats over the terminal like the find bar — it never takes layout space —
/// and stays open or closed until the pill is clicked again.
final class RunningDrawer: NSView {
    let content: RunningViewController
    /// Fired with the new state after the user expands or collapses the drawer.
    var onToggle: ((Bool) -> Void)?
    /// Fired when the drawer appears or disappears, so the owner can let the
    /// find bar take the corner back.
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isExpanded: Bool

    private let title = NSTextField(labelWithString: "Running")
    private let chevron = NSImageView()
    private let header = NSStackView()
    private let body = NSView()
    private var bodyHeight: NSLayoutConstraint!
    private var expandedWidth: NSLayoutConstraint!
    private var collapsedLeading: NSLayoutConstraint!

    static let headerHeight: CGFloat = 24

    init(content: RunningViewController, expanded: Bool) {
        self.content = content
        self.isExpanded = expanded
        super.init(frame: .zero)
        // Hidden until a render says the selection owns something.
        isHidden = true
        let theme = Theme.current

        wantsLayer = true
        layer?.backgroundColor = theme.surface.cgColor
        layer?.borderColor = theme.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        // The same float as the find bar, so the two read as one family.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        let bolt = NSImageView()
        bolt.image = NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: nil)
        bolt.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        bolt.contentTintColor = theme.muted
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = theme.text
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = theme.muted

        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.setViews([bolt, title, chevron], in: .leading)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
        header.toolTip = "Show or hide what is running"
        addSubview(header)

        body.translatesAutoresizingMaskIntoConstraints = false
        body.clipsToBounds = true
        addSubview(body)

        bodyHeight = body.heightAnchor.constraint(equalToConstant: 0)
        // Yields to the owner's "stay inside the pane" limit; the list scrolls.
        bodyHeight.priority = .defaultHigh
        expandedWidth = widthAnchor.constraint(equalToConstant: RunningViewController.width)
        collapsedLeading = header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            bodyHeight,
        ])
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shown only while the selection owns something that is running. Open or
    /// closed is kept while hidden, so it comes back the way it was left.
    func render(_ groups: [RunningGroup]) {
        title.stringValue = Running.toolbarTitle(groups)
        content.render(groups)
        apply()
        let hide = Running.ownedCount(groups) == 0
        if hide != isHidden {
            isHidden = hide
            onVisibilityChange?(!hide)
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        apply()
        onToggle?(expanded)
    }

    @objc private func toggle() { setExpanded(!isExpanded) }

    private func apply() {
        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: isExpanded ? "Collapse" : "Expand")
        body.isHidden = !isExpanded
        // Detached while closed: a hidden list still holds its rows' widths and
        // would stretch the pill to the open drawer's width.
        let list = content.view
        if isExpanded, list.superview == nil {
            list.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(list)
            NSLayoutConstraint.activate([
                list.topAnchor.constraint(equalTo: body.topAnchor),
                list.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                list.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
        } else if !isExpanded {
            list.removeFromSuperview()
        }
        bodyHeight.constant = isExpanded ? content.preferredContentSize.height : 0
        expandedWidth.isActive = isExpanded
        collapsedLeading.isActive = !isExpanded
    }
}
