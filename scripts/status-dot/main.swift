import Cocoa

// Draws the REAL AttentionDotView in every state into one PNG, and checks what a picture can show: which states are solid, which are
// rings, and that the working arc's bright end leads the way it turns.

let shots = ProcessInfo.processInfo.environment["STATUS_DOT_SHOTS"] ?? "/tmp/status-dot"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let states: [(StatusIndicator, String)] = [
    (.needsYou, "needs you"), (.unviewed, "done"), (.viewed, "viewed"),
    (.working, "working"), (.idle, "no turn yet"), (.none, "no agent"),
]
let scale: CGFloat = 16
let side: CGFloat = 12
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "ok  " : "FAIL")  \(what)")
    if !ok { failures += 1 }
}

/// The dot in `state`, drawn `scale` times its size. `turn` rotates the moving
/// layer by that many radians, as the animation would.
func render(_ state: StatusIndicator, theme: Theme, turn: CGFloat = 0) -> NSBitmapImageRep {
    Theme.current = theme
    let view = AttentionDotView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    view.animates = false
    view.indicator = state
    view.layoutSubtreeIfNeeded()
    view.display()
    if turn != 0 {
        // The key path the animation turns.
        let arcs = view.layer?.sublayers?.filter { $0 is CAGradientLayer } ?? []
        check(arcs.count == 1, "the working dot has one arc layer")
        arcs.first?.setValue(turn, forKeyPath: "transform.rotation.z")
        CATransaction.flush()
    }
    let px = Int(side * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.setFillColor(theme.bg.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    // The view is flipped: draw it top-down.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)
    view.layer?.render(in: ctx)
    return rep
}

/// How far the pixel at a point of the dot (in points, from its centre) is
/// from the background.
func ink(_ rep: NSBitmapImageRep, dx: CGFloat, dy: CGFloat, bg: NSColor) -> CGFloat {
    let x = Int((side / 2 + dx) * scale), y = Int((side / 2 + dy) * scale)
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          let b = bg.usingColorSpace(.deviceRGB) else { return 0 }
    return abs(c.redComponent - b.redComponent) + abs(c.greenComponent - b.greenComponent)
        + abs(c.blueComponent - b.blueComponent)
}

let themes: [(Theme, String)] = [(.dark, "dark")]
let cell = Int(side * scale)
let sheet = NSImage(size: NSSize(width: cell * states.count, height: cell * themes.count))
sheet.lockFocus()
for (row, (theme, themeName)) in themes.enumerated() {
    print("\(themeName):")
    for (column, (state, name)) in states.enumerated() {
        let rep = render(state, theme: theme)
        rep.draw(in: NSRect(
            x: column * cell, y: (themes.count - 1 - row) * cell, width: cell, height: cell))
        let centre = ink(rep, dx: 0, dy: 0, bg: theme.bg)
        // On the ring's band, at the left: clear of the arc's bright end.
        let band = ink(rep, dx: -(AttentionDotView.diameter - AttentionDotView.ringWidth) / 2, dy: 0, bg: theme.bg)
        switch state {
        case .needsYou, .unviewed, .none:
            check(centre > 0.3, "\(name) is solid")
        case .viewed, .idle, .working:
            check(centre < 0.05 && band > 0.1, "\(name) is a ring")
        }
    }
    // The arc's brightest point, before and after a small turn the way the
    // animation goes. The bright end must lead: the brightest point moves on
    // in that direction, into what was the dark part of the ring.
    let r = (AttentionDotView.diameter - AttentionDotView.ringWidth) / 2
    func brightest(_ rep: NSBitmapImageRep) -> CGFloat {
        (0..<72).map { CGFloat($0) * .pi / 36 }.max {
            ink(rep, dx: r * cos($0), dy: r * sin($0), bg: theme.bg)
                < ink(rep, dx: r * cos($1), dy: r * sin($1), bg: theme.bg)
        } ?? 0
    }
    let step: CGFloat = AttentionDotView.spinTurn > 0 ? 0.6 : -0.6
    let before = brightest(render(.working, theme: theme))
    let after = brightest(render(.working, theme: theme, turn: step))
    // Just past the bright end, the way it turns, the ring is dark; behind it, it fades.
    let still = render(.working, theme: theme)
    let ahead = ink(still, dx: r * cos(before + 0.7), dy: r * sin(before + 0.7), bg: theme.bg)
    let behind = ink(still, dx: r * cos(before - 0.7), dy: r * sin(before - 0.7), bg: theme.bg)
    var moved = (after - before).truncatingRemainder(dividingBy: 2 * .pi)
    if moved < 0 { moved += 2 * .pi }
    check(abs(moved - 0.6) < 0.2, "the arc turns with the animation (moved \(moved))")
    check(behind > ahead + 0.05, "the arc's bright end leads, its fade trails (\(behind) > \(ahead))")
}
sheet.unlockFocus()
if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    let path = "\(shots)/status-dots.png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
exit(failures == 0 ? 0 : 1)
