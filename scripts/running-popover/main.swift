import Cocoa

// Renders the REAL RunningViewController from fixture scans that go through the
// real Running core (attribution, claims, stacks, links, sections), snapshots it
// to PNG, then clicks it with NSEvents dispatched through AppKit. No handler is
// called directly. Built and run by scripts/running-popover-selftest.sh.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shots = ProcessInfo.processInfo.environment["RUNNING_POPOVER_SHOTS"] ?? "/tmp/running-popover"

// MARK: fixtures — a acme-app checkout with a dev server, its local stack, its
// branch's stack on devbox, a compose redis, and two stacks nobody claims.

func stack(_ id: String, base: Int) -> [DockerContainer] {
    [("studio", [base + 2]), ("kong", [base]), ("db", [base + 1]), ("inbucket", [base + 3, base + 4]),
     ("rest", []), ("auth", []), ("realtime", []), ("pg_meta", [])].map {
        DockerContainer(name: "supabase_\($0.0)_\(id)", supabaseProject: id,
                        composeWorkingDir: "", ports: $0.1, runningFor: "3 hours ago")
    }
}

let cwd = "/Users/me/code/github/acme-app"
let pane = RunningPane(
    paneID: "%12", host: "localhost", cwd: cwd, supabaseProjectID: "acme-app",
    stackID: "feat-rates", urls: [5173: "https://localhost:5173/"])
let local = RunningHostScan(
    host: "localhost",
    docker: .containers(stack("acme-app", base: 54321) + [
        DockerContainer(name: "acme-app-redis-1", supabaseProject: "", composeWorkingDir: cwd,
                        ports: [6379]),
        DockerContainer(name: "grafana", supabaseProject: "", composeWorkingDir: "/tmp/old",
                        ports: [3000]),
    ]),
    listeners: [ListeningPort(port: 5173, pid: 300)], ppids: [300: 200])
    .attributed(panePidToId: [200: "%12"])
let devbox = RunningHostScan(
    host: "devbox",
    docker: .containers(stack("feat-rates", base: 54720) + stack("fix-old-login", base: 54740)),
    listeners: [], address: "devbox1.example.ts.net")
let scans = [local, devbox]

let sessionGroups = [
    RunningGroup(title: "0: acme-app", set: Running.resources(panes: [pane], scans: scans)),
    RunningGroup(title: "unclaimed", set: Running.unclaimed(scans: scans, panes: [pane])),
]
let paneGroups = [RunningGroup(title: nil, set: Running.resources(pane: pane, scans: scans))]

// MARK: delegate that records what AppKit made it do

final class Recorder: RunningPaneDelegate {
    var log: [String] = []
    func runningPaneDidRequestRefresh() { log.append("refresh") }
    func runningPaneDidSelect(_ r: RunningResource) { log.append("select \(r.label)") }
    func runningPaneDidRequestOpen(_ r: RunningResource) { log.append("open \(r.url ?? "-")") }
    func runningPaneDidRequestOpenLink(_ l: RunningLink) { log.append("link \(l.url)") }
    func runningPaneDidRequestStop(_ r: RunningResource) { log.append("stop \(r.label)") }
}
let recorder = Recorder()

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

func mouse(_ type: NSEvent.EventType, at p: NSPoint, in w: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
}

func click(_ view: NSView) {
    let w = view.window!
    let p = view.convert(NSPoint(x: min(view.bounds.midX, 30), y: view.bounds.midY), to: nil)
    app.postEvent(mouse(.leftMouseDown, at: p, in: w), atStart: false)
    app.postEvent(mouse(.leftMouseUp, at: p, in: w), atStart: false)
    pump(0.3)
}

func snapshot(_ view: NSView, _ name: String) {
    // A popover paints its own material behind the view; stand in for it, or
    // dark-mode text lands on a transparent PNG and reads as nothing.
    view.wantsLayer = true
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let url = URL(fileURLWithPath: shots).appendingPathComponent("\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path)")
}

func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + all(type, in: $0) }
}

/// Show `groups` in a window sized as the popover would be, in `appearance`.
func present(_ groups: [RunningGroup], appearance: NSAppearance.Name) -> (NSWindow, RunningViewController) {
    let vc = RunningViewController()
    vc.delegate = recorder
    vc.render(groups)
    _ = vc.view
    vc.render(groups)
    let size = vc.preferredContentSize
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                     styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: appearance)
    w.backgroundColor = .windowBackgroundColor
    w.contentViewController = vc
    w.setContentSize(size)
    w.orderFrontRegardless()
    pump(0.3)
    return (w, vc)
}

// MARK: snapshots

for (name, groups) in [("session", sessionGroups), ("pane", paneGroups), ("empty", [])] {
    for (suffix, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        let (w, vc) = present(groups, appearance: look)
        snapshot(vc.view, "\(name)-\(suffix)")
        w.orderOut(nil)
    }
}

// MARK: what the session popover says

let (window, vc) = present(sessionGroups, appearance: .darkAqua)
let texts = all(NSTextField.self, in: vc.view).map(\.stringValue)
let buttons = all(NSButton.self, in: vc.view)
let addresses = buttons.map(\.attributedTitle.string).filter { $0.contains("://") }
expect("four sections in order",
       texts.filter { $0 == $0.uppercased() && $0.count > 3 } == ["DEV SERVERS", "SUPABASE", "DOCKER", "UNCLAIMED"],
       "\(texts.filter { $0 == $0.uppercased() && $0.count > 3 })")
expect("dev server shows its full URL", addresses.contains("https://localhost:5173/"))
expect("local stack Studio on its own port", addresses.contains("http://localhost:54323"))
expect("remote stack Studio on the tailnet name",
       addresses.contains("http://devbox1.example.ts.net:54722"))
expect("DB is a connection string",
       addresses.contains("postgresql://postgres:postgres@localhost:54322/postgres"))
expect("service names shown", ["Studio", "API", "DB", "Mail"].allSatisfy(texts.contains))
expect("height is capped", vc.preferredContentSize.height <= RunningViewController.maxHeight,
       "\(vc.preferredContentSize.height)")

// MARK: clicks, through AppKit

func button(_ title: String) -> NSButton? { buttons.first { $0.attributedTitle.string == title } }

recorder.log = []
if let b = button("https://localhost:5173/") { click(b) }
expect("clicking a URL opens that URL", recorder.log == ["link https://localhost:5173/"], "\(recorder.log)")

let saved = NSPasteboard.general.string(forType: .string)
recorder.log = []
if let b = button("postgresql://postgres:postgres@localhost:54322/postgres") { click(b) }
let copied = NSPasteboard.general.string(forType: .string)
expect("clicking the DB copies, never opens",
       recorder.log.isEmpty && copied == "postgresql://postgres:postgres@localhost:54322/postgres",
       "log=\(recorder.log) pasteboard=\(copied ?? "nil")")

recorder.log = []
if let name = all(NSTextField.self, in: vc.view).first(where: { $0.stringValue == "acme-app" }) {
    click(name)
}
expect("clicking a name focuses its pane", recorder.log.first == "select acme-app", "\(recorder.log)")

recorder.log = []
if let name = all(NSTextField.self, in: vc.view).first(where: { $0.stringValue == "fix-old-login" }) {
    click(name)
}
expect("an unclaimed name has no pane to focus", recorder.log.isEmpty, "\(recorder.log)")

NSPasteboard.general.clearContents()
if let saved { NSPasteboard.general.setString(saved, forType: .string) }
window.orderOut(nil)

// MARK: the drawer — pinned top-right over a stand-in terminal pane

let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
host.wantsLayer = true
host.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
let drawerVC = RunningViewController()
drawerVC.delegate = recorder
let drawer = RunningDrawer(content: drawerVC, expanded: false)
var toggles: [Bool] = []
drawer.onToggle = { toggles.append($0) }
drawer.translatesAutoresizingMaskIntoConstraints = false
host.addSubview(drawer)
NSLayoutConstraint.activate([
    drawer.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
    drawer.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
    drawer.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -8),
])
let paneWindow = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
paneWindow.appearance = NSAppearance(named: .darkAqua)
paneWindow.contentView = host
paneWindow.orderFrontRegardless()
drawer.render(sessionGroups)
pump(0.3)

func snapshotPane(_ name: String) {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    let url = URL(fileURLWithPath: shots).appendingPathComponent("\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path)")
}

host.layoutSubtreeIfNeeded()
let closedFrame = drawer.frame
snapshotPane("drawer-closed")
expect("closed drawer is a small pill in the top-right corner",
       closedFrame.width < 160 && closedFrame.height < 40
           && abs(closedFrame.maxX - (host.bounds.maxX - 16)) < 1
           && abs(closedFrame.maxY - (host.bounds.maxY - 8)) < 1,
       "\(closedFrame)")
expect("pill carries the count",
       all(NSTextField.self, in: drawer).contains { $0.stringValue == "4 running" },
       "\(all(NSTextField.self, in: drawer).map(\.stringValue).prefix(1))")

let pill = all(NSStackView.self, in: drawer).first { !($0.gestureRecognizers.isEmpty) }!
click(pill)
host.layoutSubtreeIfNeeded()
let openFrame = drawer.frame
snapshotPane("drawer-open")
expect("clicking the pill opens the drawer", drawer.isExpanded && toggles == [true], "\(toggles)")
expect("open drawer stays pinned top-right and inside the host",
       abs(openFrame.maxX - (host.bounds.maxX - 16)) < 1
           && abs(openFrame.maxY - (host.bounds.maxY - 8)) < 1
           && openFrame.minY >= 8 - 0.5 && openFrame.width == RunningViewController.width,
       "\(openFrame)")

click(pill)
host.layoutSubtreeIfNeeded()
expect("clicking again collapses it", !drawer.isExpanded && toggles == [true, false]
       && drawer.frame.height < 40, "\(drawer.frame)")
var visibility: [Bool] = []
drawer.onVisibilityChange = { visibility.append($0) }
drawer.render([])
expect("nothing owned hides the drawer", drawer.isHidden && visibility == [false], "\(visibility)")
drawer.render([RunningGroup(title: "unclaimed", set: Running.unclaimed(scans: scans, panes: [pane]))])
expect("unclaimed stacks alone keep it hidden", drawer.isHidden && visibility == [false], "\(visibility)")
drawer.render(paneGroups)
expect("something owned shows it again, still closed",
       !drawer.isHidden && !drawer.isExpanded && visibility == [false, true], "\(visibility)")
paneWindow.orderOut(nil)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
