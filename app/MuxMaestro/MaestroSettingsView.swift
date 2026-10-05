import Cocoa

/// The "Maestro" tab of the Settings window: the agent that runs as the
/// Maestro, its model, and the instructions it loads (`ManagerHome.contextURL`).
///
/// The agent and the model are stored as they are picked. The instructions are
/// a file, so they have a Save. None of it reaches a Maestro that is already
/// running: that takes Restart Maestro.
final class MaestroSettingsView: NSView, NSTextViewDelegate, NSComboBoxDelegate {
    /// "Restart Maestro" was clicked.
    var onRestart: (() -> Void)?

    private let provider = NSPopUpButton()
    private let model = NSComboBox()
    private let editor = NSTextView()
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let reset = NSButton(title: "Reset to Default…", target: nil, action: nil)
    private let restart = NSButton(title: "Restart Maestro", target: nil, action: nil)

    private var home: URL?
    /// The instructions as they are on disk.
    private var saved = ""
    private var edited: Bool { editor.string != saved }

    /// What the Model box offers. It takes any other id as typed.
    private static let models: [MaestroAgent: [String]] = [
        .claude: ["fable", "opus", "sonnet"],
        .codex: ["gpt-5.5"],
    ]
    private static let editorSize = NSSize(width: 620, height: 320)

    init() {
        super.init(frame: .zero)
        let theme = Theme.current

        provider.addItems(withTitles: MaestroAgent.allCases.map(\.title))
        provider.target = self
        provider.action = #selector(providerPicked)

        model.placeholderString = "Default"
        model.completes = true
        model.delegate = self
        model.target = self
        model.action = #selector(modelPicked)
        model.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let grid = NSGridView(views: [
            [Self.label("Provider", theme), provider],
            [Self.label("Model", theme), model],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).width = 110

        let header = NSTextField(labelWithString: "Instructions")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = theme.muted

        editor.delegate = self
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = theme.text
        editor.backgroundColor = theme.surface
        editor.insertionPointColor = theme.text
        editor.textContainerInset = NSSize(width: 6, height: 8)
        // The file is commands and markdown: nothing rewrites what is typed.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.widthAnchor.constraint(equalToConstant: Self.editorSize.width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: Self.editorSize.height).isActive = true

        for (button, action) in [
            (save, #selector(saveClicked)), (reset, #selector(resetClicked)),
            (restart, #selector(restartClicked)),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, restart, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [grid, header, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: grid)
        stack.setCustomSpacing(6, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        renderAgent()
        renderButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func label(_ text: String, _ theme: Theme) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = theme.text
        return label
    }

    /// Read the settings and the file again. Text being edited is left alone.
    func reload() {
        renderAgent()
        if home == nil { home = try? ManagerHome.ensure() }
        guard !edited else { return }
        saved = home.flatMap(ManagerHome.readContext(home:)) ?? ""
        editor.string = saved
        renderButtons()
    }

    /// Whether the window may close. Edits that are not saved are asked about.
    func confirmDiscardingEdits(in window: NSWindow) -> Bool {
        guard edited else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the Maestro instructions?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return write(editor.string)
        case .alertThirdButtonReturn:
            editor.string = saved
            renderButtons()
            return true
        default:
            return false
        }
    }

    private func renderAgent() {
        let agent = Settings.maestroAgent()
        provider.selectItem(at: MaestroAgent.allCases.firstIndex(of: agent) ?? 0)
        model.removeAllItems()
        model.addItems(withObjectValues: Self.models[agent] ?? [])
        model.stringValue = Settings.maestroModel(agent)
    }

    private func renderButtons() {
        editor.isEditable = home != nil
        save.isEnabled = home != nil && edited
        reset.isEnabled = home != nil
    }

    /// Put `text` in the file. False, with the reason shown, when it did not go.
    @discardableResult
    private func write(_ text: String) -> Bool {
        guard let home else { return false }
        do {
            try ManagerHome.writeContext(text, home: home)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        saved = text
        if editor.string != text { editor.string = text }
        renderButtons()
        return true
    }

    func textDidChange(_ notification: Notification) {
        renderButtons()
    }

    /// Typing in the Model box. A pick from its list comes through `modelPicked`.
    func controlTextDidChange(_ obj: Notification) {
        Settings.setMaestroModel(model.stringValue, agent: Settings.maestroAgent())
    }

    @objc private func providerPicked() {
        Settings.setMaestroAgent(MaestroAgent.allCases[provider.indexOfSelectedItem])
        renderAgent()
    }

    @objc private func modelPicked() {
        Settings.setMaestroModel(model.stringValue, agent: Settings.maestroAgent())
    }

    @objc private func saveClicked() {
        write(editor.string)
    }

    @objc private func resetClicked() {
        guard let text = ManagerHome.defaultContext() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the Maestro instructions?"
        alert.informativeText = "The default replaces everything in this file."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write(text)
    }

    @objc private func restartClicked() {
        onRestart?()
    }
}
