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
    /// "New Pairing Code" was confirmed.
    var onRotate: (() -> Void)?
    /// The view's height changed; the window refits.
    var onResize: (() -> Void)?

    private let toggle = NSSwitch()
    private let status = NSTextField(labelWithString: "Off")
    private let port = NSTextField(string: "")
    private let grouping = NSPopUpButton()
    private let keepAwake = NSSwitch()
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
        for control in [toggle, keepAwake] {
            control.controlSize = .small
            control.target = self
        }
        toggle.action = #selector(toggled)
        keepAwake.action = #selector(keepAwakeToggled)

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

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        grid.rowAlignment = .firstBaseline
        let rows: [(String, NSView, NSView)] = [
            ("Phone access", status, toggle),
            ("Port", NSGridCell.emptyContentView, port),
            ("Default grouping", NSGridCell.emptyContentView, grouping),
            ("Keep Mac awake", NSGridCell.emptyContentView, keepAwake),
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
        grid.row(at: 3).rowAlignment = .none
        grid.row(at: 3).yPlacement = .center

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

        let stack = NSStackView(views: [header, grid, urlRow, qr, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: grid)
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
        case .on(let address, let pairingLink):
            status.stringValue = "On"
            status.textColor = theme.green
            toggle.state = .on
            link = address
            pairing = pairingLink
        case .failed(let reason):
            status.stringValue = reason
            status.textColor = theme.red
            toggle.state = .off
        }
        status.toolTip = status.stringValue
        url.stringValue = link ?? ""
        if link == nil { pairing = "" }
        qr.image = link == nil ? nil : Self.qrImage(pairing, side: Self.qrSize)
        let hidden = link == nil
        guard urlRow.isHidden != hidden else { return }
        for view in [urlRow, qr, buttonRow] as [NSView] { view.isHidden = hidden }
        onResize?()
    }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }

    @objc private func keepAwakeToggled() {
        onKeepAwake?(keepAwake.state == .on)
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
        portCommitted()
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
