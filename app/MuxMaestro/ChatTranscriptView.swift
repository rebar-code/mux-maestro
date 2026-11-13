import Cocoa

/// Where a chat reads from and answers to. Every closure may block: they are
/// called off the main thread.
struct ChatSource {
    /// The pane's live transcript, asked for again on every read: the agent in
    /// a pane writes a new file after `/clear` or a restart. nil: none yet.
    var transcript: () -> (path: String, codex: Bool)?
    /// The pane, for its spinner line and the prompt it waits on. nil: none.
    var pane: () -> ChatPane?
}

/// One agent pane as a chat reaches it: its tmux target, what may be done to
/// it, and its state now.
struct ChatPane {
    let target: String
    let io: MobilePaneIO
    let state: () -> MobilePaneState?
}

/// An agent's transcript as chat, the way the phone draws it: your messages
/// on the right, replies as markdown, tool calls one line each (a long run
/// folds), reasoning muted. Under them, text sent but not in the transcript
/// yet, the agent's spinner line, and the prompt it waits on, with a button
/// per choice. It stays at the bottom unless the human scrolled up.
///
/// It reads the transcript itself, on a timer, while it is on screen.
final class ChatTranscriptView: NSView {
    /// How long a reply may be before it is cut. The phone cuts at 8000.
    static let maxText = 50_000
    static let pollInterval: TimeInterval = 1.5

    private let scroll = NSScrollView()
    private let stack = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let readQueue = DispatchQueue(label: "chat.transcript.read", qos: .utility)

    private var feed = ChatFeed()
    private var openFolds: Set<UInt64> = []
    private var thinking: String?
    private var waiting: (prompt: MobilePrompt?, on: Bool) = (nil, false)
    private var notes: [String] = []
    private var answering = false
    /// Bumped when the source changes: a read that started before is dropped.
    private var generation = 0
    private var reading = false
    private var timer: Timer?
    /// The rows on screen, by key, so a redraw keeps what did not change.
    private var rowViews: [String: NSView] = [:]
    private var renderedSession: String?

    /// What the chat reads. Setting it starts the chat over.
    var source: ChatSource? {
        didSet {
            generation += 1
            feed.clear()
            openFolds = []
            thinking = nil
            waiting = (nil, false)
            notes = []
            reading = false
            render(scrollToEnd: true)
            refresh()
        }
    }

    /// Shown when there is no source, or nothing to show yet. nil: blank.
    var emptyText: String? {
        didSet { updateEmpty() }
    }

    /// Whether the pane is busy, as last read. The owner decides from it
    /// whether a send queues.
    private(set) var paneState: MobilePaneState?

    var onOpenLink: ((ThreadLink) -> Void)?
    /// The pane waits on something with no readable choices: show the terminal.
    var onShowTerminal: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = SidebarPalette.muted
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        addSubview(scroll)
        addSubview(emptyLabel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pullRequestsChanged), name: KnownPullRequests.changed, object: nil)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    // MARK: Reading

    /// Read what the transcript wrote since the last read, and the pane's
    /// spinner or prompt. Skipped while hidden and while a read is running.
    func refresh() {
        guard let source, !reading, window?.isVisible == true, !isHiddenOrHasHiddenAncestor
        else { return }
        reading = true
        let (after, session, generation) = (feed.next, feed.session, generation)
        readQueue.async { [weak self] in
            let page = MobileChat.page(
                file: source.transcript(), after: after, session: session, maxText: Self.maxText)
            let pane = source.pane()
            let state = pane?.state()
            var spinner: String?
            var prompt: MobilePrompt?
            if let pane, let state {
                switch state.status {
                case .busy:
                    spinner = pane.io.screen().flatMap(MobileSpinner.line(in:)) ?? "Working…"
                case .waiting:
                    prompt = MobileReply.prompt(state: state, seen: MobileReply.look(pane.io), io: pane.io)
                default:
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.reading = false
                self.apply(page: page, state: state, spinner: spinner, prompt: prompt)
            }
        }
    }

    private func apply(
        page: MobileChatPage?, state: MobilePaneState?, spinner: String?, prompt: MobilePrompt?
    ) {
        var changed = false
        if let page {
            let before = feed.messages.count
            changed = feed.merge(page)
            if feed.messages.count != before || page.reset { notes = [] }
        }
        paneState = state
        let waitingNow = (prompt, state?.status == .waiting)
        if spinner != thinking || waitingNow.0 != waiting.prompt || waitingNow.1 != waiting.on {
            thinking = spinner
            waiting = waitingNow
            changed = true
        }
        if changed { render() }
    }

    // MARK: Sending

    /// Text just sent: shown until the transcript has it.
    func addPending(_ text: String) {
        feed.addPending(text)
        render(scrollToEnd: true)
    }

    /// Text that did not go in.
    func dropPending(_ text: String) {
        feed.dropPending(text)
        render()
    }

    /// A one-line note under the chat, until the transcript moves on.
    func addNote(_ text: String) {
        notes.append(text)
        render(scrollToEnd: true)
    }

    /// Read again soon: something was just sent.
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    private func answer(_ option: Int?, prompt: MobilePrompt) {
        guard let source, !answering else { return }
        answering = true
        render()
        readQueue.async { [weak self] in
            let response: MobileResponse
            if let pane = source.pane() {
                response = MobileReply.answer(
                    prompt: prompt.id, option: option, target: pane.target, io: pane.io,
                    state: pane.state())
            } else {
                response = .error(503, "unavailable", message: MobileReply.unreachable)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.answering = false
                if response.status != 200 { self.notes.append(Self.message(of: response)) }
                self.render(scrollToEnd: true)
                self.refreshSoon()
            }
        }
    }

    /// The human-readable part of a refusal.
    static func message(of response: MobileResponse) -> String {
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if let message = body?["message"] as? String, !message.isEmpty { return message }
        switch body?["error"] as? String {
        case "stale": return "The prompt changed"
        default: return "Not sent"
        }
    }

    // MARK: Drawing

    private var atBottom: Bool {
        let clip = scroll.contentView
        return clip.bounds.maxY >= stack.frame.height - 24
    }

    /// A pull request on a window changed: the messages that link to one draw
    /// again, in the colour of its state now.
    @objc private func pullRequestsChanged() {
        rowViews = rowViews.filter { !$0.key.hasPrefix("m") }
        render()
    }

    private func render(scrollToEnd: Bool = false) {
        let follow = scrollToEnd || atBottom
        if renderedSession != feed.session {
            // Another transcript: its row numbers are not this one's.
            rowViews = [:]
            renderedSession = feed.session
        }
        var keyed: [(String, () -> NSView)] = []
        for row in ChatRows.rows(feed.messages, open: openFolds) {
            switch row {
            case .message(let message):
                keyed.append(("m\(message.n)", { [weak self] in self?.messageView(message) ?? NSView() }))
            case .fold(let key, let hidden, let open):
                keyed.append(("f\(key)-\(hidden)-\(open)", { [weak self] in
                    ChatFoldRow(label: ChatRows.foldLabel(hidden: hidden, open: open)) {
                        guard let self else { return }
                        if self.openFolds.remove(key) == nil { self.openFolds.insert(key) }
                        self.render()
                    }
                }))
            }
        }
        for note in notes.enumerated() {
            keyed.append(("n\(note.offset)-\(note.element)", { ChatTextRow(.note, text: note.element) }))
        }
        for item in feed.pending.enumerated() {
            keyed.append(("p\(item.offset)-\(item.element.text)", {
                ChatTextRow(.pending, text: item.element.text)
            }))
        }
        if thinking != nil {
            keyed.append(("thinking", { ChatThinkingRow() }))
        }
        if waiting.on {
            let id = waiting.prompt?.id ?? "unread"
            keyed.append(("prompt-\(id)-\(answering)", { [weak self] in
                ChatPromptCard(prompt: self?.waiting.prompt, enabled: !(self?.answering ?? true)) { option in
                    guard let self else { return }
                    if let prompt = self.waiting.prompt {
                        self.answer(option, prompt: prompt)
                    } else {
                        self.onShowTerminal?()
                    }
                }
            }))
        }

        var next: [String: NSView] = [:]
        var views: [NSView] = []
        for (key, make) in keyed {
            let view = rowViews[key] ?? make()
            if let thinkingRow = view as? ChatThinkingRow { thinkingRow.text = thinking ?? "" }
            next[key] = view
            views.append(view)
        }
        let kept = Set(views.map(ObjectIdentifier.init))
        for view in stack.arrangedSubviews where !kept.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        for (index, view) in views.enumerated() {
            let current = stack.arrangedSubviews
            if index < current.count, current[index] === view { continue }
            stack.insertArrangedSubview(view, at: index)
            if rowViews.values.contains(where: { $0 === view }) == false {
                view.widthAnchor.constraint(
                    equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
                ).isActive = true
            }
        }
        rowViews = next
        updateEmpty()
        if follow { scrollToBottom() }
    }

    private func messageView(_ message: MobileChatMessage) -> NSView {
        let row: ChatTextRow
        switch message.role {
        case .user: row = ChatTextRow(.user, text: message.text)
        case .assistant: row = ChatTextRow(.assistant, text: message.text)
        case .reasoning: row = ChatTextRow(.reasoning, text: message.text)
        case .tool: row = ChatTextRow(.tool, text: message.text, tool: message.tool)
        }
        row.onOpenLink = { [weak self] link in self?.onOpenLink?(link) }
        return row
    }

    private func updateEmpty() {
        let empty = stack.arrangedSubviews.isEmpty
        emptyLabel.stringValue = emptyText ?? ""
        emptyLabel.isHidden = !empty || emptyText == nil
    }

    /// A row only knows its height after a layout pass, so the scroll waits
    /// for one.
    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            let clip = self.scroll.contentView
            let bottom = max(0, self.stack.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: bottom))
            self.scroll.reflectScrolledClipView(clip)
        }
    }
}

// MARK: - Rows

/// A row that lays itself out for the width the stack gives it and reports
/// the height that takes.
private class ChatRowView: NSView {
    private var measured: CGFloat = 0

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measured)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1 else { return }
        let height = ceil(arrange(width: bounds.width))
        guard height != measured else { return }
        measured = height
        invalidateIntrinsicContentSize()
    }

    /// Place the subviews for `width`; return the height they need.
    func arrange(width: CGFloat) -> CGFloat { 0 }

    /// The size `label`'s text takes at most `width` wide.
    static func measure(_ label: LinkLabel, width: CGFloat) -> NSSize {
        guard let layout = label.layoutManager, let container = label.textContainer else { return .zero }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }
}

/// One message: a bubble of yours, a reply, reasoning, a tool call, a note,
/// or text sent that the transcript does not show yet.
private final class ChatTextRow: ChatRowView {
    enum Kind { case user, pending, assistant, reasoning, tool, note }

    private let kind: Kind
    private let raw: String
    private let label: LinkLabel
    private let box = NSView()
    private let rule = NSView()
    private var copyButton: NSButton?
    private var tracking: NSTrackingArea?

    var onOpenLink: ((ThreadLink) -> Void)?

    init(_ kind: Kind, text: String, tool: String? = nil) {
        self.kind = kind
        raw = text
        let small = kind == .tool || kind == .reasoning || kind == .note
        label = LinkLabel(
            font: .systemFont(ofSize: small ? 11 : 12),
            color: kind == .assistant || kind == .user ? SidebarPalette.text : SidebarPalette.muted,
            maxLines: kind == .tool ? 1 : 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        box.wantsLayer = true
        addSubview(box)
        addSubview(label)
        switch kind {
        case .user:
            box.layer?.cornerRadius = 10
            box.layer?.backgroundColor = SidebarPalette.accent.withAlphaComponent(0.2).cgColor
            label.setText(text)
        case .pending:
            box.layer?.cornerRadius = 10
            box.layer?.borderWidth = 1
            box.layer?.borderColor = SidebarPalette.muted.withAlphaComponent(0.5).cgColor
            label.setText(text)
            toolTip = "Not in the transcript yet"
        case .assistant:
            label.setAttributedText(ChatMarkdown.render(text, style: Self.markdownStyle))
            addCopyButton()
        case .reasoning:
            rule.wantsLayer = true
            rule.layer?.backgroundColor = SidebarPalette.border.cgColor
            addSubview(rule)
            let italic = NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
            label.setAttributedText(NSAttributedString(string: text, attributes: [
                .font: italic, .foregroundColor: SidebarPalette.muted,
            ]))
        case .tool:
            rule.wantsLayer = true
            rule.layer?.backgroundColor = SidebarPalette.border.cgColor
            addSubview(rule)
            let line = NSMutableAttributedString(
                string: tool ?? "Tool",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: SidebarPalette.text])
            if !text.isEmpty {
                line.append(NSAttributedString(string: "  " + text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: SidebarPalette.muted,
                ]))
            }
            label.setAttributedText(line)
            toolTip = [tool, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        case .note:
            label.setText(text)
        }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static var markdownStyle: ChatMarkdown.Style {
        var style = ChatMarkdown.Style(
            font: .systemFont(ofSize: 12), color: SidebarPalette.text, muted: SidebarPalette.muted,
            link: SidebarPalette.accent, codeBackground: SidebarPalette.bg)
        // A link to a PR on a window looks like that window's chip.
        style.pullRequests = KnownPullRequests.byKey
        style.pullRequestLook = { (PRChipButton.tint($0), PRChipButton.symbolName($0)) }
        return style
    }

    override func arrange(width: CGFloat) -> CGFloat {
        switch kind {
        case .user, .pending:
            // Yours sits on the right, as wide as its text, at most most of the row.
            let padX: CGFloat = 10, padY: CGFloat = 6
            let maxText = floor(width * 0.86) - padX * 2
            // The layout's used rect spans the container; the text's own
            // bounds give the width a short message needs.
            let fit = label.textStorage.map {
                ceil($0.boundingRect(
                    with: NSSize(width: maxText, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
            } ?? maxText
            let text = Self.measure(label, width: min(maxText, fit + 1))
            let boxSize = NSSize(width: text.width + padX * 2, height: text.height + padY * 2)
            box.frame = NSRect(x: width - boxSize.width, y: 0, width: boxSize.width, height: boxSize.height)
            label.frame = NSRect(x: box.frame.minX + padX, y: padY, width: text.width, height: text.height)
            return boxSize.height
        case .reasoning, .tool:
            let indent: CGFloat = 10
            let text = Self.measure(label, width: width - indent)
            let height = max(text.height, 14)
            rule.frame = NSRect(x: 0, y: 0, width: 2, height: height)
            label.frame = NSRect(x: indent, y: 0, width: width - indent, height: height)
            return height
        case .assistant, .note:
            let text = Self.measure(label, width: width)
            label.frame = NSRect(x: 0, y: 0, width: width, height: text.height)
            if let copyButton {
                copyButton.frame = NSRect(x: width - 22, y: 0, width: 22, height: 18)
            }
            return text.height
        }
    }

    // MARK: Copy

    private func addCopyButton() {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = SidebarPalette.muted
        button.toolTip = "Copy"
        button.target = self
        button.action = #selector(copyClicked)
        button.isHidden = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = SidebarPalette.surface.cgColor
        addSubview(button)
        copyButton = button
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard copyButton != nil else { return }
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { copyButton?.isHidden = false }

    override func mouseExited(with event: NSEvent) {
        copyButton?.isHidden = true
        copyButton?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
    }

    @objc private func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        copyButton?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let copyButton, !copyButton.isHidden,
           copyButton.frame.contains(convert(point, from: superview)) {
            return copyButton
        }
        return super.hitTest(point)
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

/// The control for a run's earlier tool calls: a click shows or hides them.
private final class ChatFoldRow: ChatRowView {
    private let button: NSButton
    private let action: () -> Void

    init(label: String, action: @escaping () -> Void) {
        self.action = action
        button = NSButton(title: label, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = SidebarPalette.muted
        button.target = self
        button.action = #selector(clicked)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func arrange(width: CGFloat) -> CGFloat {
        let size = button.fittingSize
        button.frame = NSRect(x: 8, y: 0, width: size.width, height: size.height)
        return size.height
    }

    @objc private func clicked() { action() }
}

/// The agent's spinner line while it works: "Incubating… 4m 48s".
private final class ChatThinkingRow: ChatRowView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.font = .systemFont(ofSize: 11)
        label.textColor = SidebarPalette.muted
        label.lineBreakMode = .byTruncatingTail
        addSubview(spinner)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func arrange(width: CGFloat) -> CGFloat {
        spinner.frame = NSRect(x: 0, y: 1, width: 14, height: 14)
        label.frame = NSRect(x: 20, y: 0, width: max(0, width - 20), height: 16)
        return 16
    }
}

/// The prompt the pane waits on, with a button per choice and Cancel (Escape).
/// With no prompt that reads, one button shows the terminal instead.
private final class ChatPromptCard: ChatRowView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail: LinkLabel
    private var buttons: [NSButton] = []
    private let choose: (Int?) -> Void

    /// `choose`: an option's number, or nil for Cancel (or, with no prompt,
    /// for the terminal).
    init(prompt: MobilePrompt?, enabled: Bool, choose: @escaping (Int?) -> Void) {
        self.choose = choose
        detail = LinkLabel(font: .systemFont(ofSize: 11), color: SidebarPalette.muted, maxLines: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = SidebarPalette.amber.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = SidebarPalette.surface.cgColor

        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = SidebarPalette.text
        addSubview(title)
        addSubview(detail)

        if let prompt {
            title.stringValue = [prompt.title, prompt.question].filter { !$0.isEmpty }.first ?? "Waiting"
            let words = [prompt.detail, prompt.title.isEmpty ? "" : prompt.question]
                .filter { !$0.isEmpty && $0 != title.stringValue }
            detail.setText(words.joined(separator: "\n"))
            for option in prompt.options {
                buttons.append(button("\(option.n). \(option.label)", tag: option.n, enabled: enabled))
            }
            buttons.append(button("Cancel", tag: 0, enabled: enabled))
        } else {
            title.stringValue = "Waiting at the keyboard"
            buttons.append(button("Open terminal", tag: 0, enabled: true))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func button(_ label: String, tag: Int, enabled: Bool) -> NSButton {
        let button = NSButton(title: label, target: self, action: #selector(clicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.tag = tag
        button.isEnabled = enabled
        button.lineBreakMode = .byTruncatingTail
        addSubview(button)
        return button
    }

    override func arrange(width: CGFloat) -> CGFloat {
        let pad: CGFloat = 10
        let inner = width - pad * 2
        var y = pad
        let titleHeight = title.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height
        title.frame = NSRect(x: pad, y: y, width: inner, height: titleHeight)
        y += titleHeight + 4
        let detailSize = Self.measure(detail, width: inner)
        detail.frame = NSRect(x: pad, y: y, width: inner, height: detailSize.height)
        if detailSize.height > 0 { y += detailSize.height + 6 }
        for button in buttons {
            let size = button.fittingSize
            button.frame = NSRect(x: pad - 4, y: y, width: min(size.width, inner + 8), height: size.height)
            y += size.height + 2
        }
        return y + pad - 2
    }

    @objc private func clicked(_ sender: NSButton) {
        choose(sender.tag == 0 ? nil : sender.tag)
    }
}

// MARK: - Composer

/// The message box under a chat: it grows with its text up to a few lines.
/// ⏎ sends; ⇧⏎ or ⌥⏎ starts a new line.
final class ChatComposer: NSView, NSTextViewDelegate {
    private let scroll = NSScrollView()
    private let textView = ComposerTextView()
    private var heightConstraint: NSLayoutConstraint?
    private static let maxLines: CGFloat = 8
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let padY: CGFloat = 5

    var onSend: ((String) -> Void)?

    var placeholder: String {
        get { textView.placeholder }
        set { textView.placeholder = newValue }
    }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            updateHeight()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = SidebarPalette.border.cgColor
        layer?.backgroundColor = SidebarPalette.bg.cgColor

        textView.font = Self.font
        textView.textColor = SidebarPalette.text
        textView.insertionPointColor = SidebarPalette.text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: Self.padY)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let height = heightAnchor.constraint(equalToConstant: Self.height(lines: 1))
        heightConstraint = height
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            height,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func height(lines: CGFloat) -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return ceil(line * lines + padY * 2)
    }

    func focus() { window?.makeFirstResponder(textView) }

    func textDidChange(_ notification: Notification) { updateHeight() }

    private func updateHeight() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + Self.padY * 2
        let height = min(max(ceil(used), Self.height(lines: 1)), Self.height(lines: Self.maxLines))
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText()
        else { return false }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.option) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        let message = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return true }
        text = ""
        onSend?(message)
        return true
    }
}

/// The composer's text view: it draws its placeholder while empty.
private final class ComposerTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? .systemFont(ofSize: 13), .foregroundColor: SidebarPalette.muted,
        ])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
