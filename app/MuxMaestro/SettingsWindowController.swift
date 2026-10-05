import Cocoa

/// MuxMaestro ▸ Settings… (⌘,): one window, a toolbar tab per subject.
///
/// `Tools` is each command-line tool the app uses, found or missing, with an
/// Install button on the missing ones. Nothing installs until that button is
/// clicked; the install then runs visibly in the terminal, where it can ask for
/// a password. The window opens on it at launch when a required tool is missing.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case maestro, phone, tools

        var title: String {
            switch self {
            case .maestro: return "Maestro"
            case .phone: return "Phone"
            case .tools: return "Tools"
            }
        }

        var symbol: String {
            switch self {
            case .maestro: return "wand.and.stars"
            case .phone: return "iphone"
            case .tools: return "wrench.and.screwdriver"
            }
        }
    }

    /// Runs a tool's install recipe. Set by the app delegate, which owns the terminal.
    var onInstall: ((SetupTool) -> Void)?
    /// The "Phone" tab. The app delegate wires its switch to `PhoneLink`.
    let phone = PhoneSettingsView()
    /// The "Maestro" tab.
    let maestro = MaestroSettingsView()
    private let tabs = SettingsTabViewController()

    private struct Row {
        let status: NSTextField
        let install: NSButton
    }

    /// One per `SetupTools.all`, in the same order.
    private var rows: [Row] = []
    /// The "Voice models" row: status from `VoiceModels`, Retry when it failed.
    private var voiceRow: Row?
    private let checkAgain = NSButton(title: "Check Again", target: nil, action: nil)
    private var checking = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.current.bg
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        self.init(window: window)
        window.delegate = self

        phone.onResize = { [weak self] in self?.tabs.fitWindow() }
        tabs.tabStyle = .toolbar
        let panes: [NSView] = [Self.padded(maestro), Self.padded(phone), makeTools()]
        for (tab, pane) in zip(Tab.allCases, panes) {
            let controller = NSViewController()
            controller.view = pane
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        tabs.fitWindow()
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceStateChanged), name: VoiceModels.stateDidChange, object: nil)
        renderVoice()
    }

    /// Bring the window up, on `tab` when one is asked for.
    func show(_ tab: Tab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        maestro.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recheck()
    }

    /// Coming back from an install in the terminal re-reads what's there.
    func windowDidBecomeKey(_ notification: Notification) {
        recheck()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        maestro.confirmDiscardingEdits(in: sender)
    }

    private static func padded(_ view: NSView) -> NSView {
        let content = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func makeTools() -> NSView {
        let theme = Theme.current
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        grid.rowAlignment = .firstBaseline

        for (index, tool) in SetupTools.all.enumerated() {
            if index == 0 || tool.required != SetupTools.all[index - 1].required {
                let header = NSTextField(labelWithString: tool.required ? "Required" : "Optional")
                header.font = .systemFont(ofSize: 11, weight: .semibold)
                header.textColor = theme.muted
                let row = grid.addRow(with: [
                    header, NSGridCell.emptyContentView, NSGridCell.emptyContentView,
                ])
                row.mergeCells(in: NSRange(location: 0, length: 3))
                if index > 0 { row.topPadding = 12 }
            }

            let name = NSTextField(labelWithString: tool.name)
            name.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            name.textColor = theme.text
            let status = NSTextField(labelWithString: "…")
            status.font = .systemFont(ofSize: 12)
            status.textColor = theme.muted
            let install = NSButton(title: "Install", target: self, action: #selector(installClicked(_:)))
            install.tag = index
            install.bezelStyle = .rounded
            install.controlSize = .small
            install.isHidden = true
            grid.addRow(with: [name, status, install])
            rows.append(Row(status: status, install: install))
        }
        let voiceHeader = NSTextField(labelWithString: "Voice")
        voiceHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        voiceHeader.textColor = theme.muted
        let voiceHeaderRow = grid.addRow(with: [
            voiceHeader, NSGridCell.emptyContentView, NSGridCell.emptyContentView,
        ])
        voiceHeaderRow.mergeCells(in: NSRange(location: 0, length: 3))
        voiceHeaderRow.topPadding = 12
        let voiceName = NSTextField(labelWithString: "Voice models")
        voiceName.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        voiceName.textColor = theme.text
        let voiceStatus = NSTextField(labelWithString: "…")
        voiceStatus.font = .systemFont(ofSize: 12)
        voiceStatus.textColor = theme.muted
        let retry = NSButton(title: "Retry", target: self, action: #selector(retryVoiceClicked))
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.isHidden = true
        grid.addRow(with: [voiceName, voiceStatus, retry])
        voiceRow = Row(status: voiceStatus, install: retry)

        // Fixed widths, so the window doesn't resize as statuses fill in.
        grid.column(at: 0).width = 110
        grid.column(at: 1).width = 100
        grid.column(at: 2).width = 64
        grid.column(at: 2).xPlacement = .trailing

        checkAgain.target = self
        checkAgain.action = #selector(checkAgainClicked)
        checkAgain.bezelStyle = .rounded

        let content = NSView()
        for view in [grid, checkAgain] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            checkAgain.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            checkAgain.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            checkAgain.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func recheck() {
        guard !checking else { return }
        checking = true
        checkAgain.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let statuses = SetupTools.checkThisMac()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.checkAgain.isEnabled = true
                self.render(statuses)
            }
        }
    }

    private func render(_ statuses: [SetupTools.Status]) {
        let theme = Theme.current
        for (row, status) in zip(rows, statuses) {
            row.status.stringValue = status.found ? "Found" : "Missing"
            row.status.textColor = status.found
                ? theme.green
                : (status.tool.required ? theme.red : theme.muted)
            row.status.toolTip = status.found ? status.paths.joined(separator: "\n") : nil
            row.install.isHidden = status.found || status.tool.install == nil
        }
    }

    private func renderVoice() {
        guard let row = voiceRow else { return }
        let theme = Theme.current
        let state = VoiceModels.shared.state
        row.status.stringValue = VoiceModelStore.label(for: state)
        switch state {
        case .ready:
            row.status.textColor = theme.green
            row.status.toolTip = VoiceModelStore.directory.path
        case .failed(let message):
            row.status.textColor = theme.red
            row.status.toolTip = message
        default:
            row.status.textColor = theme.muted
            row.status.toolTip = nil
        }
        if case .failed = state { row.install.isHidden = false } else { row.install.isHidden = true }
    }

    @objc private func voiceStateChanged() {
        renderVoice()
    }

    @objc private func retryVoiceClicked() {
        VoiceModels.shared.retry()
        renderVoice()
    }

    @objc private func installClicked(_ sender: NSButton) {
        onInstall?(SetupTools.all[sender.tag])
    }

    @objc private func checkAgainClicked() {
        recheck()
    }
}

/// The tabs of the Settings window. A toolbar tab controller keeps the window
/// the size it was given, so each pane is fitted here when it is shown.
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow()
    }

    /// Size the window to the pane in front; the title bar stays where it is.
    func fitWindow() {
        guard let window = view.window,
              tabViewItems.indices.contains(selectedTabViewItemIndex) else { return }
        let item = tabViewItems[selectedTabViewItemIndex]
        window.title = item.label
        guard let pane = item.view else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.fittingSize))
        let top = window.frame.maxY
        window.setFrame(
            NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
            display: true, animate: window.isVisible)
    }
}
