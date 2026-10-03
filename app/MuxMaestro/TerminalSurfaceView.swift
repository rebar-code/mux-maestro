import Cocoa
import GhosttyKit

/// Receives the ⌘⇧-drag "rearrange panes" gesture from the terminal surface. The
/// surface owns the gesture (it gets the mouse events + knows its cell size); the
/// controller/overlay turn these callbacks into visuals + one-off tmux commands.
protocol PaneRearrangeDelegate: AnyObject {
    /// ⌘⇧ was pressed/released with ≥2 panes — reveal or hide the pane outlines.
    func paneRearrangeSetRevealed(_ revealed: Bool)
    /// A ⌘⇧-drag started on the pane with id `source`.
    func paneRearrangeBegan(source: String)
    /// The drag moved; `target` is the pane id + drop zone under the cursor (nil
    /// when over no pane).
    func paneRearrangeUpdated(target: (id: String, zone: PaneDropZone)?)
    /// The drag ended over a different pane → perform the swap/join.
    func paneRearrangeCommitted(source: String, target: String, zone: PaneDropZone)
    /// The drag ended over nothing / the source itself → no-op, clear visuals.
    func paneRearrangeCancelled()
}

/// A single embedded libghostty terminal surface, rendered into an AppKit NSView.
///
/// libghostty owns and manages a Metal layer attached to this NSView (we pass
/// the view pointer in `nsview`); we only need to keep `wantsLayer` on, report
/// content scale + framebuffer size, forward focus, drive draws, and translate
/// AppKit key/mouse events into the libghostty C API. The init/draw/input call
/// sequence is reused from Ghostty's SurfaceView_AppKit.swift (MIT).
final class TerminalSurfaceView: NSView {
    /// The underlying libghostty surface handle.
    private var surface: ghostty_surface_t?

    /// The live surface handle, for the app-level clipboard callbacks to complete
    /// a paste request against this surface.
    var surfaceHandle: ghostty_surface_t? { surface }

    /// Last non-zero content size in points, for re-sending on scale change.
    private var contentSize: CGSize = .init(width: 800, height: 600)

    /// The command to run in the surface. nil means inherit the default shell.
    private let command: String?

    private var focused = false

    // MARK: Pane rearrange (⌘⇧-drag)

    /// Receives the ⌘⇧-drag gesture. Set by the terminal view controller.
    weak var rearrangeDelegate: PaneRearrangeDelegate?
    /// The active window's panes (with cell geometry), pushed by the controller so
    /// the surface can map a click to a pane. Empty ⇒ rearrange disabled.
    var rearrangePanes: [TmuxPane] = []
    /// The pane id currently being ⌘⇧-dragged, or nil when no drag is in flight.
    private var dragSource: String?

    init(app: ghostty_app_t, command: String?) {
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // NOTE: Do NOT set `wantsLayer` here. libghostty makes this view
        // "layer-hosting" itself by assigning a custom layer to `.layer`
        // BEFORE setting `wantsLayer = true` (see Ghostty renderer/Metal.zig).
        // Setting `wantsLayer = true` first would make the view layer-BACKED
        // instead, breaking that handoff. Ghostty's own SurfaceView also does
        // not set wantsLayer.

        // Build the surface config: platform = macOS, nsview = self, userdata =
        // self (so the action callback can find us), scale + command.
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0  // inherit

        let created: ghostty_surface_t? = withOptionalCString(command) { cCommand in
            cfg.command = cCommand
            return ghostty_surface_new(app, &cfg)
        }

        guard let created else {
            NSLog("MuxMaestro: ghostty_surface_new failed")
            return
        }
        self.surface = created

        // Accept files dropped from Finder / the sidebar: type the path(s) into
        // the prompt so the user can submit with Enter (never auto-executed).
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: Drawing / sizing

    /// Trigger a libghostty draw. Called from the app action RENDER callback.
    func requestDraw() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateContentScale()
        sendSurfaceSize(bounds.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0 && newSize.height > 0 {
            sendSurfaceSize(newSize)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        sendSurfaceSize(contentSize)
    }

    private func updateContentScale() {
        guard let surface else { return }
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        let fbFrame = convertToBacking(frame)
        let xScale = frame.size.width > 0 ? fbFrame.size.width / frame.size.width : 2.0
        let yScale = frame.size.height > 0 ? fbFrame.size.height / frame.size.height : 2.0
        ghostty_surface_set_content_scale(surface, xScale, yScale)
    }

    private func sendSurfaceSize(_ size: CGSize) {
        guard let surface, size.width > 0, size.height > 0 else { return }
        contentSize = size
        let scaled = convertToBacking(size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    // MARK: Text I/O (also used by the M2 self-test)

    /// Send text to the terminal as if typed (no key encoding).
    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        let len = text.utf8CString.count
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    /// Read the current visible screen text from the terminal. Proves the
    /// surface is live and rendering real content.
    func readScreenText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        // `text.text` may be NULL even on a true return (e.g. empty selection);
        // `String(cString:)` would crash on a nil pointer, so guard it.
        guard let cstr = text.text else { return "" }
        return String(cString: cstr)
    }

    // MARK: Drag & drop (file → path at the prompt)

    /// Handles a file drop by routing it through the attached session (copy the
    /// file into the session's cwd — local cp / remote scp — then paste the path).
    /// Returns whether the drop was handled; false ⇒ fall back to typing the local
    /// path. Set by the controller so this view stays host-agnostic.
    var onFileDrop: ((_ urls: [URL]) -> Bool)?

    // MARK: Links (⌘-click)

    /// Opens a link Ghostty matched under a ⌘-click. Returns whether it was
    /// handled; false ⇒ Ghostty's own fallback (`open <url>`). Set by the controller.
    var onOpenLink: ((_ url: String) -> Bool)?

    /// Whether the pointer is over a link Ghostty will open (its pointer shape).
    private var overLink = false
    /// Whether the left press in flight carried the synthetic link Shift, so its
    /// release carries it too.
    private var linkClick = false
    /// The mods the last hover move sent to Ghostty.
    private var hoverMods: UInt32?

    /// Ghostty's mouse-shape action: the pointing hand over a link, else the arrow.
    func setOverLink(_ over: Bool) {
        overLink = over
        (over ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// Whether the terminal (tmux, with `mouse on`) takes mouse reports.
    private var mouseCaptured: Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    /// `flags`, plus Shift when `add` — see `LinkGesture`.
    private func linkMods(_ flags: NSEvent.ModifierFlags, add: Bool) -> ghostty_input_mods_e {
        GhosttyInput.mods(add ? flags.union(.shift) : flags)
    }

    /// Re-send the pointer position after ⌘ changes, so the link hover shows or
    /// clears without a mouse move.
    private func refreshLinkHover(_ flags: NSEvent.ModifierFlags) {
        guard let window, NSEvent.pressedMouseButtons == 0 else { return }
        let pos = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(pos) else { return }
        sendHoverPos(pos, flags)
    }

    /// Send a button-less pointer move, with the link Shift when `LinkGesture`
    /// says so. A negative position makes Ghostty forget its last-looked-up cell.
    private func sendHoverPos(_ pos: NSPoint, _ flags: NSEvent.ModifierFlags) {
        guard let surface else { return }
        let add = LinkGesture.hoverAddsShift(
            command: flags.contains(.command), overLink: overLink, mouseCaptured: mouseCaptured)
        let mods = linkMods(flags, add: add)
        if LinkGesture.hoverResetsLookup(addsShift: add, modsChanged: hoverMods != mods.rawValue) {
            ghostty_surface_mouse_pos(surface, -1, -1, mods)
        }
        hoverMods = mods.rawValue
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return false }
        // Take focus so the pasted/typed text lands in this surface.
        window?.makeFirstResponder(self)
        // Prefer the session-aware transfer: it copies the file into the attached
        // session's cwd (cp local / scp remote) so a REMOTE session gets the real
        // bytes, not a dead local path. Falls back to typing the space-separated,
        // shell-safe local paths (trailing space, ready to run) when no tmux
        // session is attached.
        if onFileDrop?(urls) == true { return true }
        let text = urls.map { Self.shellQuoteIfNeeded($0.path) }.joined(separator: " ") + " "
        sendText(text)
        return true
    }

    /// Is this event a plain ⌘V (exactly Command held, "v")? ⌘⇧V / ⌘⌥V and other
    /// combos are left for libghostty so we only ever divert a bare paste.
    private static func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers == "v"
    }

    /// Route a ⌘V through the session-aware transfer. Copied files (any type —
    /// they arrive as file URL(s), e.g. ⌘C in Finder) transfer as-is; a raw image
    /// with no file URL (a screenshot) is staged to a temp PNG first. Returns
    /// whether the paste was handled — false lets ⌘V fall through to libghostty
    /// (plain text, or nothing transferable, or no tmux session attached).
    private func pasteFromClipboard() -> Bool {
        guard let onFileDrop else { return false }
        // A copied file (any type) is on the pasteboard as file URL(s) — send them
        // through the same path a drop uses.
        if let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return onFileDrop(urls)
        }
        // Otherwise a raw image (no backing file) — stage its bytes as a PNG.
        guard let (data, fileName) = Self.clipboardImagePNG() else { return false }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekick-paste", isDirectory: true)
        let url = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            NSLog("MuxMaestro: failed to stage pasted image: \(error)")
            return false
        }
        return onFileDrop([url])
    }

    /// The pasteboard's image as PNG bytes + a timestamped filename, or nil when
    /// there's no image. Prefers ready PNG bytes; else converts TIFF/NSImage. The
    /// caller handles file URLs first, so this only runs for a backing-file-less
    /// image (a screenshot / copied image).
    private static func clipboardImagePNG() -> (data: Data, fileName: String)? {
        let pb = NSPasteboard.general
        let name = "pasted-\(pasteTimestamp()).png"
        if let png = pb.data(forType: .png) { return (png, name) }
        let tiff = pb.data(forType: .tiff)
            ?? (pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)?
                .tiffRepresentation
        guard let tiff, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, name)
    }

    /// `yyyyMMdd-HHmmss-SSS` stamp so pasted images get stable, sortable names in
    /// the session's cwd (milliseconds keep two pastes in the same second apart).
    private static func pasteTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return fmt.string(from: Date())
    }

    /// Single-quote a path only if it contains whitespace or a shell
    /// metacharacter; otherwise leave it bare so it stays easy to edit.
    private static func shellQuoteIfNeeded(_ path: String) -> String {
        let unsafe = CharacterSet(charactersIn: " \t\n\"'\\$`|&;()<>*?!#~[]{}")
        guard path.rangeOfCharacter(from: unsafe) != nil else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocus(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocus(false) }
        return result
    }

    private func setFocus(_ value: Bool) {
        guard let surface, focused != value else { return }
        focused = value
        ghostty_surface_set_focus(surface, value)
    }

    // MARK: Keyboard input

    override func keyDown(with event: NSEvent) {
        // ⌘V of a copied file (any type) or a raw image is diverted BEFORE it
        // reaches libghostty and routed through the same session-aware transfer a
        // drop uses, so the bytes land on a REMOTE session too (not a dead local
        // path). Plain-text paste falls through to ghostty untouched.
        if Self.isPasteShortcut(event), pasteFromClipboard() { return }
        keyAction(GHOSTTY_ACTION_PRESS, event: event)
    }

    override func keyUp(with event: NSEvent) {
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Forward modifier changes so libghostty tracks held modifiers.
        keyAction(GHOSTTY_ACTION_PRESS, event: event)
        refreshLinkHover(event.modifierFlags)
        // Holding ⌘⇧ (with ≥2 panes) reveals the pane outlines for rearranging.
        rearrangeDelegate?.paneRearrangeSetRevealed(
            event.modifierFlags.contains([.command, .shift]) && rearrangePanes.count >= 2)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent) {
        guard let surface else { return }
        var keyEv = event.ghosttyKeyEvent(action)

        // Attach the typed text (control chars/PUA filtered) for press events.
        if action == GHOSTTY_ACTION_PRESS, let text = event.ghosttyCharacters {
            _ = text.withCString { ptr -> Bool in
                keyEv.text = ptr
                return ghostty_surface_key(surface, keyEv)
            }
            return
        }

        _ = ghostty_surface_key(surface, keyEv)
    }

    // MARK: Mouse input

    override func mouseDown(with event: NSEvent) {
        // ⌘⇧-drag starts a pane rearrange (intercepted before ghostty/tmux so a
        // plain click/selection — and ⌘-click to open links — is untouched when
        // ⌘⇧ isn't held).
        if event.modifierFlags.contains([.command, .shift]), beginRearrange(event) { return }
        linkClick = LinkGesture.clickAddsShift(
            command: event.modifierFlags.contains(.command), overLink: overLink,
            mouseCaptured: mouseCaptured)
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event, addShift: linkClick)
        // Take focus on click.
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        if let source = dragSource {
            dragSource = nil
            let target = TmuxModel.dropTarget(at: topLeftPoint(event), in: currentPaneRects())
            if let target, target.id != source {
                rearrangeDelegate?.paneRearrangeCommitted(
                    source: source, target: target.id, zone: target.zone)
            } else {
                rearrangeDelegate?.paneRearrangeCancelled()
            }
            return
        }
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event, addShift: linkClick)
        linkClick = false
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendHoverPos(convert(event.locationInWindow, from: nil), event.modifierFlags)
    }
    override func mouseDragged(with event: NSEvent) {
        if dragSource != nil {
            rearrangeDelegate?.paneRearrangeUpdated(
                target: TmuxModel.dropTarget(at: topLeftPoint(event), in: currentPaneRects()))
            return
        }
        sendMousePos(event)
    }

    // MARK: Pane-rearrange geometry helpers

    /// The size of one terminal cell in view points, from libghostty's own grid
    /// metrics (pixels ÷ backing scale). nil when the surface has no size yet.
    private var cellSizePoints: CGSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2.0
        return CGSize(
            width: CGFloat(size.cell_width_px) / scale,
            height: CGFloat(size.cell_height_px) / scale)
    }

    /// The active window's panes as on-screen rects (top-left origin, points).
    private func currentPaneRects() -> [(id: String, rect: CGRect)] {
        guard let cell = cellSizePoints else { return [] }
        return TmuxModel.paneRects(rearrangePanes, cellW: cell.width, cellH: cell.height)
    }

    /// Exposed for the overlay to draw the pane outlines (same top-left rects).
    func paneScreenRects() -> [(id: String, rect: CGRect)] { currentPaneRects() }

    /// Convert a mouse event to a top-left-origin point in view space (the view is
    /// unflipped/y-up; pane rects are y-down), matching `sendMousePos`'s flip.
    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    /// Try to start a ⌘⇧-drag on the pane under the cursor. Returns whether a drag
    /// began (needs ≥2 panes and a hit).
    private func beginRearrange(_ event: NSEvent) -> Bool {
        guard rearrangePanes.count >= 2,
              let hit = TmuxModel.dropTarget(at: topLeftPoint(event), in: currentPaneRects())
        else { return false }
        dragSource = hit.id
        rearrangeDelegate?.paneRearrangeBegan(source: hit.id)
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // Packed scroll mods bitmask: bit 0 = high precision (trackpad/Magic
        // Mouse). Momentum bits are omitted for M2.
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas { scrollMods = 1 }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            scrollMods)
    }

    private func sendMouseButton(
        _ state: ghostty_input_mouse_state_e,
        _ button: ghostty_input_mouse_button_e,
        _ event: NSEvent,
        addShift: Bool = false
    ) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, state, button, linkMods(event.modifierFlags, add: addShift))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }
}

/// Call `body` with a C string for an optional Swift string, or nil.
private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
