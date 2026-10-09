import Cocoa

/// Semantic sidebar colors. Now a thin namespace over `Theme.current` (see
/// `Theme.swift`) so the left sidebar and the right Tree panel re-theme together
/// — the values live in one place and a future theme switch needs no changes
/// here. Kept as `SidebarPalette.x` because that's how every call site reads them.
enum SidebarPalette {
    static var bg: NSColor { Theme.current.bg }
    static var surface: NSColor { Theme.current.surface }
    static var card: NSColor { Theme.current.card }
    static var border: NSColor { Theme.current.border }
    static var muted: NSColor { Theme.current.muted }
    static var text: NSColor { Theme.current.text }
    static var textRemote: NSColor { Theme.current.textRemote }
    static var accent: NSColor { Theme.current.accent }
    static var green: NSColor { Theme.current.green }
    static var amber: NSColor { Theme.current.amber }
    static var red: NSColor { Theme.current.red }
    static var purple: NSColor { Theme.current.purple }
    static var managerSurface: NSColor { Theme.current.managerSurface }
}

/// A node in the sidebar outline. Reference type so NSOutlineView has stable
/// identity per node and we can preserve expansion/selection across refreshes.
final class SidebarNode {
    enum Kind {
        /// A host (local or remote). Top level; expand to see its sessions.
        case host(Host, HostReachability)
        /// A directory group header (directory grouping mode): the working
        /// directory shared by the sessions nested under it. A **pinned** row is
        /// kept on screen even at zero sessions — that is the whole point of the
        /// pin, since the group is otherwise built purely from live sessions.
        case directory(path: String, count: Int, pinned: Bool)
        case session(host: Host, session: TmuxSession)
        case window(host: Host, session: String, window: TmuxWindow)
        case pane(host: Host, session: String, window: Int, pane: TmuxPane)

        // M13 — herdr: a separate, non-tmux multiplexer surfaced as its own
        // top-level source (sibling to the tmux hosts), expanding to herdr
        // sessions → tabs → panes.
        /// The herdr source root. `available` is false when herdr isn't installed.
        case herdr(available: Bool)
        case herdrSession(HerdrSession)
        case herdrTab(session: String, tab: HerdrTab)
        case herdrPane(session: String, tab: String, pane: HerdrPane)

        /// "Active (N)" group: the local host + herdr + currently-connected remote
        /// servers — what you're working in right now.
        case activeGroup(count: Int)
        /// "Servers (N)" group: the launcher catalog — the local Mac plus every
        /// saved remote host. Its children are `serverButton`s, not host subtrees.
        case serversGroup(count: Int)
        /// A host rendered as a one-click **button** in the Servers section.
        /// Clicking it starts a NEW session on that host (promoting a remote into
        /// Active first — `active` reflects whether it already is). `reach` marks
        /// a probed tmux-less host so the button can say so (its sessions are
        /// plain shells, not tmux). Its one child is its stat card (`hostStats`),
        /// so expanding it shows the server's load — never its sessions.
        case serverButton(host: Host, active: Bool, reach: HostReachability)
        /// The stat card under an expanded server button: load, memory, disk and
        /// uptime. `stats` is nil until the first fetch answers.
        case hostStats(host: Host, stats: HostStats?)
        /// The "+ Add Server" action row inside the servers group.
        case addServer
        /// A non-selectable hint row under a source that has no loaded children
        /// yet (keeps the parent expandable so its first expand triggers a load).
        case placeholder(parent: String, text: String)
        /// An action row under a host (e.g. a tmux-less server): open a plain
        /// shell, or install tmux.
        case hostAction(host: Host, action: HostAction)

        /// "Worktrees (N · M work)" group: linked git worktrees on this Mac that
        /// **no session is sitting in**. The one thing nothing else can show — a
        /// worktree outlives the tmux window that created it, and until someone
        /// goes looking, the gap is invisible. Hidden entirely when N is 0.
        ///
        /// `work` is how many of those N hold work that exists nowhere else. It
        /// rides on the header because the section is collapsed by default and
        /// that number is the whole reason to open it: on this Mac, 81 orphans of
        /// which 39 cannot simply be deleted.
        case worktreesGroup(count: Int, work: Int)
        /// One orphaned worktree. Inert: MuxMaestro shows and offers, it does not
        /// reap. `repo` is the owning repo's shared git dir.
        case worktreeRow(entry: WorktreeEntry, repo: String, work: WorktreeWork)
        /// One detail line under an expanded worktree row — path, dirty filenames,
        /// lease state. Not selectable.
        case worktreeDetail(parent: String, index: Int, text: String)
    }

    /// Actions offered on a remote host that has no tmux, plus the local
    /// recover-previous-sessions affordance shown when the tree is empty.
    enum HostAction {
        case plainShell
        case installTmux
        case recoverSessions
        var label: String {
            switch self {
            case .plainShell: return "Open plain shell"
            case .installTmux: return "Install tmux…"
            case .recoverSessions: return "Recover previous sessions…"
            }
        }
        var key: String {
            switch self {
            case .plainShell: return "shell"
            case .installTmux: return "install"
            case .recoverSessions: return "recover"
            }
        }
    }

    /// `var` so a refresh can update a node's data in place (e.g. a changed
    /// attention dot) without replacing the object — which lets NSOutlineView keep
    /// its expansion state and avoids the full-reload flicker.
    var kind: Kind
    var children: [SidebarNode]

    /// Prepended to `identity` so the same host (and its whole subtree) rendered in
    /// both the Active and Servers sections gets two distinct identities — keeping
    /// the two copies independently expandable/selectable. Empty for un-namespaced
    /// trees (directory mode, herdr). Set via `tag(_:_:)`.
    var idPrefix = ""

    /// Host rows only: the rolled-up most-urgent attention across the host's
    /// loaded sessions (nil when none), so a collapsed watched host still shows a
    /// dot. Baked in at build time because `display` (the diff key) encodes it and
    /// the node itself has no access to `sessionsByHost`.
    var hostAttention: AttentionStatus?
    /// Host rows only: whether the host is kept polling while collapsed (drives the
    /// "watching" eye affordance). Folded into `display` so a toggle reloads the row.
    var watched = false
    /// Server buttons only: the click-launch probe is in flight (drives the row's
    /// spinner). Folded into `display` so a toggle reloads the row.
    var probing = false
    /// Session rows only: the worktree chip, nil for a plain main checkout. Baked
    /// in at build time (the node can't reach the classification cache) and folded
    /// into `display`, because `display` is the key `SidebarDiff.treesEqual`
    /// compares — a badge absent from that string would never repaint the row.
    var worktree: WorktreeBadge?
    /// Worktree rows only: the sweep's metrics for that tree. Baked in at build
    /// time and folded into `display` so a changed chip repaints the row.
    var worktreeMetrics: WorktreeMetrics?

    init(kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }

    /// Stable identity used to diff trees across refreshes (and to restore
    /// expansion state). Sessions key by name; windows by session+index; panes
    /// by id.
    var identity: String { idPrefix + identityBase }

    private var identityBase: String {
        switch kind {
        case .host(let h, _): return h.identity
        case .directory(let path, _, _): return "DIR:\(path)"
        case .session(let host, let s): return "S:\(host.name):\(s.name)"
        case .window(let host, let session, let w): return "W:\(host.name):\(session):\(w.index)"
        case .pane(let host, _, _, let p): return "P:\(host.name):\(p.id)"
        case .herdr: return "HERDR"
        case .herdrSession(let s): return "HS:\(s.name)"
        case .herdrTab(let session, let t): return "HT:\(session):\(t.id)"
        case .herdrPane(_, _, let p): return "HP:\(p.id)"
        case .activeGroup: return "ACTIVE"
        case .serversGroup: return "SERVERS"
        case .serverButton(let h, _, _): return "SB:\(h.name)"
        case .hostStats(let h, _): return "HST:\(h.name)"
        case .addServer: return "ADDSERVER"
        case .placeholder(let parent, _): return "PH:\(parent)"
        case .hostAction(let h, let a): return "HA:\(h.name):\(a.key)"
        case .worktreesGroup: return "WORKTREES"
        case .worktreeRow(let e, _, _): return "WT:\(e.path)"
        case .worktreeDetail(let parent, let i, _): return "WTD:\(parent):\(i)"
        }
    }

    /// Display string for the cell. (Hosts and sessions render custom cells, but
    /// this is kept for window/pane rows and for the diff in `treesEqual`.)
    var display: String {
        switch kind {
        case .host(let h, let r):
            // The watched flag + rolled-up attention are encoded here (not shown as
            // text — the host cell renders them as a real dot + eye) so a change to
            // either reloads the row through the existing display-diff machinery.
            let watch = watched ? " ·watch" : ""
            let roll = hostAttention.map { " ·\($0.rawValue)" } ?? ""
            return "\(h.name)\(r == .unreachable ? " (unreachable)" : "")\(watch)\(roll)"
        case .directory(let path, let count, _):
            return "\(SidebarNode.directoryLabel(path)) (\(count))"
        case .session(_, let s):
            // The worktree chip is encoded here (not shown as text — the session
            // cell renders it as a real chip) so a session moving into a worktree,
            // or its tree turning out to hold unique work, reloads the row.
            let wt = worktree.map { " ·\($0.label)" } ?? ""
            return "\(s.attention.dot) \(s.name) \(s.attention.label)\(wt)"
        case .window(_, _, let w):
            return IdleTag.windowLabel(w)
        case .pane(_, _, _, let p):
            return IdleTag.paneLabel(p)
        case .herdr(let available):
            return "herdr\(available ? "" : " (not installed)")"
        case .herdrSession(let s):
            return "\(HerdrModel.sessionAttention(s).dot) \(s.name) "
                + "\(HerdrModel.sessionAttention(s).label)"
        case .herdrTab(_, let t):
            let marker = t.focused ? " ●" : ""
            return "\(t.number): \(t.label)\(marker)"
        case .herdrPane(_, _, let p):
            let marker = p.focused ? " ◀" : ""
            let label = p.agent ?? (p.cwd.map { ($0 as NSString).lastPathComponent } ?? "shell")
            return "\(p.id) \(label)\(marker)"
        case .activeGroup(let count): return "Active (\(count))"
        case .serversGroup(let count): return "Servers (\(count))"
        case .serverButton(let h, let active, let reach):
            // active + reachability + probing are encoded so a change reloads the row.
            let reachMark: String
            switch reach {
            case .tmuxMissing: reachMark = " ·notmux"
            case .unreachable: reachMark = " ·down"
            case .reachable, .unknown: reachMark = ""
            }
            return "\(h.name)\(active ? " ·active" : "")\(reachMark)\(probing ? " ·probing" : "")"
        case .hostStats(_, let stats): return (stats ?? HostStats()).labels.joined(separator: " ")
        case .addServer: return "+ Add Server"
        case .placeholder(_, let text): return text
        case .hostAction(_, let a): return a.label
        case .worktreesGroup(let count, let work):
            return work > 0 ? "Worktrees (\(count) · \(work) work)" : "Worktrees (\(count))"
        case .worktreeRow(let e, _, let work):
            // The cell draws the branch and real chips; the chip text is encoded
            // here so a changed count or age reloads the row through the diff.
            let chips = (worktreeMetrics ?? WorktreeMetrics())
                .chips(work: work, now: Date())
                .map(\.text).joined(separator: " ")
            return "\(WorktreeMetrics.branchLabel(entry: e)) · \(e.name) \(chips)"
        case .worktreeDetail(_, _, let text): return text
        }
    }

    /// The session card this row draws part of: the session's identity, and
    /// whether this is the session row itself. nil for rows outside any card.
    var card: (key: String, isHead: Bool)? {
        switch kind {
        case .session: return (identity, true)
        case .window(let host, let session, _), .pane(let host, let session, _, _):
            return (idPrefix + "S:\(host.name):\(session)", false)
        case .herdrSession: return (identity, true)
        // A server's card: the server row is the tinted header, its stat card the body.
        case .serverButton: return (identity, true)
        case .hostStats(let h, _): return (idPrefix + "SB:\(h.name)", false)
        case .herdrTab(let session, _), .herdrPane(let session, _, _):
            return (idPrefix + "HS:\(session)", false)
        default: return nil
        }
    }

    var isHost: Bool { if case .host = kind { return true }; return false }
    var isSession: Bool { if case .session = kind { return true }; return false }
    var isWindow: Bool { if case .window = kind { return true }; return false }
    var isPane: Bool { if case .pane = kind { return true }; return false }
    var isHerdr: Bool { if case .herdr = kind { return true }; return false }
    var isHerdrSession: Bool { if case .herdrSession = kind { return true }; return false }

    /// The tmux host this node belongs to. herdr nodes aren't tmux-hosted; they
    /// default to `.local` here (the value is only consulted on the tmux service
    /// routing paths, which herdr selections never take — herdr routes through the
    /// `HerdrService` instead).
    var host: Host {
        switch kind {
        case .host(let h, _): return h
        case .directory: return .local
        case .session(let host, _): return host
        case .window(let host, _, _): return host
        case .pane(let host, _, _, _): return host
        case .herdr, .herdrSession, .herdrTab, .herdrPane: return .local
        case .serverButton(let h, _, _): return h
        case .hostStats(let h, _): return h
        case .activeGroup, .serversGroup, .addServer, .placeholder: return .local
        case .worktreesGroup, .worktreeRow, .worktreeDetail: return .local
        case .hostAction(let h, _): return h
        }
    }

    /// The tmux session name this node belongs to, or nil for a host/herdr row.
    var sessionName: String? {
        switch kind {
        case .host, .directory: return nil
        case .session(_, let s): return s.name
        case .window(_, let session, _): return session
        case .pane(_, let session, _, _): return session
        case .herdr, .herdrSession, .herdrTab, .herdrPane: return nil
        case .activeGroup, .serversGroup, .serverButton, .hostStats, .addServer, .placeholder,
             .hostAction, .worktreesGroup, .worktreeRow, .worktreeDetail:
            return nil
        }
    }

    /// The herdr session name this node belongs to, or nil for non-herdr rows.
    var herdrSessionName: String? {
        switch kind {
        case .herdrSession(let s): return s.name
        case .herdrTab(let session, _): return session
        case .herdrPane(let session, _, _): return session
        case .herdr, .host, .directory, .session, .window, .pane: return nil
        case .activeGroup, .serversGroup, .serverButton, .hostStats, .addServer, .placeholder,
             .hostAction, .worktreesGroup, .worktreeRow, .worktreeDetail:
            return nil
        }
    }

    /// A directory group's display label: the local home dir abbreviated to `~`,
    /// empty paths shown as "(no directory)". The full path is kept as the
    /// identity so two repos that abbreviate alike never collide.
    static func directoryLabel(_ path: String) -> String {
        guard !path.isEmpty else { return "(no directory)" }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension SidebarNode: DiffableTreeNode {
    var diffIdentity: String { identity }
    /// The shown `display` stays clean for window/pane rows (the dot is a drawn
    /// view, not text), so fold their dot in here — diff-only — so a pane
    /// going running→done or done→viewed (and its window's rolled-up dot)
    /// reloads the row.
    var diffDisplay: String {
        switch kind {
        // Line 2 is folded in too, so a new prompt reloads the row (and its height),
        // and so does its age, so the age ticks over as the poll runs.
        case .window(_, _, let w):
            return "\(display)\u{1}\(w.indicator.rawValue)\u{1}\(w.lastPrompt?.text ?? "")"
                + "\u{1}\(RowCell.ageLabel(w.lastActivityAt) ?? "")"
        case .pane(_, _, _, let p):
            return "\(display)\u{1}\(p.indicator.rawValue)\u{1}\(p.lastPrompt?.text ?? "")"
                + "\u{1}\(RowCell.ageLabel(p.lastActivityAt) ?? "")"
        case .session(let host, let s):
            // Fold the host's tint in so re-coloring a server reloads its session
            // cards on the next refresh (the color isn't part of `display`). The
            // sort mode too, so the header's sort button repaints.
            return "\(display)\u{1}\(Settings.colorHex(host: host))"
                + "\u{1}\(Settings.sortsByRecent(session: s.name, host: host))"
                + "\u{1}\(s.indicator.rawValue)"
        case .directory(_, _, let pinned):
            // Diff-only, like the session tint: the pin renders as a glyph, so
            // folding it in here repaints the row without putting a marker in the
            // label.
            return "\(display)\u{1}\(pinned ? "pin" : "")"
        default: return display
        }
    }
    var diffChildren: [SidebarNode] { children }
}

/// A small drawn circle showing a thread's state (`StatusIndicator`). Crisper
/// than an emoji and tints correctly in light/dark mode.
///
/// The still part is drawn once per state change. The two moving parts (the
/// working arc, the needs-you pulse) are Core Animation layers, so a frame of
/// them costs this process no drawing.
final class AttentionDotView: NSView {
    var indicator: StatusIndicator = .none {
        didSet {
            guard indicator != oldValue else { return }
            needsDisplay = true
            syncMotion()
        }
    }

    /// For a row that has a status and no thread to have viewed: idle is a grey ring.
    var status: AttentionStatus = .unknown {
        didSet { indicator = status == .idle ? .idle : StatusIndicator(status) }
    }

    /// Off in the harness that takes still pictures of the view.
    var animates = true { didSet { syncMotion() } }

    static let diameter: CGFloat = 9
    static let ringWidth: CGFloat = 1.5
    static let spinSeconds: CFTimeInterval = 1.6

    private var motion: CALayer?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    private var dotRect: NSRect {
        let d = Self.diameter
        return NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dotRect
        // Flat, Geist-style status dot — no glow.
        switch indicator {
        case .needsYou: fill(rect, SidebarPalette.red)
        case .unviewed: fill(rect, SidebarPalette.green)
        case .viewed: ring(rect, SidebarPalette.green)
        case .working: ring(rect, SidebarPalette.muted.withAlphaComponent(0.45))
        case .idle: ring(rect, SidebarPalette.muted.withAlphaComponent(0.8))
        case .none: fill(rect.insetBy(dx: 2.5, dy: 2.5), SidebarPalette.muted.withAlphaComponent(0.7))
        }
    }

    private func fill(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func ring(_ rect: NSRect, _ color: NSColor) {
        let w = Self.ringWidth
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: w / 2, dy: w / 2))
        path.lineWidth = w
        color.setStroke()
        path.stroke()
    }

    override func layout() {
        super.layout()
        motion?.frame = dotRect
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layer loses its animations when its view leaves the window.
        syncMotion()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncMotion()
    }

    /// Put up the moving layer the state needs, or take it down.
    private func syncMotion() {
        motion?.removeFromSuperlayer()
        motion = nil
        guard window != nil || !animates else { return }
        let made: CALayer
        switch indicator {
        case .working: made = arcLayer()
        case .needsYou where animates && !Self.reducesMotion: made = pulseLayer()
        default: return
        }
        made.frame = dotRect
        layer?.addSublayer(made)
        motion = made
    }

    private static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A lighter slice of the ring with a faded tail, turning. A conic gradient
    /// cut to the ring by a mask; the turn is one transform animation.
    private func arcLayer() -> CALayer {
        let size = CGSize(width: Self.diameter, height: Self.diameter)
        let arc = CAGradientLayer()
        arc.type = .conic
        arc.startPoint = CGPoint(x: 0.5, y: 0.5)
        arc.endPoint = CGPoint(x: 0.5, y: 0)
        var head = CGColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            head = SidebarPalette.text.withAlphaComponent(0.9).cgColor
        }
        arc.colors = [CGColor.clear, CGColor.clear, head, CGColor.clear]
        arc.locations = [0, 0.4, 0.94, 1]
        let band = CAShapeLayer()
        band.frame = CGRect(origin: .zero, size: size)
        let w = Self.ringWidth
        band.path = CGPath(
            ellipseIn: band.frame.insetBy(dx: w / 2, dy: w / 2), transform: nil)
        band.fillColor = nil
        band.strokeColor = CGColor.black
        band.lineWidth = w
        arc.mask = band
        if animates, !Self.reducesMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Self.spinTurn
            spin.duration = Self.spinSeconds
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            arc.add(spin, forKey: "spin")
        }
        return arc
    }

    /// One turn in the direction the gradient's bright end points, so the
    /// bright end leads and the fade trails.
    static let spinTurn = 2 * Double.pi

    /// A red halo that grows out of the dot and fades.
    private func pulseLayer() -> CALayer {
        let halo = CALayer()
        var red = CGColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance { red = SidebarPalette.red.cgColor }
        halo.backgroundColor = red
        halo.cornerRadius = Self.diameter / 2
        halo.opacity = 0
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 1.6
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        halo.add(pulse, forKey: "pulse")
        return halo
    }
}

/// The sidebar outline. A session card's session and window rows sit at the
/// outline's leftmost indent: the card groups them, so tree indentation inside
/// it is only padding. A pane row keeps one step, so it reads as its window's
/// child. `.sourceList` keeps a 12 pt step per level even at
/// `indentationPerLevel` 0, so the step is undone here, where the outline lays
/// out its cells and chevrons.
final class SidebarOutlineView: NSOutlineView {
    /// The pointer moved over the outline. Drives the ⌥-hover preview.
    var onMouseMoved: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(event)
    }

    /// How far a card row moves left: its level times one level's step, one step
    /// less for a pane. 0 for rows outside a card.
    private func cardShift(_ row: Int) -> CGFloat {
        guard row >= 0, let node = item(atRow: row) as? SidebarNode, node.card != nil
        else { return 0 }
        let level = level(forRow: row)
        guard level > 0,
              let column = tableColumns.firstIndex(where: { $0 === outlineTableColumn })
        else { return 0 }
        let parentRow = self.row(forItem: parent(forItem: item(atRow: row)))
        guard parentRow >= 0 else { return 0 }
        let step = super.frameOfCell(atColumn: column, row: row).minX
            - super.frameOfCell(atColumn: column, row: parentRow).minX
        if case .pane = node.kind { return CGFloat(level - 1) * step }
        return CGFloat(level) * step
    }

    /// The part of a session card that `row` draws. nil for rows outside a card.
    func cardSegment(atRow row: Int) -> CardSegment? {
        guard row >= 0, row < numberOfRows,
              let card = (item(atRow: row) as? SidebarNode)?.card else { return nil }
        let next = row + 1 < numberOfRows
            ? (item(atRow: row + 1) as? SidebarNode)?.card?.key : nil
        return CardSegment.of(card: card.key, isHead: card.isHead, nextCard: next)
    }

    /// Keeps a card row's content clear of the card gap and centred in its padding.
    private func contentBand(_ frame: NSRect, row: Int) -> NSRect {
        guard let segment = cardSegment(atRow: row) else { return frame }
        let insets = segment.contentInsets
        var band = frame
        band.origin.y += insets.top
        band.size.height -= insets.top + insets.bottom
        return band
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard frame.width > 0 else { return frame }
        frame.origin.x -= cardShift(row)
        return contentBand(frame, row: row)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard column >= 0, column < tableColumns.count,
              tableColumns[column] === outlineTableColumn else { return frame }
        let shift = cardShift(row)
        frame.origin.x -= shift
        frame.size.width += shift
        return contentBand(frame, row: row)
    }
}

/// The session card header's server tint: a horizontal gradient starting at
/// `color` (half-strength) on the left edge and fading to transparent within the
/// first ~180pt. Drawn over the card's flat fill.
private func drawPaneAccentGradient(_ color: NSColor, in rect: NSRect) {
    guard rect.width > 0 else { return }
    let fade = min(0.45, 180 / rect.width)
    NSGradient(
        colorsAndLocations:
            (color.withAlphaComponent(0.5), 0),
            (color.withAlphaComponent(0), fade))?
        .draw(in: rect, angle: 0)
}

/// One segment of a session card: the session row and its visible window and
/// pane rows draw one rounded card between them, a flat `SidebarPalette.card`
/// fill with no border, the header tinted in the server's colour (see
/// `CardSegment`, `CardTint`). Drawn as the ROW view's background so
/// it spans the sidebar. The segment is worked out at draw time from the outline, because expanding or collapsing a neighbour changes
/// it without recreating this view — the sidebar repaints the rows then.
final class CardRowView: NSTableRowView {
    /// The row's server colour (`#rrggbb`); nil for herdr rows, which have none.
    var hostHex: String? { didSet { if hostHex != oldValue { needsDisplay = true } } }
    /// Whether the row is a tmux session row, the card's header.
    var isSession = false { didSet { if isSession != oldValue { needsDisplay = true } } }

    static let inset: CGFloat = 4
    static let radius: CGFloat = 8

    /// Whether the pointer is over this row. Pushed to the row's `RowCell`, which
    /// shows its hover-only trash button while it is true.
    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { pushHover() } }
    }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        // Scrolling moves the row out from under a still pointer without an exit
        // event, so re-read where the pointer actually is.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = visibleRect.contains(point)
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// The outline adds the cell after the row view, and reloads swap it in place.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? RowCell)?.isRowHovered = isHovered
    }

    private func pushHover() {
        for case let cell as RowCell in subviews { cell.isRowHovered = isHovered }
    }

    private var segment: CardSegment? {
        guard let outline = superview as? SidebarOutlineView else { return nil }
        return outline.cardSegment(atRow: outline.row(for: self))
    }

    /// The outline places the chevron and cell when it lays the row out. Expanding
    /// or collapsing a neighbour changes this row's segment, and with it the
    /// content band, without doing that again, so re-place them vertically here.
    override func layout() {
        super.layout()
        guard let outline = superview as? SidebarOutlineView else { return }
        let row = outline.row(for: self)
        guard row >= 0 else { return }
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
        for sub in subviews {
            let target: NSRect
            if sub === cell {
                target = outline.frameOfCell(atColumn: 0, row: row)
            } else if sub.identifier == NSOutlineView.disclosureButtonIdentifier {
                target = outline.frameOfOutlineCell(atRow: row)
            } else { continue }
            sub.frame.origin.y = target.minY - frame.minY
            sub.frame.size.height = target.height
        }
    }

    /// The card's area within this row: the row less the gaps above and below the
    /// card, which the row's height already includes.
    private func cardRect(_ segment: CardSegment) -> NSRect {
        var r = bounds.insetBy(dx: Self.inset, dy: 0)
        // Flipped: minY is the top.
        let insets = segment.cardInsets
        r.origin.y += insets.top
        r.size.height -= insets.top + insets.bottom
        return r
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let segment else { return }
        let rect = cardRect(segment)
        let fill = Self.path(rect, segment)
        SidebarPalette.card.setFill()
        fill.fill()
        // #121 (flat cards, no border) dropped this tint too, so Set Color… drew nothing.
        if let hex = CardTint.accentHex(segment: segment, isSession: isSession, hostHex: hostHex),
           let accent = TmuxColor.parse(hex) {
            NSGraphicsContext.saveGraphicsState()
            fill.setClip()
            drawPaneAccentGradient(accent, in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Selection sits inside the card, clear of its edge.
    override func drawSelection(in dirtyRect: NSRect) {
        guard let segment else { return super.drawSelection(in: dirtyRect) }
        let rect = cardRect(segment).insetBy(dx: 3, dy: 0)
            .insetBy(dx: 0, dy: segment.roundsTop || segment.roundsBottom ? 3 : 1)
        (isEmphasized ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    /// The segment's closed outline in flipped coordinates: rounded where the card
    /// starts or ends, square where it continues into the next or previous row.
    private static func path(_ r: NSRect, _ segment: CardSegment) -> NSBezierPath {
        let rad = radius
        let top = r.minY
        let bottom = r.maxY
        let p = NSBezierPath()
        // Left side, bottom to top.
        if segment.roundsBottom {
            p.move(to: NSPoint(x: r.minX + rad, y: bottom))
            p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: bottom - rad),
                        radius: rad, startAngle: 90, endAngle: 180)
        } else {
            p.move(to: NSPoint(x: r.minX, y: bottom))
        }
        if segment.roundsTop {
            p.line(to: NSPoint(x: r.minX, y: top + rad))
            p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: top + rad),
                        radius: rad, startAngle: 180, endAngle: 270)
            p.line(to: NSPoint(x: r.maxX - rad, y: top))
            p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: top + rad),
                        radius: rad, startAngle: 270, endAngle: 360)
        } else {
            p.line(to: NSPoint(x: r.minX, y: top))
            p.line(to: NSPoint(x: r.maxX, y: top))
        }
        if segment.roundsBottom {
            p.line(to: NSPoint(x: r.maxX, y: bottom - rad))
            p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: bottom - rad),
                        radius: rad, startAngle: 0, endAngle: 90)
        } else {
            p.line(to: NSPoint(x: r.maxX, y: bottom))
        }
        p.close()
        return p
    }
}

/// A small clickable pill showing one pull request ("#240"), colored by state:
/// green = open, purple = merged, red = closed, muted = draft. Clicking opens
/// the PR on GitHub in the browser.
final class PRChipButton: NSButton {
    private var url: String = ""

    /// The glyph + tint for a PR's state. Static so the overflow menu labels
    /// itself the same way the chips do.
    static func tint(_ pr: PullRequest) -> NSColor {
        switch pr.state {
        case .merged: return SidebarPalette.purple
        case .closed: return SidebarPalette.red
        case .open: return pr.isDraft ? SidebarPalette.muted : SidebarPalette.green
        }
    }

    static func symbolName(_ pr: PullRequest) -> String {
        switch pr.state {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark"
        case .open: return "arrow.triangle.pull"
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        // One notch above the row label's 750, so a long window name truncates
        // before a chip does — but below the label's 999 width floor, so the name
        // is never squeezed out entirely. See `RowCell.minLabelWidth`.
        setContentCompressionResistancePriority(PRChipStrip.resistance, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        // Never wrap. A two-line chip once pushed a sibling row's name clean off;
        // under pressure this clips on one line instead.
        (cell as? NSButtonCell)?.wraps = false
        target = self
        action = #selector(openInBrowser)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `showIcon: false` drops the leading glyph. At a 220pt sidebar two iconed
    /// chips plus the row's name do not fit — measured, not guessed: the second
    /// chip lost its number entirely. The number and its color carry the meaning,
    /// so the glyph is spent only when a row has a single PR.
    func configure(_ pr: PullRequest, showIcon: Bool) {
        url = pr.url
        let color = Self.tint(pr)
        image = showIcon
            ? NSImage(systemSymbolName: Self.symbolName(pr),
                      accessibilityDescription: "Pull request")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            : nil
        contentTintColor = color
        attributedTitle = NSAttributedString(
            string: showIcon ? " #\(pr.number)" : "#\(pr.number)",
            attributes: [.foregroundColor: color,
                         .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        toolTip = pr.chipTooltip
    }

    @objc private func openInBrowser() {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

/// The PR pills on one row. A window can be about several PRs at once
/// (`watch PR #393 #394 CI`), so this draws up to `WindowPRs.maxChips` items:
/// two PRs render as two chips, three-plus render as one chip plus a `+N`
/// overflow pill whose click pops a menu of the rest.
///
/// Width discipline matters more than the chips do. The sidebar is ~220pt and
/// window rows are indented, so the strip is bounded twice over: by content
/// (never more than `WindowPRs.maxChips` items) and by a three-tier compression
/// ladder — chips at 751 beat the row label's 750 (so a long name truncates
/// first), and both lose to the label's 999 width floor (so the row's NAME is
/// never squeezed out; a two-line sibling chip once pushed a name clean off).
final class PRChipStrip: NSView {
    /// The chips' horizontal compression resistance — one notch above a label's
    /// default 750, well under the name floor's 999.
    /// Chips NEVER compress. At 751 they clipped instead of yielding, and a
    /// clipped chip does not degrade — it lies: `#1026` rendered as `#102` and
    /// `#411` as `#4`, which are real PR numbers pointing at the wrong work. A
    /// short name is recoverable; a wrong number is not. The name floor below is
    /// therefore a strong preference, not a guarantee.
    static let resistance = NSLayoutConstraint.Priority.required

    private let stack = NSStackView()
    private let chips: [PRChipButton]
    private let overflow = NSButton()
    private var overflowPRs: [PullRequest] = []

    init() {
        chips = (0..<WindowPRs.maxChips).map { _ in PRChipButton() }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        overflow.isBordered = false
        overflow.bezelStyle = .inline
        overflow.setButtonType(.momentaryChange)
        overflow.translatesAutoresizingMaskIntoConstraints = false
        overflow.setContentCompressionResistancePriority(Self.resistance, for: .horizontal)
        (overflow.cell as? NSButtonCell)?.wraps = false
        overflow.setContentHuggingPriority(.required, for: .horizontal)
        overflow.target = self
        overflow.action = #selector(showOverflow)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .horizontal)
        for chip in chips { stack.addArrangedSubview(chip) }
        stack.addArrangedSubview(overflow)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(Self.resistance, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        configure([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Render `prs`; an empty list hides the whole strip so the enclosing stack
    /// collapses it and the row reads exactly as it did before.
    func configure(_ prs: [PullRequest]) {
        let layout = WindowPRs.chipLayout(prs)
        overflowPRs = Array(prs.suffix(layout.overflow))
        // The glyph is the first thing to go when a `+N` pill shares the strip:
        // those ~14pt are worth more to the row's name than to decoration.
        let showIcon = layout.overflow == 0
        for (i, chip) in chips.enumerated() {
            if i < layout.visible.count {
                chip.configure(layout.visible[i], showIcon: showIcon)
                chip.isHidden = false
            } else {
                chip.isHidden = true
            }
        }
        if layout.overflow > 0 {
            overflow.attributedTitle = NSAttributedString(
                string: "+\(layout.overflow)",
                attributes: [.foregroundColor: SidebarPalette.muted,
                             .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            overflow.toolTip = overflowPRs.map(\.chipTooltip).joined(separator: "\n")
            overflow.isHidden = false
        } else {
            overflow.isHidden = true
        }
        isHidden = prs.isEmpty
    }

    @objc private func showOverflow() {
        guard !overflowPRs.isEmpty else { return }
        let menu = NSMenu()
        for pr in overflowPRs {
            let item = NSMenuItem(title: "#\(pr.number) · \(pr.stateWord)"
                                    + (pr.title.isEmpty ? "" : " — \(pr.title)"),
                                  action: #selector(openHidden(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pr.url
            item.image = NSImage(systemSymbolName: PRChipButton.symbolName(pr),
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func openHidden(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let u = URL(string: raw) else { return }
        NSWorkspace.shared.open(u)
    }
}

/// A small pill marking a session that works inside a linked git worktree —
/// "worktree" / "pool", amber with `·work` when the tree holds work that exists
/// nowhere else. Inert by design: MuxMaestro shows and offers, it does not reap,
/// so there is nothing to click here (row actions are a follow-up).
final class WorktreeChipView: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isSelectable = false
        drawsBackground = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        // One compact line. It never wraps — a two-line chip pushed the session's
        // own name clean off the row.
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ badge: WorktreeBadge) {
        // Amber only for the state that matters — a tree holding unique work is
        // the difference between "safe to delete" and "don't".
        textColor = badge.isAlert ? SidebarPalette.amber : SidebarPalette.muted
        stringValue = badge.chipText
        toolTip = badge.tooltip
    }
}

/// Custom session row content: an attention dot, name, and status label (the
/// card itself is drawn by the enclosing `CardRowView`).
final class SessionCellView: NSTableCellView {
    /// Leading host-type glyph: laptop for local sessions, server for remote —
    /// so the flat (host-less) ACTIVE list still shows which machine each is on.
    let typeIcon = NSImageView()
    let dot = AttentionDotView()
    let nameField = NSTextField(labelWithString: "")
    let statusField = NSTextField(labelWithString: "")
    /// Clickable open-PR pill; hidden (and collapsed by the stack) when the
    /// session's branch has no open PR.
    let prChip = PRChipButton()
    /// Worktree pill; hidden (and collapsed by the stack) for a plain main checkout.
    let worktreeChip = WorktreeChipView()
    /// Trailing "+" — adds a window to this session. Wired by the delegate.
    let addButton = SidebarAddButton.make(tooltip: "New window")
    /// Switches the session's windows between index order and newest prompt
    /// first. Wired by the delegate; hidden where it has no target.
    let sortButton = SidebarAddButton.make(tooltip: "Sorted by index")

    init() {
        super.init(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        statusField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.textColor = SidebarPalette.text
        // Outranks the trailing chips: a row that can't fit everything truncates
        // the chip, never the session's name.
        nameField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        statusField.font = .systemFont(ofSize: 11, weight: .regular)
        statusField.textColor = SidebarPalette.muted
        // It yields space before the name does, so it must degrade honestly —
        // without this it clipped mid-glyph and rendered "running" as "runnir".
        statusField.maximumNumberOfLines = 1
        statusField.lineBreakMode = .byTruncatingTail
        // Below the name's priority: "running" duplicates the dot beside it, so it
        // is the first thing that should give up room.
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.setContentHuggingPriority(.required, for: .horizontal)

        // Trailing accessories in a stack so a hidden PR chip collapses cleanly
        // (no leftover gap) without juggling constraints.
        let accessories = NSStackView(views: [statusField, worktreeChip, prChip, sortButton, addButton])
        accessories.orientation = .horizontal
        accessories.alignment = .centerY
        accessories.spacing = 6
        accessories.translatesAutoresizingMaskIntoConstraints = false
        accessories.setHuggingPriority(.required, for: .horizontal)
        accessories.setContentCompressionResistancePriority(.required, for: .horizontal)

        typeIcon.translatesAutoresizingMaskIntoConstraints = false
        typeIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        typeIcon.contentTintColor = SidebarPalette.muted

        addSubview(typeIcon)
        addSubview(dot)
        addSubview(nameField)
        addSubview(accessories)
        textField = nameField
        let sessionNameFloor = nameField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 96)
        sessionNameFloor.priority = .defaultHigh
        NSLayoutConstraint.activate([
            typeIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            typeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            typeIcon.widthAnchor.constraint(equalToConstant: 15),
            dot.leadingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 5),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
            nameField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(
                lessThanOrEqualTo: accessories.leadingAnchor, constant: -6),
            // Same preference the window rows get, at the same yielding priority.
            // Without it `Acme App` rendered as `A` once it carried a
            // worktree chip AND the "running" label.
            sessionNameFloor,
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Show the sort mode: Lucide `clock-arrow-down` while sorted by last
    /// activity, `arrow-down-0-1` while in index order.
    func setSortsByRecent(_ recent: Bool) {
        sortButton.isHidden = false
        sortButton.image = recent ? Self.recentIcon : Self.indexIcon
        sortButton.toolTip = recent ? "Sorted by last prompt" : "Sorted by index"
    }

    private static let recentIcon = lucide("Sorted by last prompt", """
        <path d="M12 6v6l2 1"/><path d="M12.337 21.994a10 10 0 1 1 9.588-8.767"/>\
        <path d="m14 18 4 4 4-4"/><path d="M18 14v8"/>
        """)
    private static let indexIcon = lucide("Sorted by index", """
        <path d="m3 16 4 4 4-4"/><path d="M7 20V4"/>\
        <rect x="15" y="4" width="4" height="6" ry="2"/><path d="M17 20v-6h-2"/><path d="M15 20h4"/>
        """)

    /// A 24×24 Lucide icon from its inner SVG, as a 14pt template image.
    private static func lucide(_ description: String, _ body: String) -> NSImage? {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
            fill="none" stroke="black" stroke-width="2" stroke-linecap="round" \
            stroke-linejoin="round">\(body)</svg>
            """
        let image = NSImage(data: Data(svg.utf8))
        image?.size = NSSize(width: 14, height: 14)
        image?.isTemplate = true
        image?.accessibilityDescription = description
        return image
    }

    func configure(
        _ session: TmuxSession, host: Host? = nil, pr: PullRequest? = nil,
        favicon: NSImage? = nil, worktree: WorktreeBadge? = nil
    ) {
        // The cell is pooled across rows, so this is set on every configure —
        // never left over from the session that used it last.
        if let worktree {
            worktreeChip.configure(worktree)
            worktreeChip.isHidden = false
        } else {
            worktreeChip.isHidden = true
        }
        // A chip already tells you something specific about this row; the status
        // word only repeats the dot. Drop it rather than let it crowd the name.
        statusField.isHidden = worktree != nil || pr != nil
        // A resolved favicon takes the leading slot as the row's identity icon
        // (rendered in its own color); otherwise fall back to the muted host glyph.
        if let favicon {
            typeIcon.image = favicon
            typeIcon.contentTintColor = nil
            typeIcon.toolTip = host?.name
        } else if let host {
            typeIcon.image = NSImage(
                systemSymbolName: host.isLocal ? "laptopcomputer" : "server.rack",
                accessibilityDescription: host.isLocal ? "Local" : "Remote")
            typeIcon.contentTintColor = SidebarPalette.muted
            typeIcon.toolTip = host.name
        } else {
            typeIcon.image = nil
            typeIcon.toolTip = nil
        }
        dot.indicator = session.indicator
        nameField.stringValue = session.name
        // Remote-host sessions read a step dimmer than local so the two are
        // distinguishable at a glance (defaults to local when host is unknown).
        nameField.textColor = (host?.isLocal ?? true)
            ? SidebarPalette.text : SidebarPalette.textRemote
        statusField.stringValue = session.attention.label
        if let pr {
            prChip.configure(pr, showIcon: true)
            prChip.isHidden = false
        } else {
            prChip.isHidden = true
        }
    }
}

/// Small, subtle "+" button used in row trailing edges (new session / window /
/// pane). Muted by default, accent on hover.
enum SidebarAddButton {
    static func make(tooltip: String, symbol: String = "plus") -> NSButton {
        let b = HoverTintButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        b.imageScaling = .scaleProportionallyDown
        b.bezelStyle = .inline
        b.isBordered = false
        b.contentTintColor = SidebarPalette.muted
        b.toolTip = tooltip
        b.setButtonType(.momentaryChange)
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }
}

/// An NSButton that brightens to the accent color on hover.
final class HoverTintButton: NSButton {
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { contentTintColor = SidebarPalette.accent }
    override func mouseExited(with event: NSEvent) { contentTintColor = SidebarPalette.muted }
}

/// The ACTIVE header's filter. A click on the left part turns "1 hour" on, or
/// any mode off; the arrow lists the modes.
final class SidebarFilterControl: NSStackView {
    var onChange: ((SidebarFilter) -> Void)?
    var filter: SidebarFilter = .off { didSet { render() } }

    private let toggle = NSButton()
    private let arrow = SidebarAddButton.make(tooltip: "Filter options", symbol: "chevron.down")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        toggle.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filter")
        toggle.imagePosition = .imageLeading
        toggle.imageScaling = .scaleProportionallyDown
        toggle.bezelStyle = .inline
        toggle.isBordered = false
        toggle.font = .systemFont(ofSize: 11, weight: .semibold)
        toggle.setButtonType(.momentaryChange)
        toggle.setAccessibilityLabel("Filter")
        toggle.target = self
        toggle.action = #selector(toggleClicked)
        arrow.target = self
        arrow.action = #selector(showModes)
        addArrangedSubview(toggle)
        addArrangedSubview(arrow)
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func render() {
        let color = filter == .off ? SidebarPalette.muted : SidebarPalette.accent
        toggle.contentTintColor = color
        toggle.attributedTitle = NSAttributedString(
            string: filter == .off ? "" : " " + filter.title,
            attributes: [.foregroundColor: color, .font: toggle.font as Any])
        toggle.setAccessibilityValue(filter.title)
    }

    @objc private func toggleClicked() { pick(filter.toggled) }

    @objc private func showModes() {
        let menu = NSMenu()
        for mode in SidebarFilter.modes {
            let item = NSMenuItem(title: mode.title, action: #selector(modePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == filter ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func modePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SidebarFilter(rawValue: raw)
        else { return }
        pick(mode)
    }

    private func pick(_ mode: SidebarFilter) {
        guard mode != filter else { return }
        filter = mode
        onChange?(mode)
    }
}

/// Generic row (host / window / pane / group / action / placeholder) with an
/// optional trailing "+" button (directory rows) and a hover-only trash button
/// (window rows). Window and pane rows take a second line for their thread's
/// last prompt.
final class RowCell: NSTableCellView {
    /// Leading attention dot for window/pane rows (which exact pane is running /
    /// needs you). Hidden — and collapsed by the leading stack — for every other
    /// row kind and for idle/unknown panes, so quiet rows stay clean.
    let dot = AttentionDotView()
    /// Leading pin glyph for a pinned directory row. Hidden — and collapsed by the
    /// leading stack — for every other row kind, exactly like `dot`.
    let pin = NSImageView()
    let label = NSTextField(labelWithString: "")
    /// PR pills for a window row: the PRs named in the window's title plus the
    /// one for its cwd's branch. Hidden + collapsed for windows without any and
    /// for non-window rows.
    let prChips = PRChipStrip()
    let addButton = SidebarAddButton.make(tooltip: "Add")
    /// Archive Window, on window rows only, and visible only while the row is hovered.
    /// It keeps its slot when invisible so the chips don't shift under the pointer.
    let trashButton = SidebarAddButton.make(tooltip: "Archive Window", symbol: "archivebox")
    /// Window rows set this; every other row kind leaves it off.
    var showsTrashOnHover = false { didSet { updateTrash() } }
    /// A window whose PR merged keeps its trash visible without hover.
    var pinsTrash = false { didSet { updateTrash() } }
    /// Set by `CardRowView` as the pointer enters and leaves the row.
    var isRowHovered = false { didSet { updateTrash() } }
    /// Line 2: the first line of the thread's last prompt. Hidden on one-line rows.
    let subtitle = NSTextField(labelWithString: "")
    /// Right of line 2: how long since the thread was last written ("4m", "2h").
    let age = NSTextField(labelWithString: "")
    private let accessories = NSStackView()
    /// The view `setTrailingControl` last put in `accessories`.
    private weak var trailingControl: NSView?

    /// Height of a row that shows `subtitle`.
    static let twoLineHeight: CGFloat = 38
    /// Line 1 sits in a one-line row's 24pt band; these swap when line 2 shows.
    private var oneLine: NSLayoutConstraint!
    private var twoLine: NSLayoutConstraint!

    /// Floor on the name's share of the row. The chips are capped and yield under
    /// compression, but this makes the guarantee explicit: a window row always
    /// shows some of its own name, never chips alone.
    /// The row's name never shrinks below this, no matter how many chips it
    /// carries. 48 was too tight to do its job: `17: watch PR #393 #394 CI`
    /// rendered as `17: wat...`, four characters, indistinguishable from
    /// `20: acme-app-scra...` at a glance. Identity outranks metadata — the chips
    /// give up their space first, and the strip already drops its glyph and folds
    /// extras into `+N` under pressure.
    static let minLabelWidth: CGFloat = 76

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // Under the chips' 751, so a long name truncates before a chip is clipped.
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        prChips.isHidden = true

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.isHidden = true
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pin.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        pin.contentTintColor = SidebarPalette.muted
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 14),
            pin.widthAnchor.constraint(equalToConstant: 11),
            pin.heightAnchor.constraint(equalToConstant: 14),
        ])
        // Leading stack so a hidden dot/pin collapses and the label sits flush
        // left, exactly as before for non-window/pane rows.
        let leading = NSStackView(views: [pin, dot, label])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = 4
        leading.translatesAutoresizingMaskIntoConstraints = false
        // Let the name grow into whatever the chips don't use. Hugging at the
        // default left a visible gap between a truncated name and its chip —
        // `19: mon...` with empty space before `#411` — because the stack sat at
        // its floor instead of expanding to the room actually available.
        leading.setHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Trailing accessories in a stack so a hidden chip collapses cleanly.
        for view in [prChips, addButton, trashButton] { accessories.addArrangedSubview(view) }
        accessories.orientation = .horizontal
        accessories.alignment = .centerY
        accessories.spacing = 6
        accessories.translatesAutoresizingMaskIntoConstraints = false
        accessories.setHuggingPriority(.required, for: .horizontal)
        addButton.isHidden = true
        updateTrash()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = SidebarPalette.muted.withAlphaComponent(0.75)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.isHidden = true
        age.translatesAutoresizingMaskIntoConstraints = false
        age.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        age.textColor = SidebarPalette.muted.withAlphaComponent(0.75)
        age.alignment = .right
        age.toolTip = "Last activity"
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.isHidden = true
        addSubview(leading)
        addSubview(accessories)
        addSubview(subtitle)
        addSubview(age)
        textField = label
        oneLine = leading.centerYAnchor.constraint(equalTo: centerYAnchor)
        twoLine = leading.centerYAnchor.constraint(equalTo: topAnchor, constant: 12)
        // Required, and satisfiable: the chips resist compression at only 751, so
        // the layout can always honour this by shrinking the strip. This is the
        // guarantee that a window row never becomes chips with no name.
        let nameFloor = label.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minLabelWidth)
        // Below the chips' resistance: on a row too narrow for both, the name
        // truncates rather than the number being cut into a different number.
        nameFloor.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            oneLine,
            leading.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -6),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessories.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            nameFloor,
            subtitle.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            age.firstBaselineAnchor.constraint(equalTo: subtitle.firstBaselineAnchor),
        ])
    }

    private func updateTrash() {
        let visible = showsTrashOnHover && (isRowHovered || pinsTrash)
        trashButton.isHidden = !showsTrashOnHover
        trashButton.alphaValue = visible ? 1 : 0
        // An invisible button must not take clicks meant for the row.
        trashButton.isEnabled = visible
    }

    /// Put `view` at the row's right edge, or take the last one out for nil.
    /// One view moves between pooled cells, so every configure calls this.
    func setTrailingControl(_ view: NSView?) {
        if let view, view === trailingControl, view.superview === accessories { return }
        if let old = trailingControl, old.superview === accessories {
            accessories.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        trailingControl = view
        guard let view else { return }
        view.removeFromSuperview()
        accessories.addArrangedSubview(view)
    }

    /// "now", "4m", "2h", "3d" since `at` (epoch seconds); nil for nil.
    static func ageLabel(_ at: Int?, now: Date = Date()) -> String? {
        at.map { WorktreeMetrics.ageLabel(Date(timeIntervalSince1970: TimeInterval($0)), now: now) }
    }

    /// Show `text` as line 2 with `age` on its right, or go back to one line for
    /// a nil `text`.
    func setSubtitle(_ text: String?, age ageText: String? = nil) {
        subtitle.stringValue = text ?? ""
        subtitle.toolTip = text
        subtitle.isHidden = text == nil
        age.stringValue = ageText ?? ""
        age.isHidden = text == nil || ageText == nil
        oneLine.isActive = text == nil
        twoLine.isActive = text != nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Host row: a leading attention dot (rolled up across the host's sessions so a
/// collapsed watched host still signals status), the host name, an optional
/// "watching" eye, and the trailing "+" (new session). Greyed when unreachable.
final class HostCellView: NSTableCellView {
    /// Leading host-type glyph: laptop for local, server for remote.
    let typeIcon = NSImageView()
    /// Shown in the glyph's slot while a click-launch probe is in flight.
    let spinner = NSProgressIndicator()
    let dot = AttentionDotView()
    let nameField = NSTextField(labelWithString: "")
    let eye = NSImageView()
    let addButton = SidebarAddButton.make(tooltip: "New session")

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        typeIcon.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        eye.translatesAutoresizingMaskIntoConstraints = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 12, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        eye.image = NSImage(
            systemSymbolName: "eye", accessibilityDescription: "Watching")
        eye.contentTintColor = SidebarPalette.muted
        eye.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        eye.toolTip = "Watching — polled while collapsed"
        addSubview(typeIcon)
        addSubview(spinner)
        addSubview(dot)
        addSubview(nameField)
        addSubview(eye)
        addSubview(addButton)
        textField = nameField
        NSLayoutConstraint.activate([
            typeIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            typeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            typeIcon.widthAnchor.constraint(equalToConstant: 14),
            typeIcon.heightAnchor.constraint(equalToConstant: 14),
            spinner.centerXAnchor.constraint(equalTo: typeIcon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: typeIcon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            dot.leadingAnchor.constraint(equalTo: typeIcon.trailingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 11),
            dot.heightAnchor.constraint(equalToConstant: 11),
            nameField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameField.trailingAnchor, constant: 6),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -6),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(host: Host, reach: HostReachability, indicator: StatusIndicator?, watched: Bool) {
        nameField.stringValue =
            "\(host.name)\(reach == .unreachable ? " (unreachable)" : "")"
        nameField.textColor = reach == .unreachable ? SidebarPalette.muted : SidebarPalette.text
        typeIcon.image = NSImage(
            systemSymbolName: host.isLocal ? "laptopcomputer" : "server.rack",
            accessibilityDescription: host.isLocal ? "Local" : "Remote")
        typeIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        typeIcon.contentTintColor = reach == .unreachable
            ? SidebarPalette.muted : SidebarPalette.text
        dot.isHidden = false
        dot.indicator = indicator ?? .none
        eye.isHidden = !watched
        // New sessions start from the Servers buttons now, so host rows carry no "+".
        addButton.isHidden = true
        setProbing(false)
    }

    /// Configure this cell as a Servers-section **button** (no dot/eye/+): the
    /// host-type glyph + name. Clicking starts a new session on the host; while
    /// its probe is in flight the glyph is swapped for a spinner. A probed
    /// tmux-less host is marked so it's clear its sessions are plain shells; a
    /// probed-dead host shows as unreachable (clicking retries).
    func configureAsButton(host: Host, reach: HostReachability, probing: Bool) {
        let noTmux = reach == .tmuxMissing
        let down = reach == .unreachable
        let suffix = noTmux ? " — no tmux" : (down ? " — unreachable" : "")
        nameField.stringValue = host.name + suffix
        nameField.textColor = down ? SidebarPalette.muted : SidebarPalette.text
        let symbol = host.isLocal
            ? "laptopcomputer"
            : (down ? "xmark.circle" : (noTmux ? "exclamationmark.triangle" : "server.rack"))
        typeIcon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "New session on \(host.name)")
        typeIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        typeIcon.contentTintColor = down
            ? SidebarPalette.red
            : (noTmux ? SidebarPalette.amber : SidebarPalette.accent)
        dot.isHidden = true
        eye.isHidden = true
        addButton.isHidden = true
        setProbing(probing)
        if probing {
            toolTip = "Connecting to \(host.name)…"
        } else if down {
            toolTip = "\(host.name) was unreachable over ssh — click to retry"
        } else if noTmux {
            toolTip = "New plain-shell session on \(host.name) (tmux not installed)"
        } else {
            toolTip = "New session on \(host.name)"
        }
    }

    /// Swap the host-type glyph for a spinner while the launch probe runs.
    private func setProbing(_ probing: Bool) {
        typeIcon.isHidden = probing
        if probing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

/// Receives selection events from the sidebar. Each carries the resolved
/// `TmuxService` for the selection's host so the AppDelegate stays
/// host-agnostic: it attaches / drives through whichever service it's handed
/// (local or a per-remote ssh service).
protocol SidebarSelectionDelegate: AnyObject {
    /// User selected a session — swap the terminal to attach to it on `service`.
    func sidebarDidSelectSession(_ name: String, service: TmuxService)
    /// User selected a window within the currently shown session.
    func sidebarDidSelectWindow(session: String, window: Int, service: TmuxService)
    /// User selected a pane — select + zoom it in the currently shown session.
    func sidebarDidSelectPane(session: String, window: Int, pane: TmuxPane, service: TmuxService)

    // M13 — herdr selections route through the HerdrService, not a TmuxService.
    /// User selected a herdr session — attach the terminal to it via `herdr`.
    func sidebarDidSelectHerdrSession(_ name: String, service: HerdrService)

    /// An ⌥-hover preview ended on a tmux row: ⌥ was released there. `window` is
    /// nil for a session row.
    func sidebarDidEndHoverPreview(session: String, window: Int?, service: TmuxService)

    /// User clicked a session/window/pane row — hand keyboard focus to the
    /// terminal so typing lands there. Fires on every click, including a click
    /// on the row that is already selected (no selection change).
    func sidebarDidClickTerminalRow()

    /// A host's tree finished reloading. Lets the delegate notice state that
    /// changed outside the app — chiefly a window switch made inside tmux, which
    /// no selection callback ever reports.
    func sidebarDidRefreshTree(host: Host)

    /// The selection's human label for the window title (e.g.
    /// "buildbox / test / 0: zsh"), or nil for structural rows (title unchanged).
    func sidebarDidChangeTitle(_ title: String?)

    /// The selection's path as clickable breadcrumb crumbs (nil/empty collapses the
    /// header). `service` is the tmux service the renames should run against.
    func sidebarDidChangeBreadcrumb(_ crumbs: [BreadcrumbCrumb]?, service: TmuxService)
}

/// Receives action requests originating from the sidebar (context menu /
/// double-click). The AppDelegate performs them against the host's tmux service
/// and refreshes.
protocol SidebarActionDelegate: AnyObject {
    func sidebarRequestRename(session: String, service: TmuxService)
    func sidebarRequestKill(session: String, service: TmuxService)
    /// New session on `host` (its service). Host is needed because a remote dir
    /// picker behaves differently (typed path, not NSOpenPanel).
    func sidebarRequestNewSession(host: Host, service: TmuxService)
    /// New session rooted in `dir` (a pinned directory row's "+"). Pinning is a
    /// property of the path, so this is always the local host.
    func sidebarRequestNewSession(dir: String)

    // Window actions (M9).
    func sidebarRequestKillWindow(session: String, window: Int, service: TmuxService)
    func sidebarRequestRenameWindow(session: String, window: Int, service: TmuxService)
    func sidebarRequestNewWindow(session: String, service: TmuxService)
    // Pane actions (M9).
    func sidebarRequestKillPane(
        session: String, window: Int, pane: String, service: TmuxService)
    func sidebarRequestSplitPane(
        session: String, window: Int, pane: String, vertical: Bool, service: TmuxService)

    // Move / merge. Reorganising 26 flat sessions into 14 by hand with
    // `tmux move-window` is what these exist to replace. Every destination is on
    // the row's own host — tmux cannot move anything between servers — and no
    // move is confirmed except the merge, which ends the source session.
    /// Move a window into another existing session on the same host.
    func sidebarRequestMoveWindow(
        session: String, window: Int, toSession destination: String, service: TmuxService)
    /// Move a window into a session that doesn't exist yet (prompts for the name).
    func sidebarRequestMoveWindowToNewSession(
        session: String, window: Int, service: TmuxService)
    /// Move a pane into another session on the same host, as a window of its own.
    func sidebarRequestMovePane(
        session: String, window: Int, pane: String, toSession destination: String,
        service: TmuxService)
    /// Move a pane into another window of the same session.
    func sidebarRequestMovePane(
        session: String, window: Int, pane: String, toWindow destination: Int,
        service: TmuxService)
    /// Move a pane into a session that doesn't exist yet (prompts for the name).
    func sidebarRequestMovePaneToNewSession(
        session: String, window: Int, pane: String, service: TmuxService)
    /// Move every window of `session` into `destination`. tmux ends a session when
    /// its last window leaves, so this makes the source row disappear — the
    /// AppDelegate confirms it before acting.
    func sidebarRequestMergeSession(
        session: String, windows: [Int], into destination: String, service: TmuxService)

    /// Edit a MuxMaestro-managed SSH host (prefilled Add Server sheet). Only
    /// offered for aliases in the managed hosts file — hosts from the user's own
    /// `~/.ssh/config` are never rewritten.
    func sidebarRequestEditServer(alias: String)
    /// Remove a MuxMaestro-managed SSH host: drops its block from
    /// `~/.ssh/sidekick_hosts` and its per-alias settings (mosh/watch/session
    /// order). Same managed-aliases-only restriction as edit. Destructive —
    /// gated behind a confirm.
    func sidebarRequestRemoveServer(alias: String)
    /// Remove an orphan worktree via spindown, behind a confirm. Never offered
    /// for a main checkout or a tree known to hold work (`Worktrees.removeOffer`).
    func sidebarRequestRemoveWorktree(entry: WorktreeEntry, work: WorktreeWork)

    /// Drop a local file onto a session (copy to its cwd + paste the path).
    func sidebarRequestDropFile(
        localPath: String, session: String, service: TmuxService)

    /// Beam a session/window/pane in some direction: `source` is the host it's on
    /// (local or remote), `cwd` its project dir on that host, and `destination`
    /// where it should go — back to this Mac or on to another server. Resolved to
    /// plain primitives so the AppDelegate needs no sidebar-node knowledge.
    /// `attention` gates the "mid-response / waiting" confirm; `claudeSessionId` is
    /// nil for a non-Claude window (repo-only move); `paneId` drives the
    /// local→server pane takeover.
    func sidebarRequestBeam(
        source: Host, cwd: String, paneId: String,
        claudeSessionId: String?, attention: AttentionStatus, to destination: BeamDestination)

    // M13 — herdr session lifecycle (where it maps cleanly: stop / delete).
    func sidebarRequestStopHerdr(session: String, service: HerdrService)
    func sidebarRequestDeleteHerdr(session: String, service: HerdrService)

    /// User clicked "+ Add Server" in the saved-servers group.
    func sidebarRequestAddServer()

    /// A Servers-section button was clicked: start a new session on `host`
    /// (the prompt-based flow), falling back to a plain (non-tmux) shell when
    /// the host has no tmux.
    func sidebarRequestLaunchSession(host: Host, service: TmuxService)

    /// A window row's archive button — archive the window behind the ⌘W confirm.
    /// `merged` (the window's PR merged) skips the confirm and cleans up the
    /// window's worktree.
    func sidebarRequestConfirmKillWindow(
        session: String, window: Int, merged: Bool, service: TmuxService)

    // Actions on a remote host that has no tmux.
    /// Open a plain (non-tmux) ssh login shell on `host`.
    func sidebarRequestPlainShell(host: Host)
    /// Install tmux on `host` (gated behind a confirm; runs over an interactive ssh).
    func sidebarRequestInstallTmux(host: Host)
    /// Install mosh (incl. mosh-server) on `host` for the roaming mosh attach
    /// (gated behind a confirm; runs over an interactive ssh).
    func sidebarRequestInstallMosh(host: Host)

    /// Recover Claude Code sessions lost to a reboot (the empty-tree action row).
    /// Local host only — the transcripts being scanned are this Mac's.
    func sidebarRequestRecoverSessions()
}

/// Where a beamed session should go: back to this Mac, or on to another server.
enum BeamDestination: Equatable {
    case thisMac
    case server(Host)
}

/// Carries what a beam menu item needs — the clicked node and the chosen
/// destination — through the item's single `representedObject`.
private final class BeamMenuTarget {
    let node: SidebarNode
    let destination: BeamDestination
    init(node: SidebarNode, destination: BeamDestination) {
        self.node = node
        self.destination = destination
    }
}

/// Carries what a move/merge menu item needs — the clicked node and where its
/// contents should land — through the item's single `representedObject`. Same
/// shape as `BeamMenuTarget`, and for the same reason: the destination cannot be
/// re-derived at action time, only the row can.
private final class MoveMenuTarget {
    /// Where a move lands, on the clicked row's own host.
    enum Destination {
        /// An existing session (window move, pane move, session merge).
        case session(String)
        /// Another window of the pane's own session, by index.
        case window(Int)
        /// A session that doesn't exist yet; the AppDelegate prompts for the name.
        case newSession
    }
    let node: SidebarNode
    let destination: Destination
    init(node: SidebarNode, destination: Destination) {
        self.node = node
        self.destination = destination
    }
}

/// Owns one `TmuxService` per host (local + each remote ssh alias), created
/// lazily and reused so a remote host's ControlMaster connection persists across
/// polls. The single source of truth mapping a host → how we talk to it.
final class HostRegistry {
    private var services: [String: TmuxService] = [:]
    private let lock = NSLock()

    /// The local service (always present). Exposed for the self-tests and the
    /// startup attach, which target the local host.
    let local: TmuxService

    init(local: TmuxService = TmuxService()) {
        self.local = local
        services[Host.local.name] = local
    }

    /// The service for `host`, creating + caching it on first use.
    func service(for host: Host) -> TmuxService {
        if host.isLocal { return local }
        lock.lock()
        defer { lock.unlock() }
        if let existing = services[host.name] { return existing }
        let svc = TmuxService(host: host)
        services[host.name] = svc
        return svc
    }

    /// Tear down every remote host's multiplexed SSH connection (and the `-L`
    /// forward channels riding on it). Called on app terminate so a backgrounded
    /// `ssh -fN -L` forward doesn't outlive the app.
    func closeAllMasters() {
        lock.lock()
        let remote = services.values.filter { !$0.host.isLocal }
        lock.unlock()
        for svc in remote { svc.closeMaster() }
    }
}

/// Live session→window→pane tree backed by an NSOutlineView. Polls tmux on a
/// timer and diffs so the tree does not flicker or lose expansion state.
final class SidebarViewController: NSViewController {
    /// Private pasteboard type for dragging a session row to reorder it within its
    /// host. Carries "host.name\tsession.name" (see `pasteboardWriterForItem`).
    static let sessionDragType = NSPasteboard.PasteboardType("is.rebar.muxmaestro.session")

    weak var selectionDelegate: SidebarSelectionDelegate?
    weak var actionDelegate: SidebarActionDelegate?
    /// The worktree root behind the breadcrumb's "⑂ worktree" chip, nil when none.
    private var shownWorktreeRoot: String?

    private let registry: HostRegistry
    /// M13 — the herdr session source (separate non-tmux multiplexer).
    private let herdr: HerdrService
    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private let emptyState = NSTextField(labelWithString: "")
    private var roots: [SidebarNode] = []
    private var pollTimer: Timer?

    /// Cadence for the cold discovery sweep of remotes nobody is watching.
    private let scanner = RemoteScanScheduler()
    /// True while a cold sweep is in flight — dims the SERVERS refresh button and
    /// prevents a second sweep stacking on the first.
    private var isColdScanning = false

    /// The hosts shown at the top level: local first, then ssh-config aliases.
    private var hosts: [Host] = [.local]
    /// The host the shared (modeless) color panel is currently editing.
    private var colorPanelHost: Host?
    /// Per-host loaded session subtree (built off-main, applied on main).
    private var sessionsByHost: [String: [TmuxSession]] = [:]
    /// Per-host reachability, for greying offline remote hosts.
    private var reachabilityByHost: [String: HostReachability] = [
        Host.local.name: .reachable
    ]
    /// M13 — the loaded herdr session tree (built off-main, applied on main).
    private var herdrSessions: [HerdrSession] = []

    /// Favicon cache keyed by a session's working directory, so the disk scan +
    /// decode runs once per repo (off-main) instead of on every ~1.5s poll render.
    /// `faviconByCwd` holds resolved hits; `faviconMisses` marks dirs scanned with
    /// no favicon; `faviconScanning` marks in-flight scans (dedup concurrent polls).
    private var faviconByCwd: [String: NSImage] = [:]
    private var faviconMisses = Set<String>()
    private var faviconScanning = Set<String>()

    /// Open PRs per **window**, keyed by `windowKey(...)`. Each window in a session
    /// can be a different repo/branch, so detection keys on the window's cwd (not
    /// the session's). Detected off-main on a throttled cadence (see
    /// `refreshPullRequests`) and rendered as a chip on the window row + aggregated
    /// into the toolbar "PRs" dropdown.
    private var prByWindow: [String: [PullRequest]] = [:]
    /// Guards against overlapping PR scans; the wall-clock of the last scan throttles
    /// the poll-driven cadence so gh isn't hammered every tree refresh.
    private var isScanningPRs = false
    private var lastPRScan: Date?
    /// Max repos scanned for PRs at once, to bound subprocess/thread fan-out.
    private static let maxConcurrentPRScans = 4
    /// PRs resolved **by number** (from window names), keyed by (slug, number).
    /// Process-lifetime cache so a declared number costs one `gh pr view` ever;
    /// see `PRIdentityCache` for why merged/closed and misses are never re-asked.
    private let prIdentityCache = PRIdentityCache()
    /// Set by the AppDelegate to refresh the toolbar "PRs" item when the set changes.
    var onPullRequestsChanged: (() -> Void)?

    // MARK: Worktree awareness (issue #85)

    /// Worktree classification per session cwd, plus the repo (shared git dir) the
    /// cwd belongs to. Cached for the life of the process and **never run on the
    /// 1.5s poll**: a directory does not stop being a worktree, so the answer is
    /// effectively immutable, and this repo already paid once for a subprocess
    /// storm on that poll (PR #67). `worktreeMisses` marks cwds probed and found
    /// not to be repos; `worktreeScanning` dedupes in-flight probes.
    private var worktreeByCwd: [String: (kind: WorktreeKind, commonDir: String)] = [:]
    private var worktreeMisses = Set<String>()
    private var worktreeScanning = Set<String>()
    /// Every worktree of each known repo, keyed by the repo's shared git dir —
    /// from the slow sweep. The orphan section is derived from this.
    private var worktreesByRepo: [String: [WorktreeEntry]] = [:]
    /// "Holds unique work" per worktree root, from the same sweep. A path absent
    /// here reads as `.unknown` — never as "safe to delete".
    private var worktreeWorkByPath: [String: WorktreeWork] = [:]
    /// Per-worktree metrics from the same sweep — idle age, containers, working
    /// tree, lease. Absent reads as "unknown".
    private var worktreeMetricsByPath: [String: WorktreeMetrics] = [:]
    /// `du -sk` results in kilobytes, keyed by worktree root. Computed **on
    /// demand** — when a row is expanded or selected — never on the sweep, then
    /// cached for the life of the process.
    private var worktreeDiskKB: [String: Int] = [:]
    private var worktreeDiskScanning = Set<String>()
    /// Per-repo cadence for the sweep. `RemoteScanScheduler` isn't remote-specific
    /// — it's a keyed "when is this due again" clock with geometric backoff — so
    /// the sweep reuses it with its own policy rather than a second copy of it.
    private let worktreeScanner = RemoteScanScheduler(policy: .init(
        baseInterval: Worktrees.scanBaseInterval, maxInterval: Worktrees.scanMaxInterval))
    /// Guards against overlapping sweeps, like `isScanningPRs`.
    private var isScanningWorktrees = false

    // MARK: Running (issue #131)

    /// What each host last reported: its containers and its listening ports.
    /// Absent reads as "not scanned yet", which the rail says out loud.
    private var runningScans: [String: RunningHostScan] = [:]
    /// Ports move (a dev server starts and stops all day), so they are swept
    /// often; containers barely move and `docker ps` is the expensive one, so it
    /// is swept rarely. Both keyed by host, both backing off on failure — a
    /// wedged Docker Desktop or an offline `devbox` must cost one probe every few
    /// minutes, not one every cadence.
    private let runningPortScanner = RemoteScanScheduler(policy: .init(
        baseInterval: 5, maxInterval: 60))
    private let runningDockerScanner = RemoteScanScheduler(policy: .init(
        baseInterval: 30, maxInterval: 300))
    private var isScanningRunning = false
    /// Hosts whose `docker ps` has answered at least once this launch — the only
    /// ones whose Docker is worth reporting as unavailable later.
    private var dockerEverAnswered = Set<String>()
    /// `project_id` per checkout. Effectively immutable, so cached for the life
    /// of the process; a cwd in `supabaseIDMisses` has no Supabase config.
    private var supabaseIDByCwd: [String: String] = [:]
    private var supabaseIDMisses = Set<String>()
    /// Branch per checkout, refreshed on the Docker cadence — it is the key that
    /// joins a local pane to a stack on another host.
    private var branchByCwd: [String: String] = [:]
    /// Resolved server URLs keyed by "host|port", kept for the life of that
    /// server: the scrollback answer cannot change while the process lives, and
    /// the probe is not worth repeating.
    private var urlByHostPort: [String: String] = [:]
    /// Set by the AppDelegate so the rail re-renders when a scan lands.
    var onRunningChanged: (() -> Void)?

    // MARK: Server stats

    /// The last stats each server answered, keyed by host name. Kept when a later
    /// fetch fails, so a flaky link shows slightly old numbers, not dashes.
    private var hostStatsByName: [String: HostStats] = [:]
    /// When each server's stats were last asked for, and which are in flight.
    private var hostStatsFetchedAt: [String: Date] = [:]
    private var hostStatsInFlight = Set<String>()
    /// How often an expanded server's stats are fetched again.
    private static let hostStatsInterval: TimeInterval = 30

    /// Window identity key — matches the `.window` node's `identityBase`.
    private func windowKey(host: Host, session: String, window: Int) -> String {
        "W:\(host.name):\(session):\(window)"
    }

    /// How the top level is organized: by host (default) or by the working
    /// directory the sessions live in. The header toggle flips this.
    enum GroupMode { case host, directory, recent }
    private(set) var groupMode: GroupMode = .recent

    /// The session name of the currently-selected row (session/window/pane), or
    /// nil (including when a host row is selected).
    var selectedSessionName: String? {
        selectedNode?.sessionName
    }

    /// The host of the currently-selected row, or nil.
    var selectedHost: Host? { selectedNode?.host }

    /// The `TmuxService` for the currently-selected row's host, or nil.
    var selectedService: TmuxService? {
        selectedNode.map { registry.service(for: $0.host) }
    }

    /// The pane whose agent the Artifacts panel follows: the selected pane, or
    /// the `agentPane` of the selected window (a session's active window).
    var selectedAgentPane: (pane: TmuxPane, host: Host)? {
        guard let node = selectedNode else { return nil }
        switch node.kind {
        case .pane(let host, _, _, let pane):
            return (pane, host)
        case .window(let host, _, let window):
            return window.agentPane.map { ($0, host) }
        case .session(let host, let session):
            let window = session.windows.first(where: \.active) ?? session.windows.first
            return window?.agentPane.map { ($0, host) }
        default:
            return nil
        }
    }

    /// The exact tmux target the zoom toggle must act on so it agrees with what
    /// selection drove: a selected *pane* zooms by pane id (matches
    /// `selectPane(zoom:)`); a selected *window* — or a bare session, whose
    /// active window is shown — zooms by `session:window`. nil with no selection.
    var selectedZoomTarget: String? {
        guard let node = selectedNode else { return nil }
        let selection: TmuxCommands.ZoomSelection
        switch node.kind {
        case .host, .directory, .herdr, .herdrSession, .herdrTab, .herdrPane,
             .activeGroup, .serversGroup, .serverButton, .hostStats, .addServer, .placeholder,
             .hostAction, .worktreesGroup, .worktreeRow, .worktreeDetail:
            // herdr has no tmux-style zoom in this milestone.
            return nil
        case .session(_, let s):
            // Whole-session selection shows the active window; zoom that window.
            let active = (s.windows.first(where: { $0.active }) ?? s.windows.first)?.index
            selection = .session(name: s.name, activeWindow: active)
        case .window(_, let session, let w):
            selection = .window(session: session, window: w.index)
        case .pane(_, _, _, let pane):
            selection = .pane(id: pane.id)
        }
        return TmuxCommands.zoomTarget(for: selection)
    }

    /// The currently-selected sidebar node (any kind), or nil.
    private var selectedNode: SidebarNode? {
        let row = outline.selectedRow
        guard row >= 0 else { return nil }
        return outline.item(atRow: row) as? SidebarNode
    }

    /// Identities of currently-expanded session nodes, preserved across refresh.
    private var expandedIdentities: Set<String> = []
    /// Nodes the user explicitly collapsed — suppresses the default auto-expand so
    /// a session/window stays closed once the user closes it.
    private var collapsedByUser: Set<String> = []
    /// Identity of the selected node, preserved across refresh.
    private var selectedIdentity: String?
    /// What the tree leaves out (the header's control).
    private var filter = Settings.sidebarFilter()
    private let filterControl = SidebarFilterControl()
    /// A just-created/renamed session awaiting selection: highlighted by the next
    /// refresh that loads it into the tree, then cleared. Main-thread only.
    /// A row to highlight once a refresh brings it into the tree. `window` is set
    /// when the thing just created was a window (or a pane's window), so focus
    /// lands on it rather than its session row.
    private var pendingSelect: (name: String, window: Int?, host: Host)?
    /// A server just promoted to Active (via its Servers button) awaiting reveal:
    /// selected by the next refresh that loads its host row, then cleared.
    private var pendingActivate: Host?
    /// Hosts whose click-launch probe is in flight — their Servers buttons show a
    /// spinner, and repeat clicks are ignored until the probe lands. Main-only.
    private var probingHosts: Set<String> = []
    /// Suppresses the selection callback while we restore selection after a
    /// programmatic reload.
    private var restoringSelection = false
    /// Watches for ⌥ being released while an ⌥-hover preview runs; nil otherwise.
    private var hoverPreviewMonitor: Any?
    private var hoverPreviewResignObserver: NSObjectProtocol?
    /// Whether an ⌥-hover preview is switching rows. The rows it passes over are
    /// not visits, so the AppDelegate keeps them out of its MRU stacks.
    var isHoverPreviewing: Bool { hoverPreviewMonitor != nil }
    /// Hosts (by name) whose `loadTree()` is currently in flight. Each host loads
    /// and applies independently, so this is a *per-host* guard: a wedged remote
    /// blocks only its own reload across ticks, never the local tree or another
    /// host. Main-thread only.
    private var inFlightHosts: Set<String> = []
    /// Hosts a refresh was requested for while their load was still in flight —
    /// reloaded once the current load lands (trailing edge) so a just-asked-for
    /// reload (e.g. to show a new session) isn't lost. Main-thread only.
    private var reloadWhenDone: Set<String> = []
    /// True while the herdr tree load is in flight (guarded like the hosts so a
    /// slow herdr CLI can't pile up across ticks). Main-thread only.
    private var herdrInFlight = false
    /// When each remote host's tree was last reloaded, and the same for herdr —
    /// both poll on a slower cadence than the local tree. Main-thread only.
    private var lastRemoteLoad: [String: Date] = [:]
    private var lastHerdrLoad: Date?

    init(registry: HostRegistry = HostRegistry(), herdr: HerdrService = HerdrService()) {
        self.registry = registry
        self.herdr = herdr
        super.init(nibName: nil, bundle: nil)
    }

    /// Back-compat: build a registry around a single local service.
    convenience init(service: TmuxService) {
        self.init(registry: HostRegistry(local: service))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = SidebarPalette.bg.cgColor

        let header = NSTextField(labelWithString: "SESSIONS")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = SidebarPalette.muted
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        filterControl.filter = filter
        filterControl.onChange = { [weak self] in self?.setFilter($0) }

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 0
        outline.autoresizesOutlineColumn = false
        outline.backgroundColor = SidebarPalette.bg
        outline.selectionHighlightStyle = .regular
        outline.style = .sourceList
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 26
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(handleClick)
        outline.doubleAction = #selector(handleDoubleClick)
        outline.onMouseMoved = { [weak self] event in self?.previewHover(event) }
        outline.menu = makeContextMenu()
        // M11: session rows accept dropped file URLs (e.g. from Finder) — copy to
        // the session cwd + paste the path. The private session type lets a
        // session row be dragged to reorder it within its host.
        outline.registerForDraggedTypes([.fileURL, Self.sessionDragType])

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = SidebarPalette.bg
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        // Empty state shown when no tmux server is running.
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.stringValue = "No tmux sessions.\nStart one with + below."
        emptyState.alignment = .center
        emptyState.maximumNumberOfLines = 0
        emptyState.font = .systemFont(ofSize: 12)
        emptyState.textColor = SidebarPalette.muted
        emptyState.isHidden = true
        container.addSubview(emptyState)

        NSLayoutConstraint.activate([
            // Pin below the safe area so the label clears the window controls /
            // titlebar under `.fullSizeContentView` rather than sitting on top of
            // the traffic lights.
            header.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        self.view = container
    }

    /// Resolve the row of the "+" button that was clicked and dispatch the
    /// context-appropriate add: host → new session, session → new window.
    /// Switch the clicked session's windows between index order and newest
    /// activity first.
    @objc private func toggleSortOnRow(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, case .session(let host, let s)? = (outline.item(atRow: row) as? SidebarNode)?.kind
        else { return }
        Settings.setSortsByRecent(
            !Settings.sortsByRecent(session: s.name, host: host), session: s.name, host: host)
        applyRefresh(buildHostNodes())
    }

    @objc private func addOnRow(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return }
        let service = registry.service(for: node.host)
        switch node.kind {
        case .host(let h, _):
            actionDelegate?.sidebarRequestNewSession(host: h, service: registry.service(for: h))
        case .session(_, let s):
            actionDelegate?.sidebarRequestNewWindow(session: s.name, service: service)
        case .directory(let path, _, _):
            actionDelegate?.sidebarRequestNewSession(dir: path)
        default:
            break
        }
    }

    /// A window row's archive button: archive the window behind the same confirm
    /// ⌘W raises, or with no confirm once its PR merged. A separate delegate call
    /// from the context menu's Archive Window.
    @objc private func trashOnRow(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, case .window(let host, let session, let w)? =
                (outline.item(atRow: row) as? SidebarNode)?.kind else { return }
        let prs = prByWindow[windowKey(host: host, session: session, window: w.index)] ?? []
        actionDelegate?.sidebarRequestConfirmKillWindow(
            session: session, window: w.index, merged: WindowPRs.allMerged(prs),
            service: registry.service(for: host))
    }

    // MARK: Context menu + double-click

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// The node under the most recent right-click, falling back to the selected
    /// node only when the click missed a row. Resolution is the pure
    /// `TmuxCommands.contextMenuRow` so the fallback rule is unit-tested.
    private func clickedNode() -> SidebarNode? {
        guard let row = TmuxCommands.contextMenuRow(
            clickedRow: outline.clickedRow, selectedRow: outline.selectedRow)
        else { return nil }
        return outline.item(atRow: row) as? SidebarNode
    }

    /// A mouse click on a terminal row focuses the terminal. Selection changes
    /// alone don't, so arrow-key navigation keeps focus in the sidebar.
    @objc private func handleClick() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return }
        switch node.kind {
        case .session, .window, .pane, .herdrSession, .herdrTab, .herdrPane:
            selectionDelegate?.sidebarDidClickTerminalRow()
        default:
            break
        }
    }

    /// ⌥-hover preview: while ⌥ is held, the terminal row under a moving pointer
    /// becomes the selection, so the terminal shows it at once. Only a pointer
    /// that moves counts — ⌥ pressed over a resting pointer is someone typing an
    /// ⌥-key in the terminal. Releasing ⌥ stays on the row last shown.
    private func previewHover(_ event: NSEvent) {
        let optionOnly =
            event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option
        // ⌥ can be released where the monitor can't see it (another app).
        if !optionOnly { endHoverPreview() }
        let point = outline.convert(event.locationInWindow, from: nil)
        guard let row = TmuxCommands.hoverPreviewRow(
                optionOnly: optionOnly, hoveredRow: outline.row(at: point),
                selectedRow: outline.selectedRow),
              let node = outline.item(atRow: row) as? SidebarNode
        else { return }
        switch node.kind {
        case .session, .window, .pane, .herdrSession, .herdrTab, .herdrPane:
            break
        default:
            return
        }
        beginHoverPreview()
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func beginHoverPreview() {
        guard hoverPreviewMonitor == nil else { return }
        hoverPreviewMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            if !event.modifierFlags.contains(.option) { self?.endHoverPreview() }
            return event
        }
        hoverPreviewResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.endHoverPreview() }
    }

    /// ⌥ was released: the row shown now is the one the user chose, so report it
    /// as a real visit.
    private func endHoverPreview() {
        guard let monitor = hoverPreviewMonitor else { return }
        NSEvent.removeMonitor(monitor)
        hoverPreviewMonitor = nil
        if let hoverPreviewResignObserver {
            NotificationCenter.default.removeObserver(hoverPreviewResignObserver)
        }
        hoverPreviewResignObserver = nil
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return }
        let service = registry.service(for: node.host)
        switch node.kind {
        case .session(_, let s):
            selectionDelegate?.sidebarDidEndHoverPreview(
                session: s.name, window: nil, service: service)
        case .window(_, let session, let w):
            selectionDelegate?.sidebarDidEndHoverPreview(
                session: session, window: w.index, service: service)
        case .pane(_, let session, let window, _):
            selectionDelegate?.sidebarDidEndHoverPreview(
                session: session, window: window, service: service)
        default:
            break
        }
    }

    @objc private func handleDoubleClick() {
        guard let node = clickedNode(), node.isSession, let name = node.sessionName else { return }
        actionDelegate?.sidebarRequestRename(
            session: name, service: registry.service(for: node.host))
    }

    /// Read the target node captured on the menu item at menu-open time
    /// (`menuNeedsUpdate`), never re-deriving from `clickedRow` at action time —
    /// `clickedRow` can be -1 by then and silently fall back to the *selected*
    /// row, which would let a Kill hit a different session than the one
    /// right-clicked. The node carries both the session name and its host.
    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let name = node.sessionName
        else { return }
        actionDelegate?.sidebarRequestRename(session: name, service: registry.service(for: node.host))
    }

    @objc private func contextRemoveWorktree(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode,
              case .worktreeRow(let entry, _, let work) = node.kind else { return }
        actionDelegate?.sidebarRequestRemoveWorktree(entry: entry, work: work)
    }

    @objc private func contextKill(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let name = node.sessionName
        else { return }
        actionDelegate?.sidebarRequestKill(session: name, service: registry.service(for: node.host))
    }

    // MARK: Copy tmux ID

    /// The tmux address of a row, or nil for rows that have none (groups, herdr,
    /// server buttons). Pure resolution lives in `TmuxCommands.copyableIdentifier`.
    private func tmuxIdentifier(for node: SidebarNode) -> String? {
        switch node.kind {
        case .session(_, let s):
            return TmuxCommands.copyableIdentifier(for: .session(name: s.name))
        case .window(_, let session, let w):
            return TmuxCommands.copyableIdentifier(for: .window(session: session, window: w.index))
        case .pane(_, _, _, let p):
            return TmuxCommands.copyableIdentifier(for: .pane(id: p.id))
        default:
            return nil
        }
    }

    /// Put the clicked row's tmux id on the clipboard, so it can be pasted into
    /// another agent/terminal ("monitor %12"). Reads the node pinned at menu-open
    /// time, like every other context action.
    @objc private func contextCopyIdentifier(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode,
              let id = tmuxIdentifier(for: node) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    // MARK: Copy agent session ID

    /// The pane a session/window/pane row stands for: its active pane, else its
    /// first. Beam and the agent-id menu items must agree on this — a session row
    /// that copies one pane's id but beams another would be a trap.
    private func targetPane(for node: SidebarNode) -> TmuxPane? {
        switch node.kind {
        case .session(_, let s):
            guard let w = s.windows.first(where: { $0.active }) ?? s.windows.first else { return nil }
            return w.panes.first(where: { $0.active }) ?? w.panes.first
        case .window(_, _, let w):
            return w.panes.first(where: { $0.active }) ?? w.panes.first
        case .pane(_, _, _, let p):
            return p
        default:
            return nil
        }
    }

    /// Put the **full** agent session UUID on the clipboard (the menu title shows
    /// an abbreviation, the clipboard gets the whole thing) so it can be pasted
    /// straight into `claude --resume <uuid>`.
    @objc private func contextCopyClaudeSessionId(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode,
              let id = targetPane(for: node)?.claudeSessionId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    /// As above, for `codex resume <uuid>`.
    @objc private func contextCopyCodexSessionId(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode,
              let id = targetPane(for: node)?.codexSessionId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    // MARK: Per-host color (the sidebar tint denotes which server a session is on)

    /// "Color ▸" on a server row: the palette as swatches, a custom picker, and a
    /// reset back to the name-derived default. Every session card under the host
    /// repaints on pick.
    private func addColorSubmenu(to menu: NSMenu, host: Host) {
        let parent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = Settings.colorHex(host: host)
        for hex in HostColor.palette {
            let mi = NSMenuItem(title: hex, action: #selector(contextPickColor(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [host.name, hex]
            mi.image = Self.swatch(hex)
            mi.state = (hex.caseInsensitiveCompare(current) == .orderedSame) ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(contextCustomColor(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = host.name
        sub.addItem(custom)
        if Settings.hasCustomColor(host: host) {
            let reset = NSMenuItem(title: "Reset to Default", action: #selector(contextResetColor(_:)), keyEquivalent: "")
            reset.target = self
            reset.representedObject = host.name
            sub.addItem(reset)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// A filled rounded swatch for a palette menu item.
    private static func swatch(_ hex: String) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size)
        img.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3)
        (TmuxColor.parse(hex) ?? .gray).setFill()
        path.fill()
        img.unlockFocus()
        return img
    }

    /// Resolve a host name captured in a menu item — or in a Running row — back to
    /// a live `Host`: both outlive the tree snapshot they were built from.
    func host(named name: String) -> Host? {
        hosts.first { $0.name == name } ?? (name == Host.local.name ? .local : nil)
    }

    @objc private func contextPickColor(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let h = host(named: pair[0]) else { return }
        Settings.setColorHex(pair[1], host: h)
        repaintHostColors()
    }

    @objc private func contextResetColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let h = host(named: name) else { return }
        Settings.setColorHex(nil, host: h)
        repaintHostColors()
    }

    /// Open the shared color panel bound to this host. It's modeless, so the host
    /// is remembered in `colorPanelHost` and each change writes through live.
    @objc private func contextCustomColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let h = host(named: name) else { return }
        colorPanelHost = h
        let panel = NSColorPanel.shared
        panel.color = TmuxColor.parse(Settings.colorHex(host: h)) ?? .systemBlue
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let h = colorPanelHost else { return }
        Settings.setColorHex(Self.hex(from: sender.color), host: h)
        repaintHostColors()
    }

    /// `#rrggbb` for an arbitrary picked color (converted to sRGB first — the panel
    /// can hand back catalog/greyscale colors that have no RGB components).
    static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Push new host colours onto the live card rows without a full reload (which
    /// would collapse/flicker the tree).
    private func repaintHostColors() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let node = outline.item(atRow: row) as? SidebarNode,
                  let cardRow = rowView as? CardRowView else { return }
            Self.colorCard(cardRow, node: node)
        }
    }

    /// A card row's server colour. herdr rows have no server: no colour.
    private static func colorCard(_ row: CardRowView, node: SidebarNode) {
        switch node.kind {
        case .session(let host, _), .window(let host, _, _), .pane(let host, _, _, _),
             .serverButton(let host, _, _), .hostStats(let host, _):
            row.hostHex = Settings.colorHex(host: host)
        default:
            row.hostHex = nil
        }
        // Only the header takes the tint: a session row, or a server row over its stats.
        if case .serverButton = node.kind { row.isSession = true } else { row.isSession = node.isSession }
    }

    /// Redraw every visible card row. A row's segment depends on its neighbours,
    /// so an expand, collapse, insert or removal changes rows that were not
    /// reloaded.
    private func repaintCards() {
        outline.enumerateAvailableRowViews { rowView, _ in
            if rowView is CardRowView { rowView.needsDisplay = true; rowView.needsLayout = true }
        }
        // The same change moves the card gap, which is part of the row height.
        var resized = IndexSet()
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? SidebarNode, node.card != nil,
                  outline.rect(ofRow: row).height != rowHeight(for: node, row: row)
            else { continue }
            resized.insert(row)
        }
        guard !resized.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            outline.noteHeightOfRows(withIndexesChanged: resized)
        }
    }

    /// A row's height: its content, plus the padding and card gap for a card row.
    private func rowHeight(for node: SidebarNode, row: Int) -> CGFloat {
        let content: CGFloat
        switch node.kind {
        case .session, .herdrSession: content = 34
        case .window(_, _, let w): content = w.lastPrompt == nil ? 24 : RowCell.twoLineHeight
        case .pane(_, _, _, let p): content = p.lastPrompt == nil ? 24 : RowCell.twoLineHeight
        case .herdrTab, .herdrPane, .placeholder: content = 24
        case .worktreeDetail: content = 19
        case .worktreeRow: content = 26
        case .hostStats: content = HostStatsCell.contentHeight
        default: content = 28
        }
        guard node.card != nil else { return content }
        return (outline.cardSegment(atRow: row) ?? .middle).rowHeight(content: content)
    }

    /// Mirror ⌘W (Archive Window) from a session row: archive the session's active
    /// window (the focused one, or the first if none is flagged active).
    @objc private func contextCloseWindow(_ sender: NSMenuItem) {
        guard case .session(let host, let s)? =
            (sender.representedObject as? SidebarNode)?.kind,
            let w = s.windows.first(where: { $0.active }) ?? s.windows.first else { return }
        actionDelegate?.sidebarRequestKillWindow(
            session: s.name, window: w.index, service: registry.service(for: host))
    }

    /// New session targets the host on the captured node (host row, or the
    /// session row's host), defaulting to local when invoked with no target.
    @objc private func contextNew(_ sender: NSMenuItem) {
        let host = (sender.representedObject as? SidebarNode)?.host ?? .local
        actionDelegate?.sidebarRequestNewSession(host: host, service: registry.service(for: host))
    }

    /// Toggle whether the right-clicked remote host keeps polling while collapsed,
    /// then refresh so the watch state (and the next probe) takes effect now.
    @objc private func contextToggleWatch(_ sender: NSMenuItem) {
        guard case .host(let h, _)? = (sender.representedObject as? SidebarNode)?.kind,
              !h.isLocal else { return }
        Settings.setWatch(!Settings.watch(host: h), host: h)
        refresh()
    }

    /// Pin / unpin the right-clicked directory row. A pinned directory keeps its
    /// row in directory mode even at zero sessions, and sorts to the top.
    @objc private func contextTogglePinDir(_ sender: NSMenuItem) {
        guard case .directory(let path, _, let pinned)? =
                (sender.representedObject as? SidebarNode)?.kind,
              !path.isEmpty else { return }
        Settings.setPinnedDir(!pinned, path: path)
        applyRefresh(buildHostNodes())
    }

    /// Toggle whether the right-clicked remote host attaches over mosh. Takes
    /// effect on the next attach (no refresh needed — discovery is unaffected).
    @objc private func contextToggleMosh(_ sender: NSMenuItem) {
        guard case .host(let h, _)? = (sender.representedObject as? SidebarNode)?.kind,
              !h.isLocal else { return }
        Settings.setUseMosh(!Settings.useMosh(host: h), host: h)
    }

    @objc private func contextInstallMosh(_ sender: NSMenuItem) {
        guard case .host(let h, _)? = (sender.representedObject as? SidebarNode)?.kind,
              !h.isLocal else { return }
        actionDelegate?.sidebarRequestInstallMosh(host: h)
    }

    @objc private func contextEditServer(_ sender: NSMenuItem) {
        guard let alias = (sender.representedObject as? SidebarNode)?.host.sshAlias
        else { return }
        actionDelegate?.sidebarRequestEditServer(alias: alias)
    }

    @objc private func contextRemoveServer(_ sender: NSMenuItem) {
        guard let alias = (sender.representedObject as? SidebarNode)?.host.sshAlias
        else { return }
        actionDelegate?.sidebarRequestRemoveServer(alias: alias)
    }

    /// Aliases MuxMaestro manages, read fresh at menu-open time so a host added or
    /// removed outside the app is reflected without a relaunch. Cheap (one small
    /// file) and only on right-click.
    private func managedAliases() -> Set<String> {
        let content = (try? String(
            contentsOfFile: AddServer.managedHostsPath, encoding: .utf8)) ?? ""
        return Set(AddServer.managedAliases(in: content))
    }

    // MARK: Window context actions (M9)
    //
    // Each reads the exact node pinned to the menu item at menu-open time (never
    // re-deriving from clickedRow, which can be -1 by action time and fall back
    // to the *selected* row — letting a destructive action hit the wrong node).

    @objc private func contextKillWindow(_ sender: NSMenuItem) {
        guard case .window(let host, let session, let w)? =
            (sender.representedObject as? SidebarNode)?.kind else { return }
        actionDelegate?.sidebarRequestKillWindow(
            session: session, window: w.index, service: registry.service(for: host))
    }

    @objc private func contextRenameWindow(_ sender: NSMenuItem) {
        guard case .window(let host, let session, let w)? =
            (sender.representedObject as? SidebarNode)?.kind else { return }
        actionDelegate?.sidebarRequestRenameWindow(
            session: session, window: w.index, service: registry.service(for: host))
    }

    @objc private func contextNewWindow(_ sender: NSMenuItem) {
        guard case .window(let host, let session, _)? =
            (sender.representedObject as? SidebarNode)?.kind else { return }
        actionDelegate?.sidebarRequestNewWindow(
            session: session, service: registry.service(for: host))
    }

    // MARK: Pane context actions (M9)

    @objc private func contextKillPane(_ sender: NSMenuItem) {
        guard case .pane(let host, let session, let window, let p)? =
            (sender.representedObject as? SidebarNode)?.kind else { return }
        actionDelegate?.sidebarRequestKillPane(
            session: session, window: window, pane: p.id, service: registry.service(for: host))
    }

    @objc private func contextSplitHorizontal(_ sender: NSMenuItem) {
        splitPane(sender, vertical: false)
    }

    @objc private func contextSplitVertical(_ sender: NSMenuItem) {
        splitPane(sender, vertical: true)
    }

    private func splitPane(_ sender: NSMenuItem, vertical: Bool) {
        guard case .pane(let host, let session, let window, let p)? =
            (sender.representedObject as? SidebarNode)?.kind else { return }
        actionDelegate?.sidebarRequestSplitPane(
            session: session, window: window, pane: p.id, vertical: vertical,
            service: registry.service(for: host))
    }

    // MARK: Move / merge context actions

    /// Build one destination item, pinned to the clicked node so the action hits
    /// the row that was right-clicked even after `clickedRow` has reset.
    private func moveItem(
        _ title: String, node: SidebarNode, to destination: MoveMenuTarget.Destination,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = MoveMenuTarget(node: node, destination: destination)
        item.target = self
        return item
    }

    /// Every other session on `host`, in sidebar order — the only legal move
    /// destinations. Filtered to one host because tmux moves windows and panes
    /// within a single server and has no verb that crosses servers, so a
    /// cross-host destination would be an action that can never succeed.
    private func moveDestinationSessions(host: Host, excluding exclude: String) -> [String] {
        (sessionsByHost[host.name] ?? []).map(\.name).filter { $0 != exclude }
    }

    /// "Move to Session ▸" + "Move to New Session…" for a window or pane row.
    /// The submenu is omitted entirely rather than shown empty when the host has
    /// no other session — a lone session would otherwise offer a move with
    /// nowhere to go. "Move to New Session…" is always offered: it needs no
    /// existing destination, and it's the one that makes a lone session splittable.
    private func addMoveToSessionItems(to menu: NSMenu, node: SidebarNode, session: String) {
        let others = moveDestinationSessions(host: node.host, excluding: session)
        if !others.isEmpty {
            let parent = NSMenuItem(title: "Move to Session", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for name in others {
                sub.addItem(moveItem(
                    name, node: node, to: .session(name),
                    action: #selector(contextMoveToSession(_:))))
            }
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(moveItem(
            "Move to New Session…", node: node, to: .newSession,
            action: #selector(contextMoveToNewSession(_:))))
    }

    /// "Move to Window ▸" for a pane row: the other windows of the pane's own
    /// session. Omitted when the session has only the one window, which is the
    /// common case and would otherwise be a permanently empty submenu.
    private func addMoveToWindowItem(
        to menu: NSMenu, node: SidebarNode, session: String, window: Int
    ) {
        let others = (sessionsByHost[node.host.name] ?? [])
            .first { $0.name == session }?
            .windows.filter { $0.index != window } ?? []
        guard !others.isEmpty else { return }
        let parent = NSMenuItem(title: "Move to Window", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for w in others {
            sub.addItem(moveItem(
                "\(w.index): \(w.name)", node: node, to: .window(w.index),
                action: #selector(contextMoveToWindow(_:))))
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// "Merge into Session ▸" for a session row — move all of its windows into
    /// another session. Omitted when the session is empty (nothing to merge) or
    /// when it's the host's only one (nowhere to merge to). Owns its trailing
    /// separator rather than leaving it to the caller, so the omitted case doesn't
    /// leave two separators stacked in the menu.
    private func addMergeItem(to menu: NSMenu, node: SidebarNode, session: TmuxSession) {
        let others = moveDestinationSessions(host: node.host, excluding: session.name)
        guard !others.isEmpty, !session.windows.isEmpty else { return }
        let parent = NSMenuItem(title: "Merge into Session", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in others {
            sub.addItem(moveItem(
                name, node: node, to: .session(name),
                action: #selector(contextMergeSession(_:))))
        }
        parent.submenu = sub
        menu.addItem(parent)
        menu.addItem(.separator())
    }

    /// Move the clicked window or pane into the session pinned on the menu item.
    @objc private func contextMoveToSession(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MoveMenuTarget,
              case .session(let destination) = target.destination else { return }
        let service = registry.service(for: target.node.host)
        switch target.node.kind {
        case .window(_, let session, let w):
            actionDelegate?.sidebarRequestMoveWindow(
                session: session, window: w.index, toSession: destination, service: service)
        case .pane(_, let session, let window, let p):
            actionDelegate?.sidebarRequestMovePane(
                session: session, window: window, pane: p.id, toSession: destination,
                service: service)
        default:
            break
        }
    }

    /// Move the clicked pane into another window of its own session.
    @objc private func contextMoveToWindow(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MoveMenuTarget,
              case .window(let destination) = target.destination,
              case .pane(let host, let session, let window, let p) = target.node.kind
        else { return }
        actionDelegate?.sidebarRequestMovePane(
            session: session, window: window, pane: p.id, toWindow: destination,
            service: registry.service(for: host))
    }

    /// Move the clicked window or pane out into a session of its own; the
    /// AppDelegate owns the name prompt.
    @objc private func contextMoveToNewSession(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MoveMenuTarget else { return }
        let service = registry.service(for: target.node.host)
        switch target.node.kind {
        case .window(_, let session, let w):
            actionDelegate?.sidebarRequestMoveWindowToNewSession(
                session: session, window: w.index, service: service)
        case .pane(_, let session, let window, let p):
            actionDelegate?.sidebarRequestMovePaneToNewSession(
                session: session, window: window, pane: p.id, service: service)
        default:
            break
        }
    }

    /// Merge the clicked session into the one pinned on the menu item. The window
    /// indices are read here, from the tree the menu was built against, so the
    /// AppDelegate needs no sidebar-node knowledge.
    @objc private func contextMergeSession(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MoveMenuTarget,
              case .session(let destination) = target.destination,
              case .session(let host, let s) = target.node.kind else { return }
        actionDelegate?.sidebarRequestMergeSession(
            session: s.name, windows: s.windows.map(\.index), into: destination,
            service: registry.service(for: host))
    }

    // MARK: Beam context action

    /// Rows that can be beamed to a server — a session, a window, or a pane
    /// (each resolves to a repo cwd + a pane to hand over).
    private func isBeamableRow(_ node: SidebarNode) -> Bool {
        switch node.kind {
        case .session, .window, .pane: return true
        default: return false
        }
    }

    /// Append the beam actions for a beamable row, direction depending on where the
    /// row lives. A **local** row gets "Beam to server ▸ <host>" (local → remote).
    /// A **remote** row gets "Beam to this Mac" (remote → local) plus "Beam to
    /// another server ▸ <host>" (server → server, via this Mac). Offline hosts are
    /// greyed out.
    private func addBeamSubmenu(to menu: NSMenu, node: SidebarNode) {
        let remotes = hosts.filter { !$0.isLocal }
        if node.host.isLocal {
            let beamItem = NSMenuItem(title: "Beam to server", action: nil, keyEquivalent: "")
            if remotes.isEmpty {
                beamItem.isEnabled = false  // no servers to beam to yet
            } else {
                beamItem.submenu = beamHostSubmenu(node: node, hosts: remotes)
            }
            menu.addItem(beamItem)
        } else {
            let home = NSMenuItem(
                title: "Beam to this Mac", action: #selector(contextBeam(_:)), keyEquivalent: "")
            home.representedObject = BeamMenuTarget(node: node, destination: .thisMac)
            home.target = self
            menu.addItem(home)
            let others = remotes.filter { $0.name != node.host.name }
            if !others.isEmpty {
                let beamItem = NSMenuItem(
                    title: "Beam to another server", action: nil, keyEquivalent: "")
                beamItem.submenu = beamHostSubmenu(node: node, hosts: others)
                menu.addItem(beamItem)
            }
        }
    }

    /// A submenu of servers as beam destinations for `node`, offline ones greyed.
    private func beamHostSubmenu(node: SidebarNode, hosts: [Host]) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false  // honor the per-host isEnabled below
        for h in hosts {
            let offline = reachabilityByHost[h.name] == .unreachable
            let it = NSMenuItem(
                title: offline ? "\(h.name) (offline)" : h.name,
                action: #selector(contextBeam(_:)), keyEquivalent: "")
            it.representedObject = BeamMenuTarget(node: node, destination: .server(h))
            it.target = self
            it.isEnabled = !offline
            sub.addItem(it)
        }
        return sub
    }

    /// Resolve the clicked node to what beam needs: the repo cwd, the pane to hand
    /// over, the pane's Claude session id (nil ⇒ repo-only), and its attention
    /// (for the mid-response safety confirm). nil for a non-beamable row.
    private func resolveBeam(_ node: SidebarNode)
        -> (cwd: String, paneId: String, sessionId: String?, attention: AttentionStatus)? {
        guard let p = targetPane(for: node) else { return nil }
        switch node.kind {
        case .session(_, let s):
            let w = s.windows.first(where: { $0.active }) ?? s.windows.first
            return (w?.cwd ?? "", p.id, p.claudeSessionId, p.attention)
        case .window(_, _, let w):
            return (w.cwd, p.id, p.claudeSessionId, p.attention)
        case .pane:
            return (p.path, p.id, p.claudeSessionId, p.attention)
        default:
            return nil
        }
    }

    @objc private func contextBeam(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? BeamMenuTarget,
              let r = resolveBeam(target.node) else { return }
        actionDelegate?.sidebarRequestBeam(
            source: target.node.host, cwd: r.cwd, paneId: r.paneId,
            claudeSessionId: r.sessionId, attention: r.attention, to: target.destination)
    }

    // MARK: herdr context actions (M13)

    @objc private func contextStopHerdr(_ sender: NSMenuItem) {
        guard let name = (sender.representedObject as? SidebarNode)?.herdrSessionName
        else { return }
        actionDelegate?.sidebarRequestStopHerdr(session: name, service: herdr)
    }

    @objc private func contextDeleteHerdr(_ sender: NSMenuItem) {
        guard let name = (sender.representedObject as? SidebarNode)?.herdrSessionName
        else { return }
        actionDelegate?.sidebarRequestDeleteHerdr(session: name, service: herdr)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
        startPolling()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPolling() {
        let timer = Timer(timeInterval: Settings.pollInterval(), repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Poll every host on the tick. `refresh()` starts a load only for hosts that
    /// aren't already loading (per-host guard), so a host still mid-load is simply
    /// skipped this tick while every other host reloads — no global drop, and no
    /// back-to-back polling of a slow host.
    private func pollTick() {
        refresh(pollTick: true)
    }

    /// Main-thread only (reads `sessionsByHost`). See `RemoteTier.isHot`.
    private func isHotRemote(_ host: Host, expanded: Set<String>) -> Bool {
        RemoteTier.isHot(
            watched: Settings.watch(host: host),
            expanded: Self.isExpandedInAnySection(host.identity, in: expanded),
            hasSessions: !(sessionsByHost[host.name] ?? []).isEmpty)
    }

    /// Collapse aliases that reach the same machine down to the first declared, so
    /// one box is never polled — or rendered — twice. Uses only the memoized
    /// identity, so an alias not yet resolved is kept (never falsely merged).
    private static func dedupedByMachine(_ hosts: [Host]) -> [Host] {
        SshIdentity.dedupe(hosts) { SshIdentity.cached($0) }
    }

    /// The remotes contributing session rows to ACTIVE. See `RemoteTier.active`.
    private func activeRemotes(_ remotes: [Host]) -> [Host] {
        RemoteTier.active(
            remotes,
            watched: { Settings.watch(host: $0) },
            hasSessions: { !(self.sessionsByHost[$0.name] ?? []).isEmpty },
            identity: { SshIdentity.cached($0) })
    }

    /// Sweep collapsed, unwatched remotes on the slow cadence so their sessions turn
    /// up on their own instead of only after an expand or a Watch toggle.
    ///
    /// Deliberately detached from `refresh()`: cold candidates are swept on their own
    /// slow cadence rather than every 1.5s tick, so a cold host's 4s `ConnectTimeout`
    /// never rides along on the hot poll. (Hot hosts already apply per-host, so a slow
    /// one only delays itself either way — but a cold sweep would add many such hosts.)
    private func startColdScan(_ candidates: [Host]) {
        guard !candidates.isEmpty, !isColdScanning else { return }
        isColdScanning = true
        candidates.forEach { scanner.begin($0.name) }
        reloadServersHeader()

        let registry = self.registry
        let group = DispatchGroup()
        let lock = NSLock()
        var sessions: [String: [TmuxSession]] = [:]
        var reach: [String: HostReachability] = [:]

        for host in candidates {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let service = registry.service(for: host)
                var r = service.probeReachability()
                var tree: [TmuxSession]?
                if r == .reachable {
                    if service.hasTmux() { tree = service.loadTree() } else { r = .tmuxMissing }
                }
                lock.lock()
                reach[host.name] = r
                if let tree { sessions[host.name] = tree }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let now = Date()
            for host in candidates {
                // `.tmuxMissing` backs off like a failure: a NAS won't grow tmux
                // between sweeps. The SERVERS refresh button still forces a recheck.
                if reach[host.name] == .reachable { self.scanner.recordSuccess(host.name, now: now) }
                else { self.scanner.recordFailure(host.name, now: now) }
            }
            for host in candidates {
                guard let tree = sessions[host.name] else { continue }
                self.sessionsByHost[host.name] = self.stampViewed(tree, host: host)
            }
            for (k, v) in reach { self.reachabilityByHost[k] = v }
            self.isColdScanning = false
            // Re-render the header explicitly. `refresh()` can't do it: `mergeInPlace`
            // only reloads rows whose `diffDisplay` changed, and `.serversGroup`'s is
            // just "Servers (N)" — it doesn't encode `isColdScanning`. A sweep of dead
            // or idle remotes (exactly what the cold tier targets) changes nothing
            // else, so without this the button stays disabled and swallows clicks.
            self.reloadServersHeader()
            // A host that turned out to hold sessions is now hot: rebuild so it lands
            // in ACTIVE and joins the fast poll from the next tick.
            self.refresh()
        }
    }

    /// Re-render just the SERVERS header row (its refresh button's enabled/tint state
    /// reads `isColdScanning`), without disturbing expansion or selection.
    private func reloadServersHeader() {
        // `mergeInPlace` keeps `roots` holding the live outline items, but the header
        // may not be rendered yet on the first refresh.
        guard let node = roots.first(where: {
            if case .serversGroup = $0.kind { return true }
            return false
        }), outline.row(forItem: node) >= 0 else { return }
        outline.reloadItem(node)
    }

    /// SERVERS header refresh button: clear every backoff and sweep the cold remotes
    /// now. Hot remotes need no sweep — they reload on the next ~1.5s tick anyway.
    @objc private func refreshServersClicked(_ sender: NSButton) {
        guard !isColdScanning else { return }
        scanner.forceAll()
        let expanded = expandedIdentities
        let remotes = hosts.filter { !$0.isLocal && !isHotRemote($0, expanded: expanded) }
        startColdScan(Self.dedupedByMachine(remotes))
        refresh()
    }

    /// Reload the tree, preserving expansion + selection and only reloading on a
    /// real change (avoids flicker).
    ///
    /// The host list is parsed from `~/.ssh/config`; each host's session subtree
    /// + reachability is fetched off the main thread (the local host always; a
    /// remote host only when its row is expanded, so a collapsed offline host
    /// never blocks the local tree). Per-host work is dispatched concurrently so
    /// one slow/offline host doesn't delay the others; only the diff + reload +
    /// restore touch the main thread.
    /// `pollTick` marks the timer-driven call, which is the only one that honors
    /// the slower remote/herdr cadence. Every other caller is a user action (a
    /// session was created, a host was activated, Refresh was clicked) and
    /// reloads everything immediately — being cheap must never make the app feel
    /// stale in response to a click.
    func refresh(pollTick: Bool = false) {
        let hosts = SshConfig.loadHosts()
        self.hosts = hosts
        // Which remote hosts are expanded (need a live load) — captured on main.
        let expanded = expandedIdentities

        // Split the remotes into the two poll tiers, on main (both read `self`).
        // Hot: loaded on every tick below. Cold: swept every few minutes by
        // `startColdScan`, fully detached from this load.
        scanner.retain(Set(hosts.map(\.name)))
        let remotes = hosts.filter { !$0.isLocal }
        let hot = Self.dedupedByMachine(remotes.filter { isHotRemote($0, expanded: expanded) })
        let hotNames = Set(hot.map(\.name))
        // Exclude cold candidates by MACHINE, not by alias: watching `buildbox1`
        // must not leave its twin `buildbox` looking idle and eligible for a sweep —
        // that box is already being polled once every 1.5s.
        let hotMachines = Set(hot.compactMap { SshIdentity.cached($0) })
        let now = Date()
        let coldDue = Self.dedupedByMachine(remotes.filter { host in
            guard !hotNames.contains(host.name) else { return false }
            if let machine = SshIdentity.cached(host), hotMachines.contains(machine) { return false }
            return scanner.isDue(host.name, now: now)
        })
        startColdScan(coldDue)
        // Only load the herdr tree when its node is expanded (cheap when collapsed
        // — herdr isn't on the ssh-config path, so loading it always is wasted work
        // if the user never expands it). The root is always shown. herdr lives under
        // Active, so its expanded identity is namespaced ("A/HERDR").
        let herdrExpanded = Self.isExpandedInAnySection("HERDR", in: expanded)

        // Resolve every alias to the machine it reaches so the next render's
        // `SshIdentity.cached` dedupe is free. `ssh -G` parses the config only (no
        // network) and memoizes per alias — fire-and-forget so it never gates a load.
        DispatchQueue.global(qos: .utility).async { SshIdentity.prewarm(hosts) }

        // Load the local host and every hot remote — each independently, applied the
        // moment it lands (no barrier): a wedged remote can't delay local discovery
        // or another host's rows. `loadHost` guards per-host against pile-up.
        //
        // The local host reloads on every tick; hot remotes reload every third
        // (see `RemoteTier.remotePollTicks`), since each remote load is three ssh
        // round-trips for a tree that changes far more slowly than the local one.
        let remoteInterval = Settings.pollInterval() * Double(RemoteTier.remotePollTicks)
        for host in hosts where host.isLocal || hotNames.contains(host.name) {
            if !host.isLocal, pollTick,
               !RemoteTier.isDue(last: lastRemoteLoad[host.name], now: now, interval: remoteInterval) {
                continue
            }
            if !host.isLocal { lastRemoteLoad[host.name] = now }
            loadHost(host)
        }

        // herdr tree: load only when its node is expanded, guarded so a slow herdr
        // CLI can't pile up across ticks — and on the same slower cadence as
        // remotes, since it's three more CLI spawns for another tree that isn't
        // changing every 1.5s.
        let herdrDue = !pollTick
            || RemoteTier.isDue(last: lastHerdrLoad, now: now, interval: remoteInterval)
        if herdrExpanded, herdr.isAvailable, !herdrInFlight, herdrDue {
            lastHerdrLoad = now
            herdrInFlight = true
            let herdr = self.herdr
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tree = herdr.loadTree()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.herdrInFlight = false
                    self.herdrSessions = tree
                    self.applyRefresh(self.buildHostNodes())
                }
            }
        }
        requestHostStats(now: now)
    }

    /// The stat card node for `host`'s server button, carrying its last stats.
    private func hostStatsNode(_ host: Host) -> SidebarNode {
        SidebarNode(kind: .hostStats(host: host, stats: hostStatsByName[host.name]))
    }

    /// Fetch stats for every server whose card is on screen and due: on expand,
    /// then every `hostStatsInterval`. A collapsed server costs nothing. Each
    /// fetch runs off-main; a failed one keeps the last value on the card.
    /// Main-thread only.
    private func requestHostStats(now: Date = Date()) {
        var wanted: [Host] = []
        if let servers = roots.first(where: {
            if case .serversGroup = $0.kind { return true }
            return false
        }), outline.isItemExpanded(servers) {
            for button in servers.children where outline.isItemExpanded(button) {
                if case .serverButton(let host, _, _) = button.kind { wanted.append(host) }
            }
        }
        // The phone lists every host's stats, expanded here or not. Only hosts
        // that answer are asked, and only while a phone is reading them.
        if wantsAllHostStats?() == true {
            wanted += mobileHosts().filter { host in
                reachabilityByHost[host.name] == .reachable && !wanted.contains(host)
            }
        }
        for host in wanted {
            guard !hostStatsInFlight.contains(host.name),
                  RemoteTier.isDue(last: hostStatsFetchedAt[host.name], now: now,
                                   interval: Self.hostStatsInterval)
            else { continue }
            hostStatsInFlight.insert(host.name)
            hostStatsFetchedAt[host.name] = now
            let service = registry.service(for: host)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let stats = service.hostStats()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hostStatsInFlight.remove(host.name)
                    guard let stats else { return }
                    self.hostStatsByName[host.name] = stats
                    self.applyRefresh(self.buildHostNodes())
                }
            }
        }
    }

    /// Load one host's session subtree off-main and apply it the instant it lands.
    /// Per-host in-flight guard: a host still loading is skipped (its slow ssh can't
    /// pile up loads tick after tick), but every *other* host still reloads — so a
    /// wedged remote never blocks local discovery. Main-thread only.
    private func loadHost(_ host: Host) {
        guard !inFlightHosts.contains(host.name) else {
            // Already loading — remember to reload once it lands (trailing edge) so an
            // explicit refresh (e.g. just after creating a session) isn't dropped.
            reloadWhenDone.insert(host.name)
            return
        }
        inFlightHosts.insert(host.name)
        let service = registry.service(for: host)
        // Read on main: was this host reachable as of its last load? Drives the
        // probe-skipping fast path below.
        let trustReachable = reachabilityByHost[host.name] == .reachable
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var reach: HostReachability = .reachable
            // A nil tree means list-sessions failed transiently (e.g. timed out under
            // load) — the applier keeps the prior tree instead of blanking. [] means
            // genuinely no sessions and DOES update.
            var tree: [TmuxSession]?
            if host.isLocal {
                tree = service.loadTree()
                // Empty tree → the recover-previous-sessions row may render; prewarm
                // its disk scan off-main so buildHostNodes reads a cached answer.
                if tree?.isEmpty == true { _ = ClaudeSessionRecovery.lostSessions }
            } else if trustReachable, let loaded = service.loadTree() {
                // A host that answered last time gets straight to the tree: a
                // successful `list-sessions` IS proof it's reachable and running
                // tmux, so the `ssh echo ok` probe and `tmux -V` ahead of it were
                // two extra round-trips per poll to re-derive what the load
                // already tells us. Only a failed load pays for the diagnosis.
                tree = loaded
                reach = .reachable
            } else {
                reach = service.probeReachability()
                if reach == .reachable {
                    // Reachable but no tmux → distinct state so we can offer a plain
                    // shell / install instead of a misleading failure.
                    if service.hasTmux() { tree = service.loadTree() }
                    else { reach = .tmuxMissing }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightHosts.remove(host.name)
                self.applyHostResult(host: host, tree: tree, reach: reach)
                // Trailing edge: a refresh asked for while this host was loading.
                if self.reloadWhenDone.remove(host.name) != nil { self.loadHost(host) }
            }
        }
    }

    /// Merge one host's freshly-loaded subtree into the model and re-render — on the
    /// main thread, once per host per poll, as each host's load lands.
    private func applyHostResult(host: Host, tree: [TmuxSession]?, reach: HostReachability) {
        // Keep the prior tree on a transient load failure (nil); update on success
        // (including a genuine empty []).
        if let tree { sessionsByHost[host.name] = stampViewed(tree, host: host) }
        reachabilityByHost[host.name] = reach
        // A hot poll is also a scan. Without this, a remote whose last session ends
        // drops out of the hot tier and — never having been "scanned" — is
        // immediately due for a cold sweep on the next tick.
        if reach == .reachable { scanner.recordSuccess(host.name, now: Date()) }

        applyRefresh(buildHostNodes())
        selectionDelegate?.sidebarDidRefreshTree(host: host)

        // Highlight a freshly created/renamed session once it appears in the tree
        // (refresh loads asynchronously, so the creator couldn't). Idempotent:
        // selectSession only succeeds — and clears the pending state — once the row
        // exists, so this converges as the relevant host's load lands.
        if let p = pendingSelect, selectRow(session: p.name, window: p.window, host: p.host) {
            pendingSelect = nil
            // The just-created session is the better reveal target than the promoted
            // host's first session — drop the pending reveal.
            if pendingActivate?.name == p.host.name { pendingActivate = nil }
        }
        // Reveal a just-activated server once its sessions land in Active (but never
        // steal the selection from a pending session select).
        if pendingSelect == nil, let h = pendingActivate, revealActiveHost(h) {
            pendingActivate = nil
        }
        // Notify observers (e.g. the terminal's pane-rearrange overlay) that the
        // cached tree — including pane geometry — was refreshed.
        onRefreshed?()
        // Detect open PRs for the (now-loaded) sessions off-main; throttled
        // internally so this poll-driven call is cheap most of the time.
        refreshPullRequests()
        // Same shape for the worktree sweep: gated internally by a slow per-repo
        // cadence, so the poll tick costs a dictionary walk almost every time.
        refreshWorktrees()
        // And the Running sweep: ports on a 5s cadence, containers on 30s, both
        // per host and both off this tick — `docker ps` and `lsof` must never
        // ride the 1.5s poll (PR #67).
        refreshRunning()
        if let tree { syncIdleTags(host: host, sessions: tree) }
    }

    /// Keep each window's tmux name tagged with its stage: 🥱, 💤 or neither.
    /// Writes only where the tag must change, so a steady poll is a walk.
    ///
    /// A host with no known agent status is skipped: a failed status scan reads
    /// as "no agents", and acting on it would strip every tag and put them all
    /// back one scan later.
    private func syncIdleTags(host: Host, sessions: [TmuxSession]) {
        guard sessions.contains(where: { $0.windows.contains { $0.attention != .unknown } })
        else { return }
        let service = registry.service(for: host)
        for session in sessions where !Self.isHiddenManagerSession(host, session.name) {
            for window in session.windows {
                let stage = window.idleStage
                guard IdleTag.update(
                    name: window.name, base: window.nameBase, tags: window.nameTags,
                    stage: stage) != nil
                else { continue }
                service.driverQueue.async {
                    service.syncIdleTag(
                        session: session.name, window: window.index, stage: stage,
                        seen: (window.name, window.nameBase, window.nameTags))
                }
            }
        }
    }

    // MARK: viewed threads

    private lazy var viewedThreads = Settings.viewedThreads(now: Int(Date().timeIntervalSince1970))

    /// A host's fresh tree with each pane's `viewed` set. The threads of the
    /// window on screen are marked first, so an agent that finishes while the
    /// user looks at it never shows as not viewed.
    private func stampViewed(_ tree: [TmuxSession], host: Host) -> [TmuxSession] {
        let now = Int(Date().timeIntervalSince1970)
        let onScreen = NSApp.isActive && view.window?.isVisible == true && !isHoverPreviewing
            && selectedHost?.name == host.name
        let open = onScreen ? selectedSessionName : nil
        let before = viewedThreads
        var live = Set<String>()
        for session in tree {
            for window in session.windows {
                for pane in window.panes {
                    let id = MobileSnapshot.threadID(host: host, pane: pane.id)
                    live.insert(id)
                    if session.name == open, window.active {
                        viewedThreads.mark(id, finishedAt: pane.finishedAt, now: now)
                    }
                }
            }
        }
        viewedThreads.prune(host: host.name, live: live)
        if viewedThreads != before { Settings.setViewedThreads(viewedThreads) }
        return tree.map { session in
            session.stamped(viewedThreads) { MobileSnapshot.threadID(host: host, pane: $0) }
        }
    }

    /// The phone has thread `id` on screen: it is viewed here too.
    func markViewed(threadID id: String) {
        for host in hosts {
            guard let tree = sessionsByHost[host.name] else { continue }
            let pane = tree.lazy.flatMap(\.windows).flatMap(\.panes)
                .first { MobileSnapshot.threadID(host: host, pane: $0.id) == id }
            guard let pane else { continue }
            guard viewedThreads.mark(
                id, finishedAt: pane.finishedAt, now: Int(Date().timeIntervalSince1970))
            else { return }
            Settings.setViewedThreads(viewedThreads)
            sessionsByHost[host.name] = tree.map { session in
                session.stamped(viewedThreads) { MobileSnapshot.threadID(host: host, pane: $0) }
            }
            applyRefresh(buildHostNodes())
            onRefreshed?()
            return
        }
    }

    /// Fired on the main thread after each successful refresh. The AppDelegate uses
    /// it to keep the terminal surface's pane geometry (for ⌘⇧-drag rearrange) fresh.
    var onRefreshed: (() -> Void)?

    /// The whole cached tree flattened for the manager agent's `mux sessions`
    /// survey — every host, one row per session, attention folded onto the
    /// active/inactive/waiting vocabulary. The manager's own control session is
    /// left out (it is infrastructure, and it is the thing doing the reading).
    func managerSessionSnapshot() -> [ManagerSessionRow] {
        var rows: [ManagerSessionRow] = []
        for host in hosts {
            for s in sessionsByHost[host.name] ?? []
            where !Self.isHiddenManagerSession(host, s.name) {
                rows.append(ManagerSessionRow(
                    name: s.name,
                    host: host.name,
                    attached: s.attached,
                    state: ManagerSessionRow.State(s.attention),
                    windows: s.windows.count,
                    panes: s.windows.reduce(0) { $0 + $1.panes.count },
                    cwd: s.cwd,
                    windowIndexes: s.windows.map(\.index)))
            }
        }
        return rows
    }

    /// Set by the app delegate: true while a phone is reading host stats.
    var wantsAllHostStats: (() -> Bool)?

    /// The hosts the phone lists: this Mac, then the SERVERS catalog.
    private func mobileHosts() -> [Host] {
        [.local] + RemoteTier.servers(hosts.filter { !$0.isLocal }) { SshIdentity.cached($0) }
    }

    /// The cached tree and host stats as the phone API serves them. Reads only
    /// what the poll already loaded.
    func mobileSnapshot() -> MobileSnapshot {
        MobileSnapshot.build(mobileHosts().map { host in
            MobileHostInput(
                host: host, colorHex: Settings.colorHex(host: host),
                reachability: reachabilityByHost[host.name] ?? .unknown,
                stats: hostStatsByName[host.name],
                sessions: loadedSessions(host: host),
                prs: { [self] session, window in
                    prByWindow[windowKey(host: host, session: session, window: window)] ?? []
                })
        })
    }

    /// The window that holds the pane `paneID` on `host` in the tree as it is
    /// now, for the phone's archive. nil once the pane has gone. The manager's
    /// own session is not looked in.
    func windowRef(paneID: String, host: Host) -> WindowRef? {
        for session in loadedSessions(host: host) {
            if let window = session.windows.first(where: { $0.panes.contains { $0.id == paneID } }) {
                return WindowRef(session: session.name, window: window.index, host: host)
            }
        }
        return nil
    }

    /// `session`'s attention on `host` from the cached tree, or nil when it isn't
    /// loaded. Used to tell whether the manager session is alive (it stays in the
    /// model even though the tree hides it).
    func sessionAttention(_ name: String, host: Host = .local) -> AttentionStatus? {
        (sessionsByHost[host.name] ?? []).first { $0.name == name }?.attention
    }

    /// `host`'s sessions from the cached tree, without the manager's own session —
    /// for the agent toasts, which read hook state off the panes.
    func loadedSessions(host: Host = .local) -> [TmuxSession] {
        (sessionsByHost[host.name] ?? []).filter { !Self.isHiddenManagerSession(host, $0.name) }
    }

    /// The manager agent's own control session is infrastructure, not a peer —
    /// hidden from the tree, the pickers, the `mux sessions` survey and the PR
    /// scan (its `mgr-*` workers stay visible everywhere). It remains in the
    /// loaded model so the app can still tell whether it is alive.
    private static func isHiddenManagerSession(_ host: Host, _ name: String) -> Bool {
        host.isLocal && name == ManagerHome.sessionName
    }

    /// Every session on `host` from the cached tree, the manager's own included —
    /// the close confirm checks all of them for a pane still in a worktree.
    func cachedSessions(host: Host) -> [TmuxSession] {
        sessionsByHost[host.name] ?? []
    }

    /// The panes of `session`'s active window on `host`, from the cached tree — for
    /// the terminal's ⌘⇧-drag rearrange (which needs live pane cell geometry). Empty
    /// when the session/window isn't loaded yet.
    func activeWindowPanes(host: Host, session: String) -> [TmuxPane] {
        let sessions = sessionsByHost[host.name] ?? []
        guard let s = sessions.first(where: { $0.name == session }) else { return [] }
        let window = s.windows.first(where: { $0.active }) ?? s.windows.first
        return window?.panes ?? []
    }

    /// A window of `session` on `host` from the cached tree, plus whether it is
    /// that session's only window — what the ⌘W confirm needs to name what it is
    /// about to kill. `index` nil means "the active window" (⌘W's own target).
    /// nil when the session/window isn't loaded yet.
    func windowForConfirm(
        host: Host, session: String, index: Int? = nil
    ) -> (window: TmuxWindow, isLast: Bool)? {
        guard let s = (sessionsByHost[host.name] ?? []).first(where: { $0.name == session })
        else { return nil }
        let match = index.map { i in s.windows.first { $0.index == i } }
            ?? (s.windows.first { $0.active } ?? s.windows.first)
        guard let match else { return nil }
        return (match, s.windows.count == 1)
    }

    /// Apply a freshly-built tree on the main thread: toggle the empty state,
    /// diff against the current tree, and reload + restore only on real change.
    private func applyRefresh(_ newRoots: [SidebarNode]) {
        defer { repaintCards() }
        // The host level is always present, so the tree is never "empty" the way
        // the local-only build was; hide the empty-state entirely.
        emptyState.isHidden = true
        scroll.isHidden = false

        // Same structure → merge new data into the existing node objects and
        // reload ONLY the rows whose display changed. NSOutlineView keeps its
        // expansion (it's keyed by object identity), so nothing collapses /
        // flickers. A full reloadData happens only when the structure actually
        // changes (a session/window/host added or removed).
        if let changed = Self.mergeInPlace(roots, newRoots) {
            var resized = IndexSet()
            for node in changed where outline.row(forItem: node) >= 0 {
                outline.reloadItem(node)
                resized.insert(outline.row(forItem: node))
            }
            // A line 2 that appears or goes changes the row's height.
            if !resized.isEmpty {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    outline.noteHeightOfRows(withIndexesChanged: resized)
                }
            }
            Diag.log("applyRefresh", "path=merge changedRows=\(changed.count)")
            checkOutlineInvariant("after merge")
            return
        }

        // A real structural change (a session/window/host added or removed). Try to
        // animate it as a fluid collapse/expand by reconciling identities in place;
        // fall back to a plain reload when the change involves a reorder (which we
        // don't animate) or the outline isn't populated yet.
        if animateStructuralChange(into: newRoots) {
            Diag.log("applyRefresh", "path=animate")
            checkOutlineInvariant("after animate")
            return
        }

        // reloadData collapses every row before `restoreExpansion` reopens them, so
        // the clip view clamps to the top on the way. Every reorder (a window
        // moving up in sort-by-recent, a session moving up its list) lands here,
        // so keep the user's scroll across it.
        let scrolledTo = scroll.contentView.bounds.origin
        roots = newRoots
        outline.reloadData()
        restoreExpansion()
        autoExpand()
        restoreSelection()
        scroll.contentView.scroll(to: scrolledTo)
        scroll.reflectScrolledClipView(scroll.contentView)
        Diag.log("applyRefresh", "path=fullReload roots=\(roots.count)")
        checkOutlineInvariant("after fullReload")
    }

    /// Diag-only: every model node whose ancestors are all expanded must own a real
    /// row in the outline, and the visible-node count must equal `numberOfRows`.
    ///
    /// A desync here is both invisible and sticky: the row is simply absent, and
    /// because `mergeInPlace` reloads *cells* without ever re-reading structure, the
    /// outline never recovers on a later poll. That is precisely the "sessions
    /// disappeared until I relaunched" report, so this check names the node that went
    /// missing and the path that lost it.
    private func checkOutlineInvariant(_ context: String) {
        guard Diag.on else { return }
        var missing: [String] = []
        var expectedVisible = 0

        func walk(_ nodes: [SidebarNode], ancestorsExpanded: Bool) {
            for node in nodes {
                let row = outline.row(forItem: node)
                if ancestorsExpanded {
                    expectedVisible += 1
                    if row < 0 { missing.append(node.identity) }
                }
                walk(node.children,
                     ancestorsExpanded: ancestorsExpanded && row >= 0 && outline.isItemExpanded(node))
            }
        }
        walk(roots, ancestorsExpanded: true)

        guard !missing.isEmpty || expectedVisible != outline.numberOfRows else { return }
        Diag.log("INVARIANT", "DESYNC \(context): outlineRows=\(outline.numberOfRows) "
            + "expectedVisible=\(expectedVisible) missingRows=\(missing)")
    }

    /// One level's animated delta: the parent whose children changed (nil = roots),
    /// the indexes removed (into the parent's OLD children) and inserted (into the
    /// parent's NEW children). Collected read-only, then replayed on the outline.
    private struct StructuralOp {
        let parent: SidebarNode?
        let removes: IndexSet
        let inserts: IndexSet
    }

    /// Reconcile the current `roots` into `newRoots`, reusing existing node objects
    /// wherever identity matches (so NSOutlineView keeps their expansion/selection)
    /// and animating inserted/removed rows so a session or window appearing/leaving
    /// reads as a fluid collapse/expand rather than an instant pop. Returns false —
    /// changing nothing — when the delta contains a reorder of surviving rows (out
    /// of scope; animating moves is crash-prone) so the caller can plain-reload.
    private func animateStructuralChange(into newRoots: [SidebarNode]) -> Bool {
        // The outline must already show its current rows to diff against; on the very
        // first population it has none, so let the caller reload instead.
        guard outline.numberOfRows > 0 else { return false }

        var ops: [StructuralOp] = []
        guard let reconciled = reconcile(parent: nil, old: roots, new: newRoots, ops: &ops)
        else { return false }
        guard !ops.isEmpty else { return false }  // no structural delta after all

        // The model is fully updated (surviving objects re-parented, new subtrees
        // attached) before we tell the outline — the animated calls describe the
        // delta against its cached old rows, so remove-before-insert per parent is
        // safe. Parents that gained rows are expanded afterward so a new session
        // reveals its window as part of the same motion.
        roots = reconciled
        var parentsGainingRows: [SidebarNode] = []

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            outline.beginUpdates()
            for op in ops {
                if !op.removes.isEmpty {
                    outline.removeItems(at: op.removes, inParent: op.parent,
                                        withAnimation: [.effectFade, .slideUp])
                }
                if !op.inserts.isEmpty {
                    outline.insertItems(at: op.inserts, inParent: op.parent,
                                        withAnimation: [.effectFade, .slideDown])
                    if let parent = op.parent { parentsGainingRows.append(parent) }
                }
            }
            outline.endUpdates()
        }

        for parent in parentsGainingRows { autoExpand([parent], animated: true) }
        autoExpand(animated: true)
        // Surviving rows took their new data above without a reload, so a line 2
        // that changed in the same poll would keep a stale cell and height. Root
        // headers too: their counts ("WORKTREES (2)") change with every add/remove.
        var lineRows = IndexSet()
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? SidebarNode,
                  node.isWindow || node.isPane || outline.parent(forItem: node) == nil
            else { continue }
            outline.reloadItem(node)
            lineRows.insert(row)
        }
        outline.noteHeightOfRows(withIndexesChanged: lineRows)
        restoreSelection()
        return true
    }

    /// Recursively reconcile `old` children into `new` by identity: reuse the old
    /// object for a surviving row (folding new display data into it and recursing
    /// into its children), mark absent rows for removal and fresh rows for insertion,
    /// appending one `StructuralOp` per changed level to `ops`. Returns the rebuilt
    /// child array, or nil when the surviving rows change order at this level (the
    /// signal for the caller to fall back to a non-animated reload).
    private func reconcile(parent: SidebarNode?, old: [SidebarNode], new: [SidebarNode],
                           ops: inout [StructuralOp]) -> [SidebarNode]? {
        // Reorder guard + index math live in the pure, unit-tested SidebarDiff so
        // NSOutlineView never gets an inconsistent batch. nil ⇒ a move at this level
        // ⇒ caller falls back to a full reload.
        guard let delta = SidebarDiff.levelDelta(oldIDs: old.map(\.identity),
                                                 newIDs: new.map(\.identity)) else { return nil }

        var oldByID: [String: SidebarNode] = [:]
        for n in old { oldByID[n.identity] = n }

        var result: [SidebarNode] = []
        for n in new {
            if let existing = oldByID[n.identity] {
                // Surviving row: fold new data into the same object so the outline
                // keeps its expansion, then reconcile its subtree.
                existing.kind = n.kind
                existing.hostAttention = n.hostAttention
                existing.watched = n.watched
                existing.probing = n.probing
                existing.worktreeMetrics = n.worktreeMetrics
                guard let kids = reconcile(parent: existing, old: existing.children,
                                           new: n.children, ops: &ops) else { return nil }
                existing.children = kids
                result.append(existing)
            } else {
                // Brand-new row: take the freshly built subtree whole (it enters the
                // outline as one unit, so we emit no child ops for it).
                result.append(n)
            }
        }

        if !delta.removes.isEmpty || !delta.inserts.isEmpty {
            ops.append(StructuralOp(parent: parent, removes: delta.removes, inserts: delta.inserts))
        }
        return result
    }

    /// Merge `new` into the existing `old` node objects in place. Returns the list
    /// of existing nodes whose display changed (caller reloads just those cells),
    /// or nil if the STRUCTURE differs (caller does a full reload + restore).
    /// Matching is positional by identity — the tree is built in a stable order.
    private static func mergeInPlace(_ old: [SidebarNode], _ new: [SidebarNode]) -> [SidebarNode]? {
        guard old.count == new.count else { return nil }
        var changed: [SidebarNode] = []
        for (o, n) in zip(old, new) {
            guard o.identity == n.identity else { return nil }
            guard let childChanged = mergeInPlace(o.children, n.children) else { return nil }
            changed.append(contentsOf: childChanged)
            if o.diffDisplay != n.diffDisplay {
                o.kind = n.kind  // update data in place; keep the object identity
                o.hostAttention = n.hostAttention  // host rollup folds into display
                o.watched = n.watched
                o.probing = n.probing
                o.worktree = n.worktree  // folded into display; carry it with the data
                o.worktreeMetrics = n.worktreeMetrics
                changed.append(o)
            }
        }
        return changed
    }

    /// Sessions, windows, the local host, and herdr default to expanded so the
    /// structure is visible without clicking — unless the user explicitly
    /// collapsed that node. Remote hosts stay lazy (expanding them probes/loads),
    /// and the Servers group stays closed by design.
    private func autoExpand(_ nodes: [SidebarNode]? = nil, animated: Bool = false) {
        for node in nodes ?? roots {
            if Self.autoExpands(node), !collapsedByUser.contains(node.identity) {
                // Animated during a structural change so a freshly inserted session
                // unfurls to reveal its window; instant otherwise (initial load).
                (animated ? outline.animator() : outline).expandItem(node)
            }
            autoExpand(node.children, animated: animated)
        }
    }

    private static func autoExpands(_ node: SidebarNode) -> Bool {
        switch node.kind {
        case .host(let h, _): return h.isLocal
        // A server's stat card stays open across relaunches once opened.
        case .serverButton(let h, _, _): return Settings.hostExpanded(h)
        case .directory, .herdr, .session, .window: return true
        // Active opens by default; Servers stays closed by design.
        case .activeGroup, .serversGroup: return true
        // WORKTREES stays CLOSED by default. It is a pile, not a working surface —
        // on this Mac it is 81 rows. Auto-expanding it buried the tree it was meant
        // to sit beside. The header alone ("WORKTREES (81)") is the signal; open it
        // when you want the list.
        case .worktreesGroup: return false
        default: return false
        }
    }

    /// Whether `baseIdentity` (an un-namespaced node identity like a host's
    /// "H:box" or "HERDR") is expanded in either section. Host-mode subtrees are
    /// tagged "A/" (Active) or "S/" (Servers); the bare base covers directory mode
    /// and any un-tagged tree.
    private static func isExpandedInAnySection(
        _ baseIdentity: String, in expanded: Set<String>
    ) -> Bool {
        expanded.contains("A/" + baseIdentity)
            || expanded.contains("S/" + baseIdentity)
            || expanded.contains(baseIdentity)
    }

    /// Whether `kind` is an uppercase section header (Active / Servers /
    /// Worktrees) — they share the muted-header cell styling.
    private static func isSectionHeader(_ kind: SidebarNode.Kind) -> Bool {
        switch kind {
        case .activeGroup, .serversGroup, .worktreesGroup: return true
        default: return false
        }
    }

    /// Every discovered tmux session across all hosts. Host order (local first,
    /// then remotes as loaded); within a host, tree order. Herdr sessions are
    /// excluded — the switchers attach via tmux.
    func switcherSessions() -> [(session: String, host: Host, service: TmuxService)] {
        hosts.flatMap { host in
            (sessionsByHost[host.name] ?? [])
                .filter { !Self.isHiddenManagerSession(host, $0.name) }
                .map { (session: $0.name, host: host, service: registry.service(for: host)) }
        }
    }

    /// The loaded session trees per host, for the ⌘K switcher's session, window
    /// and pane rows. Same order and hidden-manager filter as `switcherSessions`.
    func switcherTree() -> [(host: Host, sessions: [TmuxSession])] {
        hosts.map { host in
            (host: host, sessions: (sessionsByHost[host.name] ?? [])
                .filter { !Self.isHiddenManagerSession(host, $0.name) })
        }
    }

    /// Every window on every host, flat, in sidebar order — the ⌘` cycler's
    /// universe. Same hidden-manager filter as `switcherSessions`, one level down.
    func switcherWindows() -> [(ref: WindowRef, name: String)] {
        hosts.flatMap { host -> [(ref: WindowRef, name: String)] in
            (sessionsByHost[host.name] ?? [])
                .filter { !Self.isHiddenManagerSession(host, $0.name) }
                .flatMap { session in
                    session.windows.map {
                        (ref: WindowRef(session: session.name, window: $0.index, host: host),
                         name: $0.name)
                    }
                }
        }
    }

    /// The active window index of `session` on `host` in the loaded tree — the
    /// window an attach to that session lands on. nil when the session isn't
    /// loaded (or has no windows yet).
    func activeWindow(session: String, host: Host) -> Int? {
        guard let s = (sessionsByHost[host.name] ?? []).first(where: { $0.name == session })
        else { return nil }
        return (s.windows.first(where: \.active) ?? s.windows.first)?.index
    }

    /// The cached favicon for a session's working directory, resolving it off-main
    /// on first ask. Only local hosts are scanned (a remote cwd isn't on this disk).
    /// Returns a cached hit immediately; returns nil while missing/scanning and
    /// kicks off a background scan that reloads the affected rows when it lands.
    private func favicon(for cwd: String, host: Host) -> NSImage? {
        guard host.isLocal, !cwd.isEmpty else { return nil }
        if let hit = faviconByCwd[cwd] { return hit }
        if faviconMisses.contains(cwd) || faviconScanning.contains(cwd) { return nil }
        faviconScanning.insert(cwd)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = Favicon.load(dir: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.faviconScanning.remove(cwd)
                if let image {
                    self.faviconByCwd[cwd] = image
                    self.reloadSessionRows(cwd: cwd)
                } else {
                    self.faviconMisses.insert(cwd)
                }
            }
        }
        return nil
    }

    /// Reload every session row whose cwd matches `cwd` (a favicon just resolved).
    private func reloadSessionRows(cwd: String) {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? SidebarNode,
                  case .session(_, let session) = node.kind, session.cwd == cwd else { continue }
            outline.reloadItem(node)
        }
    }

    /// The cached favicon for a named session on `host`, for the ⌘` cycler overlay.
    /// Resolves via the shared cache (kicking off a scan on a miss).
    func faviconForSession(_ name: String, host: Host) -> NSImage? {
        guard let session = (sessionsByHost[host.name] ?? []).first(where: { $0.name == name })
        else { return nil }
        return favicon(for: session.cwd, host: host)
    }

    /// The worktree chip for a session's working directory, resolving the
    /// classification off-main on first ask. Mirrors `favicon(for:host:)`: cached
    /// hit returns immediately, a miss returns nil and kicks off one background
    /// probe that reloads the affected rows when it lands.
    ///
    /// Local hosts only for now. The 2026-08-19 incident was local, and a remote
    /// sweep means ssh round-trips per repo — with state 3 doing a `git fetch` over
    /// ssh — which is a different cost conversation.
    private func worktreeBadge(for cwd: String, host: Host) -> WorktreeBadge? {
        guard host.isLocal, !cwd.isEmpty else { return nil }
        if let hit = worktreeByCwd[cwd] {
            return WorktreeBadge(kind: hit.kind, work: work(forCwd: cwd, repo: hit.commonDir))
        }
        if worktreeMisses.contains(cwd) || worktreeScanning.contains(cwd) { return nil }
        worktreeScanning.insert(cwd)
        let service = registry.service(for: host)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = service.worktreeInfo(cwd: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.worktreeScanning.remove(cwd)
                Diag.log("worktree", "classify \(cwd) → "
                    + (info.map { "\($0.kind.rawValue) repo=\($0.commonDir)" } ?? "not a repo"))
                if let info {
                    self.worktreeByCwd[cwd] = info
                    self.reloadSessionRows(cwd: cwd)
                } else {
                    self.worktreeMisses.insert(cwd)
                }
            }
        }
        return nil
    }

    /// The sweep's verdict for the worktree containing `cwd`. `.unknown` until the
    /// first sweep of that repo lands — the badge degrades to "not computed yet",
    /// never to a wrong claim of "safe to delete".
    private func work(forCwd cwd: String, repo: String) -> WorktreeWork {
        guard let entry = (worktreesByRepo[repo] ?? []).first(
            where: { Worktrees.isInside(path: cwd, root: $0.path) }) else { return .unknown }
        return worktreeWorkByPath[entry.path] ?? .unknown
    }

    /// Sweep each known local repo for its worktrees and which of them hold unique
    /// work. Runs off the poll tick but on `worktreeScanner`'s slow per-repo cadence
    /// (10 min, backing off to an hour), because this path runs `git fetch` — real
    /// network I/O — and is bounded by the same concurrency gate as the PR scan so
    /// an ungated fan-out can't become N simultaneous fetches.
    ///
    /// Repos are the distinct `--git-common-dir` values across local session cwds:
    /// no config, no repo list to maintain. Reading the real cwd is also why a
    /// stale `treehouse status` label can't fool this.
    /// Drop a worktree spindown just removed, so its row goes now rather than at
    /// the next sweep (up to 10 minutes away).
    func forgetWorktree(path: String) {
        let gone = Worktrees.normalize(path)
        worktreesByRepo = worktreesByRepo.mapValues { $0.filter { $0.path != gone } }
        refresh()
    }

    func refreshWorktrees(force: Bool = false) {
        guard !isScanningWorktrees else { return }

        // Snapshot on main: one probe cwd per repo, from the already-classified
        // session cwds (so this adds no classification work of its own).
        var probeByRepo: [String: String] = [:]
        for host in hosts where host.isLocal {
            for s in sessionsByHost[host.name] ?? [] {
                guard let info = worktreeByCwd[s.cwd] else { continue }
                probeByRepo[info.commonDir] = s.cwd
            }
        }
        let now = Date()
        if force { worktreeScanner.forceAll() }
        worktreeScanner.retain(Set(probeByRepo.keys))
        let due = probeByRepo.filter { worktreeScanner.isDue($0.key, now: now) }
        Diag.log("worktree", "sweep repos=\(probeByRepo.count) due=\(due.count) "
            + "classified=\(worktreeByCwd.count) misses=\(worktreeMisses.count)")
        guard !due.isEmpty else { return }

        isScanningWorktrees = true
        for repo in due.keys { worktreeScanner.begin(repo) }
        let service = registry.local
        let targets = due.map { (repo: $0.key, cwd: $0.value) }.sorted { $0.repo < $1.repo }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Same gate discipline as `refreshPullRequests`: acquire on THIS
            // coordinator thread before dispatching, so at most N worker blocks are
            // ever live rather than M blocks all parked on the semaphore.
            let gate = DispatchSemaphore(value: Self.maxConcurrentPRScans)
            let group = DispatchGroup()
            let lock = NSLock()
            var lists: [String: [WorktreeEntry]] = [:]
            var work: [String: WorktreeWork] = [:]
            var metrics: [String: WorktreeMetrics] = [:]

            // ONE `docker ps` for the whole sweep, bounded by
            // `TmuxService.slowCommandTimeout` — never per worktree, never on the
            // poll. Timeout, dead daemon and missing binary all read "unknown".
            let docker = service.dockerSnapshot()

            for t in targets {
                gate.wait()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    // One fetch per repo (worktrees share the object store), then
                    // one dirty/cherry pass per worktree.
                    service.fetchOrigin(cwd: t.cwd)
                    let entries = service.worktrees(cwd: t.cwd)
                    // Per-repo context: the lease table (treehouse must run from the
                    // main checkout) and the extensions this repo authors.
                    let mainPath = entries.first(where: \.isMain)?.path ?? t.cwd
                    let leases = Dictionary(
                        service.treehouseStatus(repo: mainPath).map { ($0.path, $0) },
                        uniquingKeysWith: { _, new in new })
                    let exts = service.authoredExtensions(repo: mainPath)

                    var found: [String: WorktreeWork] = [:]
                    var foundMetrics: [String: WorktreeMetrics] = [:]
                    for e in entries {
                        // One `git status` feeds both the work verdict and the row's
                        // file names.
                        let status = service.worktreeStatus(cwd: e.path)
                        let w = status.map { service.worktreeWork(cwd: e.path, status: $0) } ?? .unknown
                        found[e.path] = w
                        guard !e.isMain else { continue }

                        var m = WorktreeMetrics()
                        m.lastUsed = service.worktreeLastUsed(path: e.path)
                        m.changes = status.map {
                            WorktreeChanges.parse(porcelain: $0, authoredExtensions: exts)
                        }
                        m.docker = Docker.attribute(
                            snapshot: docker, path: e.path,
                            supabaseProjectID: service.supabaseProjectID(root: e.path))
                        m.lease = leases[e.path]
                        // Only a scratch-only tree needs the commit check: it decides
                        // `scratch` vs `work`. Everywhere else it can't change the chip.
                        if w == .unique, m.changes?.isScratchOnly == true {
                            switch service.worktreeCommitWork(cwd: e.path) {
                            case .unique: m.hasUnpushedCommits = true
                            case .none: m.hasUnpushedCommits = false
                            case .unknown: m.hasUnpushedCommits = nil
                            }
                        }
                        foundMetrics[e.path] = m
                    }
                    lock.lock()
                    lists[t.repo] = entries
                    work.merge(found) { _, new in new }
                    metrics.merge(foundMetrics) { _, new in new }
                    lock.unlock()
                    gate.signal()
                    group.leave()
                }
            }
            group.wait()

            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanningWorktrees = false
                let done = Date()
                for t in targets {
                    // An empty list means git failed (a real repo always lists at
                    // least its own checkout) — back that repo off.
                    if (lists[t.repo] ?? []).isEmpty {
                        self.worktreeScanner.recordFailure(t.repo, now: done)
                    } else {
                        self.worktreeScanner.recordSuccess(t.repo, now: done)
                    }
                }
                Diag.log("worktree", "swept " + targets.map {
                    "\(($0.repo as NSString).lastPathComponent):\((lists[$0.repo] ?? []).count)wt"
                }.joined(separator: " ")
                    + " unique=\(work.values.filter { $0 == .unique }.count)")
                let unchanged = self.worktreesByRepo == lists
                    && self.worktreeWorkByPath == work
                    && metrics.allSatisfy { self.worktreeMetricsByPath[$0.key] == $0.value }
                guard !unchanged else { return }
                self.worktreesByRepo.merge(lists) { _, new in new }
                self.worktreeWorkByPath.merge(work) { _, new in new }
                self.worktreeMetricsByPath.merge(metrics) { _, new in new }
                // Both the orphan section's contents and the session chips derive
                // from this, so rebuild — `applyRefresh` diffs and only repaints
                // the rows that actually changed.
                self.applyRefresh(self.buildHostNodes())
            }
        }
    }

    // MARK: Running sweep

    /// Ask every reachable host what it is running: one `lsof` for its listening
    /// ports, one `docker ps` for its containers, and — only for panes that
    /// actually hold a port — one batched scrollback capture to read the URL the
    /// server printed.
    ///
    /// Never on the poll tick's own thread and never per pane: at most three
    /// subprocesses per host per sweep, under the same `maxConcurrentPRScans`
    /// gate as the PR and worktree sweeps. The two cadences differ because the
    /// costs do — see `runningPortScanner` / `runningDockerScanner`.
    func refreshRunning(force: Bool = false) {
        guard !isScanningRunning else { return }
        let now = Date()
        if force {
            runningPortScanner.forceAll()
            runningDockerScanner.forceAll()
        }
        let names = Set(hosts.map(\.name))
        runningPortScanner.retain(names)
        runningDockerScanner.retain(names)

        // Snapshot on main: the panes each host holds, with the pid that roots
        // each pane's process tree.
        var panePidsByHost: [String: [Int: String]] = [:]
        var panesByHost: [String: [TmuxPane]] = [:]
        for host in hosts {
            var pids: [Int: String] = [:]
            var panes: [TmuxPane] = []
            for session in sessionsByHost[host.name] ?? [] {
                for window in session.windows {
                    for pane in window.panes {
                        panes.append(pane)
                        if pane.pid > 0 { pids[pane.pid] = pane.id }
                    }
                }
            }
            panePidsByHost[host.name] = pids
            panesByHost[host.name] = panes
        }

        // One box, one sweep: `Host host3 host3-server` in ~/.ssh/config is two
        // aliases for one machine, and scanning both listed every container on it
        // twice — once per alias.
        let targets = Self.dedupedByMachine(hosts).filter { host in
            guard reachabilityByHost[host.name] != .unreachable else { return false }
            return runningPortScanner.isDue(host.name, now: now)
                || runningDockerScanner.isDue(host.name, now: now)
        }
        guard !targets.isEmpty else { return }

        let work = targets.map { host -> (host: Host, ports: Bool, docker: Bool, cwds: [String]) in
            let cwds = Set((panesByHost[host.name] ?? []).map(\.path).filter { !$0.isEmpty })
            return (host,
                    runningPortScanner.isDue(host.name, now: now),
                    runningDockerScanner.isDue(host.name, now: now),
                    cwds.sorted())
        }
        for t in work {
            if t.ports { runningPortScanner.begin(t.host.name) }
            if t.docker { runningDockerScanner.begin(t.host.name) }
        }
        isScanningRunning = true

        let registry = self.registry
        let knownIDs = supabaseIDByCwd
        let knownMisses = supabaseIDMisses
        let knownURLs = urlByHostPort
        let knownBranches = branchByCwd

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Acquire on THIS coordinator thread before dispatching, so at most N
            // worker blocks are ever live — the discipline `refreshWorktrees`
            // and `refreshPullRequests` already use.
            let gate = DispatchSemaphore(value: Self.maxConcurrentPRScans)
            let group = DispatchGroup()
            let lock = NSLock()
            var scans: [String: RunningHostScan] = [:]
            var okPorts: [String: Bool] = [:]
            var okDocker: [String: Bool] = [:]
            var ids: [String: String] = [:]
            var idMisses: [String] = []
            var branches: [String: String] = [:]
            var urls: [String: String] = [:]

            for t in work {
                gate.wait()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let service = registry.service(for: t.host)
                    let panePids = panePidsByHost[t.host.name] ?? [:]
                    // Resolve (and memoize) this alias's machine identity off-main,
                    // so the NEXT sweep can collapse `Host buildbox buildbox-hermes`
                    // into one host. Until it resolves, both are scanned and every
                    // container on that box is listed twice.
                    _ = SshIdentity.canonical(t.host)
                    // …and the name a browser HERE can open for that box. An ssh
                    // alias is not a DNS name, so this is what the rail's ↗ links
                    // are built from. Same thread, cached after the first sweep.
                    let address = HostAddress.resolve(t.host)

                    var listeners: [ListeningPort]?
                    var ppids: [Int: Int] = [:]
                    if t.ports {
                        listeners = service.listeningPorts()
                        if listeners != nil { ppids = service.processTable() }
                    }
                    // Attributed here only to find the panes worth capturing
                    // scrollback for; the rail re-attributes against the live
                    // tree when it renders.
                    let byPane = listeners.map {
                        Running.portsByPane(
                            listeners: $0, panePidToId: panePids, ppids: ppids)
                    } ?? [:]

                    // Read the URL a server printed, for panes that hold a port
                    // we have not resolved yet. One tmux invocation for the lot.
                    let unresolved = byPane.filter { _, ports in
                        ports.contains { knownURLs["\(t.host.name)|\($0.port)"] == nil }
                    }
                    if !unresolved.isEmpty {
                        let captures = service.capturePanes(
                            Array(unresolved.keys).sorted(), lines: Self.runningCaptureLines)
                        for (pane, ports) in unresolved {
                            let lines = captures[pane] ?? []
                            for listener in ports {
                                let key = "\(t.host.name)|\(listener.port)"
                                guard knownURLs[key] == nil else { continue }
                                let printed = Running.urlFromScrollback(
                                    lines, port: listener.port, host: t.host.name)
                                urls[key] = Running.serverURL(
                                    port: listener.port, host: t.host.name, address: address,
                                    scrollbackURL: printed,
                                    probe: { service.probeHTTPS(port: listener.port) })
                            }
                        }
                    }

                    let docker = t.docker ? service.dockerSnapshot() : nil

                    // The two directory keys. `project_id` is cached for the
                    // life of the process; the branch is re-read each sweep
                    // because it moves.
                    for cwd in t.cwds {
                        if knownIDs[cwd] == nil, !knownMisses.contains(cwd) {
                            if let id = service.supabaseProjectID(root: cwd) {
                                ids[cwd] = id
                            } else {
                                idMisses.append(cwd)
                            }
                        }
                        // A branch moves, so it is re-read — but on the SLOW
                        // cadence, not every five seconds per checkout.
                        if knownBranches[cwd] == nil || t.docker,
                           let branch = service.currentBranch(cwd: cwd) {
                            branches[cwd] = branch
                        }
                    }

                    lock.lock()
                    scans[t.host.name] = RunningHostScan(
                        host: t.host.name,
                        docker: docker ?? .unavailable,
                        listeners: listeners,
                        ppids: ppids,
                        address: address)
                    if t.ports { okPorts[t.host.name] = listeners != nil }
                    if t.docker { okDocker[t.host.name] = docker != nil && docker != .unavailable }
                    lock.unlock()
                    gate.signal()
                    group.leave()
                }
            }
            group.wait()

            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanningRunning = false
                let done = Date()
                for (host, ok) in okPorts {
                    ok ? self.runningPortScanner.recordSuccess(host, now: done)
                       : self.runningPortScanner.recordFailure(host, now: done)
                }
                for (host, ok) in okDocker {
                    if ok { self.dockerEverAnswered.insert(host) }
                    ok ? self.runningDockerScanner.recordSuccess(host, now: done)
                       : self.runningDockerScanner.recordFailure(host, now: done)
                }
                self.supabaseIDByCwd.merge(ids) { _, new in new }
                self.supabaseIDMisses.formUnion(idMisses)
                self.branchByCwd.merge(branches) { _, new in new }
                self.urlByHostPort.merge(urls) { _, new in new }

                // A sweep that only refreshed the ports must not erase the
                // container half of that host's answer, and vice versa.
                for (host, fresh) in scans {
                    let old = self.runningScans[host]
                    self.runningScans[host] = RunningHostScan(
                        host: host,
                        docker: okDocker[host] == nil ? (old?.docker ?? .unavailable) : fresh.docker,
                        listeners: okPorts[host] == nil ? old?.listeners : fresh.listeners,
                        ppids: okPorts[host] == nil ? (old?.ppids ?? [:]) : fresh.ppids,
                        address: fresh.address)
                }
                let containers = self.runningScans.values.reduce(0) { sum, scan in
                    if case .containers(let list) = scan.docker { return sum + list.count }
                    return sum
                }
                let ports = self.runningScans.values.reduce(0) { $0 + ($1.listeners?.count ?? 0) }
                Diag.log("running", "swept " + work.map {
                    "\($0.host.name)\($0.ports ? "+ports" : "")\($0.docker ? "+docker" : "")"
                }.joined(separator: " ") + " containers=\(containers) listeners=\(ports)")
                self.onRunningChanged?()
            }
        }
    }

    /// How far back a pane's scrollback is read for the URL its server printed.
    /// Deep enough to clear a noisy request log, shallow enough that a dozen
    /// panes stay well under a megabyte of capture.
    private static let runningCaptureLines = 500

    /// Every pane MuxMaestro can see, on every host, reduced to the two keys that
    /// claim a resource. The *unclaimed* group is "everything none of these
    /// claims", so it has to be the whole list, not the selection's.
    private func allRunningPanes(scans: [RunningHostScan]) -> [RunningPane] {
        hosts.flatMap { host -> [RunningPane] in
            (sessionsByHost[host.name] ?? []).flatMap { session in
                session.windows.flatMap { window in
                    window.panes.map { runningPane($0, host: host, scans: scans) }
                }
            }
        }
    }

    private func runningPane(_ pane: TmuxPane, host: Host, scans: [RunningHostScan]) -> RunningPane {
        let cwd = pane.path
        let ports = scans.first { $0.host == host.name }?.portsByPane[pane.id] ?? []
        var urls: [Int: String] = [:]
        for listener in ports {
            if let url = urlByHostPort["\(host.name)|\(listener.port)"] {
                urls[listener.port] = url
            }
        }
        return RunningPane(
            paneID: pane.id,
            host: host.name,
            cwd: cwd,
            supabaseProjectID: supabaseIDByCwd[cwd],
            stackID: branchByCwd[cwd].map(Running.stackID(branch:)),
            urls: urls)
    }

    /// What `pane` alone has running, for the Artifacts panel's Servers.
    func runningSet(forPane pane: TmuxPane, host: Host) -> RunningSet {
        let scans = attributedScans
        return Running.resources(pane: runningPane(pane, host: host, scans: scans), scans: scans)
    }

    /// The same for the pane `paneID` names on `host` in the tree as it is
    /// now, for the phone. nil once the pane has gone.
    func runningSet(paneID: String, host: Host) -> RunningSet? {
        for session in sessionsByHost[host.name] ?? [] {
            for window in session.windows {
                if let pane = window.panes.first(where: { $0.id == paneID }) {
                    return runningSet(forPane: pane, host: host)
                }
            }
        }
        return nil
    }

    /// What the rail shows for the current selection.
    ///
    /// A pane is a flat list of its own. A window is that window, named. A
    /// session or a host header is one group per window, plus the *unclaimed*
    /// group — which appears ONLY here, never repeated under every pane.
    func runningGroupsForSelection() -> [RunningGroup] {
        let scans = attributedScans
        guard let node = selectedNode else { return [] }
        let host = node.host

        func panes(of window: TmuxWindow) -> [RunningPane] {
            window.panes.map { runningPane($0, host: host, scans: scans) }
        }
        func windows(of session: String) -> [TmuxWindow] {
            (sessionsByHost[host.name] ?? []).first { $0.name == session }?.windows ?? []
        }
        func groups(for sessionWindows: [TmuxWindow]) -> [RunningGroup] {
            sessionWindows.map { window in
                RunningGroup(
                    title: Self.runningGroupTitle(window),
                    set: Running.resources(panes: panes(of: window), scans: scans))
            } + [RunningGroup(
                title: "unclaimed",
                set: Running.unclaimed(scans: scans, panes: allRunningPanes(scans: scans)))]
        }

        switch node.kind {
        case .pane(let host, _, _, let pane):
            return [RunningGroup(
                title: nil,
                set: Running.resources(
                    pane: runningPane(pane, host: host, scans: scans), scans: scans))]
        case .window(_, _, let window):
            return [RunningGroup(
                title: Self.runningGroupTitle(window),
                set: Running.resources(panes: panes(of: window), scans: scans))]
        case .session(_, let session):
            return groups(for: session.windows)
        case .host:
            return groups(for: (sessionsByHost[host.name] ?? []).flatMap(\.windows))
        default:
            return []
        }
    }

    /// A window group's header. `nameBase` is only filled when the name carries an
    /// idle tag, so it is empty for most windows — falling back to it alone left
    /// every group reading "0: ".
    private static func runningGroupTitle(_ window: TmuxWindow) -> String {
        let name = window.nameBase.isEmpty ? window.name : window.nameBase
        return "\(window.index): \(name)"
    }

    /// Detect the pull requests each loaded **window** is about, off the main
    /// thread, then reload only the rows whose PR set changed.
    ///
    /// A window's PRs are the union of the numbers declared for it — the `@mm_prs`
    /// window option an agent set (resolved against `@mm_repo` when present), then
    /// the numbers in its NAME — and the open PR for its cwd's branch; see
    /// `WindowPRs`. The branch half is one `gh pr list` per unique (host, cwd),
    /// exactly as before. The declared half is one `gh pr view` per unresolved
    /// (slug, number), cached by
    /// `prIdentityCache` so a number resolves once and merged/closed PRs and
    /// misses are never asked about again.
    ///
    /// Throttled to ~20s between poll-driven scans so gh isn't hit every tree
    /// refresh; pass `force` to bypass. Both fan-outs run through the same
    /// `maxConcurrentPRScans` gate — this repo already paid once for a subprocess
    /// storm on the 1.5s poll (PR #67).
    func refreshPullRequests(force: Bool = false) {
        guard !isScanningPRs else { return }
        if !force, let last = lastPRScan, Date().timeIntervalSince(last) < 20 { return }

        // Snapshot targets on main: every window across sessions, with the window's
        // cwd (from the loaded pane data — no extra tmux calls) and the PR numbers
        // declared for it via `@mm_prs` and its name (pure string work, cheap
        // enough for the main thread).
        struct Target {
            let key: String
            let cwdKey: String
            let cwd: String
            let sessionKey: String
            let session: String
            let window: Int
            let declared: [Int]
            let declaredPRs: [Int]
            let declaredRepo: String
            let service: TmuxService
        }
        var targets: [Target] = []
        for host in hosts {
            let service = registry.service(for: host)
            for s in sessionsByHost[host.name] ?? []
            where !Self.isHiddenManagerSession(host, s.name) {
                for w in s.windows {
                    targets.append(Target(
                        key: windowKey(host: host, session: s.name, window: w.index),
                        cwdKey: "\(host.name)\n\(w.cwd)",
                        cwd: w.cwd,
                        sessionKey: "\(host.name)\n\(s.name)",
                        session: s.name,
                        window: w.index,
                        declared: WindowPRs.declaredNumbers(metadata: w.declaredPRs, name: w.name),
                        declaredPRs: w.declaredPRs,
                        declaredRepo: w.declaredRepo,
                        service: service))
                }
            }
        }
        guard !targets.isEmpty else { return }
        isScanningPRs = true
        lastPRScan = Date()
        let cache = prIdentityCache

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Phase 1 — branch PRs. Dedupe by (host, cwd) so windows sharing a repo
            // make one gh call; the call also hands back the repo slug, which
            // phase 2 needs and would otherwise re-derive.
            var seen = Set<String>()
            var uniques: [(cwdKey: String, cwd: String, service: TmuxService)] = []
            for t in targets where !t.cwd.isEmpty && seen.insert(t.cwdKey).inserted {
                uniques.append((t.cwdKey, t.cwd, t.service))
            }
            // Cap concurrent `gh`/`git` fan-out. Each lookup runs a few subprocesses
            // (each spawning its own reader/waiter threads), so one async per repo
            // across many open repos could push the process past the GCD 64-thread
            // soft limit. Acquire the gate on THIS coordinator thread *before*
            // dispatching so at most `maxConcurrentPRScans` worker blocks are ever
            // live (not M blocks all parked on the semaphore).
            let gate = DispatchSemaphore(value: Self.maxConcurrentPRScans)
            let group = DispatchGroup()
            let lock = NSLock()
            var prsByCwd: [String: [PullRequest]] = [:]
            var slugByCwd: [String: String] = [:]
            for u in uniques {
                gate.wait()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let found = u.service.branchPullRequests(cwd: u.cwd)
                    lock.lock()
                    prsByCwd[u.cwdKey] = found.prs
                    if let slug = found.slug { slugByCwd[u.cwdKey] = slug }
                    lock.unlock()
                    gate.signal()
                    group.leave()
                }
            }
            group.wait()

            // Phase 2 — validate the declared numbers. A window's `@mm_repo` names
            // the repo outright; otherwise a window whose own cwd isn't a checkout
            // (watcher windows often aren't) falls back to the slug its session's
            // other windows agree on.
            var slugsBySession: [String: [String?]] = [:]
            for t in targets {
                slugsBySession[t.sessionKey, default: []].append(slugByCwd[t.cwdKey])
            }
            var declaredSlug: [String: String] = [:]   // target key -> slug
            var wanted: [(slug: String, number: Int, service: TmuxService)] = []
            var wantedSeen = Set<String>()
            for t in targets where !t.declared.isEmpty {
                guard let slug = WindowPRs.slugForDeclared(
                    declaredRepo: t.declaredRepo,
                    windowSlug: slugByCwd[t.cwdKey],
                    sessionSlugs: slugsBySession[t.sessionKey] ?? []) else { continue }
                declaredSlug[t.key] = slug
                for n in t.declared where cache.needsFetch(slug: slug, number: n) {
                    if wantedSeen.insert(PRIdentityCache.key(slug: slug, number: n)).inserted {
                        wanted.append((slug, n, t.service))
                    }
                }
            }
            if !wanted.isEmpty {
                let group2 = DispatchGroup()
                for w in wanted {
                    gate.wait()
                    group2.enter()
                    DispatchQueue.global(qos: .utility).async {
                        // nil is a real answer here: that number is not a PR in that
                        // repo, and the cache remembers the miss so we never re-ask.
                        let pr = w.service.pullRequest(slug: w.slug, number: w.number)
                        cache.store(slug: w.slug, number: w.number, pr: pr)
                        gate.signal()
                        group2.leave()
                    }
                }
                group2.wait()
            }

            var found: [String: [PullRequest]] = [:]
            for t in targets {
                let branch = t.cwd.isEmpty ? [] : (prsByCwd[t.cwdKey] ?? [])
                var declared: [PullRequest] = []
                if let slug = declaredSlug[t.key] {
                    declared = t.declared.compactMap { cache.pr(slug: slug, number: $0) }
                }
                found[t.key] = WindowPRs.merge(declared: declared, branch: branch)
            }

            // Write detected open PRs back into each window's `@mm_prs`, so the
            // window keeps them after its branch moves on or the PR merges. Additive
            // only, and only PRs from the repo those numbers are read against (see
            // `WindowPRs.backfill`). Deliberately ahead of the unchanged-result early
            // return below: after a tmux server restart `prByWindow` can match while
            // `@mm_prs` is empty, and repopulating it is the point.
            for t in targets {
                let readSlug = WindowPRs.slugForDeclared(
                    declaredRepo: t.declaredRepo,
                    windowSlug: slugByCwd[t.cwdKey],
                    sessionSlugs: slugsBySession[t.sessionKey] ?? [])
                guard let value = WindowPRs.backfill(
                    declared: t.declaredPRs, found: found[t.key] ?? [], readSlug: readSlug)
                else { continue }
                t.service.driverQueue.async {
                    t.service.setWindowUserOption(
                        session: t.session, window: t.window, key: WindowPRs.prsOptionKey,
                        value: value.map(String.init).joined(separator: " "))
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanningPRs = false
                guard self.prByWindow != found else { return }
                let old = self.prByWindow
                self.prByWindow = found
                // Reload only the window rows whose PR set actually changed.
                var rows = IndexSet()
                for row in 0..<self.outline.numberOfRows {
                    guard let node = self.outline.item(atRow: row) as? SidebarNode,
                          case .window(let host, let session, let w) = node.kind else { continue }
                    let key = self.windowKey(host: host, session: session, window: w.index)
                    if old[key] ?? [] != found[key] ?? [] { rows.insert(row) }
                }
                if !rows.isEmpty {
                    self.outline.reloadData(forRowIndexes: rows,
                                            columnIndexes: IndexSet(integer: 0))
                }
                self.onPullRequestsChanged?()
            }
        }
    }

    /// Every session that has ≥1 open PR across its windows, for the toolbar "PRs"
    /// dropdown — the union of its windows' PRs (deduped by number). Host order
    /// (local first), then tree order.
    func sessionsWithPullRequests() -> [(host: Host, session: String, prs: [PullRequest])] {
        var out: [(host: Host, session: String, prs: [PullRequest])] = []
        for host in hosts {
            for s in sessionsByHost[host.name] ?? [] {
                var prs: [PullRequest] = []
                var seen = Set<Int>()
                for w in s.windows {
                    // Open only: window rows now also chip the merged/closed PRs a
                    // window's NAME watches, but the toolbar item counts work in
                    // flight and would read wrong if it included those.
                    for pr in prByWindow[windowKey(host: host, session: s.name, window: w.index)] ?? []
                    where pr.state == .open {
                        if seen.insert(pr.number).inserted { prs.append(pr) }
                    }
                }
                if !prs.isEmpty { out.append((host, s.name, prs)) }
            }
        }
        return out
    }

    /// Every PR a window is about, with the windows about it — the PRs screen's
    /// data. Unlike `sessionsWithPullRequests()` this keeps merged and closed PRs.
    func pullRequestIndex() -> [PullRequestsViewController.Entry] {
        var windows: [(window: PullRequestsViewController.WindowRow, prs: [PullRequest])] = []
        for host in hosts {
            for s in sessionsByHost[host.name] ?? []
            where !Self.isHiddenManagerSession(host, s.name) {
                for w in s.windows {
                    let prs = prByWindow[windowKey(host: host, session: s.name, window: w.index)] ?? []
                    guard !prs.isEmpty else { continue }
                    let row = PullRequestsViewController.WindowRow(
                        ref: WindowRef(session: s.name, window: w.index, host: host),
                        name: w.name, attention: w.attention)
                    windows.append((row, prs))
                }
            }
        }
        return WindowPRs.index(windows).map { .init(slug: $0.slug, pr: $0.pr, windows: $0.windows) }
    }

    /// The window whose pane runs the Claude or Codex conversation `id`, if any
    /// is live. Lets the PRs screen jump to a running session instead of
    /// resuming a second copy of it.
    func windowRunning(agentSessionId id: String) -> WindowRef? {
        for host in hosts {
            for s in sessionsByHost[host.name] ?? [] {
                for w in s.windows
                where w.panes.contains(where: { $0.claudeSessionId == id || $0.codexSessionId == id }) {
                    return WindowRef(session: s.name, window: w.index, host: host)
                }
            }
        }
        return nil
    }

    /// Select a session row by name on `host` (after creating/renaming one).
    /// Expands the host if needed; highlights the row if present. Returns whether
    /// the row was found and selected (it won't be until a refresh has loaded the
    /// new session into the tree — see `selectSessionWhenReady`).
    @discardableResult
    func selectSession(_ name: String, host: Host = .local) -> Bool {
        // Host subtrees are namespaced per section; prefer the Active copy (local +
        // connected hosts live there), falling back to Servers / un-tagged.
        if let hostNode = findNodeByBase(host.identity) {
            outline.expandItem(hostNode)
        }
        guard let node = findNodeByBase("S:\(host.name):\(name)") else { return false }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        selectedIdentity = node.identity
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        return true
    }

    /// Expand + select `host`'s row in the Active section (after promoting it via a
    /// Servers button). Returns whether the row was found (it won't be until the
    /// refresh that loads it lands — see `pendingActivate`).
    @discardableResult
    private func revealActiveHost(_ host: Host) -> Bool {
        // No host row in the flat tree — reveal the host's first session instead
        // (it won't exist until the promoted remote's sessions load, so this stays
        // pending across refreshes until one appears).
        guard let node = firstSessionNode(host: host) else { return false }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        selectedIdentity = node.identity
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        return true
    }

    /// The first session node on `host` in the current tree, or nil.
    private func firstSessionNode(host: Host) -> SidebarNode? {
        func search(_ nodes: [SidebarNode]) -> SidebarNode? {
            for n in nodes {
                if n.isSession, n.host == host { return n }
                if let found = search(n.children) { return found }
            }
            return nil
        }
        return search(roots)
    }

    /// Resolve a `muxmaestro://` link against the cached tree (main thread), with
    /// the target's host as a live `Host` so the caller can pick its service.
    func resolveLink(
        _ link: ThreadLink
    ) -> Result<(host: Host, target: ThreadLinks.Target), ThreadLinks.LinkError> {
        ThreadLinks.resolve(link, in: sessionsByHost).flatMap { target in
            guard let host = host(named: target.host) else {
                return .failure(.unknownSession(target.session, host: target.host))
            }
            return .success((host, target))
        }
    }

    /// Refresh, then highlight `name` on `host` once the reload has the new node.
    /// `refresh()` loads the tree asynchronously, so a just-created session isn't
    /// in the outline yet when the creator returns — record it as pending and let
    /// the refresh completion select it (retried across polls until it appears).
    func selectSessionWhenReady(_ name: String, host: Host = .local) {
        pendingSelect = (name, nil, host)
        refresh()
    }

    /// Refresh, then highlight window `window` of `session` on `host` once the
    /// reload has the new node — the window analog of `selectSessionWhenReady`,
    /// for a window/pane that was just created and isn't in the tree yet.
    func selectWindowWhenReady(_ window: Int, session: String, host: Host = .local) {
        pendingSelect = (session, window, host)
        refresh()
    }

    /// Select a session row, or a window row inside it when `window` is set.
    @discardableResult
    private func selectRow(session: String, window: Int?, host: Host) -> Bool {
        guard let window else { return selectSession(session, host: host) }
        return selectWindow(window, session: session, host: host)
    }

    /// Select window `window` of `session` on `host`. Expands the host and the
    /// session so the row exists to select. Returns whether it was found (it
    /// won't be until the refresh that loads it lands — see
    /// `selectWindowWhenReady`).
    @discardableResult
    func selectWindow(_ window: Int, session: String, host: Host = .local) -> Bool {
        if let hostNode = findNodeByBase(host.identity) { outline.expandItem(hostNode) }
        if let sessionNode = findNodeByBase("S:\(host.name):\(session)") {
            outline.expandItem(sessionNode)
        }
        guard let node = findNodeByBase(windowKey(host: host, session: session, window: window))
        else { return false }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        selectedIdentity = node.identity
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        return true
    }

    /// Select the pane row `id` on `host` — the Running popover's primary verb,
    /// "put me where this port came from". Expands the session and window that
    /// hold it so the row exists to select. False when the pane is not in the
    /// loaded tree (it died between the scan and the click).
    @discardableResult
    func selectPane(id: String, host: Host) -> Bool {
        for session in sessionsByHost[host.name] ?? [] {
            for window in session.windows where window.panes.contains(where: { $0.id == id }) {
                selectWindow(window.index, session: session.name, host: host)
                // The window row has to be EXPANDED before its pane rows exist to
                // select. Without this the jump silently stopped at the window,
                // which is what a collapsed window looks like — i.e. nearly always.
                if let windowNode = findNodeByBase(
                    windowKey(host: host, session: session.name, window: window.index)) {
                    outline.expandItem(windowNode)
                }
                // A single-pane window has no pane row of its own — the window row
                // IS that pane — so landing on the window is the whole jump.
                guard let node = findNodeByBase("P:\(host.name):\(id)") else {
                    return window.panes.count == 1
                }
                let row = outline.row(forItem: node)
                guard row >= 0 else { return false }
                selectedIdentity = node.identity
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return true
            }
        }
        return false
    }

    /// Every host's latest Running scan, for the rail's Stop (which needs a
    /// container's stack siblings) and for anything else that must see what the
    /// last sweep found.
    var runningScanList: [RunningHostScan] { attributedScans }

    /// Every host's scan with its ports attributed to the panes in the tree as it
    /// stands NOW. The sweep is slower than the tree, so binding the two at scan
    /// time left a freshly started server — or every pane, on the first sweep
    /// after launch — claiming nothing.
    private var attributedScans: [RunningHostScan] {
        // A host that has never answered `docker ps` in this launch is not a
        // Docker host — `nas` and an SFTP endpoint never will be. Saying "Docker
        // unavailable on nas" for ever is noise about a machine that has nothing
        // to do with this work; a host that HAS answered and now fails still says
        // so, because there the unknown is real.
        runningScans.values.filter {
            dockerEverAnswered.contains($0.host) || $0.host == Host.local.name
        }.map { scan in
            var pids: [Int: String] = [:]
            if let host = hosts.first(where: { $0.name == scan.host }) {
                for session in sessionsByHost[host.name] ?? [] {
                    for window in session.windows {
                        for pane in window.panes where pane.pid > 0 { pids[pane.pid] = pane.id }
                    }
                }
            }
            return scan.attributed(panePidToId: pids)
        }
    }

    /// The service for a host named `name` (as `Host.name` spells it), or nil.
    func service(hostNamed name: String) -> TmuxService? {
        hosts.first { $0.name == name }.map { registry.service(for: $0) }
    }


    /// The click-launch probe for a Servers button completed: stop the row's
    /// spinner, record the result (so the button shows unreachable / no-tmux),
    /// and — only now that the host proved reachable with tmux — promote it into
    /// Active (persisted via `watch`) so its sessions load and stay polled.
    func launchProbeFinished(host: Host, reach: HostReachability) {
        probingHosts.remove(host.name)
        reachabilityByHost[host.name] = reach
        if reach == .reachable, !Settings.watch(host: host) {
            Settings.setWatch(true, host: host)
            pendingActivate = host
        }
        applyRefresh(buildHostNodes())
        if reach == .reachable { refresh() }
    }

    /// Optimistically splice a just-created session into the tree and select it
    /// NOW — before the reconciling `refresh()` (which pays the ~300ms status
    /// snapshot + the remote poll barrier) lands. The next refresh replaces this
    /// stub with the real session (windows, attention, activity). No-op if it's
    /// already present, so a racing poll that already loaded it doesn't duplicate.
    func insertOptimisticSession(_ name: String, host: Host = .local) {
        var list = sessionsByHost[host.name] ?? []
        if !list.contains(where: { $0.name == name }) {
            list.append(TmuxSession(name: name, attached: false, windows: []))
            sessionsByHost[host.name] = list
            applyRefresh(buildHostNodes())
        }
        _ = selectSession(name, host: host)
    }

    /// First-load only — builds the local host's tree synchronously so the
    /// self-test can reach sessions/windows/panes without the timer. Returns the
    /// Active section's host rows (local + herdr) so callers see the host subtree
    /// directly. Expands every level (group → host → session) for the walk.
    @discardableResult
    func loadOnce() -> [SidebarNode] {
        let sessions = registry.local.loadTree() ?? []
        sessionsByHost[Host.local.name] = sessions
        hosts = [.local]
        roots = buildHostNodes()
        outline.reloadData()
        // Expand every level so the self-test can walk the tree. ACTIVE's children
        // are now flat session nodes (+ herdr); expanding a session shows windows.
        for group in roots {
            outline.expandItem(group)
            for child in group.children {
                outline.expandItem(child)
                for sub in child.children { outline.expandItem(sub) }
            }
        }
        // The Active group's children are the flat session nodes (+ herdr source).
        let activeGroup = roots.first(where: {
            if case .activeGroup = $0.kind { return true }
            return false
        })
        return activeGroup?.children ?? []
    }

    /// Build the host-rooted node tree from the cached per-host session subtrees
    /// + reachability. Local first, then ssh-config hosts in file order.
    private func buildHostNodes() -> [SidebarNode] {
        if groupMode == .directory { return buildDirectoryNodes() }

        let local = hosts.first(where: { $0.isLocal }) ?? .local
        let remotes = hosts.filter { !$0.isLocal }

        // SERVERS (on top): the launcher catalog — this Mac + every saved remote,
        // as one-click buttons. Clicking one starts a NEW session on that host
        // (see the selection handler); a remote that probes healthy is promoted
        // into Active. A launcher, not a tree: its one child is its stat card, so
        // expanding a server shows its load, memory and disk (see `requestHostStats`).
        var servers = [SidebarNode(
            kind: .serverButton(host: local, active: true, reach: .reachable),
            children: [hostStatsNode(local)])]
        servers += RemoteTier.servers(remotes) { SshIdentity.cached($0) }.map { host -> SidebarNode in
            let node = SidebarNode(kind: .serverButton(
                host: host, active: Settings.watch(host: host),
                reach: reachabilityByHost[host.name] ?? .unknown),
                children: [hostStatsNode(host)])
            node.probing = probingHosts.contains(host.name)
            return node
        }
        servers.append(SidebarNode(kind: .addServer))

        // ACTIVE: a FLAT list of every session in the working set — local first,
        // then each activated (watched) remote — with no per-host grouping. Each
        // session row carries a host-type icon (laptop/server) so its host is
        // still legible; remote management lives in SERVERS + the session's
        // right-click menu. herdr (a separate multiplexer source) stays grouped.
        // "Most Recent" mode instead interleaves ALL hosts' sessions by activity.
        var active: [SidebarNode]
        if groupMode == .recent {
            active = buildRecentSessionNodes()
        } else {
            active = flatSessionNodes(for: local)
            for remote in activeRemotes(remotes) {
                active += flatSessionNodes(for: remote)
            }
        }
        let sessionCount = active.count
        // The filter took every session out: say so, the sessions are still there.
        let allHidden = active.isEmpty && filter != .off
            && ([local] + activeRemotes(remotes)).contains { host in
                (sessionsByHost[host.name] ?? []).contains {
                    !Self.isHiddenManagerSession(host, $0.name)
                }
            }
        if allHidden {
            active = [SidebarNode(kind: .placeholder(parent: "ACTIVE", text: "Nothing awake"))]
        } else if active.isEmpty {
            active = [SidebarNode(kind: .placeholder(
                parent: "ACTIVE", text: "No sessions — click a server to create one"))]
            // The tree being empty is exactly the post-reboot state — offer to
            // recover the Claude Code sessions that were live when tmux died.
            // The lost-session cache is prewarmed off-main by the refresh worker,
            // so this main-thread read is cheap.
            if !ClaudeSessionRecovery.lostSessions.isEmpty {
                active.append(SidebarNode(
                    kind: .hostAction(host: local, action: .recoverSessions)))
            }
        }
        active.append(buildHerdrNode())

        var roots = [
            SidebarNode(kind: .serversGroup(count: remotes.count + 1), children: servers),
            SidebarNode(kind: .activeGroup(count: sessionCount), children: active),
        ]
        // WORKTREES: linked worktrees with no session in them. A third root, and
        // only when there are any — an empty section would be pure chrome.
        let orphans = buildWorktreeNodes()
        if !orphans.isEmpty {
            let holdingWork = orphans.filter {
                if case .worktreeRow(_, _, let w) = $0.kind { return w == .unique }
                return false
            }.count
            roots.append(SidebarNode(
                kind: .worktreesGroup(count: orphans.count, work: holdingWork),
                children: orphans))
        }
        return roots
    }

    /// The orphan rows: every linked worktree of every known repo that no session
    /// — by session cwd or any window cwd — is sitting inside. Sorted by path so
    /// the list is stable across sweeps.
    ///
    /// Hidden manager sessions count as watchers here: the row asks "is anything
    /// working in this tree", and infrastructure sessions are still something.
    private func buildWorktreeNodes() -> [SidebarNode] {
        guard !worktreesByRepo.isEmpty else { return [] }
        var cwds: [String] = []
        for host in hosts where host.isLocal {
            for s in sessionsByHost[host.name] ?? [] {
                cwds.append(s.cwd)
                for w in s.windows { cwds.append(w.cwd) }
            }
        }
        let now = Date()
        var rows: [SidebarNode] = []
        for repo in worktreesByRepo.keys.sorted() {
            let list = worktreesByRepo[repo] ?? []
            for entry in Worktrees.orphans(worktrees: list, sessionCwds: cwds) {
                let work = worktreeWorkByPath[entry.path] ?? .unknown
                var metrics = worktreeMetricsByPath[entry.path] ?? WorktreeMetrics()
                metrics.diskKB = worktreeDiskKB[entry.path]
                metrics.diskPending = worktreeDiskScanning.contains(entry.path)
                let details = metrics.detailLines(entry: entry, work: work, now: now)
                    .enumerated().map {
                        SidebarNode(kind: .worktreeDetail(
                            parent: entry.path, index: $0.offset, text: $0.element))
                    }
                let node = SidebarNode(
                    kind: .worktreeRow(entry: entry, repo: repo, work: work), children: details)
                node.worktreeMetrics = metrics
                rows.append(node)
            }
        }
        Diag.log("worktree", "orphans=\(rows.count) from repos=\(worktreesByRepo.count) "
            + "sessionCwds=\(cwds.count)")
        return rows.sorted {
            guard case .worktreeRow(let a, _, _) = $0.kind,
                  case .worktreeRow(let b, _, _) = $1.kind else { return false }
            return a.path < b.path
        }
    }

    /// `du -sk` for one worktree, on demand, cached for the life of the process.
    func requestWorktreeDiskUsage(path: String) {
        guard worktreeDiskKB[path] == nil, !worktreeDiskScanning.contains(path) else { return }
        worktreeDiskScanning.insert(path)
        applyRefresh(buildHostNodes())  // show "…" right away
        let service = registry.local
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let kb = service.diskUsageKB(path: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.worktreeDiskScanning.remove(path)
                if let kb { self.worktreeDiskKB[path] = kb }
                self.applyRefresh(self.buildHostNodes())
            }
        }
    }

    /// "Most Recent" mode: every session across local + activated remotes, as one
    /// flat list sorted by tmux `session_activity` descending (most recent on top).
    /// Ignores custom drag order — recency is the whole point.
    private func buildRecentSessionNodes() -> [SidebarNode] {
        var pairs: [(host: Host, session: TmuxSession)] = []
        let local = hosts.filter(\.isLocal)
        for host in local + activeRemotes(hosts.filter { !$0.isLocal }) {
            for s in shownSessions(on: host) {
                pairs.append((host, s))
            }
        }
        pairs.sort { $0.session.activity > $1.session.activity }
        return pairs.map { buildSessionNode(host: $0.host, session: $0.session) }
    }

    /// The session nodes for `host` (custom-ordered), for the flat ACTIVE list —
    /// the flattened equivalent of `buildHostNode`'s children.
    private func flatSessionNodes(for host: Host) -> [SidebarNode] {
        let raw = shownSessions(on: host)
        let sessions = TmuxModel.applyCustomOrder(raw, order: Settings.sessionOrder(host: host))
        return sessions.map { buildSessionNode(host: host, session: $0) }
    }

    /// The sessions of `host` the tree shows: not the manager's own, and not
    /// what the filter hides. The selected window shows whatever the filter says.
    private func shownSessions(on host: Host) -> [TmuxSession] {
        let sessions = (sessionsByHost[host.name] ?? [])
            .filter { !Self.isHiddenManagerSession(host, $0.name) }
        guard filter != .off else { return sessions }
        let selected = selectedIdentity ?? ""
        return filter.apply(to: sessions, now: Int(Date().timeIntervalSince1970)) { session, window in
            selected.hasSuffix("W:\(host.name):\(session.name):\(window.index)")
                || window.panes.contains { selected.hasSuffix("P:\(host.name):\($0.id)") }
        }
    }

    /// Change what the sidebar leaves out, and keep it for the next launch.
    private func setFilter(_ mode: SidebarFilter) {
        filter = mode
        Settings.setSidebarFilter(mode)
        applyRefresh(buildHostNodes())
    }

    /// Switch the top-level organization (host ↔ directory) and rebuild from the
    /// already-cached session subtrees — no re-poll needed. Session identities are
    /// the same in both modes, so the current selection survives the switch.
    func setGroupMode(_ mode: GroupMode) {
        guard mode != groupMode else { return }
        groupMode = mode
        applyRefresh(buildHostNodes())
    }

    /// Build the directory-grouped tree: every loaded session across all hosts,
    /// bucketed by its working directory (`TmuxSession.cwd`), plus every pinned
    /// directory — pinned first (in pin order), the rest sorted by label, sessions
    /// sorted by name within each. A pinned directory with no sessions still gets
    /// a row (childless, `(0)`); that is what the pin buys. Remote sessions appear
    /// once their host has been loaded (local always is); herdr sessions have no
    /// tmux cwd and are not grouped here.
    private func buildDirectoryNodes() -> [SidebarNode] {
        var byDir: [String: [(host: Host, session: TmuxSession)]] = [:]
        for host in hosts {
            for session in shownSessions(on: host) {
                byDir[session.cwd, default: []].append((host, session))
            }
        }
        let pinned = Settings.pinnedDirs()
        guard !byDir.isEmpty || !pinned.isEmpty else {
            return [SidebarNode(kind: .placeholder(parent: "DIRS", text: "No sessions"))]
        }
        let pinnedSet = Set(pinned)
        let order = TmuxModel.directoryOrder(
            sessionDirs: Array(byDir.keys), pinned: pinned,
            label: SidebarNode.directoryLabel)
        return order.map { dir in
            let pairs = (byDir[dir] ?? []).sorted { $0.session.name < $1.session.name }
            let children = pairs.map { buildSessionNode(host: $0.host, session: $0.session) }
            return SidebarNode(
                kind: .directory(
                    path: dir, count: children.count, pinned: pinnedSet.contains(dir)),
                children: children)
        }
    }

    /// Build the herdr source root → session → tab → pane subtree from the cached
    /// herdr tree. Always shown (even when herdr isn't installed, so it's
    /// discoverable); its children populate when expanded.
    private func buildHerdrNode() -> SidebarNode {
        let sessionNodes = herdrSessions.map { session -> SidebarNode in
            let tabNodes = session.tabs.map { tab -> SidebarNode in
                let paneNodes = tab.panes.map { pane in
                    SidebarNode(kind: .herdrPane(
                        session: session.name, tab: tab.id, pane: pane))
                }
                return SidebarNode(
                    kind: .herdrTab(session: session.name, tab: tab), children: paneNodes)
            }
            return SidebarNode(kind: .herdrSession(session), children: tabNodes)
        }
        // Placeholder when empty so the herdr root stays expandable and its first
        // expand kicks off the lazy load.
        let children = sessionNodes.isEmpty
            ? [SidebarNode(kind: .placeholder(
                parent: "HERDR", text: herdr.isAvailable ? "No sessions" : "Not installed"))]
            : sessionNodes
        return SidebarNode(kind: .herdr(available: herdr.isAvailable), children: children)
    }

    /// Instance (not static) so the session node can carry its worktree chip,
    /// baked in at build time — `display` is the diff key, so a badge resolved
    /// later must arrive through a rebuild to repaint the row.
    private func buildSessionNode(host: Host, session: TmuxSession) -> SidebarNode {
        let windows = Settings.sortsByRecent(session: session.name, host: host)
            ? TmuxWindow.byRecent(session.windows) : session.windows
        let windowNodes = windows.map { window -> SidebarNode in
            // A single-pane window's lone pane row just repeats the window (same
            // command); omit it so the tree isn't visually doubled. Multi-pane
            // windows still expand to show each pane.
            let paneNodes = window.panes.count > 1
                ? window.panes.map { pane in
                    SidebarNode(kind: .pane(
                        host: host, session: session.name, window: window.index, pane: pane))
                }
                : []
            return SidebarNode(
                kind: .window(host: host, session: session.name, window: window),
                children: paneNodes)
        }
        let node = SidebarNode(kind: .session(host: host, session: session), children: windowNodes)
        node.worktree = worktreeBadge(for: session.cwd, host: host)
        return node
    }


    private func restoreExpansion(_ nodes: [SidebarNode]? = nil) {
        for node in nodes ?? roots where expandedIdentities.contains(node.identity) {
            outline.expandItem(node)
            // Recurse so a session expanded under a host is restored too.
            restoreExpansion(node.children)
        }
    }

    private func restoreSelection() {
        guard let selectedIdentity else { return }
        if let node = findNode(identity: selectedIdentity) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                restoringSelection = true
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                restoringSelection = false
            }
            // The selected pane cd'd into or out of a worktree since it was picked.
            // Re-sent only on that change, so a poll never resets an inline rename.
            let root = Self.worktreeCrumb(for: node)?.root
            if root != shownWorktreeRoot {
                shownWorktreeRoot = root
                selectionDelegate?.sidebarDidChangeBreadcrumb(
                    Self.breadcrumb(for: node), service: registry.service(for: node.host))
            }
        }
    }

    /// The window-title label for a selected node: server / session / window-or-pane.
    /// nil for structural rows (servers group, add-server, placeholders, actions),
    /// which shouldn't disturb the title.
    static func title(for node: SidebarNode) -> String? {
        switch node.kind {
        case .host(let h, _): return h.name
        case .session(let h, let s): return "\(h.name) / \(s.name)"
        case .window(let h, let session, let w):
            return "\(h.name) / \(session) / \(w.index): \(w.name)"
        case .pane(let h, let session, _, let p):
            return "\(h.name) / \(session) / \(p.id) \(p.command)"
        case .herdr: return "herdr"
        case .herdrSession(let s): return "herdr / \(s.name)"
        case .herdrTab(let session, let t):
            return "herdr / \(session) / \(t.number): \(t.label)"
        case .herdrPane(let session, _, let p):
            let label = p.agent ?? (p.cwd.map { ($0 as NSString).lastPathComponent } ?? "shell")
            return "herdr / \(session) / \(p.id) \(label)"
        case .directory, .activeGroup, .serversGroup, .serverButton, .hostStats, .addServer,
             .placeholder, .hostAction, .worktreesGroup, .worktreeRow, .worktreeDetail:
            return nil
        }
    }

    /// The selection path as clickable breadcrumb crumbs. Session, window, and pane
    /// crumbs are renamable; the host crumb and herdr/structural rows are plain.
    /// Mirrors `title(for:)` (a pane shows host / session / pane — no window crumb,
    /// since the pane node carries only the window index, not its name).
    static func breadcrumb(for node: SidebarNode) -> [BreadcrumbCrumb]? {
        guard var crumbs = pathCrumbs(for: node) else { return nil }
        if let wt = worktreeCrumb(for: node) {
            crumbs.append(.chip(wt.text, tooltip: wt.tooltip))
        }
        return crumbs
    }

    /// The linked worktree the selection's pane sits in, if any. A filesystem
    /// walk to the nearest `.git` (no git process), so it is cheap enough for
    /// every selection change and refresh.
    static func worktreeCrumb(for node: SidebarNode) -> Worktrees.Crumb? {
        let cwd: String
        switch node.kind {
        case .session(_, let s): cwd = s.cwd
        case .window(_, _, let w): cwd = w.cwd
        case .pane(_, _, _, let p): cwd = p.path
        default: return nil
        }
        return Worktrees.worktreeCrumb(
            cwd: cwd, isLocal: node.host.isLocal, home: NSHomeDirectory(),
            dotGit: Worktrees.readDotGit)
    }

    private static func pathCrumbs(for node: SidebarNode) -> [BreadcrumbCrumb]? {
        switch node.kind {
        case .host(let h, _):
            return [BreadcrumbCrumb(h.name)]
        case .session(let h, let s):
            return [BreadcrumbCrumb(h.name),
                    BreadcrumbCrumb(s.name, rename: .session(name: s.name))]
        case .window(let h, let session, let w):
            return [BreadcrumbCrumb(h.name),
                    BreadcrumbCrumb(session, rename: .session(name: session)),
                    BreadcrumbCrumb("\(w.index): \(w.name)", editText: w.name,
                                    rename: .window(session: session, window: w.index))]
        case .pane(let h, let session, let window, let p):
            let label = p.title.isEmpty ? p.command : p.title
            return [BreadcrumbCrumb(h.name),
                    BreadcrumbCrumb(session, rename: .session(name: session)),
                    BreadcrumbCrumb("\(p.id) \(label)", editText: p.title,
                                    rename: .pane(session: session, window: window, paneId: p.id))]
        default:
            return title(for: node).map { [BreadcrumbCrumb($0)] }
        }
    }

    private func findNode(identity: String, in nodes: [SidebarNode]? = nil) -> SidebarNode? {
        for node in nodes ?? roots {
            if node.identity == identity { return node }
            if let found = findNode(identity: identity, in: node.children) { return found }
        }
        return nil
    }

    /// Find a node by its un-namespaced base identity, preferring the Active copy
    /// (then Servers, then an un-tagged tree). In host mode every subtree is tagged
    /// "A/" or "S/", so a bare base like "S:box:web" never matches directly.
    private func findNodeByBase(_ base: String) -> SidebarNode? {
        findNode(identity: "A/" + base)
            ?? findNode(identity: "S/" + base)
            ?? findNode(identity: base)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode).map { !$0.children.isEmpty } ?? false
    }

    // MARK: Drag source — drag a SESSION row to reorder it within its host.

    /// Only session rows are draggable (for reorder); every other kind returns nil
    /// so it can't be dragged. The item carries "host.name\tsession.name".
    func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode, node.isSession,
              let session = node.sessionName else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString("\(node.host.name)\t\(session)", forType: Self.sessionDragType)
        return pbItem
    }

    // MARK: Drop destination — file-URL onto a session (M11), or session reorder.

    /// Two accepted drops:
    /// - A file URL "on" a session row → copy to the session cwd (M11).
    /// - A session-reorder drag between rows under the SAME host → `.move`.
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Session reorder: dragged pasteboard carries our private type.
        if let (hostName, _) = Self.decodeSessionDrag(info.draggingPasteboard) {
            // Must be a between-rows drop targeting the same host's children.
            guard let parent = item as? SidebarNode, parent.isHost,
                  parent.host.name == hostName,
                  index != NSOutlineViewDropOnItemIndex
            else { return [] }
            return .move
        }
        // File URL onto a session row (only "on" the row, not between).
        guard let node = item as? SidebarNode, node.isSession,
              index == NSOutlineViewDropOnItemIndex,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        // Retarget any drop within the session's subtree onto the session row.
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
        item: Any?, childIndex index: Int
    ) -> Bool {
        // Session reorder: move the dragged session to the drop index within its
        // host's children, persist the new order, and rebuild so the row moves now.
        if let (hostName, dragged) = Self.decodeSessionDrag(info.draggingPasteboard),
           let parent = item as? SidebarNode, parent.isHost,
           parent.host.name == hostName {
            var names = parent.children.compactMap { $0.sessionName }
            guard let from = names.firstIndex(of: dragged) else { return false }
            names.remove(at: from)
            // The proposed index is into the pre-removal list; shift down by one
            // when the item moved from above the drop point.
            let insertAt = min(from < index ? index - 1 : index, names.count)
            names.insert(dragged, at: insertAt)
            Settings.setSessionOrder(names, host: parent.host)
            applyRefresh(buildHostNodes())
            return true
        }
        // File-URL drop onto a session row (M11).
        guard let node = item as? SidebarNode, let session = node.sessionName,
              let urls = info.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return false }
        let service = registry.service(for: node.host)
        for url in urls where url.isFileURL {
            actionDelegate?.sidebarRequestDropFile(
                localPath: url.path, session: session, service: service)
        }
        return true
    }

    /// Decode a session-reorder drag payload ("host.name\tsession.name"), or nil
    /// when the pasteboard isn't carrying our private session type.
    private static func decodeSessionDrag(
        _ pasteboard: NSPasteboard
    ) -> (host: String, session: String)? {
        guard let raw = pasteboard.string(forType: sessionDragType) else { return nil }
        let parts = raw.components(separatedBy: "\t")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    /// Session rows are taller (they're the cards); structural + leaf rows are
    /// tighter so the tree stays compact under each card. A window or pane row
    /// with a last prompt takes a second line for it.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode else { return 28 }
        return rowHeight(for: node, row: outlineView.row(forItem: item))
    }

    /// Session rows (tmux + herdr) and the window, pane, tab rows under them get
    /// a row view that draws their segment of the session card behind the
    /// chevron + cell (see `CardRowView`).
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? SidebarNode, node.card != nil else { return nil }
        let id = NSUserInterfaceItemIdentifier("cardRow")
        let row = outlineView.makeView(withIdentifier: id, owner: self) as? CardRowView
            ?? { let r = CardRowView(); r.identifier = id; return r }()
        // Set on every use: row views are pooled.
        Self.colorCard(row, node: node)
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }

        if case .session(let host, let session) = node.kind {
            let id = NSUserInterfaceItemIdentifier("sessionCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SessionCellView
                ?? { let c = SessionCellView(); c.identifier = id; return c }()
            // PR chips live on the window rows now (each window can be a different
            // branch), so the session row itself shows no chip. The favicon (when
            // the session's repo has one) replaces the host glyph as the row icon.
            cell.configure(session, host: host, pr: nil,
                           favicon: favicon(for: session.cwd, host: host),
                           worktree: node.worktree)
            // "+" adds a window to this session.
            cell.addButton.isHidden = false
            cell.addButton.target = self
            cell.addButton.action = #selector(addOnRow(_:))
            cell.setSortsByRecent(Settings.sortsByRecent(session: session.name, host: host))
            cell.sortButton.target = self
            cell.sortButton.action = #selector(toggleSortOnRow(_:))
            return cell
        }
        // herdr session rows reuse the attention-dot cell, fed herdr's rolled-up
        // status mapped onto the shared AttentionStatus. No "+" (herdr has no
        // tmux-style add in this milestone).
        if case .herdrSession(let s) = node.kind {
            let id = NSUserInterfaceItemIdentifier("sessionCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SessionCellView
                ?? { let c = SessionCellView(); c.identifier = id; return c }()
            let attn = HerdrModel.sessionAttention(s)
            cell.configure(TmuxSession(name: s.name, attached: false, windows: [], attention: attn))
            cell.addButton.isHidden = true
            cell.sortButton.isHidden = true
            return cell
        }

        // Host rows render a custom cell: a rolled-up attention dot (so a collapsed
        // watched host still shows status) + an optional "watching" eye + "+".
        if case .host(let h, let reach) = node.kind {
            let id = NSUserInterfaceItemIdentifier("hostCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? HostCellView
                ?? { let c = HostCellView(); c.identifier = id; return c }()
            cell.configure(
                host: h, reach: reach, indicator: node.hostAttention.map(StatusIndicator.init),
                watched: node.watched)
            cell.addButton.target = self
            cell.addButton.action = #selector(addOnRow(_:))
            return cell
        }

        // Server buttons reuse the host cell (for the leading server glyph) in a
        // stripped-down "button" mode — no dot/eye/+, accent when not yet active.
        // A separate reuse id keeps them out of the host-row pool.
        if case .serverButton(let h, _, let reach) = node.kind {
            let id = NSUserInterfaceItemIdentifier("serverButtonCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? HostCellView
                ?? { let c = HostCellView(); c.identifier = id; return c }()
            cell.configureAsButton(host: h, reach: reach, probing: node.probing)
            return cell
        }

        if case .hostStats(_, let stats) = node.kind {
            let id = NSUserInterfaceItemIdentifier("hostStatsCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? HostStatsCell
                ?? HostStatsCell(id: id)
            cell.configure(stats)
            return cell
        }

        // Worktree rows and their detail lines get their own cells: chips that never
        // clip, a branch-first name, and head-truncated paths.
        if case .worktreeRow(let e, _, let work) = node.kind {
            let id = NSUserInterfaceItemIdentifier("worktreeCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? WorktreeRowCell
                ?? WorktreeRowCell(id: id)
            cell.configure(entry: e, work: work,
                           metrics: node.worktreeMetrics ?? WorktreeMetrics(), now: Date())
            return cell
        }
        if case .worktreeDetail(_, _, let text) = node.kind {
            let id = NSUserInterfaceItemIdentifier("worktreeDetailCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? WorktreeDetailCell
                ?? WorktreeDetailCell(id: id)
            cell.configure(text)
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? RowCell
            ?? RowCell(id: id)
        cell.textField?.stringValue = node.display
        if case .directory(let path, _, _) = node.kind, !path.isEmpty {
            // The label abbreviates $HOME to `~`, so the full path lives here.
            cell.toolTip = path
        } else {
            cell.toolTip = nil
        }
        // Pin glyph on a pinned directory row. Set on every configure — the cell
        // is pooled across every row kind.
        if case .directory(_, _, let pinned) = node.kind {
            cell.pin.isHidden = !pinned
        } else {
            cell.pin.isHidden = true
        }
        // Leading status dot on window/pane rows that run an agent, so a plain
        // shell's row stays clean. Rolled up for windows.
        let rowIndicator: StatusIndicator
        switch node.kind {
        case .window(_, _, let w): rowIndicator = w.indicator
        case .pane(_, _, _, let p): rowIndicator = p.indicator
        default: rowIndicator = .none
        }
        cell.dot.indicator = rowIndicator
        cell.dot.isHidden = rowIndicator == .none
        // Hover trash on a window, "+" on a directory, "rescan" on the SERVERS
        // header; hidden elsewhere. (Host rows render their own "+" via
        // HostCellView and never reach here.) The cell is pooled across every row kind, so the symbol, enabled
        // state and alpha are all set explicitly on each configure — never left over.
        cell.addButton.isEnabled = true
        cell.addButton.alphaValue = 1
        cell.showsTrashOnHover = node.isWindow
        cell.trashButton.target = self
        cell.trashButton.action = #selector(trashOnRow(_:))
        switch node.kind {
        case .window:
            cell.addButton.isHidden = true
        case .directory(let path, _, _):
            // "+" starts a session rooted in this directory — the payoff of a pin:
            // the project is still on screen at zero sessions, one click from the
            // next one.
            cell.addButton.isHidden = path.isEmpty
            cell.addButton.image = NSImage(
                systemSymbolName: "plus", accessibilityDescription: "New session here")
            cell.addButton.toolTip = "New session in \(SidebarNode.directoryLabel(path))"
            cell.addButton.target = self
            cell.addButton.action = #selector(addOnRow(_:))
        case .serversGroup:
            cell.addButton.isHidden = false
            cell.addButton.image = NSImage(
                systemSymbolName: "arrow.clockwise", accessibilityDescription: "Rescan servers")
            cell.addButton.toolTip = isColdScanning
                ? "Scanning servers…"
                : "Rescan servers for sessions"
            // The sweep can take seconds (a dead host burns its connect timeout), so
            // the button reads as busy rather than silently swallowing clicks.
            cell.addButton.isEnabled = !isColdScanning
            cell.addButton.alphaValue = isColdScanning ? 0.4 : 1
            cell.addButton.target = self
            cell.addButton.action = #selector(refreshServersClicked(_:))
        default:
            cell.addButton.isHidden = true
        }
        // The filter sits at the right edge of the ACTIVE header.
        if case .activeGroup = node.kind {
            cell.setTrailingControl(filterControl)
        } else {
            cell.setTrailingControl(nil)
        }
        if case .herdr(let available) = node.kind {
            // herdr source row: bold like a host; greyed when not installed.
            cell.textField?.font = .systemFont(ofSize: 12, weight: .semibold)
            cell.textField?.textColor = available ? SidebarPalette.text : SidebarPalette.muted
        } else if Self.isSectionHeader(node.kind) {
            // Section header (Active / Servers) — uppercase, quiet, like "SESSIONS".
            cell.textField?.stringValue = node.display.uppercased()
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = SidebarPalette.muted
        } else if case .directory = node.kind {
            // Directory group header — bold like a host row, but tinted muted so the
            // path reads as a grouping, not a session.
            cell.textField?.font = .systemFont(ofSize: 12, weight: .semibold)
            cell.textField?.textColor = SidebarPalette.text
        } else if case .addServer = node.kind {
            cell.textField?.font = .systemFont(ofSize: 12, weight: .medium)
            cell.textField?.textColor = SidebarPalette.accent
        } else if case .placeholder = node.kind {
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = SidebarPalette.muted
        } else if case .hostAction = node.kind {
            cell.textField?.font = .systemFont(ofSize: 12, weight: .medium)
            cell.textField?.textColor = SidebarPalette.accent
        } else {
            // Window / pane rows.
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = SidebarPalette.muted
        }
        switch node.kind {
        case .window(_, _, let w): cell.setSubtitle(w.lastPrompt?.text, age: RowCell.ageLabel(w.lastActivityAt))
        case .pane(_, _, _, let p): cell.setSubtitle(p.lastPrompt?.text, age: RowCell.ageLabel(p.lastActivityAt))
        default: cell.setSubtitle(nil)
        }
        // Per-window PR chips: the PRs named in the window's title first, then
        // the one for its cwd's branch (see `WindowPRs`).
        if case .window(let host, let session, let w) = node.kind {
            let prs = prByWindow[windowKey(host: host, session: session, window: w.index)] ?? []
            cell.prChips.configure(prs)
            cell.pinsTrash = WindowPRs.allMerged(prs)
        } else {
            cell.prChips.isHidden = true
            cell.pinsTrash = false
        }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        repaintCards()
        let wasExpanded = expandedIdentities.contains(node.identity)
        expandedIdentities.insert(node.identity)
        collapsedByUser.remove(node.identity)
        // Expanding a remote host for the first time should load its tree now
        // (the poll only loads expanded remotes), so the user doesn't wait a
        // poll tick to see sessions appear. Same for the herdr source.
        if !wasExpanded, (node.isHost && !node.host.isLocal) || node.isHerdr {
            refresh()
        }
        // A server button opens onto its stat card: remember that across
        // relaunches, and fetch now rather than on the next tick.
        if case .serverButton(let h, _, _) = node.kind {
            Settings.setHostExpanded(true, host: h)
            requestHostStats()
        }
        // Expanding a worktree row is the signal to pay for its size.
        if case .worktreeRow(let e, _, _) = node.kind { requestWorktreeDiskUsage(path: e.path) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        repaintCards()
        expandedIdentities.remove(node.identity)
        if case .serverButton(let h, _, _) = node.kind { Settings.setHostExpanded(false, host: h) }
        // Remember the user's intent so auto-expand doesn't immediately reopen it.
        if Self.autoExpands(node) { collapsedByUser.insert(node.identity) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection else { return }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return }
        selectedIdentity = node.identity
        let service = registry.service(for: node.host)
        selectionDelegate?.sidebarDidChangeTitle(Self.title(for: node))
        selectionDelegate?.sidebarDidChangeBreadcrumb(Self.breadcrumb(for: node), service: service)
        shownWorktreeRoot = Self.worktreeCrumb(for: node)?.root

        switch node.kind {
        case .host:
            // Selecting a host row doesn't attach a terminal; just expand it.
            outline.expandItem(node)
        case .session(_, let s):
            selectionDelegate?.sidebarDidSelectSession(s.name, service: service)
        case .window(_, let session, let w):
            selectionDelegate?.sidebarDidSelectSession(session, service: service)
            selectionDelegate?.sidebarDidSelectWindow(session: session, window: w.index, service: service)
        case .pane(_, let session, let window, let pane):
            selectionDelegate?.sidebarDidSelectSession(session, service: service)
            selectionDelegate?.sidebarDidSelectPane(
                session: session, window: window, pane: pane, service: service)
        case .herdr:
            // Selecting the herdr source row just expands it (like a host row).
            outline.expandItem(node)
        case .herdrSession, .herdrTab, .herdrPane:
            // Any herdr row attaches the surface to its session via `herdr attach`.
            // herdr has no per-tab/pane surface targeting in this milestone, so a
            // tab/pane selection attaches the whole session (the focused tab/pane
            // is what herdr shows).
            if let session = node.herdrSessionName {
                selectionDelegate?.sidebarDidSelectHerdrSession(session, service: herdr)
            }
        case .activeGroup, .serversGroup, .directory, .worktreesGroup:
            // Group header — toggle the section open/closed.
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { outline.expandItem(node) }
        case .serverButton(let h, _, _):
            // A Servers-section button: clicking starts a NEW session on that
            // host. A remote is probed first (spinner on the row; repeat clicks
            // ignored while in flight) — promotion into Active happens in
            // `launchProbeFinished`, only once the host proves reachable, so a
            // dead box never gets promoted. Don't leave the button selected (also
            // forget it as the restore target, or the post-probe reload would
            // re-highlight it).
            selectedIdentity = nil
            outline.deselectAll(nil)
            if !h.isLocal {
                guard !probingHosts.contains(h.name) else { return }
                probingHosts.insert(h.name)
                applyRefresh(buildHostNodes())  // show the spinner right away
            }
            actionDelegate?.sidebarRequestLaunchSession(host: h, service: service)
        case .addServer:
            // Don't leave the action row selected after firing it.
            outline.deselectAll(nil)
            actionDelegate?.sidebarRequestAddServer()
        case .placeholder, .hostStats:
            // A hint row or a stat card — not a real target. Clear the selection.
            outline.deselectAll(nil)
        case .worktreeRow(let e, _, _):
            // Selecting a worktree opens its detail and pays for its size.
            requestWorktreeDiskUsage(path: e.path)
            outline.expandItem(node)
        case .worktreeDetail:
            outline.deselectAll(nil)
        case .hostAction(let h, let action):
            outline.deselectAll(nil)
            switch action {
            case .plainShell: actionDelegate?.sidebarRequestPlainShell(host: h)
            case .installTmux: actionDelegate?.sidebarRequestInstallTmux(host: h)
            case .recoverSessions: actionDelegate?.sidebarRequestRecoverSessions()
            }
        }
    }
}

// MARK: - NSMenuDelegate (right-click context menu)

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Capture the right-clicked node NOW and pin it to each item via
        // representedObject. The handlers read that node (which carries the host
        // + session/window/pane id), so the action always hits the row that was
        // clicked even if clickedRow has reset by action time.
        let node = clickedNode()

        // Helper: build an item already pinned to `node` and targeting self.
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = node
            item.target = self
            return item
        }

        // "Copy tmux ID “web:1”" — the title shows exactly what lands on the
        // clipboard. Only rows that have a tmux address get one.
        func copyIdItem() -> NSMenuItem? {
            guard let node, let id = tmuxIdentifier(for: node) else { return nil }
            return item("Copy tmux ID “\(id)”", #selector(contextCopyIdentifier(_:)))
        }

        // The agent ids of the row's target pane — what `claude --resume` /
        // `codex resume` need. Shown only when the pane actually has one, so a
        // plain shell row gets no dead entries. Like `copyIdItem`, the title shows
        // (an abbreviation of) exactly what lands on the clipboard.
        func copyAgentIdItems(into menu: NSMenu) {
            guard let node, let pane = targetPane(for: node) else { return }
            if let id = pane.claudeSessionId {
                menu.addItem(item(
                    "Copy Claude session ID “\(TmuxCommands.abbreviatedSessionId(id))”",
                    #selector(contextCopyClaudeSessionId(_:))))
            }
            if let id = pane.codexSessionId {
                menu.addItem(item(
                    "Copy Codex session ID “\(TmuxCommands.abbreviatedSessionId(id))”",
                    #selector(contextCopyCodexSessionId(_:))))
            }
        }

        switch node?.kind {
        case .session(_, let s):
            menu.addItem(item("Rename “\(s.name)”…", #selector(contextRename(_:))))
            // Kills the session's active window outright. No ⌘W chord shown any
            // more: ⌘W closes only the focused *pane* of a multi-pane window, so
            // advertising it on a window-kill item promised the wrong blast radius.
            menu.addItem(item("Archive Window", #selector(contextCloseWindow(_:))))
            menu.addItem(item("Kill “\(s.name)”", #selector(contextKill(_:))))
            menu.addItem(.separator())
            if let node { addMergeItem(to: menu, node: node, session: s) }
            copyIdItem().map { menu.addItem($0) }
            copyAgentIdItems(into: menu)
            menu.addItem(.separator())
        case .window(_, let owner, let w):
            menu.addItem(item("New Window", #selector(contextNewWindow(_:))))
            menu.addItem(item("Rename Window “\(w.name)”…", #selector(contextRenameWindow(_:))))
            menu.addItem(item("Archive Window", #selector(contextKillWindow(_:))))
            menu.addItem(.separator())
            if let node {
                addMoveToSessionItems(to: menu, node: node, session: owner)
                menu.addItem(.separator())
            }
            copyIdItem().map { menu.addItem($0) }
            copyAgentIdItems(into: menu)
            menu.addItem(.separator())
        case .pane(_, let owner, let ownerWindow, let p):
            menu.addItem(item("Split Horizontally", #selector(contextSplitHorizontal(_:))))
            menu.addItem(item("Split Vertically", #selector(contextSplitVertical(_:))))
            menu.addItem(.separator())
            if let node {
                addMoveToSessionItems(to: menu, node: node, session: owner)
                addMoveToWindowItem(
                    to: menu, node: node, session: owner, window: ownerWindow)
                menu.addItem(.separator())
            }
            menu.addItem(item("Kill Pane \(p.id)", #selector(contextKillPane(_:))))
            menu.addItem(.separator())
            copyIdItem().map { menu.addItem($0) }
            copyAgentIdItems(into: menu)
            menu.addItem(.separator())
        case .host(let h, _):
            // A remote host in Active is there because it's "activated" (watch on);
            // offer to remove it (which stops polling + drops it from Active).
            if !h.isLocal {
                menu.addItem(item("Remove from Active", #selector(contextToggleWatch(_:))))
                let moshItem = item("Use mosh for terminal", #selector(contextToggleMosh(_:)))
                moshItem.state = Settings.useMosh(host: h) ? .on : .off
                menu.addItem(moshItem)
                // Offer the server install only when mosh is the chosen transport.
                if Settings.useMosh(host: h) {
                    menu.addItem(item("Install mosh…", #selector(contextInstallMosh(_:))))
                }
                // Only hosts we wrote are editable/removable; one from the user's
                // own ~/.ssh/config is never rewritten by the app.
                if let alias = h.sshAlias, managedAliases().contains(alias) {
                    menu.addItem(item("Edit Server…", #selector(contextEditServer(_:))))
                    menu.addItem(item("Remove Server…", #selector(contextRemoveServer(_:))))
                }
                menu.addItem(.separator())
            }
            addColorSubmenu(to: menu, host: h)
            menu.addItem(.separator())
        case .serverButton(let h, _, _):
            // A Servers-section row: the natural place to manage a host that
            // hasn't been activated yet. Edit + Remove, only for managed aliases.
            guard let alias = h.sshAlias, managedAliases().contains(alias) else { return }
            menu.addItem(item("Edit Server…", #selector(contextEditServer(_:))))
            menu.addItem(item("Remove Server…", #selector(contextRemoveServer(_:))))
            return
        case .herdrSession(let s):
            // herdr lifecycle: stop the server, or delete the session. (Delete is
            // the destructive one — the AppDelegate gates it behind a confirm.)
            menu.addItem(item("Stop “\(s.name)”", #selector(contextStopHerdr(_:))))
            menu.addItem(item("Delete “\(s.name)”", #selector(contextDeleteHerdr(_:))))
            return  // no tmux "New Session" fallback for a herdr row
        case .herdr, .herdrTab, .herdrPane:
            // herdr root / tab / pane rows have no context actions in this
            // milestone (herdr exposes no tab/pane lifecycle that maps cleanly).
            return
        case .serverButton(let h, _, _):
            // A Servers-section row (the top list). Let the user set the server
            // tint color here — same submenu as an Active host row — then fall
            // through to the "New Session on <host>" item below.
            addColorSubmenu(to: menu, host: h)
            menu.addItem(.separator())
        case .directory(let path, _, let pinned):
            // A directory row is a project. Pinning keeps it on screen once its
            // last session is killed; the "(no directory)" bucket is not a project
            // and so is not pinnable.
            if !path.isEmpty {
                let label = SidebarNode.directoryLabel(path)
                menu.addItem(item(
                    "\(pinned ? "Unpin" : "Pin") “\(label)”",
                    #selector(contextTogglePinDir(_:))))
                menu.addItem(.separator())
            }
        case .worktreeRow(let entry, _, let work):
            // Removal is spindown's job (it re-checks for work); this only asks.
            // A refused offer stays visible but disabled, so the reason shows.
            let offer = Worktrees.removeOffer(entry: entry, work: work)
            let remove = item(Worktrees.removeMenuTitle(offer), #selector(contextRemoveWorktree(_:)))
            if case .refuse = offer { remove.action = nil }
            menu.addItem(remove)
            return
        case .activeGroup, .serversGroup, .addServer, .hostStats,
             .placeholder, .hostAction, .worktreesGroup, .worktreeDetail:
            // Structural rows — no context menu.
            return
        case .none:
            break
        }

        // Beam this row's session/window/pane to a server (local → remote), just
        // above New Session. Only for beamable local rows; the submenu lists the
        // reachable remote hosts.
        if let node, isBeamableRow(node) {
            addBeamSubmenu(to: menu, node: node)
        }

        // New session on the clicked row's host (or local when none) — always
        // offered so a right-click anywhere can start a session.
        let host = node?.host ?? .local
        menu.addItem(item("New Session on \(host.name)…", #selector(contextNew(_:))))
    }
}
