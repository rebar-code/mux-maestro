import Cocoa

/// A borderless floating panel that never becomes key — the manager's toast
/// must not steal first responder from the terminal. Same shape as the ⌘`
/// cycler's panel (see `SessionCyclerOverlay`).
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The toast's background view. Reports the pointer entering and leaving, so the
/// toast can show its close button and hold the auto-dismiss clock. `activeAlways`
/// because the panel is never key and the app is often inactive when it shows.
private final class ToastContainerView: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The manager agent's toast: a transient banner in the top-right of the main
/// window, raised by `mux notify`. Auto-fades after a few seconds; clicking a
/// link in it opens that pane, clicking anywhere else opens the session it points
/// at. When several notifications land in one DB poll, the newest shows with a
/// "+N more" suffix — the review list holds the full story.
final class ManagerToastOverlay: NSViewController {
    private let robot = NSTextField(labelWithString: "🤖")
    private let titleLabel = NSTextField(labelWithString: "")
    private let body = LinkLabel(font: .systemFont(ofSize: 12), color: SidebarPalette.muted, maxLines: 2)
    private let closeButton = SidebarAddButton.make(tooltip: "Dismiss", symbol: "xmark")
    private var dismissTimer: Timer?
    private var current: ManagerNotification?

    /// Click → open the toast's target session.
    var onOpen: ((ManagerNotification) -> Void)?
    /// Click a `muxmaestro://` link in the text → open the pane it points at.
    var onOpenLink: ((ThreadLink) -> Void)?

    private static let panelWidth: CGFloat = 320
    private static let panelHeight: CGFloat = 66
    private static let showFor: TimeInterval = 6

    private lazy var panel: ToastPanel = {
        let p = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
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
        let container = ToastContainerView()
        container.onHover = { [weak self] in self?.setHovered($0) }
        container.wantsLayer = true
        container.layer?.backgroundColor = SidebarPalette.bg.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = SidebarPalette.border.cgColor

        robot.font = .systemFont(ofSize: 18)
        robot.setContentHuggingPriority(.required, for: .horizontal)
        robot.translatesAutoresizingMaskIntoConstraints = false
        // Hug the emoji: otherwise the panel's spare width goes to this label and
        // pushes the text to the right edge.
        robot.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = SidebarPalette.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        body.translatesAutoresizingMaskIntoConstraints = false

        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(robot)
        container.addSubview(titleLabel)
        container.addSubview(body)
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            // The panel takes its size from this view, and the link text has no
            // intrinsic width to size it by — pin the designed size.
            container.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            container.heightAnchor.constraint(equalToConstant: Self.panelHeight),
            robot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            robot.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: robot.trailingAnchor, constant: 8),
            // Room for the close button even while it is hidden, so the title
            // never reflows on hover and the × never covers text.
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        container.addGestureRecognizer(click)
        self.view = container
    }

    /// Show `notification` in the top-right of `parent` (below the titlebar),
    /// replacing any toast already up and resetting the auto-dismiss clock.
    /// `extra` > 0 appends a "+N more" hint.
    func show(over parent: NSWindow, notification: ManagerNotification, extra: Int) {
        let session = notification.session.isEmpty ? "manager" : notification.session
        let suffix = extra > 0 ? "   +\(extra) more" : ""
        present(
            over: parent, glyph: "🤖", title: session + suffix, text: notification.text,
            notification: notification)
    }

    /// A toast with no session behind it (a worktree cleanup's outcome): `glyph`
    /// replaces the robot, and a click only dismisses it.
    func show(over parent: NSWindow, glyph: String, title: String, text: String) {
        present(over: parent, glyph: glyph, title: title, text: text, notification: nil)
    }

    private func present(
        over parent: NSWindow, glyph: String, title: String, text: String,
        notification: ManagerNotification?
    ) {
        current = notification
        loadViewIfNeeded()
        robot.stringValue = glyph
        titleLabel.stringValue = title
        body.setText(text)

        let p = panel
        let pf = parent.frame
        // Size as well as place: assigning `contentViewController` shrinks the
        // panel to its content's fitting width (~115pt), which cut every body
        // off after a few characters.
        p.setFrame(NSRect(
            x: pf.maxX - Self.panelWidth - 16,
            y: pf.maxY - Self.panelHeight - 52,
            width: Self.panelWidth, height: Self.panelHeight), display: true)
        p.orderFrontRegardless()

        // A toast can appear under a still pointer, which sends no enter event.
        setHovered(p.frame.contains(NSEvent.mouseLocation))
    }

    /// While the pointer is over the toast it stays up and shows its close
    /// button; leaving restarts the full auto-dismiss clock.
    private func setHovered(_ hovered: Bool) {
        closeButton.isHidden = !hovered
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard !hovered, panel.isVisible else { return }
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.showFor, repeats: false
        ) { [weak self] _ in self?.hide() }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        closeButton.isHidden = true
        panel.orderOut(nil)
    }

    @objc private func dismissClicked() {
        hide()
    }

    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        // A click on the × lands here, not on the button: this recognizer delays
        // the mouse-down, so the button never tracks it. Dismiss here too.
        let inClose = !closeButton.isHidden
            && closeButton.bounds.contains(gesture.location(in: closeButton))
        switch ToastClick.action(inCloseButton: inClose, link: body.link(at: gesture.location(in: body))) {
        case .dismiss: break
        case .openLink(let link): onOpenLink?(link)
        case .open: if let current { onOpen?(current) }
        }
        hide()
    }
}
