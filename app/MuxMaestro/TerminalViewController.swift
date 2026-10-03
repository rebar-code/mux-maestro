import Cocoa
import GhosttyKit

/// A transparent, click-through layer painted on top of the terminal surface that
/// draws pane outlines while ⌘⇧ is held and the live drop-zone during a ⌘⇧-drag.
/// Purely visual — the gesture itself lives in `TerminalSurfaceView`.
final class PaneRearrangeOverlay: NSView {
    /// Top-left origin so tmux pane rects (y-down) map directly to draw coords.
    override var isFlipped: Bool { true }

    /// Whether ⌘ is held (show outlines even before a drag starts).
    var revealed = false { didSet { needsDisplay = true } }
    /// Pane rects to draw (id + top-left rect), pushed from the surface.
    var paneRects: [(id: String, rect: CGRect)] = [] { didSet { needsDisplay = true } }
    /// The pane being dragged (nil ⇒ not dragging).
    var sourceID: String? { didSet { needsDisplay = true } }
    /// The pane + zone currently under the cursor during a drag.
    var dropTargetID: String? { didSet { needsDisplay = true } }
    var dropZone: PaneDropZone? { didSet { needsDisplay = true } }

    private var dragging: Bool { sourceID != nil }

    /// Never intercept the mouse — the terminal/gesture own it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Clear all transient state (end of a drag or ⌘ released).
    func reset() {
        sourceID = nil
        dropTargetID = nil
        dropZone = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard revealed || dragging else { return }
        let accent = SidebarPalette.accent

        for (id, rect) in paneRects {
            let isSource = id == sourceID
            // Outline every pane; the source pane reads brighter.
            (isSource ? accent : accent.withAlphaComponent(0.5)).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = isSource ? 2 : 1
            path.stroke()
            if isSource {
                accent.withAlphaComponent(0.12).setFill()
                path.fill()
            }
            // Drop-zone shading on the hovered target.
            if id == dropTargetID, let zone = dropZone, id != sourceID {
                accent.withAlphaComponent(0.28).setFill()
                NSBezierPath(rect: Self.zoneRect(zone, in: rect)).fill()
            }
        }

        // Hint line while revealed but not yet dragging.
        if revealed, !dragging {
            let hint = "Drag a pane onto another’s edge to move it · center to swap"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: SidebarPalette.text.withAlphaComponent(0.8),
            ]
            let size = (hint as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 6
            let boxH = size.height + pad
            // Flipped view (y-down): place the banner near the bottom edge.
            let box = CGRect(
                x: (bounds.width - size.width) / 2 - pad, y: bounds.height - boxH - 10,
                width: size.width + pad * 2, height: boxH)
            SidebarPalette.surface.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            (hint as NSString).draw(
                at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
        }
    }

    /// The sub-rect of a pane to shade for a given drop zone (the half it docks to;
    /// the whole rect for a center/swap).
    private static func zoneRect(_ zone: PaneDropZone, in r: CGRect) -> CGRect {
        switch zone {
        case .center: return r
        case .left:   return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right:  return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .top:    return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .bottom: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        }
    }
}

/// Hosts a single embedded libghostty terminal surface filling its pane.
final class TerminalViewController: NSViewController {
    private let ghostty: GhosttyApp
    private var command: String?
    /// The currently-visible surface (nil before the view loads / after evicting
    /// the active one). The rest of the app reads this for the active session's
    /// pane geometry, text I/O, and file-drop wiring.
    private(set) var surfaceView: TerminalSurfaceView?

    /// When true, every surface this controller installs gets the Manager theme
    /// (a distinct terminal background) — used for the ambient Manager rail.
    private let useManagerTheme: Bool
    /// LRU cache of live surfaces keyed by their attach command. A session switch
    /// re-shows the cached surface — already attached and streaming — instead of
    /// tearing down + respawning a tmux/ssh client (which left the terminal blank
    /// until the attach handshake produced output). The command string is a
    /// stable, unique key per host+session+mosh-variant, so reuse is exact.
    /// Bounded so we don't hold an unbounded number of live remote ssh clients.
    private var surfaceCache: [String: TerminalSurfaceView] = [:]
    /// Command keys least-recently-shown first, most-recent last (eviction order).
    private var lruKeys: [String] = []
    /// The active surface's command key (its cache key), or nil when none.
    private var activeKey: String?
    /// Max simultaneously-alive surfaces (each is a live tmux/ssh client). Beyond
    /// this the least-recently-shown is torn down; re-selecting it respawns.
    private let maxCachedSurfaces = 4

    /// Overlay for the ⌘⇧-drag pane rearrange, kept above the surface across swaps.
    private let overlay = PaneRearrangeOverlay()

    /// Called when a ⌘⇧-drag commits a rearrange (source pane, target pane, zone).
    /// The AppDelegate turns it into a `swap-pane`/`join-pane`.
    var onRearrange: ((_ source: String, _ target: String, _ zone: PaneDropZone) -> Void)?

    /// Called when file URLs are dropped on the terminal surface. Returns whether
    /// the drop was handled by the session-aware transfer; false falls back to the
    /// surface typing the local path. Re-wired onto each swapped-in surface.
    var onFileDrop: ((_ urls: [URL]) -> Bool)?

    /// Called with a ⌘-clicked link's text. Returns whether it was handled.
    /// Re-wired onto each swapped-in surface.
    var onOpenLink: ((_ url: String) -> Bool)?

    init(ghostty: GhosttyApp, command: String?, useManagerTheme: Bool = false) {
        self.ghostty = ghostty
        self.command = command
        self.useManagerTheme = useManagerTheme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container
        activateSurface(command: command)
        // Add the overlay once, pinned over the whole pane, above the surface.
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// Show the surface for `command`, reusing a cached one if it's still alive.
    /// This is how selection swaps the terminal between sessions: a cache hit
    /// re-shows an already-attached, still-streaming surface instantly; a miss
    /// spawns a fresh one. The previously-visible surface is hidden, NOT freed —
    /// it stays attached in the cache so switching back is instant too.
    func swap(command: String?) {
        guard isViewLoaded else { self.command = command; return }
        self.command = command
        Diag.time("swap", "activateSurface") { activateSurface(command: command) }
    }

    /// Drop the cached surface for `command` (freeing its libghostty surface +
    /// killing its client). Called when a session is killed/renamed so a later
    /// re-attach under the same command doesn't reuse a dead surface.
    func evictSurface(command: String?) {
        let key = command ?? ""
        guard let victim = surfaceCache.removeValue(forKey: key) else { return }
        lruKeys.removeAll { $0 == key }
        victim.removeFromSuperview()  // deinit → ghostty_surface_free
        if activeKey == key {
            activeKey = nil
            surfaceView = nil
        }
    }

    private func activateSurface(command: String?) {
        let key = command ?? ""

        // Already showing this session — nothing to do.
        if key == activeKey, surfaceCache[key] != nil {
            touch(key)
            return
        }

        // Hide the current surface but keep it alive (attached + streaming).
        surfaceView?.isHidden = true

        if let cached = surfaceCache[key] {
            // Cache hit: re-show the live surface. No respawn, no blank terminal.
            cached.isHidden = false
            surfaceView = cached
            activeKey = key
            touch(key)
            raiseOverlay(above: cached)
            focusActiveSurface()
            return
        }

        // Cache miss: build a fresh surface and cache it.
        guard let surface = makeSurface(command: command) else { return }
        surfaceCache[key] = surface
        lruKeys.append(key)
        surfaceView = surface
        activeKey = key
        raiseOverlay(above: surface)
        focusActiveSurface()
        evictIfOverCap()
    }

    /// Build, install, and wire a new terminal surface (constraints + delegates).
    private func makeSurface(command: String?) -> TerminalSurfaceView? {
        guard let app = ghostty.app else { return nil }
        let surface = TerminalSurfaceView(app: app, command: command)
        // Theme the ambient Manager surface distinctly (per-surface config override).
        // Applied here so every cache-miss surface is themed; cached ones keep it.
        if useManagerTheme { ghostty.applyManagerTheme(to: surface) }
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        surface.rearrangeDelegate = self
        surface.onFileDrop = { [weak self] urls in self?.onFileDrop?(urls) ?? false }
        surface.onOpenLink = { [weak self] url in self?.onOpenLink?(url) ?? false }
        return surface
    }

    /// Move `key` to the most-recently-shown end of the LRU order.
    private func touch(_ key: String) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    /// Keep the overlay z-ordered directly above the active surface (re-asserted
    /// on every activation since the surface set changes).
    private func raiseOverlay(above surface: TerminalSurfaceView) {
        if overlay.superview != nil {
            view.addSubview(overlay, positioned: .above, relativeTo: surface)
        }
    }

    /// Take keyboard focus so the shown terminal is immediately usable.
    private func focusActiveSurface() {
        if view.window != nil, let surfaceView {
            view.window?.makeFirstResponder(surfaceView)
        }
    }

    /// Tear down least-recently-shown surfaces past the cap (never the active one).
    private func evictIfOverCap() {
        while surfaceCache.count > maxCachedSurfaces {
            guard let victim = lruKeys.first(where: { $0 != activeKey }) else { break }
            lruKeys.removeAll { $0 == victim }
            surfaceCache.removeValue(forKey: victim)?.removeFromSuperview()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Focus the terminal so it takes keyboard input immediately.
        if let surfaceView { view.window?.makeFirstResponder(surfaceView) }
    }
}

// MARK: - Pane rearrange (⌘⇧-drag) → overlay visuals + commit callback

extension TerminalViewController: PaneRearrangeDelegate {
    func paneRearrangeSetRevealed(_ revealed: Bool) {
        if revealed { overlay.paneRects = surfaceView?.paneScreenRects() ?? [] }
        overlay.revealed = revealed
        if !revealed, overlay.sourceID == nil { overlay.reset() }
    }

    func paneRearrangeBegan(source: String) {
        overlay.paneRects = surfaceView?.paneScreenRects() ?? []
        overlay.sourceID = source
    }

    func paneRearrangeUpdated(target: (id: String, zone: PaneDropZone)?) {
        overlay.dropTargetID = target?.id
        overlay.dropZone = target?.zone
    }

    func paneRearrangeCommitted(source: String, target: String, zone: PaneDropZone) {
        overlay.reset()
        onRearrange?(source, target, zone)
    }

    func paneRearrangeCancelled() {
        overlay.reset()
    }
}
