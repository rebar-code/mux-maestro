import Cocoa

/// The right sidebar: a collapsible rail to the RIGHT of the terminal that hosts
/// the Diff and/or the Tree browser. Unlike the old single-slot side panel,
/// both can be shown at once, split as columns (side by side) OR
/// rows (stacked) — the orientation flips at runtime, the same way tmux panes
/// split horizontally or vertically. Empty (none shown) ⇒ the host
/// (`DetailViewController`) collapses the whole rail so the terminal fills the
/// detail area.
///
/// The two view controllers are children, kept alive across show/hide so
/// toggling never drops their state (the diff keeps its render, the tree its
/// expansion). Each lives in a stable wrapper (`treeHost`/`diffHost`) so it can be added to / removed from the split without disturbing
/// the others and always in the canonical order below.
final class RightSidebarViewController: NSViewController {
    let diff: DiffViewController
    let tree: TreeViewController
    let artifacts: ArtifactsViewController

    enum Item { case diff, tree, artifacts }

    /// Top-to-bottom (or left-to-right) order, regardless of which was toggled on
    /// first.
    private static let order: [Item] = [.tree, .diff, .artifacts]

    /// Floor for any one pane while dragging, and the room the others are
    /// guaranteed by the divider constraints.
    private static let minPaneExtent: CGFloat = 120

    private let split = NSSplitView()
    private let treeHost = NSView()
    private let diffHost = NSView()
    private let artifactsHost = NSView()

    /// Whether the two panes lay out as columns (side by side) vs rows (stacked).
    /// A vertical divider means columns. Restored from the persisted preference.
    private(set) var isColumns: Bool = Settings.rightSidebarColumns()

    init(diff: DiffViewController, tree: TreeViewController, artifacts: ArtifactsViewController) {
        self.diff = diff
        self.tree = tree
        self.artifacts = artifacts
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        addChild(diff)
        addChild(tree)
        addChild(artifacts)
        embed(tree.view, in: treeHost)
        embed(diff.view, in: diffHost)
        embed(artifacts.view, in: artifactsHost)

        split.isVertical = isColumns
        split.dividerStyle = .thin
        split.delegate = self
        split.autosaveName = "SidekickRightSidebarSplit"
        self.view = split
    }

    private func embed(_ content: NSView, in host: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    // MARK: Show / hide

    /// Neither pane is shown — the host uses this to collapse the whole rail.
    var isEmpty: Bool { split.arrangedSubviews.isEmpty }

    func isShown(_ item: Item) -> Bool { host(item).superview != nil }

    /// Which panes are currently shown (for remembering across a master collapse).
    var shownItems: [Item] { Self.order.filter(isShown) }

    /// Hide every pane (master collapse). The children stay alive — only their
    /// hosts leave the split — so re-showing restores their render/expansion state.
    func hideAll() {
        Self.order.forEach(hide)
    }

    private func host(_ item: Item) -> NSView {
        switch item {
        case .tree: return treeHost
        case .diff: return diffHost
        case .artifacts: return artifactsHost
        }
    }

    /// Ensure `item` is visible, inserted at its place in `order` so the layout
    /// is stable regardless of which pane was toggled on first.
    func show(_ item: Item) {
        let host = host(item)
        guard host.superview == nil else { return }
        let ahead = Self.order.prefix { $0 != item }.filter(isShown).count
        if ahead < split.arrangedSubviews.count {
            split.insertArrangedSubview(host, at: ahead)
        } else {
            split.addArrangedSubview(host)
        }
        rebalance()
    }

    func hide(_ item: Item) {
        let host = host(item)
        guard host.superview != nil else { return }
        split.removeArrangedSubview(host)
        host.removeFromSuperview()
        rebalance()
    }

    /// Flip `item` on/off. Returns whether `item` is shown afterward.
    @discardableResult
    func toggle(_ item: Item) -> Bool {
        if isShown(item) { hide(item) } else { show(item) }
        return isShown(item)
    }

    /// The view controller backing `item`, for focus.
    func controller(for item: Item) -> NSViewController {
        switch item {
        case .tree: return tree
        case .diff: return diff
        case .artifacts: return artifacts
        }
    }

    // MARK: Orientation

    /// Flip between columns (side by side) and rows (stacked), persisting the
    /// choice. A no-op visually when fewer than two panes are shown, but the
    /// preference still updates so the next two-pane layout honors it.
    func toggleOrientation() {
        isColumns.toggle()
        Settings.setRightSidebarColumns(isColumns)
        split.isVertical = isColumns
        rebalance()
    }

    /// Lay the shown panes out along the current axis in even shares.
    private func rebalance() {
        split.adjustSubviews()
        let shown = shownItems
        guard shown.count > 1 else { return }
        split.layoutSubtreeIfNeeded()
        let extent = isColumns ? split.bounds.width : split.bounds.height
        guard extent > 0 else { return }

        let share = extent / CGFloat(shown.count)
        for divider in 0..<(shown.count - 1) {
            split.setPosition(share * CGFloat(divider + 1), ofDividerAt: divider)
        }
    }
}

// MARK: - NSSplitViewDelegate (keep both panes usable)

extension RightSidebarViewController: NSSplitViewDelegate {
    /// Every pane above this divider keeps at least `paneFloor`.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMin, CGFloat(dividerIndex + 1) * paneFloor(splitView))
    }

    /// …and so does every pane below it.
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let below = splitView.arrangedSubviews.count - dividerIndex - 1
        return min(proposedMax, extent - CGFloat(max(1, below)) * paneFloor(splitView))
    }

    /// `minPaneExtent`, capped at an equal share of what the rail actually has.
    /// Two panes in a 170-wide rail cannot both hold 120: the computed minimum
    /// would exceed the computed maximum and the divider would fight the drag.
    /// Whenever there is room this returns `minPaneExtent` and nothing changes.
    private func paneFloor(_ splitView: NSSplitView) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let panes = max(1, splitView.arrangedSubviews.count)
        guard extent > 0 else { return Self.minPaneExtent }
        return min(Self.minPaneExtent, extent / CGFloat(panes))
    }
}
