import Cocoa

/// The request list in the Maestro rail: what the human asked for, as the
/// phone's `/requests` page shows it. An Open | Done filter, the requests newest
/// first under their project, a checkbox each, and a request's history under
/// its row on a click.
///
/// It draws `RequestListModel` and nothing else. The file is read and written
/// off the main thread through `RequestTracker`, the same write the phone's API
/// makes, and is read again when its directory changes: the agent and the phone
/// both replace the file by rename.
final class RequestListView: NSView {
    /// The list's file. nil when this Mac has no place for a manager home.
    var tracker: RequestTracker? {
        didSet { load() }
    }

    private var model = RequestListModel()
    private let filter = NSSegmentedControl(
        labels: ["Open", "Done"], trackingMode: .selectOne, target: nil, action: nil)
    /// Why the last tick was not saved. Shown for `noteTime`, then cleared.
    private let note = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let rows = FlippedStackView()
    /// The empty state, or the heading of a list that did not read.
    private let message = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)

    /// Every read and write of the file runs here, one at a time.
    private let queue = DispatchQueue(label: "muxmaestro.request-list", qos: .userInitiated)
    private var watcher: DirectoryWatcher?
    /// Whether the list is on screen. It reads and watches the file only then.
    private var isActive = false
    /// A read is already due for a change to the directory.
    private var reloadPending = false
    /// Counts the notes, so an old note's timer does not clear a newer one.
    private var notes = 0

    private static let noteTime: TimeInterval = 4

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        filter.segmentStyle = .roundRect
        filter.controlSize = .small
        filter.font = .systemFont(ofSize: 11)
        filter.target = self
        filter.action = #selector(filterChanged)

        note.font = .systemFont(ofSize: 11)
        note.textColor = SidebarPalette.red
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        rows.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        message.font = .systemFont(ofSize: 11)
        message.textColor = SidebarPalette.muted

        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.font = .systemFont(ofSize: 11)
        retry.target = self
        retry.action = #selector(retryClicked)

        for child in [filter, note, scroll, message, retry] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: topAnchor),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            note.leadingAnchor.constraint(equalTo: filter.trailingAnchor, constant: 8),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            note.centerYAnchor.constraint(equalTo: filter.centerYAnchor),

            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            message.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            message.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            retry.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 8),
            retry.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // On screen means in a window with nothing above it hidden: the rail hides
    // this view for the board, and a collapsed rail is a hidden ancestor.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateActive()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateActive()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateActive()
    }

    /// The list came on screen, or left it. Off screen it holds no watcher and
    /// reads nothing; back on screen it reads the file again.
    private func updateActive() {
        let on = window != nil && !isHiddenOrHasHiddenAncestor
        guard on != isActive else { return }
        isActive = on
        if on {
            load()
        } else {
            watcher?.cancel()
            watcher = nil
        }
    }

    // MARK: The file

    /// Read the file off the main thread and draw it if it changed.
    private func load() {
        guard isActive, let tracker else { return }
        watch(tracker)
        let writes = model.writes
        queue.async { [weak self] in
            let result = tracker.read()
            DispatchQueue.main.async {
                guard let self, self.model.loaded(result, writes: writes) else { return }
                self.render()
            }
        }
    }

    /// Watch the directory the list is in. It may not exist until the agent's
    /// home is first made, so every read tries again.
    private func watch(_ tracker: RequestTracker) {
        guard watcher == nil else { return }
        // A link is followed, as the write follows it.
        let directory = tracker.url.resolvingSymlinksInPath().deletingLastPathComponent()
        watcher = DirectoryWatcher(url: directory, queue: queue) { [weak self] in
            DispatchQueue.main.async { self?.directoryChanged() }
        }
    }

    /// Other files live in that directory too: one read for a burst of changes.
    private func directoryChanged() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.reloadPending = false
            self?.load()
        }
    }

    /// A tick shows at once. The write runs off the main thread; a write that
    /// fails puts the checkbox back and says why for a moment.
    private func tick(_ id: String) {
        guard let tracker, let state = model.tick(id) else {
            render()
            return
        }
        render()
        queue.async { [weak self] in
            let result = tracker.setState(state, of: id)
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.ticked(result)
                self.render()
                guard case .failure = result else { return }
                self.clearNoteLater()
                // After a failed write, read what the file holds now.
                self.load()
            }
        }
    }

    private func clearNoteLater() {
        notes += 1
        let shown = notes
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteTime) { [weak self] in
            guard let self, self.notes == shown else { return }
            self.model.clearNote()
            self.render()
        }
    }

    // MARK: Actions

    @objc private func filterChanged() {
        model.done = filter.selectedSegment == 1
        render()
    }

    @objc private func retryClicked() {
        model.retry()
        render()
        load()
    }

    // MARK: Draw

    private func render() {
        filter.setLabel(model.filterTitle(done: false), forSegment: 0)
        filter.setLabel(model.filterTitle(done: true), forSegment: 1)
        filter.selectedSegment = model.done ? 1 : 0
        note.stringValue = model.note
        note.toolTip = model.note.isEmpty ? nil : model.note

        for view in rows.arrangedSubviews { view.removeFromSuperview() }
        message.toolTip = nil
        retry.isHidden = true
        switch model.content {
        case .loading:
            message.stringValue = ""
        case .failed(let reason):
            message.stringValue = RequestListModel.unreadable
            message.textColor = SidebarPalette.text
            message.toolTip = reason.isEmpty ? nil : reason
            retry.isHidden = false
        case .empty(let label):
            message.stringValue = label
            message.textColor = SidebarPalette.muted
        case .groups(let groups):
            message.stringValue = ""
            for group in groups { add(group) }
        }
        message.isHidden = message.stringValue.isEmpty
    }

    private func add(_ group: RequestGroup) {
        add(ManagerRailViewController.sectionHeader("\(group.project) · \(group.requests.count)"))
        for request in group.requests {
            let id = request.id
            let open = model.expanded.contains(id)
            let row = RequestRowView(request: request, open: open, busy: model.busy == id)
            row.onTick = { [weak self] in self?.tick(id) }
            row.onOpen = { [weak self] in
                self?.model.toggleHistory(id)
                self?.render()
            }
            add(row)
            if open { add(RequestHistoryView(entries: request.history)) }
        }
    }

    private func add(_ view: NSView) {
        rows.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
}

/// One request: its checkbox, its title, the state the checkbox does not say,
/// and a caret. A click on the checkbox ticks it; a click anywhere else opens
/// or closes its history.
private final class RequestRowView: NSView, NSGestureRecognizerDelegate {
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var tracking: NSTrackingArea?

    var onTick: (() -> Void)?
    var onOpen: (() -> Void)?

    /// Where the title starts. The history under the row starts there too.
    static let titleInset: CGFloat = 34

    init(request: TrackedRequest, open: Bool, busy: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        // The full title, for one that does not fit the rail.
        toolTip = request.title

        check.state = request.isDone ? .on : .off
        check.isEnabled = !busy
        check.target = self
        check.action = #selector(checkClicked)
        check.setAccessibilityLabel(request.title)

        let title = NSTextField(labelWithString: request.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = request.isDone ? SidebarPalette.muted : SidebarPalette.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chip = Self.chip(request.state)

        let caret = NSImageView()
        caret.image = NSImage(
            systemSymbolName: open ? "chevron.down" : "chevron.right",
            accessibilityDescription: open ? "Hide history" : "Show history")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        caret.contentTintColor = SidebarPalette.muted

        for child in [check, title, chip, caret] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleInset),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -6),

            chip.trailingAnchor.constraint(equalTo: caret.leadingAnchor, constant: -6),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),

            caret.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            caret.centerYAnchor.constraint(equalTo: centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 10),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delegate = self
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The state as a small outlined label, in the colour the phone gives it.
    /// No width at all for todo and done: the checkbox says those.
    private static func chip(_ state: String) -> NSView {
        let chip = NSView()
        let text = RequestList.stateLabel(state)
        guard !text.isEmpty else {
            chip.widthAnchor.constraint(equalToConstant: 0).isActive = true
            return chip
        }
        let color: NSColor
        switch state {
        case RequestState.inProgress.rawValue: color = SidebarPalette.accent
        case RequestState.blocked.rawValue: color = SidebarPalette.red
        case RequestState.review.rawValue: color = SidebarPalette.amber
        default: color = SidebarPalette.muted
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = color.cgColor
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2),
        ])
        return chip
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

    /// The recognizer sits out a click on the checkbox, which tracks that click
    /// itself (see `ManagerRowView`).
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        !check.bounds.contains(check.convert(event.locationInWindow, from: nil))
    }

    @objc private func clicked() { onOpen?() }

    @objc private func checkClicked() { onTick?() }
}

/// How one request got to its state, oldest first, under its row. Who wrote an
/// entry shows in the colour of the name: the human's, or the agent's. The
/// human's exact words are a quote. Nothing here edits it.
private final class RequestHistoryView: NSView {
    init(entries: [RequestHistoryEntry]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RequestRowView.titleInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        let views = entries.isEmpty
            ? [Self.text("No history", color: SidebarPalette.muted)]
            : entries.map(Self.entry)
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func entry(_ entry: RequestHistoryEntry) -> NSView {
        let who = NSMutableAttributedString(
            string: entry.by,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: entry.isAgent ? SidebarPalette.purple : SidebarPalette.accent,
            ])
        who.append(NSAttributedString(
            string: entry.by.isEmpty ? entry.at : " \(entry.at)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: SidebarPalette.muted,
            ]))
        let heading = NSTextField(labelWithAttributedString: who)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var lines: [NSView] = [heading]
        if !entry.verbatim.isEmpty { lines.append(quote(entry.verbatim)) }
        if !entry.note.isEmpty { lines.append(text(entry.note, color: SidebarPalette.muted)) }

        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for line in lines {
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// The human's exact words: quoted, and set off by a bar.
    private static func quote(_ words: String) -> NSView {
        let host = NSView()
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = SidebarPalette.accent.cgColor
        let label = text("“\(words)”", color: SidebarPalette.text)
        for child in [bar, label] {
            child.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(child)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 2),

            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -1),
        ])
        return host
    }

    /// Text that wraps to the rail's width.
    private static func text(_ string: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: 11)
        label.textColor = color
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
