import Cocoa

// Drives the REAL ManagerRailViewController with synthesized mouse events that go
// through AppKit's own dispatch (NSApp event queue → NSWindow.sendEvent →
// gesture recognizers / hit-tested view). No handler is called directly: a
// dismiss or an open only happens if AppKit routes the click to it. Built and
// run by scripts/manager-rail-click-selftest.sh.

// A failed run is read from a pipe: keep what was printed before it stopped.
setlinebuf(stdout)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Start from the defaults a first launch sees, whatever an earlier run saved.
for key in ["managerRailSideBySide", "managerRailListHeight", "managerRailListWidth",
            "managerRailShowsRequests"] {
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

// MARK: the request list

/// A demo list in a scratch directory: the rail reads and writes this file and
/// no other.
let requestsHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("manager-rail-requests-\(UUID().uuidString)")
let requestsFile = requestsHome.appendingPathComponent(RequestTracker.fileName)
let demoRequests = """
{
  "schema": 2,
  "updated": "2026-10-04T09:00:00Z",
  "requests": [
    {
      "id": "req-007",
      "title": "Search across every session and every host, not only the one in front",
      "project": "acme-app",
      "asked": "earlier, restated 2026-10-04",
      "state": "in_progress",
      "history": [
        { "at": "2026-10-01", "by": "me", "verbatim": "search should look in every session, not just this one", "note": "Original ask." },
        { "at": "2026-10-02", "by": "maestro", "note": "Built search for one host only. That was a misread of the ask." },
        { "at": "2026-10-04", "by": "me", "verbatim": "every session means every host too", "note": "Clarified the scope." }
      ]
    },
    {
      "id": "req-006",
      "title": "Dark theme for the settings page",
      "project": "acme-app",
      "asked": "2026-10-04",
      "state": "blocked",
      "history": [
        { "at": "2026-10-04", "by": "me", "verbatim": "settings should follow the dark theme", "note": "Original ask." }
      ]
    },
    {
      "id": "req-005",
      "title": "Nightly backup",
      "project": "devbox",
      "asked": "2026-10-03",
      "state": "todo",
      "history": [
        { "at": "2026-10-03", "by": "me", "note": "Original ask." }
      ]
    },
    {
      "id": "req-004",
      "title": "Checkout test is flaky",
      "project": "acme-app",
      "asked": "2026-10-03",
      "state": "review",
      "history": []
    },
    {
      "id": "req-003",
      "title": "Order export as CSV",
      "project": "widget-shop",
      "asked": "2026-10-02",
      "state": "todo",
      "history": [
        { "at": "2026-10-02", "by": "me", "note": "Original ask." }
      ]
    },
    {
      "id": "req-002",
      "title": "Rotate the deploy key",
      "project": "devbox",
      "asked": "2026-10-02",
      "state": "done",
      "history": [
        { "at": "2026-10-02", "by": "me", "note": "Original ask." },
        { "at": "2026-10-03", "by": "maestro", "note": "Rotated. The old key is revoked." }
      ]
    },
    {
      "id": "req-001",
      "title": "Theme tokens",
      "project": "acme-app",
      "asked": "2026-10-01",
      "state": "done",
      "history": [
        { "at": "2026-10-01", "by": "me", "note": "Original ask." }
      ]
    }
  ]
}

"""

/// Replace the list as the agent does: a temporary file, renamed over it.
func writeRequests(_ text: String) {
    let temporary = requestsHome.appendingPathComponent(".requests.json.tmp")
    try! Data(text.utf8).write(to: temporary)
    _ = rename(temporary.path, requestsFile.path)
}

func requestOnDisk(_ id: String) -> [String: Any] {
    let list = (try? JSONSerialization.jsonObject(with: Data(contentsOf: requestsFile))) as? [String: Any]
    let requests = list?["requests"] as? [[String: Any]] ?? []
    return requests.first { $0["id"] as? String == id } ?? [:]
}

/// One real click at a window point.
func click(_ p: NSPoint) {
    pump(NSEvent.doubleClickInterval + 0.1)
    app.activate(ignoringOtherApps: true)
    window.makeKey()
    app.postEvent(mouse(.leftMouseDown, at: p), atStart: false)
    app.postEvent(mouse(.leftMouseUp, at: p), atStart: false)
    pump(0.8)
}

func center(_ view: NSView) -> NSPoint {
    view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
}

/// The middle of one segment, taking the segments as equal parts of the control.
func segment(_ index: Int, of control: NSSegmentedControl) -> NSPoint {
    let part = control.bounds.width / CGFloat(control.segmentCount)
    return control.convert(
        NSPoint(x: part * (CGFloat(index) + 0.5), y: control.bounds.midY), to: nil)
}

func requestList() -> RequestListView { views(RequestListView.self, in: rail.view).first! }

/// Every text the request list shows, top to bottom.
func requestTexts() -> [String] {
    views(NSTextField.self, in: requestList())
        .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
        .sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
        .map(\.stringValue)
}

/// The row of the request with this title: its checkbox and its title label.
func requestRow(_ title: String) -> (check: NSButton, title: NSTextField)? {
    guard let label = views(NSTextField.self, in: requestList()).first(where: { $0.stringValue == title }),
          let row = label.superview,
          let check = row.subviews.compactMap({ $0 as? NSButton }).first
    else { return nil }
    return (check, label)
}

func filterControl() -> NSSegmentedControl {
    views(NSSegmentedControl.self, in: requestList()).first!
}

func checkRequests() {
    print("\n== the request list")
    try! FileManager.default.createDirectory(at: requestsHome, withIntermediateDirectories: true)
    writeRequests(demoRequests)
    rail.requests = RequestTracker(url: requestsFile, author: "me", origin: .mac)
    let listSwitch = views(NSSegmentedControl.self, in: rail.view)
        .first { $0.label(forSegment: 1) == "Requests" }!
    expect(!rail.showsRequests && requestList().isHidden, "the list card starts on the board")

    click(segment(1, of: listSwitch))
    expect(rail.showsRequests && !requestList().isHidden, "a click on Requests shows the request list")
    expect(Settings.managerRailShowsRequests(), "the choice is remembered")
    let long = "Search across every session and every host, not only the one in front"
    print("  " + requestTexts().joined(separator: " | "))
    expect(requestTexts() == [
        "acme-app · 3", long, "in progress", "Dark theme for the settings page", "blocked",
        "Checkout test is flaky", "review", "devbox · 1", "Nightly backup",
        "widget-shop · 1", "Order export as CSV",
    ], "the open requests, newest first, under their projects")
    expect(filterControl().label(forSegment: 0) == "Open 5"
        && filterControl().label(forSegment: 1) == "Done 2", "the filter counts both")
    if let row = requestRow(long) {
        expect(row.title.frame.maxX <= row.title.superview!.bounds.width
            && row.title.cell!.cellSize.width > row.title.frame.width
            && row.title.superview?.toolTip == long,
            "a long title is cut to the rail and whole in the tooltip")
    }

    print("\n== click a request's title")
    click(center(requestRow("Dark theme for the settings page")!.title))
    expect(requestTexts().contains("“settings should follow the dark theme”"),
           "a click on the title opens the history, the human's words as a quote")
    expect(requestOnDisk("req-006")["state"] as? String == "blocked", "and ticks nothing")
    click(center(requestRow("Dark theme for the settings page")!.title))
    expect(!requestTexts().contains("“settings should follow the dark theme”"), "a second click closes it")

    print("\n== tick a request")
    click(center(requestRow("Nightly backup")!.check))
    let ticked = requestOnDisk("req-005")
    let added = (ticked["history"] as? [[String: String]])?.last ?? [:]
    print("  → \(added)")
    expect(ticked["state"] as? String == "done", "a click on the checkbox writes done to the file")
    expect(added["note"] == "State changed from todo to done on the Mac." && added["by"] == "me"
        && added.count == 3, "with one history entry that says it was the Mac")
    expect(!requestTexts().contains("Nightly backup")
        && filterControl().label(forSegment: 1) == "Done 3", "the row leaves Open")

    print("\n== the Done filter")
    click(segment(1, of: filterControl()))
    expect(requestTexts().first == "devbox · 2" && requestTexts().contains("Nightly backup"),
           "Done shows the ticked row, newest first")
    click(center(requestRow("Nightly backup")!.check))
    expect(requestOnDisk("req-005")["state"] as? String == "todo", "an untick writes todo")
    click(segment(0, of: filterControl()))

    print("\n== the agent writes the file")
    writeRequests(demoRequests.replacingOccurrences(of: "Order export as CSV", with: "Order export as PDF"))
    pump(1)
    expect(requestTexts().contains("Order export as PDF"), "the list follows a rename over the file")
    rail.showRequests(false)
    writeRequests(demoRequests.replacingOccurrences(of: "Order export as CSV", with: "Order export as XML"))
    pump(1)
    expect(views(NSTextField.self, in: requestList()).contains { $0.stringValue == "Order export as PDF" },
           "behind the board it reads nothing")
    rail.showRequests(true)
    pump(0.5)
    expect(requestTexts().contains("Order export as XML"), "and reads again when it is shown")
    writeRequests(demoRequests.replacingOccurrences(of: "Order export as CSV", with: "Order export as PDF"))
    pump(1)

    print("\n== a write that fails")
    chmod(requestsHome.path, 0o555)
    click(center(requestRow("Order export as PDF")!.check))
    print("  " + requestTexts().prefix(3).joined(separator: " | "))
    expect(requestRow("Order export as PDF")?.check.state == .off, "the checkbox goes back")
    expect(requestTexts().contains("Permission denied"), "and the list says why")
    expect(requestOnDisk("req-003")["state"] as? String == "todo", "the file is as it was")
    chmod(requestsHome.path, 0o755)
    pump(4.5)
    expect(!requestTexts().contains("Permission denied"), "the reason goes away by itself")

    print("\n== a list that does not read")
    writeRequests(String(demoRequests.prefix(200)))
    pump(1.5)
    print("  " + requestTexts().joined(separator: " | "))
    expect(requestTexts() == [RequestListModel.unreadable], "the error and no rows, never an empty list")
    let retry = views(NSButton.self, in: requestList()).first { $0.title == "Retry" }!
    expect(!retry.isHidden, "with a Retry")
    // Mend the file in place: no rename, so the directory does not change and
    // only Retry reads it again.
    let handle = try! FileHandle(forWritingTo: requestsFile)
    handle.truncateFile(atOffset: 0)
    handle.write(Data(demoRequests.utf8))
    try! handle.close()
    pump(0.5)
    expect(requestTexts() == [RequestListModel.unreadable], "the error stays until a read")
    click(center(retry))
    expect(requestTexts().contains("Nightly backup") && retry.isHidden, "Retry reads the list again")
}

/// The request list's four states, on the demo list.
func shootRequests(dir: String) {
    writeRequests(demoRequests)
    pump(1)
    window.setContentSize(NSSize(width: 420, height: 820))
    rail.view.needsLayout = true
    shot("rail-requests-open.png", dir: dir)
    click(center(requestRow("Search across every session and every host, not only the one in front")!.title))
    // Off the row, so its hover tint is not in the picture.
    shot("rail-requests-history.png", dir: dir)
    click(segment(1, of: filterControl()))
    shot("rail-requests-done.png", dir: dir)
    click(segment(0, of: filterControl()))
    writeRequests(String(demoRequests.prefix(200)))
    pump(1.5)
    shot("rail-requests-error.png", dir: dir)
    writeRequests(demoRequests)
    pump(1)
}

// A timer and not `DispatchQueue.main.async`: the main queue is not drained
// from inside one of its own blocks, and the request list comes back from its
// reads on the main queue.
Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
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

    checkRequests()
    if let dir = ProcessInfo.processInfo.environment["RAIL_SHOT"] {
        print("\n== screenshots")
        shootRequests(dir: dir)
        rail.showRequests(false)
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

    try? FileManager.default.removeItem(at: requestsHome)
    print(failures.isEmpty ? "\nALL PASS" : "\n\(failures.count) FAILED")
    exit(failures.isEmpty ? 0 : 1)
}
app.run()
