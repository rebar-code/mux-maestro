import Cocoa
import Quartz

// Renders the REAL ArtifactsViewController at sidebar width, fed by the real
// ArtifactTranscriptReader + ArtifactScanner.resolve over a Claude transcript
// and real files written to a demo checkout. Snapshots it, then drives
// selection, the Quick Look preview, arrow keys and ↩ through AppKit.
// Built and run by scripts/artifacts-panel-selftest.sh.

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shots = ProcessInfo.processInfo.environment["ARTIFACTS_PANEL_SHOTS"] ?? "/tmp/artifacts-panel"

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

// MARK: demo checkout — what an agent made during one thread

let root = "/tmp/artifacts-demo/acme-app"
let fm = FileManager.default
try? fm.removeItem(atPath: "/tmp/artifacts-demo")
for dir in ["shots", "out", "docs", "assets", "src/routes/checkout", "src/lib", "tasks"] {
    try! fm.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
}

func png(_ path: String, size: NSSize, draw: @escaping (NSRect) -> Void) {
    let image = NSImage(size: size, flipped: false) { rect in draw(rect); return true }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(root)/\(path)"))
}

func page(_ title: String, accent: NSColor) -> (NSRect) -> Void {
    { r in
        NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
        accent.setFill(); NSRect(x: 0, y: r.height - 70, width: r.width, height: 70).fill()
        (title as NSString).draw(at: NSPoint(x: 30, y: r.height - 50), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.white])
        NSColor(white: 0.85, alpha: 1).setFill()
        for i in 0..<5 { NSRect(x: 30, y: r.height - 130 - CGFloat(i) * 46, width: r.width - 60, height: 26).fill() }
        accent.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.width - 230, y: 40, width: 200, height: 54), xRadius: 10, yRadius: 10).fill()
    }
}

png("shots/home.png", size: NSSize(width: 1280, height: 800), draw: page("Acme — Home", accent: .systemIndigo))
png("shots/checkout.png", size: NSSize(width: 1280, height: 800), draw: page("Checkout", accent: .systemTeal))
png("out/revenue-chart.png", size: NSSize(width: 900, height: 600)) { r in
    NSColor.white.setFill(); r.fill()
    let values: [CGFloat] = [0.35, 0.5, 0.42, 0.68, 0.74, 0.9]
    for (i, v) in values.enumerated() {
        NSColor.systemBlue.withAlphaComponent(0.55 + 0.07 * CGFloat(i)).setFill()
        NSRect(x: 80 + CGFloat(i) * 130, y: 60, width: 90, height: (r.height - 140) * v).fill()
    }
    NSColor.darkGray.setFill(); NSRect(x: 60, y: 58, width: r.width - 100, height: 2).fill()
}
png("assets/logo.png", size: NSSize(width: 256, height: 256)) { r in
    NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 20, dy: 20)).fill()
}
try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                      ofItemAtPath: "\(root)/assets/logo.png")
try! """
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="260" viewBox="0 0 400 260">
<rect width="400" height="260" fill="#fff"/>
<rect x="20" y="100" width="100" height="60" rx="8" fill="#6366f1"/>
<rect x="150" y="100" width="100" height="60" rx="8" fill="#14b8a6"/>
<rect x="280" y="100" width="100" height="60" rx="8" fill="#f59e0b"/>
<path d="M120 130h30M250 130h30" stroke="#334155" stroke-width="4"/>
</svg>
""".write(toFile: "\(root)/docs/checkout-flow.svg", atomically: true, encoding: .utf8)
let files = [
    "src/routes/checkout/+page.svelte": "<script lang=\"ts\">\n  let { data } = $props();\n</script>\n\n<h1>Checkout</h1>\n",
    "src/lib/cart.ts": "export function total(items: { price: number; qty: number }[]): number {\n  return items.reduce((s, i) => s + i.price * i.qty, 0);\n}\n",
    "README.md": "# acme-app\n\nCheckout flow and revenue chart.\n",
    "tasks/plan.md": "# Checkout plan\n\n- [x] cart total\n- [x] page\n",
]
for (path, text) in files { try! text.write(toFile: "\(root)/\(path)", atomically: true, encoding: .utf8) }

// The transcript: started ten minutes ago.
let start = Date(timeIntervalSinceNow: -600)
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
var minute = 0
func record(_ type: String, _ content: [[String: Any]]) -> String {
    let at = iso.string(from: start.addingTimeInterval(Double(minute) * 60))
    minute += 1
    let obj: [String: Any] = ["type": type, "cwd": root, "sessionId": "demo", "timestamp": at,
                              "message": ["role": type, "content": content]]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}
func tool(_ name: String, _ input: [String: Any]) -> [[String: Any]] {
    [["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input]]
}
let transcript = [
    record("user", [["type": "text", "text": "Build the checkout page and chart revenue"]]),
    record("assistant", tool("Read", ["file_path": "\(root)/README.md"])),
    record("user", [["type": "tool_result", "tool_use_id": "x", "content": "logo at assets/logo.png"]]),
    record("assistant", tool("Write", ["file_path": "\(root)/tasks/plan.md", "content": "…"])),
    record("assistant", tool("Write", ["file_path": "\(root)/src/lib/cart.ts", "content": "…"])),
    record("assistant", tool("Edit", ["file_path": "\(root)/src/lib/legacy-cart.ts", "old_string": "a", "new_string": "b"])),
    record("assistant", tool("Write", ["file_path": "\(root)/src/routes/checkout/+page.svelte", "content": "…"])),
    record("assistant", tool("Write", ["file_path": "\(root)/docs/checkout-flow.svg", "content": "…"])),
    record("assistant", tool("Bash", ["command": "python3 chart.py --out out/revenue-chart.png"])),
    record("assistant", tool("Bash", ["command": "npx playwright screenshot http://localhost:5173 shots/home.png && npx playwright screenshot http://localhost:5173/checkout shots/checkout.png"])),
    record("assistant", tool("Edit", ["file_path": "\(root)/README.md", "old_string": "a", "new_string": "b"])),
    record("assistant", [["type": "text", "text": "Done. Screenshots in shots/home.png and shots/checkout.png; chart at out/revenue-chart.png."]]),
]
let transcriptPath = "/tmp/artifacts-demo/demo.jsonl"
try! (transcript.joined(separator: "\n") + "\n").write(toFile: transcriptPath, atomically: true, encoding: .utf8)

let reader = ArtifactTranscriptReader()
let mentions = reader.mentions(transcript: transcriptPath)!
let artifacts = ArtifactScanner.resolve(
    mentions, fileExists: { fm.fileExists(atPath: $0) },
    mtime: { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date })

// MARK: present at sidebar width

final class Recorder: ArtifactsPaneDelegate {
    var log: [String] = []
    func artifactsPaneDidActivate(_ a: Artifact) { log.append("open \(a.name)") }
}
let recorder = Recorder()

let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main!
let size = NSSize(width: 340, height: 820)
let window = NSWindow(
    contentRect: NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: size.width, height: size.height),
    styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .darkAqua)
let vc = ArtifactsViewController()
vc.delegate = recorder
window.contentViewController = vc
window.setContentSize(size)
window.orderFrontRegardless()
pump(0.3)

typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let windowImage = unsafeBitCast(
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: WindowImage.self)

func shoot(_ w: NSWindow, _ name: String) {
    guard let cg = windowImage(.null, 8, UInt32(w.windowNumber), 1 | 8)?.takeRetainedValue() else {
        print("capture failed for \(name)"); return
    }
    let url = URL(fileURLWithPath: shots).appendingPathComponent("\(name).png")
    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path) (\(cg.width)x\(cg.height))")
}

func labels() -> [String] { all(NSTextField.self, in: vc.view).filter { !$0.isHidden }.map(\.stringValue) }

// Empty states.
vc.render(.noThread)
pump(0.2)
expect("no-thread state says so", labels().contains("No agent thread in this pane"))
vc.render(.remote)
pump(0.2)
expect("remote state says local only", labels().contains("Local panes only"))
shoot(window, "artifacts-remote")
vc.render(.list([]))
pump(0.2)
expect("empty thread says nothing made", labels().contains("Nothing made yet"))

// The list.
vc.render(.list(artifacts))
pump(2.5)  // thumbnails come back async
let collection = all(ArtifactCollectionView.self, in: vc.view).first!
let imageNames = (0..<collection.numberOfItems(inSection: 0)).compactMap {
    (collection.item(at: IndexPath(item: $0, section: 0)) as? ArtifactImageItem)?.artifact?.name
}
expect("images: made + fresh, newest first; the old logo left out",
       imageNames == ["revenue-chart.png", "checkout.png", "home.png", "checkout-flow.svg"], "\(imageNames)")
expect("files: five made, newest first", collection.numberOfItems(inSection: 1) == 5,
       "\(collection.numberOfItems(inSection: 1))")
expect("the gone file is listed as missing",
       labels().contains { $0.hasPrefix("missing · ") }, "\(labels().filter { $0.contains("missing") })")
expect("a file both Read and edited is listed once",
       artifacts.filter { $0.name == "README.md" }.count == 1)

// Click the first thumbnail through AppKit.
func mouse(_ type: NSEvent.EventType, at p: NSPoint, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                       clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0)!
}
let first = collection.item(at: IndexPath(item: 0, section: 0))!.view
let firstPoint = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
app.postEvent(mouse(.leftMouseUp, at: firstPoint), atStart: false)
window.sendEvent(mouse(.leftMouseDown, at: firstPoint))
pump(0.3)
let clickWorked = vc.selectedArtifact?.name == "revenue-chart.png"
print("note: synthesized click \(clickWorked ? "selected" : "did NOT select") the thumbnail")
if !clickWorked { collection.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: []);
    collection.delegate?.collectionView?(collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)]) }
pump(1.5)
let ql = all(QLPreviewView.self, in: vc.view).first
expect("selection previews in Quick Look",
       (ql?.previewItem as? NSURL)?.path == "\(root)/out/revenue-chart.png", "\(String(describing: ql?.previewItem))")
shoot(window, "artifacts-image-selected")

// Arrow keys step, through the window.
window.makeFirstResponder(collection)
func key(_ code: UInt16, _ chars: String) {
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    window.sendEvent(e)
    pump(0.3)
}
key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
expect("→ steps to the next image", vc.selectedArtifact?.name == "checkout.png", "\(vc.selectedArtifact?.name ?? "nil")")
key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
let afterDown = vc.selectedArtifact
expect("↓ reaches the Files rows", afterDown?.kind == .file, "\(afterDown?.name ?? "nil")")
pump(1.5)
expect("the preview follows the keys", (ql?.previewItem as? NSURL)?.path == afterDown?.path)
shoot(window, "artifacts-file-selected")

recorder.log = []
key(36, "\r")
expect("↩ opens the selection", recorder.log == ["open \(afterDown?.name ?? "")"], "\(recorder.log)")

// A poll that finds the same list keeps the selection.
vc.render(.list(artifacts))
pump(0.2)
expect("an identical re-render keeps the selection", vc.selectedArtifact == afterDown)

// A poll that finds a new screenshot adds it on top and keeps the selection.
png("shots/cart-empty.png", size: NSSize(width: 1280, height: 800), draw: page("Cart", accent: .systemPink))
let handle = FileHandle(forWritingAtPath: transcriptPath)!
handle.seekToEndOfFile()
minute = 12
handle.write((record("assistant", tool("Bash", ["command": "npx playwright screenshot http://localhost:5173/cart shots/cart-empty.png"])) + "\n").data(using: .utf8)!)
handle.closeFile()
let grown = ArtifactScanner.resolve(
    reader.mentions(transcript: transcriptPath)!, fileExists: { fm.fileExists(atPath: $0) },
    mtime: { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date })
vc.render(.list(grown))
pump(1.5)
expect("an appended screenshot shows up first", grown.first?.name == "cart-empty.png"
       && collection.numberOfItems(inSection: 0) == 5, "\(grown.first?.name ?? "nil")")
expect("…and the selection survives", vc.selectedArtifact?.path == afterDown?.path)
expect("the reader parsed only the appended line", reader.linesParsed == transcript.count + 1,
       "\(reader.linesParsed)")

// Hover a thumbnail (tracking areas need a real pointer; the handler is called).
let hoverItem = collection.item(at: IndexPath(item: 1, section: 0)) as! ArtifactImageItem
(hoverItem.view as! ArtifactHoverView).onHover?(true)
pump(0.2)
let popoverEarly = NSApp.windows.contains { $0.className.contains("Popover") && $0.isVisible }
pump(1.2)
let popoverWindow = NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible }
expect("hover waits 400 ms, then shows a larger preview", !popoverEarly && popoverWindow != nil)
if let popoverWindow { shoot(popoverWindow, "artifacts-hover") }
(hoverItem.view as! ArtifactHoverView).onHover?(false)
pump(0.2)
expect("leaving closes it", !NSApp.windows.contains { $0.className.contains("Popover") && $0.isVisible })

window.appearance = NSAppearance(named: .aqua)
pump(0.8)
shoot(window, "artifacts-light")

window.orderOut(nil)
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
