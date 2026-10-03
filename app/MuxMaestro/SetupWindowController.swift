import Cocoa

/// MuxMaestro ▸ Setup…: each command-line tool the app uses, found or missing,
/// with an Install button on the missing ones. Nothing installs until that
/// button is clicked; the install then runs visibly in the terminal, where it can
/// ask for a password. Opens by itself at launch when a required tool is missing.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    /// Runs a tool's install recipe. Set by the app delegate, which owns the terminal.
    var onInstall: ((SetupTool) -> Void)?

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
        window.title = "Setup"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.current.bg
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        let content = makeContent()
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceStateChanged), name: VoiceModels.stateDidChange, object: nil)
        renderVoice()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recheck()
    }

    /// Coming back from an install in the terminal re-reads what's there.
    func windowDidBecomeKey(_ notification: Notification) {
        recheck()
    }

    private func makeContent() -> NSView {
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
