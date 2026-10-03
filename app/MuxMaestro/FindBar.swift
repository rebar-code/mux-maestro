import Cocoa

/// The ⌘F find bar — a small strip floated over the terminal that searches the
/// attached session's scrollback. It is UI only: every keystroke/step/close is
/// reported through the callbacks below, and the owner (AppDelegate) drives the
/// actual search with tmux copy-mode commands. tmux does the searching because
/// the embedded surface only ever holds the visible tmux screen — the session's
/// real history lives on the tmux server — and copy-mode search also paints its
/// own match highlights and works unchanged for remote (ssh) hosts.
final class FindBarView: NSView {
    /// The needle changed (fired per keystroke; the owner debounces).
    var onNeedleChange: ((String) -> Void)?
    /// Step through matches: `older == true` moves up the scrollback (⏎ / ∧),
    /// false moves back down (⇧⏎ / ∨).
    var onStep: ((_ older: Bool) -> Void)?
    /// Esc / the close button — the owner ends the search and hides the bar.
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let upButton = NSButton()
    private let downButton = NSButton()
    private let closeButton = NSButton()

    init() {
        super.init(frame: .zero)
        let theme = Theme.current

        wantsLayer = true
        layer?.backgroundColor = theme.surface.cgColor
        layer?.borderColor = theme.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        // Soft drop shadow so the bar reads as floating over the terminal.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        field.placeholderString = "Find in session"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.font = .systemFont(ofSize: 13)
        // The magnifier's menu/cancel decorations are noise here; Esc closes.
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = theme.muted
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureStepButton(upButton, symbol: "chevron.up", tip: "Older match (⏎)",
                            action: #selector(stepUp))
        configureStepButton(downButton, symbol: "chevron.down", tip: "Newer match (⇧⏎)",
                            action: #selector(stepDown))
        configureStepButton(closeButton, symbol: "xmark", tip: "Done (Esc)",
                            action: #selector(closeTapped))

        let stack = NSStackView(views: [field, countLabel, upButton, downButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureStepButton(_ button: NSButton, symbol: String, tip: String,
                                     action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.contentTintColor = Theme.current.muted
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    // MARK: Owner API

    /// Reveal + focus, selecting any previous needle so typing replaces it but
    /// ⏎ can immediately re-run the last search.
    func present() {
        isHidden = false
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    var needle: String { field.stringValue }

    /// Pre-fill the field without firing `onNeedleChange` — the caller that sets
    /// it is already running the search itself.
    func setNeedle(_ text: String) {
        field.stringValue = text
    }

    /// Show the match count ("14 matches", "no matches"); nil clears it.
    func setCount(_ text: String?) {
        countLabel.stringValue = text ?? ""
    }

    // MARK: Actions

    @objc private func stepUp() { onStep?(true) }
    @objc private func stepDown() { onStep?(false) }
    @objc private func closeTapped() { onClose?() }
}

extension FindBarView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onNeedleChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // ⏎ steps up the scrollback (older); ⇧⏎ back down (newer) — the
            // direction people expect when digging for something that scrolled by.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep?(!shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
