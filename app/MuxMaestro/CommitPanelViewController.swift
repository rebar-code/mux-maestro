import Cocoa

/// Drives the ⌥⌘C commit panel. The AppDelegate implements this to run the git
/// work off-main (mirroring the Diff pane's data flow) and call back into the VC.
protocol CommitPanelDelegate: AnyObject {
    /// Stage (or unstage) one file, then the panel reloads its list.
    func commitPanel(_ vc: CommitPanelViewController, toggleStage path: String, staged: Bool)
    /// Re-read the changed-file list + header for the bound session.
    func commitPanelReload(_ vc: CommitPanelViewController)
    /// Run the full flow: commit the staged index → push → open a PR.
    func commitPanel(_ vc: CommitPanelViewController, submitSubject subject: String, body: String)
}

/// An NSPanel that can become key so its fields accept typing.
private final class FloatingCommitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One changed-file row: a stage checkbox, a status glyph, and the path.
private final class CommitFileCell: NSTableCellView {
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let glyph = NSTextField(labelWithString: "")
    let pathField = NSTextField(labelWithString: "")
    var onToggle: ((Bool) -> Void)?

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        check.title = ""
        check.target = self
        check.action = #selector(toggled)
        check.setContentHuggingPriority(.required, for: .horizontal)
        glyph.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        glyph.alignment = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        pathField.font = .systemFont(ofSize: 12)
        pathField.textColor = SidebarPalette.text
        pathField.alignment = .left
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.usesSingleLineMode = true
        pathField.maximumNumberOfLines = 1
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)  // fill remaining width

        // A leading-aligned stack lays the row out left→right robustly: checkbox,
        // fixed-width glyph, then the path filling the rest.
        let row = NSStackView(views: [check, glyph, pathField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        textField = pathField
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ file: ChangedFile) {
        check.state = file.staged ? .on : .off
        glyph.stringValue = file.glyph
        glyph.textColor = Self.color(for: file.glyph)
        pathField.stringValue = file.path
    }
    @objc private func toggled() { onToggle?(check.state == .on) }

    static func color(for glyph: String) -> NSColor {
        switch glyph {
        case "A": return SidebarPalette.green
        case "D": return SidebarPalette.red
        case "M": return SidebarPalette.amber
        default: return SidebarPalette.muted
        }
    }
}

/// The ⌥⌘C commit panel: a floating panel bound to the selected session's repo
/// that lists uncommitted files with stage checkboxes, takes a commit message,
/// and runs the commit → push → open-PR flow. First write-git surface in the app,
/// so every step reports success/failure explicitly. Sibling of the ⌘P/⌘K palettes.
final class CommitPanelViewController: NSViewController {
    weak var delegate: CommitPanelDelegate?

    private let branchLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let subjectField = NSTextField()
    private let bodyView = NSTextView()
    private let bodyScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let commitButton = NSButton(title: "Commit, Push & PR", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private var files: [ChangedFile] = []
    private var busy = false

    private lazy var panel: FloatingCommitPanel = {
        let p = FloatingCommitPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.contentViewController = self
        return p
    }()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = SidebarPalette.bg.cgColor

        branchLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        branchLabel.textColor = SidebarPalette.text
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = SidebarPalette.muted
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = SidebarPalette.bg
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = SidebarPalette.bg
        scroll.borderType = .lineBorder

        subjectField.placeholderString = "Commit message (subject)…"
        subjectField.font = .systemFont(ofSize: 13)
        subjectField.focusRingType = .none
        subjectField.delegate = self

        bodyView.font = .systemFont(ofSize: 12)
        bodyView.textColor = SidebarPalette.text
        bodyView.backgroundColor = SidebarPalette.surface
        bodyView.isRichText = false
        bodyView.isVerticallyResizable = true
        bodyView.textContainer?.widthTracksTextView = true
        bodyScroll.documentView = bodyView
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .lineBorder
        bodyScroll.drawsBackground = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = SidebarPalette.muted
        statusLabel.lineBreakMode = .byTruncatingTail

        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"  // ⏎ triggers the primary action
        commitButton.target = self
        commitButton.action = #selector(submit)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        [branchLabel, subtitleLabel, subjectField, statusLabel, commitButton, spinner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        [branchLabel, subtitleLabel, scroll, subjectField, bodyScroll, statusLabel, spinner, commitButton]
            .forEach(container.addSubview)

        NSLayoutConstraint.activate([
            branchLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
            branchLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            branchLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            subtitleLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            subjectField.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            subjectField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            subjectField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            bodyScroll.topAnchor.constraint(equalTo: subjectField.bottomAnchor, constant: 8),
            bodyScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            bodyScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            bodyScroll.heightAnchor.constraint(equalToConstant: 72),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),

            commitButton.topAnchor.constraint(equalTo: bodyScroll.bottomAnchor, constant: 10),
            commitButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            commitButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        self.view = container
        preferredContentSize = NSSize(width: 640, height: 520)
    }

    // MARK: Presentation

    func present(over parent: NSWindow) {
        let p = panel
        let size = p.frame.size
        let pf = parent.frame
        p.setFrameOrigin(NSPoint(x: pf.midX - size.width / 2, y: pf.maxY - size.height - 60))
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(subjectField)
    }
    func close() { panel.close() }

    // MARK: Data in

    func setHeader(branch: String, subtitle: String) {
        branchLabel.stringValue = branch
        subtitleLabel.stringValue = subtitle
    }
    func setFiles(_ files: [ChangedFile]) {
        self.files = files
        tableView.reloadData()
        updateCommitEnabled()
    }
    /// A transient status line; `error` colors it red.
    func setStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? SidebarPalette.red : SidebarPalette.muted
    }
    /// Disable inputs + spin while a git op runs.
    func setBusy(_ busy: Bool) {
        self.busy = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        subjectField.isEnabled = !busy
        bodyView.isEditable = !busy
        updateCommitEnabled()
    }

    private var stagedCount: Int { files.filter(\.staged).count }
    private var subject: String {
        subjectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func updateCommitEnabled() {
        commitButton.isEnabled = !busy && stagedCount > 0 && !subject.isEmpty
    }

    // MARK: Actions

    @objc private func submit() {
        guard !busy, stagedCount > 0, !subject.isEmpty else { return }
        delegate?.commitPanel(self, submitSubject: subject, body: bodyView.string)
    }
    private func toggle(path: String, staged: Bool) {
        guard !busy else { return }
        delegate?.commitPanel(self, toggleStage: path, staged: staged)
    }
}

// MARK: - NSTextFieldDelegate (enable Commit as the subject is typed)

extension CommitPanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { updateCommitEnabled() }
}

// MARK: - Table

extension CommitPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("commitFile")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? CommitFileCell
            ?? CommitFileCell(id: id)
        let file = files[row]
        cell.configure(file)
        cell.onToggle = { [weak self] staged in self?.toggle(path: file.path, staged: staged) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
