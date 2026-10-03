import Cocoa

// Renders the REAL HostStatsCell from stats that go through the real
// HostStats.parse, at the sidebar's 220 pt width, dark and light, and checks
// that no value clips. Built and run by scripts/server-stats-selftest.sh.
//
// The card is drawn the way CardRowView draws a server's card: the server row
// is the header (`.top`, tinted via the real drawPaneAccentGradient and
// CardTint), the stat row the body (`.bottom`, plain). CardRowView itself needs the whole sidebar to compile, so this is
// the one stand-in; the tint decision and gradient are the app's own code.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shots = ProcessInfo.processInfo.environment["SERVER_STATS_SHOTS"] ?? "/tmp/server-stats-shots"
let sidebarWidth: CGFloat = 220
/// Where the outline puts a card row's cell: clear of the chevron column.
let cellX: CGFloat = 16

// MARK: fixtures — real script output from a Linux server and this Mac.

let linux = """
    @os
    Linux
    @cores
    6
    @loadavg
    3.02 3.86 3.76 1/6888 486617
    @cpu
    cpu  190198395 35248 71758638 1835528884 35161645 0 1913588 0 0 0
    cpu  190198495 35248 71758672 1835529309 35161676 0 1913589 0 0 0
    @meminfo
    MemTotal:       32180324 kB
    MemAvailable:   13880688 kB
    @uptime
    3572677.08 18176369.87
    @df
    Filesystem     1024-blocks      Used Available Capacity Mounted on
    /dev/sda2        959218776 116648484 793770960      13% /
    """
let mac = """
    @cores
    10
    @loadavg
    { 2.07 3.70 1.09 }
    @cpu
     39  33  29  105.58 184.81 158.19
    @memsize
    68719476736
    @vmstat
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages wired down:                             466625.
    Pages purgeable:                                1000.
    Anonymous pages:                             1555898.
    Pages occupied by compressor:                1642708.
    @boottime
    { sec = 1787933000, usec = 257221 } Fri Aug 28 11:03:20 2026
    @now
    1790215919
    @df
    Filesystem     1024-blocks      Used Available Capacity  Mounted on
    /dev/disk3s1s1   971350180  15829280 104461248    14%    /
    """
/// The widest realistic values: a loaded 128-core box, 512 GB of RAM, terabytes
/// of disk, years of uptime. (A 1 TB RAM box still fits, 4 pt from the edge.)
let wide = """
    @cores
    128
    @loadavg
    226.31 267.33 199.61
    @cpu
    cpu  100 0 100 0 0 0 0 0 0 0
    cpu  100100 0 100100 0 0 0 0 0 0 0
    @meminfo
    MemTotal:       528000000 kB
    MemAvailable:   12000000 kB
    @uptime
    99999999
    @df
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/md0 99999999999 1 99999999999 1% /
    """

// The local Mac, fetched live through the app's own path.
let live = TmuxService().hostStats()

let cases: [(name: String, host: String, stats: HostStats?)] = [
    ("linux", "devbox", HostStats.parse(linux)),
    ("mac", "localhost", HostStats.parse(mac)),
    ("wide", "big-iron", HostStats.parse(wide)),
    ("pending", "buildbox", nil),
    ("live-local", "localhost", live),
]

var failures = 0
func expect(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

func pump(_ seconds: TimeInterval) {
    let until = Date(timeIntervalSinceNow: seconds)
    while Date() < until {
        if let e = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                 inMode: .default, dequeue: true) {
            app.sendEvent(e)
        }
    }
}

func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + all(type, in: $0) }
}

/// One segment of a server's card as CardRowView draws it: `.top` for the
/// server row (the header), `.bottom` for its stat row.
final class StandInCardRow: NSView {
    var hostHex: String?
    var segment = CardSegment.single
    var isHeader = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        SidebarPalette.bg.setFill()
        bounds.fill()
        var rect = bounds.insetBy(dx: 4, dy: 0)
        rect.origin.y += segment.cardInsets.top
        rect.size.height -= segment.cardInsets.top + segment.cardInsets.bottom
        // Round only the card's outer corners: extend the square edge past the row.
        var shape = rect
        if !segment.roundsBottom { shape.size.height += 8 }
        if !segment.roundsTop { shape.origin.y -= 8; shape.size.height += 8 }
        let fill = NSBezierPath(roundedRect: shape, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).setClip()
        SidebarPalette.card.setFill()
        fill.fill()
        if let hex = CardTint.accentHex(segment: segment, isSession: isHeader, hostHex: hostHex),
           let accent = TmuxColor.parse(hex) {
            NSGraphicsContext.saveGraphicsState()
            fill.setClip()
            drawPaneAccentGradient(accent, in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The server row above the card, for context: glyph and name as the Servers
/// section shows them.
func serverRow(_ name: String, width: CGFloat) -> NSView {
    let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
    let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down",
                                             accessibilityDescription: nil)!)
    chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
    chevron.contentTintColor = SidebarPalette.muted
    chevron.frame = NSRect(x: 18, y: 7, width: 12, height: 14)
    let glyph = NSImageView(image: NSImage(systemSymbolName: name == "localhost"
        ? "laptopcomputer" : "server.rack", accessibilityDescription: nil)!)
    glyph.symbolConfiguration = .init(pointSize: 11, weight: .regular)
    glyph.contentTintColor = SidebarPalette.accent
    glyph.frame = NSRect(x: 34, y: 7, width: 14, height: 14)
    let label = NSTextField(labelWithString: name)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = SidebarPalette.text
    label.frame = NSRect(x: 54, y: 5, width: width - 60, height: 17)
    [chevron, glyph, label].forEach(row.addSubview)
    return row
}

for (suffix, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
    let appearance = NSAppearance(named: look)!
    let headHeight = CardSegment.top.rowHeight(content: 28)
    let rowHeight = CardSegment.bottom.rowHeight(content: HostStatsCell.contentHeight)
    let stackHeight = CGFloat(cases.count) * (headHeight + rowHeight)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: stackHeight))
    root.appearance = appearance
    root.wantsLayer = true
    let window = NSWindow(contentRect: root.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = root
    appearance.performAsCurrentDrawingAppearance {
        root.layer?.backgroundColor = SidebarPalette.bg.cgColor
    }

    var cells: [(String, HostStatsCell)] = []
    var y = stackHeight
    for c in cases {
        let hex = Settings.colorHex(host: Host(name: c.host, sshAlias: c.host))
        y -= headHeight
        let head = StandInCardRow(frame: NSRect(x: 0, y: y, width: sidebarWidth, height: headHeight))
        head.hostHex = hex
        head.segment = .top
        let header = serverRow(c.host, width: sidebarWidth)
        header.frame.origin.y = CardSegment.top.contentInsets.top
        head.addSubview(header)
        root.addSubview(head)
        y -= rowHeight
        let card = StandInCardRow(frame: NSRect(x: 0, y: y, width: sidebarWidth, height: rowHeight))
        card.hostHex = hex
        card.segment = .bottom
        card.isHeader = false
        let insets = CardSegment.bottom.contentInsets
        let cell = HostStatsCell(id: .init("hostStatsCell"))
        cell.frame = NSRect(x: cellX, y: insets.top, width: sidebarWidth - cellX,
                            height: rowHeight - insets.top - insets.bottom)
        cell.configure(c.stats)
        card.addSubview(cell)
        root.addSubview(card)
        cells.append((c.name, cell))
    }
    window.orderFrontRegardless()
    pump(0.3)
    root.layoutSubtreeIfNeeded()

    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(2) }
    root.cacheDisplay(in: root.bounds, to: rep)
    let url = URL(fileURLWithPath: shots).appendingPathComponent("stat-cards-\(suffix).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path)")

    for (name, cell) in cells {
        let fields = all(NSTextField.self, in: cell)
        let clipped = fields.filter { $0.frame.width + 0.5 < $0.intrinsicContentSize.width }
        expect("\(suffix) \(name): no value clipped", clipped.isEmpty,
               clipped.map(\.stringValue).joined(separator: ", "))
        let right = fields.map { $0.convert($0.bounds, to: cell).maxX }.max() ?? 0
        expect("\(suffix) \(name): fits the \(Int(sidebarWidth)) pt sidebar",
               right <= cell.bounds.width - 8 - 4, "right edge \(right) of \(cell.bounds.width)")
        expect("\(suffix) \(name): four labels", fields.count == 4, "\(fields.count)")
    }
    window.orderOut(nil)
}

expect("pending card shows a dash for every value",
       HostStats().labels.allSatisfy { $0.hasSuffix("—") })
expect("the live local fetch answered", live != nil && live?.cores != nil
       && live?.memTotalBytes != nil && live?.diskFreeBytes != nil && live?.uptimeSeconds != nil,
       live.map { $0.labels.joined(separator: " · ") } ?? "nil")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
