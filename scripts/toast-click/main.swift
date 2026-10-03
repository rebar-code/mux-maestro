import Cocoa

// Drives the REAL ManagerToastOverlay with synthesized mouse events that go
// through AppKit's own dispatch (NSApp event queue → NSApp.sendEvent →
// NSWindow.sendEvent → gesture recognizers / hit-tested view). No handler is
// called directly: the only way `dismissClicked` or `clicked:` runs is if AppKit
// routes the click to it. Built and run by scripts/toast-click-selftest.sh.

/// Stands in for the real target and logs every action AppKit sends it, then
/// forwards it — so the log shows which receiver actually got the click.
final class LoggingProxy: NSObject {
    let wrapped: NSObject
    let name: String
    var fired: [String] = []
    init(_ wrapped: NSObject, name: String) { self.wrapped = wrapped; self.name = name }
    override func responds(to aSelector: Selector!) -> Bool {
        wrapped.responds(to: aSelector) || super.responds(to: aSelector)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        fired.append(NSStringFromSelector(aSelector))
        print("  [\(name)] AppKit sent \(NSStringFromSelector(aSelector))")
        return wrapped
    }
}


// MARK: diagnostics (TOAST_DIAG=1) — log where AppKit routes the click.
if ProcessInfo.processInfo.environment["TOAST_DIAG"] == "1" {
    func swap(_ cls: AnyClass, _ orig: Selector, _ repl: Selector) {
        method_exchangeImplementations(class_getInstanceMethod(cls, orig)!, class_getInstanceMethod(cls, repl)!)
    }
    swap(NSButton.self, #selector(NSButton.mouseDown(with:)), #selector(NSButton.diag_mouseDown(with:)))
    swap(NSView.self, #selector(NSView.acceptsFirstMouse(for:)), #selector(NSView.diag_acceptsFirstMouse(for:)))
    swap(NSWindow.self, #selector(NSWindow.sendEvent(_:)), #selector(NSWindow.diag_sendEvent(_:)))
}
extension NSButton {
    @objc func diag_mouseDown(with e: NSEvent) { print("  diag: NSButton.mouseDown"); diag_mouseDown(with: e) }
}
extension NSView {
    @objc func diag_acceptsFirstMouse(for e: NSEvent?) -> Bool {
        let r = diag_acceptsFirstMouse(for: e); print("  diag: \(type(of: self)).acceptsFirstMouse → \(r)"); return r
    }
}
extension NSWindow {
    @objc func diag_sendEvent(_ e: NSEvent) {
        if e.type == .leftMouseDown || e.type == .leftMouseUp {
            let hit = contentView?.superview?.hitTest(e.locationInWindow) ?? contentView?.hitTest(e.locationInWindow)
            let btn = contentView?.subviews.compactMap { $0 as? NSButton }.first
            print("  diag: loc=\(e.locationInWindow) ×hidden=\(btn?.isHidden as Any) visible=\(isVisible) frame=\(frame)")
            print("  diag: \(type(of: self)).sendEvent \(e.type == .leftMouseDown ? "down" : "up") hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") appActive=\(NSApp.isActive) key=\(isKeyWindow)")
        }
        diag_sendEvent(e)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                      styleMask: [.titled], backing: .buffered, defer: false)
parent.orderFrontRegardless()

let overlay = ManagerToastOverlay()
var opened = 0
overlay.onOpen = { _ in opened += 1 }
overlay.onOpenLink = { _ in opened += 1 }

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
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
}

struct Outcome { let buttonFired: Int; let gestureFired: Int; let opened: Int; let visible: Bool }

/// Show a fresh toast, hover it, then click at `pointIn(view)` through the queue.
func run(_ label: String, target: (NSView, NSButton) -> NSPoint) -> Outcome {
    print("\n== \(label)")
    opened = 0
    overlay.show(over: parent, notification: ManagerNotification(
        id: 1, host: "local", session: "demo", text: "build finished", createdAt: 0), extra: 0)
    let container = overlay.view
    let panel = container.window!
    let button = container.subviews.compactMap { $0 as? NSButton }.first!
    // Hover is not under test: the tracking area needs a real pointer, so enter directly.
    container.mouseEntered(with: mouse(.leftMouseDown, at: .zero, in: panel))
    panel.layoutIfNeeded()
    panel.displayIfNeeded()
    // Let the window server register a freshly created panel first: an event
    // addressed to it before then arrives in the wrong coordinate space.
    pump(0.3)

    let buttonProxy = LoggingProxy(button.target as! NSObject, name: "closeButton")
    button.target = buttonProxy
    let gesture = container.gestureRecognizers.first!
    let gestureProxy = LoggingProxy(gesture.target as! NSObject, name: "clickGesture")
    gesture.target = gestureProxy

    let p = target(container, button)
    if ProcessInfo.processInfo.environment["TOAST_DIAG"] == "1" {
        print("  diag: panel=\(panel.frame) contentView=\(String(describing: panel.contentView.map { type(of: $0) })) frame=\(panel.contentView!.frame) container=\(container.frame) inWindow=\(container.window === panel) button=\(button.frame) superview=\(String(describing: button.superview.map { type(of: $0) }))")
        let frameView = panel.contentView!.superview!
        print("  diag: frameView=\(type(of: frameView)) hit=\(String(describing: frameView.hitTest(p).map { type(of: $0) })) contentHit=\(String(describing: panel.contentView!.hitTest(panel.contentView!.superview!.convert(p, from: nil)).map { type(of: $0) })) btnHit=\(String(describing: button.hitTest(button.superview!.convert(p, from: nil)).map { type(of: $0) }))")
    }
    print("  × visible=\(!button.isHidden) click at window point \(p) panel visible=\(panel.isVisible)")
    app.postEvent(mouse(.leftMouseDown, at: p, in: panel), atStart: false)
    app.postEvent(mouse(.leftMouseUp, at: p, in: panel), atStart: false)
    if ProcessInfo.processInfo.environment["TOAST_DIAG"] == "1" {
        print("  diag: before pump ×hidden=\(button.isHidden) mouse=\(NSEvent.mouseLocation)")
    }
    pump(0.6)

    let o = Outcome(buttonFired: buttonProxy.fired.count, gestureFired: gestureProxy.fired.count,
                    opened: opened, visible: panel.isVisible)
    print("  → button action \(o.buttonFired)×, gesture action \(o.gestureFired)×, onOpen \(o.opened)×, toast visible after=\(o.visible)")
    button.target = buttonProxy.wrapped
    gesture.target = gestureProxy.wrapped
    overlay.hide()
    return o
}

var failures: [String] = []
func expect(_ ok: Bool, _ what: String) {
    print(ok ? "  PASS \(what)" : "  FAIL \(what)")
    if !ok { failures.append(what) }
}

DispatchQueue.main.async {
    let x = run("click the × (close button)") { c, b in
        b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
    }
    expect(!x.visible, "× click hides the toast")
    expect(x.opened == 0, "× click does not open the target")
    expect(x.buttonFired + x.gestureFired == 1, "× click reaches exactly one handler")

    let body = run("click the toast body") { c, _ in
        c.convert(NSPoint(x: 40, y: c.bounds.midY), to: nil)
    }
    expect(!body.visible, "body click hides the toast")
    expect(body.opened == 1, "body click opens the target exactly once")
    expect(body.buttonFired == 0, "body click does not reach the × button")

    print(failures.isEmpty ? "\nALL PASS" : "\n\(failures.count) FAILED")
    exit(failures.isEmpty ? 0 : 1)
}
app.run()
