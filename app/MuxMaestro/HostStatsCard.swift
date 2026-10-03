import Cocoa

/// The stat card under an expanded Servers row: CPU and RAM on the first line,
/// disk and uptime on the second. Values are in the text colour and their words
/// muted, so the numbers are what the eye lands on. The card fill and server
/// tint behind it are the row view's (`CardRowView`).
final class HostStatsCell: NSTableCellView {
    /// Content height of the two lines; the row adds the card's gap and padding.
    static let contentHeight: CGFloat = 34
    /// Fits "Disk 757G free" and "CPU 226/128".
    private static let firstColumn: CGFloat = 84

    private let cpu = HostStatsCell.label()
    private let ram = HostStatsCell.label()
    private let disk = HostStatsCell.label()
    private let uptime = HostStatsCell.label()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let grid = NSGridView(views: [[cpu, ram], [disk, uptime]])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 10
        grid.rowSpacing = 2
        grid.yPlacement = .center
        addSubview(grid)
        NSLayoutConstraint.activate([
            // A floor on the first column lines RAM and uptime up across every
            // server's card; a wider value still pushes it right, never clips.
            cpu.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.firstColumn),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            grid.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// nil stats: nothing fetched yet, every value a dash.
    func configure(_ stats: HostStats?) {
        let s = stats ?? HostStats()
        cpu.attributedStringValue = Self.styled(s.cpuLabel)
        ram.attributedStringValue = Self.styled(s.ramLabel)
        disk.attributedStringValue = Self.styled(s.diskLabel)
        uptime.attributedStringValue = Self.styled(s.uptimeLabel)
        cpu.toolTip = s.cpuTooltip
        disk.toolTip = s.diskTooltip
    }

    private static func label() -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byClipping
        // Every character of a number carries meaning: never compress one.
        f.setContentCompressionResistancePriority(.required, for: .horizontal)
        return f
    }

    /// "Disk 120G free": the value (any word with a digit, or the dash) in the
    /// text colour, the words around it muted.
    private static func styled(_ label: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let out = NSMutableAttributedString()
        for (i, word) in label.split(separator: " ").enumerated() {
            let isValue = word.contains(where: \.isNumber) || word == HostStats.dash
            out.append(NSAttributedString(
                string: (i > 0 ? " " : "") + word,
                attributes: [
                    .font: isValue ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium) : font,
                    .foregroundColor: isValue ? SidebarPalette.text : SidebarPalette.muted,
                ]))
        }
        return out
    }
}
