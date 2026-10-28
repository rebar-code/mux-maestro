import Cocoa

// Drives the REAL ⌘P file palette and ⌘K session palette with key events
// dispatched through AppKit. ⌘P lists a demo folder that is not a git repo
// through the real `TmuxService.repoFiles`, plus an artifact outside that
// folder. Both palettes are reopened over an old query to check that typing
// replaces it. Built and run by scripts/palette-selftest.sh.

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shots = ProcessInfo.processInfo.environment["PALETTE_SHOTS"] ?? "/tmp/palette"

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

/// Type `text` into `window` one key event at a time, as a keyboard would.
func type(_ text: String, into window: NSWindow) {
    for ch in text {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(
                with: kind, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: String(ch), charactersIgnoringModifiers: String(ch),
                isARepeat: false, keyCode: 0)!
            app.sendEvent(e)
        }
        pump(0.03)
    }
}

func press(_ keyCode: UInt16, _ chars: String, into window: NSWindow) {
    let e = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    app.sendEvent(e)
    pump(0.1)
}

func snapshot(_ window: NSWindow, _ name: String) {
    guard let view = window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let url = URL(fileURLWithPath: "\(shots)/\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("      shot  \(url.path)")
}

/// The field's text and selection while it is being edited.
func fieldState(_ field: NSSearchField) -> (text: String, selected: NSRange?) {
    (field.stringValue, field.currentEditor()?.selectedRange)
}

// MARK: demo folder — not a git repo, with a heavy folder the walk must skip

let demo = "/tmp/palette-demo"
let fm = FileManager.default
try? fm.removeItem(atPath: demo)
let workspace = "\(demo)/workspace"
let home = "\(demo)/home"
for path in [
    "workspace/notes/listing.md", "workspace/notes/standup.md", "workspace/plans/roadmap.md",
    "workspace/acme-app/src/app.ts", "workspace/acme-app/README.md",
    "workspace/node_modules/left-pad/index.js", "workspace/.cache/blob.bin",
    "home/.handoff/brief-acme.md",
] {
    let url = URL(fileURLWithPath: "\(demo)/\(path)")
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("demo\n".utf8).write(to: url)
}
let artifact = "\(home)/.handoff/brief-acme.md"

// The main window the palettes float over.
let main = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 1000, height: 640),
    styleMask: [.titled], backing: .buffered, defer: false)
main.title = "acme-app"
main.backgroundColor = SidebarPalette.bg
main.orderFront(nil)

// MARK: ⌘P — files outside git, plus the pane's artifacts

final class FileDelegate: FilePaletteDelegate {
    var opened: [String] = []
    func filePaletteDidActivate(path: String) { opened.append(path) }
}

let listed = TmuxService().repoFiles(cwd: workspace)
expect("non-git folder lists its files", listed.contains("notes/listing.md"), "\(listed.count) files")
expect("walk skips node_modules and dot-folders",
       !listed.contains { $0.hasPrefix("node_modules/") || $0.hasPrefix(".cache/") })

let files = FilePaletteViewController()
let fileDelegate = FileDelegate()
files.delegate = fileDelegate
files.present(over: main)
files.setFiles(QuickOpenFiles.merge(listed: listed, artifacts: [artifact], cwd: workspace, home: home))
pump(0.3)
let filePanel = files.view.window!
let fileField = all(NSSearchField.self, in: files.view)[0]
let fileTable = all(NSTableView.self, in: files.view)[0]

type("listing", into: filePanel)
expect("⌘P finds listing.md", fileTable.numberOfRows > 0)
snapshot(filePanel, "file-palette-listing")

fileField.stringValue = ""
type("brief", into: filePanel)
expect("⌘P finds the artifact outside the folder", fileTable.numberOfRows > 0)
snapshot(filePanel, "file-palette-artifact")
press(36, "\r", into: filePanel)
let opened = fileDelegate.opened.last ?? ""
expect("↩ opens the artifact's real path",
       QuickOpenFiles.absolutePath(opened, cwd: workspace, home: home) == artifact, opened)

// MARK: ⌘P and ⌘K reopen with the old query selected

files.present(over: main)
pump(0.3)
let reopened = fieldState(fileField)
expect("⌘P reopens with the whole query selected",
       reopened.selected == NSRange(location: 0, length: (reopened.text as NSString).length),
       "\(reopened.text) \(String(describing: reopened.selected))")
snapshot(filePanel, "file-palette-reopen")
type("road", into: filePanel)
expect("typing replaces the old ⌘P query", fileField.stringValue == "road", fileField.stringValue)
press(53, "\u{1b}", into: filePanel)

final class SessionDelegate: SessionPaletteDelegate {
    func sessionPaletteDidActivate(_ entry: SwitcherEntry, service: TmuxService) {}
    func sessionPaletteDidActivateScrollback(_ hit: PaneMatch, needle: String) {}
    func sessionPaletteDidRequestNewSession(name: String) {}
}

let sessions = SessionPaletteViewController()
let sessionDelegate = SessionDelegate()
sessions.delegate = sessionDelegate
sessions.present(over: main)
sessions.setSessions([])
pump(0.3)
let sessionPanel = sessions.view.window!
let sessionField = all(NSSearchField.self, in: sessions.view)[0]
type("acme-app", into: sessionPanel)
press(53, "\u{1b}", into: sessionPanel)

sessions.present(over: main)
pump(0.3)
let reopenedK = fieldState(sessionField)
expect("⌘K reopens with the whole query selected",
       reopenedK.selected == NSRange(location: 0, length: (reopenedK.text as NSString).length),
       "\(reopenedK.text) \(String(describing: reopenedK.selected))")
snapshot(sessionPanel, "session-palette-reopen")
type("api", into: sessionPanel)
expect("typing replaces the old ⌘K query", sessionField.stringValue == "api", sessionField.stringValue)

try? fm.removeItem(atPath: demo)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
