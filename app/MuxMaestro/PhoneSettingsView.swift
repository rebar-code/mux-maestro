import Cocoa
import CoreImage

/// The "Phone" section of the Setup window: the master switch, the settings
/// that go with it, and while it is on, the URL to open on the phone and that
/// URL as a QR code. A PR that adds a phone feature adds its row here.
final class PhoneSettingsView: NSView, NSTextFieldDelegate {
    /// The master switch was flipped by the user.
    var onToggle: ((Bool) -> Void)?
    var onPort: ((Int) -> Void)?
    var onGrouping: ((MobileGrouping) -> Void)?
    var onKeepAwake: ((Bool) -> Void)?
    /// A feature's switch was flipped.
    var onCapability: ((MobileCapability, Bool) -> Void)?
    var onVoice: ((MobileVoiceDefaults) -> Void)?
    var onUploadLimit: ((Int) -> Void)?
    var onPush: ((MobilePushOptions) -> Void)?
    /// "Send Test Notification" was clicked.
    var onTestPush: (() -> Void)?
    /// "New Pairing Code" was confirmed.
    var onRotate: (() -> Void)?
    /// The view's height changed; the window refits.
    var onResize: (() -> Void)?

    private let toggle = NSSwitch()
    private let status = NSTextField(labelWithString: "Off")
    /// Why the last start failed, on its own line: the status column is too
    /// narrow for it, and a switch that turns itself off must say why.
    private let failure = NSTextField(wrappingLabelWithString: "")
    private let port = NSTextField(string: "")
    private let grouping = NSPopUpButton()
    private let keepAwake = NSSwitch()
    private let manager = NSSwitch()
    private let voice = NSSwitch()
    private let voiceMode = NSPopUpButton()
    private let voiceSpeaker = NSPopUpButton()
    private let replies = NSSwitch()
    private let keyBar = NSSwitch()
    private let upload = NSSwitch()
    private let uploadLimit = NSPopUpButton()
    private let sessionActions = NSSwitch()
    private let kill = NSSwitch()
    private let find = NSSwitch()
    private let artifacts = NSSwitch()
    private let localServers = NSSwitch()
    private let notifications = NSSwitch()
    private let liveTerminal = NSSwitch()
    private let pushEvents = NSPopUpButton()
    private let pushText = NSPopUpButton()
    /// The VAPID contact: a `mailto:` address or an `https:` URL.
    private let pushSubject = NSTextField(string: "")
    private let pushTest = NSButton(title: "Send Test Notification", target: nil, action: nil)
    private let pushTestStatus = NSTextField(labelWithString: "")
    private let pushContactRow = NSStackView()
    private let pushTestRow = NSStackView()
    /// The ports of the dev servers published on the tailnet now.
    private let mappings = NSTextField(labelWithString: "")
    private let url = NSTextField(labelWithString: "")
    private let copy = NSButton(title: "Copy Pairing Link", target: nil, action: nil)
    private let rotate = NSButton(title: "New Pairing Code…", target: nil, action: nil)
    private let buttonRow = NSStackView()
    /// The link with the pairing token: what the QR code and Copy hold.
    private var pairing = ""
    private let qr = NSImageView()
    private let urlRow = NSStackView()

    private static let qrSize: CGFloat = 200
    private static let groupings: [(MobileGrouping, String)] = [
        (.recent, "Most Recent"), (.host, "Host"), (.directory, "Directory"),
    ]
    private static let voiceModes: [(MobileVoiceMode, String)] = [(.manual, "Manual"), (.auto, "Auto")]
    private static let voiceSpeakers: [(Bool, String)] = [(true, "Two-way"), (false, "Input only")]
    private static let uploadLimits = MobileReply.uploadLimits.map { ($0, "\($0 / 1_048_576) MB") }
    private static let pushEventChoices: [(waiting: Bool, done: Bool, title: String)] = [
        (true, true, "Both events"), (true, false, "Needs you"), (false, true, "Finished"),
    ]
    private static let pushTextChoices: [(Bool, String)] = [(false, "Generic"), (true, "Detailed")]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let theme = Theme.current

        let header = NSTextField(labelWithString: "Phone")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = theme.muted

        status.font = .systemFont(ofSize: 12)
        status.textColor = theme.muted
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for control in [
            toggle, keepAwake, manager, voice, replies, keyBar, upload, sessionActions, kill, find,
            artifacts, localServers, notifications, liveTerminal,
        ] {
            control.controlSize = .small
            control.target = self
        }
        toggle.action = #selector(toggled)
        keepAwake.action = #selector(keepAwakeToggled)
        manager.action = #selector(managerToggled)
        voice.action = #selector(voiceToggled)

        port.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        port.alignment = .right
        port.controlSize = .small
        port.delegate = self
        port.target = self
        port.action = #selector(portCommitted)
        port.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let digits = NumberFormatter()
        digits.allowsFloats = false
        digits.usesGroupingSeparator = false
        digits.minimum = NSNumber(value: Settings.phonePortRange.lowerBound)
        digits.maximum = NSNumber(value: Settings.phonePortRange.upperBound)
        port.formatter = digits

        grouping.controlSize = .small
        grouping.font = .systemFont(ofSize: 12)
        grouping.addItems(withTitles: Self.groupings.map(\.1))
        grouping.target = self
        grouping.action = #selector(groupingPicked)
        for (popup, titles) in [
            (voiceMode, Self.voiceModes.map(\.1)), (voiceSpeaker, Self.voiceSpeakers.map(\.1)),
        ] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 12)
            popup.addItems(withTitles: titles)
            popup.target = self
            popup.action = #selector(voicePicked)
        }
        replies.action = #selector(repliesToggled)
        keyBar.action = #selector(keyBarToggled)
        upload.action = #selector(uploadToggled)
        sessionActions.action = #selector(sessionActionsToggled)
        kill.action = #selector(killToggled)
        find.action = #selector(findToggled)
        artifacts.action = #selector(artifactsToggled)
        localServers.action = #selector(localServersToggled)
        mappings.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        mappings.textColor = theme.muted
        mappings.lineBreakMode = .byTruncatingTail
        mappings.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mappings.setAccessibilityLabel("Open local servers")
        notifications.action = #selector(notificationsToggled)
        liveTerminal.action = #selector(liveTerminalToggled)
        // The subscribed phones, until a test is sent; then what the test came to.
        pushTestStatus.font = .systemFont(ofSize: 12)
        pushTestStatus.textColor = theme.muted
        pushTestStatus.lineBreakMode = .byTruncatingTail
        pushTestStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pushTestStatus.setAccessibilityLabel("Subscribed phones and test result")
        for (popup, titles) in [
            (pushEvents, Self.pushEventChoices.map(\.title)), (pushText, Self.pushTextChoices.map(\.1)),
        ] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 12)
            popup.addItems(withTitles: titles)
            popup.target = self
            popup.action = #selector(pushPicked)
        }
        pushSubject.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pushSubject.controlSize = .small
        pushSubject.delegate = self
        pushSubject.target = self
        pushSubject.action = #selector(pushPicked)
        pushSubject.lineBreakMode = .byTruncatingTail
        pushSubject.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pushSubject.setAccessibilityLabel("Push contact")
        pushText.toolTip = "Detailed: session name and prompt text"
        pushSubject.toolTip = "mailto: address or https: URL sent to the push service"
        // The contact and the test are wider than the grid's control column:
        // in it they would take the status column's room. They get rows of their own.
        let contactName = NSTextField(labelWithString: "Push contact")
        contactName.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        contactName.textColor = theme.text
        contactName.setContentHuggingPriority(.required, for: .horizontal)
        pushContactRow.setViews([contactName, pushSubject], in: .leading)
        pushContactRow.spacing = 16
        pushTestRow.setViews([pushTest, pushTestStatus], in: .leading)
        pushTestRow.spacing = 8
        pushTest.setContentHuggingPriority(.required, for: .horizontal)
        pushTest.bezelStyle = .rounded
        pushTest.controlSize = .small
        pushTest.target = self
        pushTest.action = #selector(pushTestClicked)
        uploadLimit.controlSize = .small
        uploadLimit.font = .systemFont(ofSize: 12)
        uploadLimit.addItems(withTitles: Self.uploadLimits.map(\.1))
        uploadLimit.target = self
        uploadLimit.action = #selector(uploadLimitPicked)

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        grid.rowAlignment = .firstBaseline
        let rows: [(String, NSView, NSView)] = [
            ("Phone access", status, toggle),
            ("Port", NSGridCell.emptyContentView, port),
            ("Default grouping", NSGridCell.emptyContentView, grouping),
            ("Keep Mac awake", NSGridCell.emptyContentView, keepAwake),
            ("Run Maestro agent", NSGridCell.emptyContentView, manager),
            ("Voice", NSGridCell.emptyContentView, voice),
            ("Voice mode", NSGridCell.emptyContentView, voiceMode),
            ("Voice speaker", NSGridCell.emptyContentView, voiceSpeaker),
            ("Replies", NSGridCell.emptyContentView, replies),
            ("Key bar", NSGridCell.emptyContentView, keyBar),
            ("File upload", NSGridCell.emptyContentView, upload),
            ("Upload limit", NSGridCell.emptyContentView, uploadLimit),
            ("Session actions", NSGridCell.emptyContentView, sessionActions),
            ("Kill", NSGridCell.emptyContentView, kill),
            ("Find", NSGridCell.emptyContentView, find),
            ("Artifacts", NSGridCell.emptyContentView, artifacts),
            ("Local servers", mappings, localServers),
            ("Notifications", NSGridCell.emptyContentView, notifications),
            ("Notify on", NSGridCell.emptyContentView, pushEvents),
            ("Notification text", NSGridCell.emptyContentView, pushText),
            ("Live terminal", NSGridCell.emptyContentView, liveTerminal),
        ]
        for (title, middle, control) in rows {
            let name = NSTextField(labelWithString: title)
            name.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            name.textColor = theme.text
            control.setAccessibilityLabel(title)
            grid.addRow(with: [name, middle, control])
        }
        grid.column(at: 0).width = 150
        grid.column(at: 2).xPlacement = .trailing
        grid.row(at: 0).rowAlignment = .none
        grid.row(at: 0).yPlacement = .center
        // A row whose control is a switch is centred on it. Found by the
        // control, not by a list of row numbers that a new row would shift.
        for (row, entry) in rows.enumerated() where entry.2 is NSSwitch {
            grid.row(at: row).rowAlignment = .none
            grid.row(at: row).yPlacement = .center
        }

        url.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        url.textColor = theme.accent
        url.isSelectable = true
        url.lineBreakMode = .byTruncatingMiddle
        url.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.target = self
        copy.action = #selector(copyURL)
        rotate.bezelStyle = .rounded
        rotate.controlSize = .small
        rotate.target = self
        rotate.action = #selector(rotateClicked)
        urlRow.setViews([url], in: .leading)
        buttonRow.setViews([copy, rotate], in: .leading)
        buttonRow.spacing = 8

        qr.imageScaling = .scaleNone
        qr.setAccessibilityLabel("QR code that pairs a phone")
        qr.translatesAutoresizingMaskIntoConstraints = false

        failure.font = .systemFont(ofSize: 12)
        failure.textColor = theme.red
        failure.isSelectable = true
        failure.setAccessibilityLabel("Phone access error")

        let stack = NSStackView(
            views: [header, grid, pushContactRow, pushTestRow, failure, urlRow, qr, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: pushTestRow)
        stack.setCustomSpacing(12, after: urlRow)
        stack.setCustomSpacing(12, after: qr)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pushContactRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pushTestRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            failure.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            qr.widthAnchor.constraint(equalToConstant: Self.qrSize),
            qr.heightAnchor.constraint(equalToConstant: Self.qrSize),
        ])
        loadSettings()
        render(.off)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show the stored values in the controls.
    func loadSettings() {
        port.integerValue = Settings.phonePort()
        let current = Settings.phoneGrouping()
        grouping.selectItem(at: Self.groupings.firstIndex { $0.0 == current } ?? 0)
        keepAwake.state = Settings.phoneKeepAwake() ? .on : .off
        manager.state = Settings.phoneCapability(.manager) ? .on : .off
        voice.state = Settings.phoneCapability(.voice) ? .on : .off
        let defaults = Settings.phoneVoice()
        voiceMode.selectItem(at: Self.voiceModes.firstIndex { $0.0 == defaults.mode } ?? 0)
        voiceSpeaker.selectItem(at: Self.voiceSpeakers.firstIndex { $0.0 == defaults.speaker } ?? 0)
        replies.state = Settings.phoneCapability(.replies) ? .on : .off
        keyBar.state = Settings.phoneCapability(.keyBar) ? .on : .off
        upload.state = Settings.phoneCapability(.upload) ? .on : .off
        sessionActions.state = Settings.phoneCapability(.sessionActions) ? .on : .off
        kill.state = Settings.phoneCapability(.kill) ? .on : .off
        // Kill is one of the session actions: it has nothing to do without them.
        kill.isEnabled = sessionActions.state == .on
        find.state = Settings.phoneCapability(.find) ? .on : .off
        artifacts.state = Settings.phoneCapability(.artifacts) ? .on : .off
        localServers.state = Settings.phoneCapability(.localServers) ? .on : .off
        notifications.state = Settings.phoneCapability(.notifications) ? .on : .off
        liveTerminal.state = Settings.phoneCapability(.liveTerminal) ? .on : .off
        let push = Settings.phonePush()
        pushEvents.selectItem(at: Self.pushEventChoices.firstIndex {
            $0.waiting == push.waiting && $0.done == push.done
        } ?? 0)
        pushText.selectItem(at: Self.pushTextChoices.firstIndex { $0.0 == push.detail } ?? 0)
        pushSubject.stringValue = push.subject
        let limit = Settings.phoneUploadLimit()
        uploadLimit.selectItem(at: Self.uploadLimits.firstIndex { $0.0 == limit } ?? 0)
    }

    func render(_ state: PhoneLink.State) {
        let theme = Theme.current
        var link: String?
        switch state {
        case .off:
            status.stringValue = "Off"
            status.textColor = theme.muted
            toggle.state = .off
        case .starting:
            status.stringValue = "Starting…"
            status.textColor = theme.muted
            toggle.state = .on
        case .waitingForKeychain:
            status.stringValue = "Waiting"
            status.textColor = theme.amber
            toggle.state = .on
        case .on(let address, let pairingLink):
            status.stringValue = "On"
            status.textColor = theme.green
            toggle.state = .on
            link = address
            pairing = pairingLink
        case .failed:
            status.stringValue = "Failed"
            status.textColor = theme.red
            toggle.state = .off
        }
        // The full-width line under the grid: why a start failed, or what a
        // start is waiting for.
        var reason = ""
        if case .failed(let why) = state { reason = why }
        if state == .waitingForKeychain { reason = "Waiting for Keychain" }
        failure.textColor = state == .waitingForKeychain ? theme.amber : theme.red
        let failureChanged = failure.stringValue != reason
        failure.stringValue = reason
        failure.isHidden = reason.isEmpty
        url.stringValue = link ?? ""
        if link == nil { pairing = "" }
        qr.image = link == nil ? nil : Self.qrImage(pairing, side: Self.qrSize)
        let hidden = link == nil
        let linkChanged = urlRow.isHidden != hidden
        for view in [urlRow, qr, buttonRow] as [NSView] { view.isHidden = hidden }
        if linkChanged || failureChanged { onResize?() }
    }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }

    @objc private func keepAwakeToggled() {
        onKeepAwake?(keepAwake.state == .on)
    }

    @objc private func managerToggled() {
        onCapability?(.manager, manager.state == .on)
    }

    @objc private func voiceToggled() {
        onCapability?(.voice, voice.state == .on)
    }

    @objc private func repliesToggled() {
        onCapability?(.replies, replies.state == .on)
    }

    @objc private func keyBarToggled() {
        onCapability?(.keyBar, keyBar.state == .on)
    }

    @objc private func uploadToggled() {
        onCapability?(.upload, upload.state == .on)
    }

    @objc private func sessionActionsToggled() {
        kill.isEnabled = sessionActions.state == .on
        onCapability?(.sessionActions, sessionActions.state == .on)
    }

    @objc private func killToggled() {
        onCapability?(.kill, kill.state == .on)
    }

    @objc private func findToggled() {
        onCapability?(.find, find.state == .on)
    }

    @objc private func artifactsToggled() {
        onCapability?(.artifacts, artifacts.state == .on)
    }

    @objc private func localServersToggled() {
        onCapability?(.localServers, localServers.state == .on)
    }

    @objc private func notificationsToggled() {
        onCapability?(.notifications, notifications.state == .on)
    }

    /// The live terminal is a keyboard on the pane, with none of the checks
    /// the other switches apply, so turning it on asks first.
    @objc private func liveTerminalToggled() {
        if liveTerminal.state == .on {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = MobileTerminal.confirmTitle
            alert.informativeText = MobileTerminal.confirmText
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Turn On")
            guard alert.runModal() == .alertSecondButtonReturn else {
                liveTerminal.state = .off
                return
            }
        }
        onCapability?(.liveTerminal, liveTerminal.state == .on)
    }

    /// A pick, or a committed contact. A contact that is not a `mailto:`
    /// address or an `https:` URL is put back as it was.
    @objc private func pushPicked() {
        let events = pushEvents.indexOfSelectedItem, text = pushText.indexOfSelectedItem
        guard Self.pushEventChoices.indices.contains(events), Self.pushTextChoices.indices.contains(text)
        else { return }
        let stored = Settings.phonePush()
        let subject = MobilePush.subject(pushSubject.stringValue) ?? stored.subject
        pushSubject.stringValue = subject
        let options = MobilePushOptions(
            waiting: Self.pushEventChoices[events].waiting, done: Self.pushEventChoices[events].done,
            detail: Self.pushTextChoices[text].0, subject: subject)
        if options != stored { onPush?(options) }
    }

    @objc private func pushTestClicked() {
        pushTestStatus.stringValue = "Sending…"
        onTestPush?()
    }

    func renderPushCount(_ count: Int) {
        let text = count == 0 ? "No phone" : count == 1 ? "1 phone" : "\(count) phones"
        pushTestStatus.stringValue = text
        pushTestStatus.toolTip = text
    }

    /// What the test came to. A refusal shows what the push service said
    /// (a contact it does not accept is "403 BadJwtToken"); the tooltip has
    /// the whole line when the column cuts it.
    func renderPushTest(_ result: MobilePushCenter.TestResult) {
        let text: String
        switch result {
        case .noPhone: text = "No phone"
        case .unavailable: text = "Failed"
        case .sent(let accepted, let total, let error):
            if accepted == total {
                text = "Sent"
            } else if accepted == 0 {
                text = error.isEmpty ? "Failed" : "Failed: \(error)"
            } else {
                text = "Sent to \(accepted) of \(total)" + (error.isEmpty ? "" : ": \(error)")
            }
        }
        pushTestStatus.stringValue = text
        pushTestStatus.toolTip = text
    }

    /// Show the dev-server ports that are published on the tailnet now.
    func renderMappings(_ ports: [Int]) {
        mappings.stringValue = ports.sorted().map { ":\($0)" }.joined(separator: " ")
    }

    @objc private func uploadLimitPicked() {
        let index = uploadLimit.indexOfSelectedItem
        guard Self.uploadLimits.indices.contains(index) else { return }
        onUploadLimit?(Self.uploadLimits[index].0)
    }

    @objc private func voicePicked() {
        let mode = voiceMode.indexOfSelectedItem, speaker = voiceSpeaker.indexOfSelectedItem
        guard Self.voiceModes.indices.contains(mode), Self.voiceSpeakers.indices.contains(speaker)
        else { return }
        onVoice?(MobileVoiceDefaults(mode: Self.voiceModes[mode].0, speaker: Self.voiceSpeakers[speaker].0))
    }

    @objc private func groupingPicked() {
        let index = grouping.indexOfSelectedItem
        guard Self.groupings.indices.contains(index) else { return }
        onGrouping?(Self.groupings[index].0)
    }

    /// Return or a focus change commits the port. The formatter has already
    /// refused anything out of range.
    @objc private func portCommitted() {
        let value = port.integerValue
        guard Settings.phonePortRange.contains(value), value != Settings.phonePort() else {
            port.integerValue = Settings.phonePort()
            return
        }
        onPort?(value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === pushSubject { pushPicked() } else { portCommitted() }
    }

    @objc private func copyURL() {
        guard !pairing.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairing, forType: .string)
    }

    /// A new code signs every paired phone out, so it asks first.
    @objc private func rotateClicked() {
        let alert = NSAlert()
        alert.messageText = "Make a new pairing code?"
        alert.informativeText = "Every paired phone is signed out and must scan the new QR code."
        alert.addButton(withTitle: "New Pairing Code")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRotate?()
    }

    /// `text` as a QR code with a white quiet zone, so a phone camera reads it
    /// on the dark window.
    static func qrImage(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let quiet: CGFloat = 12
        let scale = floor((side - quiet * 2) / output.extent.width)
        guard scale >= 1 else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                     xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(
            x: (side - rep.size.width) / 2, y: (side - rep.size.height) / 2,
            width: rep.size.width, height: rep.size.height))
        image.unlockFocus()
        return image
    }
}
