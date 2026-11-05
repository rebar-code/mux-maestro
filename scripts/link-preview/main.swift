import Cocoa
import GhosttyKit
import WebKit

// Drives the REAL TerminalSurfaceView (a live libghostty surface printing demo
// URLs) and the REAL LinkPreviewViewController beside it. Sends mouse moves
// with and without ⌘ through the surface's own handlers, then checks which
// URL reached the preview, that the terminal kept focus, and snapshots it.
// Built and run by scripts/link-preview-selftest.sh.

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shots = ProcessInfo.processInfo.environment["LINK_PREVIEW_SHOTS"] ?? "/tmp/link-preview"

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

guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
      let ghostty = GhosttyApp(), let ghosttyApp = ghostty.app else {
    print("FAIL  libghostty did not start")
    exit(1)
}

// Row 0: one URL mid-row. Row 2: a URL in parens with a trailing period.
// The screen is cleared first: login(1) prints a banner above the command.
let demo = "printf '\\033[2J\\033[HPR opened: https://example.com/acme-app/pull/42 (ready)\\n\\n"
    + "Docs (see https://example.org/guide).\\n'; sleep 600"
let surface = TerminalSurfaceView(app: ghosttyApp, command: "/bin/sh -c \"\(demo)\"")
let preview = LinkPreviewViewController()

var hovered: [URL] = []
let split = NSSplitView()
split.isVertical = true
split.dividerStyle = .thin
split.addArrangedSubview(surface)
surface.onHoverLink = { url in
    hovered.append(url)
    // What DetailViewController.reveal does: show the pane, leave focus alone.
    if preview.view.superview == nil {
        split.addArrangedSubview(preview.view)
        split.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.width * 0.55, ofDividerAt: 0)
    }
    preview.load(url)
}

let window = NSWindow(
    contentRect: NSRect(x: 80, y: 80, width: 1280, height: 640),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.title = "acme-app"
window.contentView = split
window.orderFrontRegardless()
window.makeFirstResponder(surface)
pump(2.0)

func snapshot(_ name: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(shots)/\(name).png"]
    try? task.run()
    task.waitUntilExit()
    print("shot  \(shots)/\(name).png")
}

/// The view point at the centre of cell (col, row), same grid the surface uses.
func point(col: Int, row: Int) -> NSPoint {
    let size = ghostty_surface_size(surface.surfaceHandle!)
    let scale = window.backingScaleFactor
    let cw = CGFloat(size.cell_width_px) / scale, ch = CGFloat(size.cell_height_px) / scale
    return NSPoint(x: (CGFloat(col) + 0.5) * cw, y: surface.bounds.height - (CGFloat(row) + 0.5) * ch)
}

func move(col: Int, row: Int, command: Bool) {
    let p = surface.convert(point(col: col, row: row), to: nil)
    let e = NSEvent.mouseEvent(
        with: .mouseMoved, location: p, modifierFlags: command ? [.command] : [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    surface.mouseMoved(with: e)
}

/// Put the real pointer over a surface point: the ⌘-press path reads the live
/// pointer position, not an event's.
func warp(to viewPoint: NSPoint) {
    let screen = window.convertPoint(toScreen: surface.convert(viewPoint, to: nil))
    let top = NSScreen.screens[0].frame.maxY
    CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: top - screen.y))
}

func flags(command: Bool) {
    let e = NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: command ? [.command] : [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: 55)!
    surface.flagsChanged(with: e)
}

try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
snapshot("before")

// 1. Plain hover (no ⌘) on the first URL: nothing.
move(col: 20, row: 0, command: false)
pump(0.8)
expect("plain hover opens nothing", hovered.isEmpty, "\(hovered)")

// 2. ⌘-hover that leaves before the delay: nothing.
move(col: 20, row: 0, command: true)
pump(0.1)
move(col: 2, row: 0, command: true)
pump(0.8)
expect("⌘ pass-over shorter than the delay opens nothing", hovered.isEmpty, "\(hovered)")

// 3. ⌘-rest on the first URL: it opens.
move(col: 25, row: 0, command: true)
pump(0.8)
expect("⌘-hover opens the URL under the pointer",
       hovered.map(\.absoluteString) == ["https://example.com/acme-app/pull/42"], "\(hovered)")
expect("terminal keeps keyboard focus", window.firstResponder === surface,
       "\(String(describing: window.firstResponder))")
pump(2.5)
snapshot("after-first")

// 4. Moving within the same URL does not fire again.
move(col: 30, row: 0, command: true)
pump(0.8)
expect("same URL fires once", hovered.count == 1, "\(hovered)")

// 5. Pointer resting on the second URL, then ⌘ pressed: it opens (no move needed
// after ⌘ goes down). Trailing ")." is not part of it.
flags(command: false)
move(col: 15, row: 2, command: false)
pump(0.5)
expect("no ⌘, no preview", hovered.count == 1, "\(hovered)")
warp(to: point(col: 15, row: 2))
flags(command: true)
pump(0.8)
expect("⌘ pressed over a URL opens it",
       hovered.last?.absoluteString == "https://example.org/guide", "\(hovered)")
expect("terminal still has focus", window.firstResponder === surface)
pump(2.5)
snapshot("after-second")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
