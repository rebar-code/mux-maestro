import Cocoa

// Drives the REAL ManagerRailViewController with synthesized mouse events that go
// through AppKit's own dispatch (NSApp event queue → NSWindow.sendEvent →
// gesture recognizers / hit-tested view). No handler is called directly: a
// dismiss or an open only happens if AppKit routes the click to it. Built and
// run by scripts/manager-rail-click-selftest.sh.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Start from the defaults a first launch sees, whatever an earlier run saved.
for key in ["managerRailSideBySide", "managerRailListHeight", "managerRailListWidth"] {
    UserDefaults.standard.removeObject(forKey: key)
}

let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 700),
                      styleMask: [.titled], backing: .buffered, defer: false)
let rail = ManagerRailViewController()
window.contentViewController = rail
window.setContentSize(NSSize(width: 420, height: 700))
window.orderFrontRegardless()

var dismissed: [String] = []
var opened = 0
rail.onDismiss = { dismissed.append($0) }
rail.onOpenLink = { _ in opened += 1 }
rail.onOpen = { _ in opened += 1 }

func review(_ key: String) -> ManagerReviewItem {
    ManagerReviewItem(key: key, host: "localhost", session: "demo", window: 1, severity: .warn,
                      text: "needs a decision", updatedAt: 0, dismissed: false)
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

func mouse(_ type: NSEvent.EventType, at p: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
}

func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
    root.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + views(type, in: $0) }
}

/// Load one review row, then click at the window point `target` picks.
func run(_ label: String, target: (NSButton) -> NSPoint) {
    print("\n== \(label)")
    // Outlast the double-click interval, so this click is not read as the
    // second half of the previous run's.
    pump(NSEvent.doubleClickInterval + 0.1)
    // In the app the rail sits in the key window. A non-key window drops the
    // first click on any view that does not accept first mouse — not under test.
    app.activate(ignoringOtherApps: true)
    window.makeKey()
    dismissed = []
    opened = 0
    let item = review("k1")
    rail.setSnapshot(ManagerSnapshot(
        needsYou: [NeedsYouItem(kind: .review(item), link: .open(
            session: "demo", window: 1, pane: nil, host: "localhost"),
            title: "demo", detail: item.text)],
        recentWork: [], updates: []))
    window.layoutIfNeeded()
    window.displayIfNeeded()
    pump(0.3)

    let check = views(NSButton.self, in: rail.view).first { !$0.isHidden && $0.frame.width == 16 }!
    let p = target(check)
    app.postEvent(mouse(.leftMouseDown, at: p), atStart: false)
    app.postEvent(mouse(.leftMouseUp, at: p), atStart: false)
    pump(0.6)
    print("  → dismissed \(dismissed), opened \(opened)×")
}

var failures: [String] = []
func expect(_ ok: Bool, _ what: String) {
    print(ok ? "  PASS \(what)" : "  FAIL \(what)")
    if !ok { failures.append(what) }
}

/// The rail's split view: the one NSSplitView under the rail.
func railSplit() -> NSSplitView { views(NSSplitView.self, in: rail.view).first! }

/// Drag the divider between the cards by `dy` points, through the event queue.
func dragDivider(by dy: CGFloat) {
    let split = railSplit()
    let list = split.arrangedSubviews[0]
    // The divider is the 10pt gap just below the list card (the split is flipped).
    let inSplit = NSPoint(x: split.bounds.midX, y: list.frame.maxY + split.dividerThickness / 2)
    let start = split.convert(inSplit, to: nil)
    let end = NSPoint(x: start.x, y: start.y - dy)
    app.postEvent(mouse(.leftMouseDown, at: start), atStart: false)
    for step in 1...5 {
        let p = NSPoint(x: start.x, y: start.y - dy * CGFloat(step) / 5)
        app.postEvent(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: p, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
    }
    app.postEvent(mouse(.leftMouseUp, at: end), atStart: false)
    pump(0.6)
}

/// Render the rail to a PNG in `dir` (in-process; no screen-recording grant).
func shot(_ name: String, dir: String) {
    // An active field editor draws scrolled in an offscreen capture.
    window.makeFirstResponder(nil)
    window.layoutIfNeeded()
    pump(0.3)
    let v = rail.view
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    print("  wrote \(dir)/\(name)")
}

DispatchQueue.main.async {
    run("click the row body") { b in
        let row = b.superview!
        return row.convert(NSPoint(x: 40, y: row.bounds.midY), to: nil)
    }
    expect(dismissed.isEmpty, "body click does not dismiss")
    expect(opened == 1, "body click opens the row exactly once")

    run("click the dismiss checkbox") { b in
        b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
    }
    expect(dismissed == ["k1"], "checkbox click dismisses the review item once")
    expect(opened == 0, "checkbox click does not open the row")

    print("\n== drag the divider between the cards")
    let list = railSplit().arrangedSubviews[0]
    let before = list.frame.height
    dragDivider(by: 60)
    print("  list height \(before) → \(list.frame.height)")
    expect(before == 400, "the list card starts 400pt tall")
    expect(abs(list.frame.height - (before + 60)) <= 2, "dragging the divider resizes the list card")
    expect(Settings.managerRailListSize(sideBySide: false).map { abs($0 - list.frame.height) <= 1 } == true,
           "the dragged height is remembered")

    print("\n== grow the window")
    let held = list.frame.height
    window.setContentSize(NSSize(width: 420, height: 820))
    window.layoutIfNeeded()
    pump(0.3)
    print("  list height \(held) → \(list.frame.height)")
    expect(abs(list.frame.height - held) <= 1, "a taller window grows the chat, not the list")
    window.setContentSize(NSSize(width: 420, height: 700))
    pump(0.3)

    if let dir = ProcessInfo.processInfo.environment["RAIL_SHOT"] {
        print("\n== screenshots")
        UserDefaults.standard.removeObject(forKey: "managerRailListHeight")
        UserDefaults.standard.removeObject(forKey: "managerRailListWidth")
        let now = Int(Date().timeIntervalSince1970)
        rail.setSnapshot(ManagerSnapshot(
            needsYou: [
                NeedsYouItem(kind: .review(ManagerReviewItem(
                    key: "a", host: "localhost", session: "acme-app", window: 2, severity: .blocked,
                    text: "PR 623 access model needs your review", updatedAt: now - 3_600, dismissed: false)),
                    link: nil, title: "acme-app", detail: "PR 623 access model needs your review"),
                NeedsYouItem(kind: .review(ManagerReviewItem(
                    key: "b", host: "localhost", session: "rcc", window: nil, severity: .warn,
                    text: "Orphan commit 4405c890 needs a decision", updatedAt: now - 7_200, dismissed: false)),
                    link: nil, title: "rcc", detail: "Orphan commit 4405c890 needs a decision"),
            ],
            recentWork: [
                WorkLogRow(id: 1, sessionId: "s1", agent: "claude", repo: "widget-shop",
                           branch: "feat/po-log", prs: [1214], host: "localhost", session: "widget-shop",
                           window: 3, pane: "%1", cwd: "", lastState: "busy",
                           firstSeen: now - 900, lastSeen: now - 300),
            ],
            updates: []))
        rail.beginTurn("which PR needs me most?")
        rail.appendReply("Acme PR 623, the access model. It is the only item that cannot move without you.")
        rail.endTurn(.done(reply: "Acme PR 623, the access model. It is the only item that cannot move without you."))
        rail.beginTurn("spin an agent to merge prod into the widget-shop branches")
        rail.endTurn(.unreachable(ManagerTurnWatcher.neverStarted))
        window.setContentSize(NSSize(width: 420, height: 820))
        rail.view.needsLayout = true
        shot("rail-stacked.png", dir: dir)
        window.setContentSize(NSSize(width: 860, height: 620))
        let toggle = views(NSButton.self, in: rail.view).first { $0.toolTip == "Side by side" }!
        toggle.performClick(nil)
        shot("rail-side-by-side.png", dir: dir)
        toggle.performClick(nil)
    }

    print(failures.isEmpty ? "\nALL PASS" : "\n\(failures.count) FAILED")
    exit(failures.isEmpty ? 0 : 1)
}
app.run()
