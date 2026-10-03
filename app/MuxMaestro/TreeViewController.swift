import Cocoa
import WebKit

/// Raised by the Tree side panel so the AppDelegate (which owns the selection +
/// services) can run searches / list files / read previews off-main and open a
/// chosen file. Mirrors `DiffPaneDelegate`.
protocol TreePaneDelegate: AnyObject {
    /// Re-list / re-run for the current selection (Refresh button).
    func treePaneDidRequestRefresh()
    /// The search query or its scope changed (already debounced). Empty query →
    /// show the full tree; non-empty → search `scope` and show the matches.
    func treePaneDidChangeQuery(_ query: String, scope: TreeSearchScope)
    /// A pane result row was activated — go to that pane and find `needle` in it.
    func treePaneDidActivatePane(_ pane: PaneSearchTarget, needle: String)
    /// A row was *selected* (single click / arrow) — load it into the preview.
    /// `line` is set for a match row so the preview scrolls there.
    func treePaneDidRequestPreview(file relativePath: String, line: Int?)
    /// A row was *activated* (double-click / Enter) — open it in the editor.
    /// `line` is set for a match row so the editor opens at that line.
    func treePaneDidActivate(file relativePath: String, line: Int?)
    /// "Open in Default App" (right-click) — open the file in the OS-default app
    /// for its type (Preview for png/pdf, Chrome for html, Excel for xlsx, …).
    /// Local sessions only.
    func treePaneDidOpenInDefaultApp(file relativePath: String)
}

/// An NSOutlineView that fires `onActivate` on Return/Enter, so a keyboard user
/// can open the selected file the same way a double-click does.
private final class KeyOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {  // Return / numpad Enter
            onActivate?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The Tree side panel: a search-driven repo browser shown in the same detail
/// slot as the Diff pane (mutually exclusive — see `DetailViewController`). A
/// search field on top filters the tree to matching files, each expandable to its
/// matching lines; with an empty query it shows the full `.gitignore`-aware file
/// tree. Clicking a file (or a match line) opens it in the editor.
///
/// All data is computed off-main by the AppDelegate (`TmuxService.search` /
/// `.fileTree`) and handed here via `renderTree` / `renderSearch`.
///
/// NOTE — file preview (disabled): a syntax-highlighted preview pane (a WKWebView
/// + vendored highlight.js under `Resources/preview/`, incl. the Svelte grammar)
/// is fully implemented but turned OFF behind `previewEnabled` for now — opening
/// the file in the editor on click was deemed sufficient. To bring it back, flip
/// `previewEnabled` to true: `loadView` then mounts the tree + preview in a split,
/// row selection drives `treePaneDidRequestPreview`, and `showPreview` renders it.
/// The bundle + the preview code (`showPreview`/`applyTheme`/`WKNavigationDelegate`/
/// the inner split) are kept intact so re-enabling is a one-line change.
final class TreeViewController: NSViewController {
    weak var delegate: TreePaneDelegate?

    /// Master switch for the file-preview pane (see the type's NOTE). Off for now;
    /// clicking a file opens it in the editor instead.
    private static let previewEnabled = false

    private let searchField = NSSearchField()
    private let scopeControl = NSSegmentedControl(
        labels: ["All panes", "This repo"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = HoverTintButton()
    private let statusLabel = NSTextField(labelWithString: "No session selected")
    private let outline = KeyOutlineView()
    private let scroll = NSScrollView()
    private lazy var webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let innerSplit = NSSplitView()

    /// Whether the bound session's host is local — gates the "Open in Default App"
    /// context action (it can't reach a file living on a remote host). Set by the
    /// AppDelegate when the panel binds to a session.
    var hostIsLocal = false
    private var debounce: Timer?

    private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    /// Preview bundle readiness (like the Diff pane): renders before the page
    /// finishes loading are stashed and flushed on `didFinish`.
    private var isReady = false
    private var pending: (() -> Void)?
    private var appearanceObservation: NSKeyValueObservation?

    /// A node in the displayed tree. A folder holds children; a file holds its
    /// match rows (in search mode) and a hit count; a match is a single line.
    private final class Node {
        enum Kind {
            case folder
            case file(hits: Int)
            case match(SearchMatch)
            /// A pane header row in "All panes" results, with its hit count.
            case pane(PaneSearchTarget, hits: Int)
            /// One matching scrollback line under a pane header.
            case paneMatch(PaneMatch)
        }
        let name: String
        let relativePath: String
        let kind: Kind
        let children: [Node]
        init(name: String, relativePath: String, kind: Kind, children: [Node] = []) {
            self.name = name
            self.relativePath = relativePath
            self.kind = kind
            self.children = children
        }
        var isFolder: Bool { if case .folder = kind { return true }; return false }
        var isMatch: Bool {
            switch kind {
            case .match, .paneMatch: return true
            default: return false
            }
        }
        /// The pane a row points at, for the two pane kinds — nil for file rows.
        var pane: PaneSearchTarget? {
            switch kind {
            case .pane(let p, _): return p
            case .paneMatch(let m): return m.pane
            default: return nil
            }
        }
        var lineNumber: Int? { if case .match(let m) = kind { return m.lineNumber }; return nil }
    }
    private var roots: [Node] = []

    /// The current text in the search field — read by the AppDelegate to choose
    /// between listing the tree and searching.
    var currentQuery: String { searchField.stringValue }

    private var previewIndexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "preview")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = SidebarPalette.bg.cgColor

        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // A borderless, muted→accent-on-hover button matching the left sidebar's
        // inline "+" buttons (see `SidebarAddButton`), rather than a heavy system
        // bezel — so both sidebars share one button language.
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.imageScaling = .scaleProportionallyDown
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.setButtonType(.momentaryChange)
        refreshButton.contentTintColor = SidebarPalette.muted
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Re-list / re-run for the selected session"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.widthAnchor.constraint(equalToConstant: 20).isActive = true

        scopeControl.segmentStyle = .roundRect
        scopeControl.controlSize = .small
        scopeControl.font = .systemFont(ofSize: 11)
        scopeControl.selectedSegment = Self.segment(for: .repo)
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.toolTip = "What ⇧⌘F searches"
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        applyScopePlaceholder()

        let bar = NSStackView(views: [searchField, refreshButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 4, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)

        let scopeRow = NSStackView(views: [scopeControl])
        scopeRow.orientation = .horizontal
        scopeRow.alignment = .centerY
        scopeRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 4, right: 8)
        scopeRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scopeRow)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = SidebarPalette.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.indentationPerLevel = 16  // match the left sidebar
        outline.rowHeight = 24
        outline.backgroundColor = SidebarPalette.bg
        outline.selectionHighlightStyle = .regular
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(handleClick)            // single click opens a file
        outline.doubleAction = #selector(handleDoubleClick) // double click toggles a folder
        outline.onActivate = { [weak self] in self?.activateSelected() }
        outline.menu = makeContextMenu()                   // right-click: open in editor / default app

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = SidebarPalette.bg
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The content area is the tree alone, or — when the preview is enabled — a
        // tree | preview split (see the type's NOTE).
        let content: NSView
        if Self.previewEnabled {
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.navigationDelegate = self
            if #available(macOS 13.3, *) { webView.isInspectable = true }
            innerSplit.isVertical = true
            innerSplit.dividerStyle = .thin
            innerSplit.delegate = self
            innerSplit.autosaveName = "SidekickTreeSplit"
            innerSplit.addArrangedSubview(scroll)
            innerSplit.addArrangedSubview(webView)
            content = innerSplit
        } else {
            content = scroll
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scopeRow.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scopeRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scopeRow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: scopeRow.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            content.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container

        guard Self.previewEnabled else { return }

        appearanceObservation = container.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self, self.isReady else { return }
            self.applyTheme()
        }
        if let previewIndexURL {
            webView.loadFileURL(
                previewIndexURL, allowingReadAccessTo: previewIndexURL.deletingLastPathComponent())
        }
        // Give the tree and preview roughly equal width on first layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let total = self.innerSplit.bounds.width
            if total > 0 { self.innerSplit.setPosition(total * 0.5, ofDividerAt: 0) }
        }
    }

    /// Focus the search field (used when ⌘⇧F opens the panel).
    func focusSearch() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(searchField)
    }

    /// What the search field currently searches — read by the AppDelegate to
    /// route the query.
    var scope: TreeSearchScope {
        scopeControl.selectedSegment == 0 ? .panes : .repo
    }

    private static func segment(for scope: TreeSearchScope) -> Int {
        scope == .panes ? 0 : 1
    }

    /// Put the switch back on "This repo" — ⇧⌘F always opens there.
    func selectRepoScope() {
        loadViewIfNeeded()
        scopeControl.selectedSegment = Self.segment(for: .repo)
        applyScopePlaceholder()
    }

    /// The scope switch moved: retitle the field, and re-run the
    /// query in the new scope so the results match the switch immediately.
    @objc private func scopeChanged() {
        applyScopePlaceholder()
        delegate?.treePaneDidChangeQuery(searchField.stringValue, scope: scope)
    }

    private func applyScopePlaceholder() {
        searchField.placeholderString =
            scope == .panes ? "Search all panes  (⇧⌘F)" : "Find in repo  (⇧⌘F)"
    }

    // MARK: Rendering — full file tree

    /// Show the full `.gitignore`-aware file tree (empty query). Top-level folders
    /// expand so the structure is visible without clicking.
    func renderTree(_ result: FileTreeResult, status: String) {
        statusLabel.stringValue = status
        roots = result.root.map(Self.node(fromFileTree:))
        outline.reloadData()
        for node in roots where node.isFolder { outline.expandItem(node) }
    }

    private static func node(fromFileTree n: FileTreeNode) -> Node {
        if n.isDir {
            return Node(name: n.name, relativePath: n.relativePath, kind: .folder,
                        children: n.children.map(node(fromFileTree:)))
        }
        return Node(name: n.name, relativePath: n.relativePath, kind: .file(hits: 0))
    }

    // MARK: Rendering — search results (files + matching lines)

    /// Show search matches as a tree: matching files (nested in their folders),
    /// each expandable to its matching lines. Everything is expanded so the lines
    /// are visible.
    func renderSearch(matches: [SearchMatch], cwd: String, status: String) {
        statusLabel.stringValue = status
        roots = Self.searchNodes(matches: matches, cwd: cwd)
        outline.reloadData()
        expandAll(roots)
    }

    /// Show pane matches as a tree: one header row per pane, expanded to its
    /// matching scrollback lines. The pane rows carry no path — clicking either
    /// level goes to the pane instead of opening a file.
    func renderPaneSearch(matches: [PaneMatch], status: String) {
        statusLabel.stringValue = status
        roots = PaneSearch.group(matches).map { group in
            Node(name: Self.paneLabel(group.pane), relativePath: "",
                 kind: .pane(group.pane, hits: group.matches.count),
                 children: group.matches.map {
                     Node(name: $0.lineText, relativePath: "", kind: .paneMatch($0))
                 })
        }
        outline.reloadData()
        expandAll(roots)
    }

    /// A pane header's label: "session › 2 build · claude", prefixed with the host
    /// for a remote pane so same-named sessions on two machines stay tellable
    /// apart.
    private static func paneLabel(_ p: PaneSearchTarget) -> String {
        let where_ = p.host.isLocal ? p.session : "\(p.host.name)/\(p.session)"
        let window = p.windowName.isEmpty ? "\(p.window)" : "\(p.window) \(p.windowName)"
        return "\(where_) › \(window) · \(p.command)"
    }

    /// Build the matching-file tree: reuse `FileTree.build` for the folder nesting
    /// (from the matching files' relative paths), then hang each file's matches off
    /// its leaf as line rows.
    private static func searchNodes(matches: [SearchMatch], cwd: String) -> [Node] {
        let groups = CodeSearch.group(matches)
        guard !groups.isEmpty else { return [] }
        var matchesByRel: [String: [SearchMatch]] = [:]
        for g in groups { matchesByRel[relative(g.path, cwd: cwd)] = g.matches }
        let nul = groups.map { relative($0.path, cwd: cwd) }.joined(separator: "\u{0}") + "\u{0}"
        let (fileTree, _) = FileTree.build(fromNulList: nul)
        return fileTree.map { searchNode($0, matchesByRel) }
    }

    private static func searchNode(_ n: FileTreeNode, _ matchesByRel: [String: [SearchMatch]]) -> Node {
        if n.isDir {
            return Node(name: n.name, relativePath: n.relativePath, kind: .folder,
                        children: n.children.map { searchNode($0, matchesByRel) })
        }
        let ms = matchesByRel[n.relativePath] ?? []
        let lines = ms.map {
            Node(name: $0.lineText, relativePath: n.relativePath, kind: .match($0))
        }
        return Node(name: n.name, relativePath: n.relativePath,
                    kind: .file(hits: ms.count), children: lines)
    }

    /// Make a path relative to `cwd` when it's under it, else return it unchanged.
    private static func relative(_ path: String, cwd: String) -> String {
        guard !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    private func expandAll(_ nodes: [Node]) {
        for node in nodes where !node.children.isEmpty {
            outline.expandItem(node)
            expandAll(node.children)
        }
    }

    // MARK: Preview

    /// Render `content` (for `filename`) in the syntax-highlighted preview,
    /// scrolling to `line` when set. Safe before the bundle is ready (flushed on load).
    func showPreview(content: String, filename: String, line: Int?) {
        run {
            let code = Self.jsString(content)
            let name = Self.jsString(filename)
            let lineArg = line.map(String.init) ?? "null"
            self.webView.evaluateJavaScript(
                "window.SidekickPreview && SidekickPreview.render(\(code), \(name), \(lineArg))",
                completionHandler: nil)
        }
    }

    /// Show a plain message in the preview (e.g. a read failure).
    func previewMessage(_ text: String) {
        run {
            self.webView.evaluateJavaScript(
                "window.SidekickPreview && SidekickPreview.message(\(Self.jsString(text)))",
                completionHandler: nil)
        }
    }

    /// Run a preview JS action now, or stash it until the bundle finishes loading.
    private func run(_ action: @escaping () -> Void) {
        if isReady { action() } else { pending = action }
    }

    private func applyTheme() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.evaluateJavaScript(
            "window.SidekickPreview && SidekickPreview.setTheme('\(dark ? "dark" : "light")')",
            completionHandler: nil)
    }

    /// JSON-encode a Swift string into a JS string literal (quotes, newlines,
    /// `</script>` all delivered verbatim), like the Diff pane.
    private static func jsString(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    // MARK: Actions

    @objc private func refresh() { delegate?.treePaneDidRequestRefresh() }

    /// Single click: open a file/match in the editor; a folder just selects (its
    /// disclosure triangle / double-click handles expansion).
    @objc private func handleClick() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        activate(node)
    }

    /// Double click: toggle a folder (or a file that has match rows). Files already
    /// opened on the single click, so they're not re-opened here.
    @objc private func handleDoubleClick() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        guard !node.children.isEmpty else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) }
        else { outline.expandItem(node) }
    }

    private func activateSelected() {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        activate(node)
    }

    /// Open a row: a pane row goes to that pane (carrying the query, so the find
    /// bar lands on the line you clicked); a file or match row opens in the
    /// editor; a folder does nothing.
    private func activate(_ node: Node) {
        guard !node.isFolder else { return }
        if let pane = node.pane {
            delegate?.treePaneDidActivatePane(pane, needle: searchField.stringValue)
            return
        }
        delegate?.treePaneDidActivate(file: node.relativePath, line: node.lineNumber)
    }

    // MARK: Context menu (right-click a file)

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// The file/match node under the right-click, or nil for a folder / empty space.
    private func clickedFileNode() -> Node? {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, !node.isFolder,
              node.pane == nil  // pane rows have no file to open
        else { return nil }
        return node
    }

    @objc private func ctxOpenInEditor(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? Node else { return }
        delegate?.treePaneDidActivate(file: node.relativePath, line: node.lineNumber)
    }

    @objc private func ctxOpenInDefaultApp(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? Node else { return }
        delegate?.treePaneDidOpenInDefaultApp(file: node.relativePath)
    }
}

// MARK: - NSMenuDelegate (right-click: open in editor / default app)

extension TreeViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedFileNode() else { return }
        let editorItem = NSMenuItem(
            title: "Open in Editor", action: #selector(ctxOpenInEditor(_:)), keyEquivalent: "")
        editorItem.target = self
        editorItem.representedObject = node
        menu.addItem(editorItem)
        // "Open in Default App" only for local sessions — it can't reach a file on
        // a remote host.
        if hostIsLocal {
            let appItem = NSMenuItem(
                title: "Open in Default App", action: #selector(ctxOpenInDefaultApp(_:)),
                keyEquivalent: "")
            appItem.target = self
            appItem.representedObject = node
            menu.addItem(appItem)
        }
    }
}

// MARK: - NSSearchFieldDelegate (debounced query + key routing)

extension TreeViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.delegate?.treePaneDidChangeQuery(query, scope: self.scope)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelected(); return true
        default:
            return false
        }
    }

    /// Move the outline selection to the next/previous selectable (non-folder) row
    /// while keeping focus in the search field, and preview it.
    private func moveSelection(by delta: Int) {
        let selectable = (0..<outline.numberOfRows).filter {
            if let n = outline.item(atRow: $0) as? Node { return !n.isFolder }
            return false
        }
        guard !selectable.isEmpty else { return }
        let current = outline.selectedRow
        let next: Int
        if let pos = selectable.firstIndex(of: current) {
            next = selectable[min(max(pos + delta, 0), selectable.count - 1)]
        } else {
            next = delta >= 0 ? selectable.first! : selectable.last!
        }
        outline.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        outline.scrollRowToVisible(next)
    }
}

// MARK: - NSOutlineViewDataSource

extension TreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node).map { !$0.children.isEmpty } ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension TreeViewController: NSOutlineViewDelegate {
    /// Match (line) rows are a touch denser than file/folder rows, like the left
    /// sidebar's leaf rows under its cards.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Node)?.isMatch == true ? 22 : 24
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if case .match(let m) = node.kind {
            let id = NSUserInterfaceItemIdentifier("matchCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? Self.makeMatchCell(id: id)
            cell.textField?.attributedStringValue = matchString(
                lineNumber: m.lineNumber, text: m.lineText, highlights: m.highlights)
            return cell
        }
        if case .paneMatch(let m) = node.kind {
            let id = NSUserInterfaceItemIdentifier("matchCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? Self.makeMatchCell(id: id)
            // No line number: a scrollback offset means nothing to a reader.
            cell.textField?.attributedStringValue = matchString(
                lineNumber: nil, text: m.lineText, highlights: m.highlights)
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("rowCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? TreeRowCell
            ?? TreeRowCell(id: id)
        cell.textField?.stringValue = node.name
        let isPane = node.pane != nil
        cell.textField?.textColor =
            node.isFolder || isPane ? SidebarPalette.text : SidebarPalette.muted
        let symbol = isPane ? "terminal" : (node.isFolder ? "folder" : "doc")
        cell.imageView?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: isPane ? "Pane" : nil)
        cell.imageView?.contentTintColor =
            node.isFolder || isPane ? SidebarPalette.accent : SidebarPalette.muted
        switch node.kind {
        case .file(let hits) where hits > 0, .pane(_, let hits) where hits > 0:
            cell.hits.stringValue = "\(hits)"
            cell.hits.isHidden = false
        default:
            cell.hits.isHidden = true
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard Self.previewEnabled else { return }  // preview off → selection just highlights
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, !node.isFolder else { return }
        delegate?.treePaneDidRequestPreview(file: node.relativePath, line: node.lineNumber)
    }

    /// Match row cell: a single monospaced attributed field (line number + line
    /// text with the matched span highlighted).
    private static func makeMatchCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        // One line, always: a pane's scrollback line can be far wider than the
        // panel, and a wrapping label overflows its fixed-height row and paints
        // over the next one.
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// One match row: an optional line number (files have one; a pane's
    /// scrollback offset would be noise) then the line with its matched spans
    /// picked out. Shared by both scopes so hits read identically.
    private func matchString(
        lineNumber: Int?, text lineText: String, highlights: [Range<Int>]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: lineNumber.map { String(format: "%5d  ", $0) } ?? "  ",
            attributes: [.foregroundColor: SidebarPalette.muted, .font: mono])
        let text = NSMutableAttributedString(
            string: lineText,
            attributes: [.foregroundColor: SidebarPalette.text, .font: mono])
        for byteRange in highlights {
            guard let ns = Self.nsRange(byteRange: byteRange, in: lineText) else { continue }
            text.addAttributes([.foregroundColor: SidebarPalette.amber, .font: monoBold], range: ns)
        }
        result.append(text)
        return result
    }

    /// Convert ripgrep's UTF-8 byte range into an `NSRange` (UTF-16) within `s`.
    static func nsRange(byteRange r: Range<Int>, in s: String) -> NSRange? {
        let u = s.utf8
        guard let lo = u.index(u.startIndex, offsetBy: r.lowerBound, limitedBy: u.endIndex),
              let hi = u.index(u.startIndex, offsetBy: r.upperBound, limitedBy: u.endIndex),
              let loStr = lo.samePosition(in: s), let hiStr = hi.samePosition(in: s)
        else { return nil }
        return NSRange(loStr..<hiStr, in: s)
    }
}

// MARK: - Cell for folder / file rows (icon + name + optional hit count)

private final class TreeRowCell: NSTableCellView {
    let hits = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        hits.font = .systemFont(ofSize: 11)
        hits.textColor = SidebarPalette.muted
        hits.translatesAutoresizingMaskIntoConstraints = false
        hits.setContentHuggingPriority(.required, for: .horizontal)
        hits.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(imageView)
        addSubview(field)
        addSubview(hits)
        self.imageView = imageView
        textField = field
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: hits.leadingAnchor, constant: -6),
            hits.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hits.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - WKNavigationDelegate (bundle ready → flush pending preview)

extension TreeViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        applyTheme()
        if let pending { self.pending = nil; pending() }
    }
}

// MARK: - NSSplitViewDelegate (keep tree + preview usable)

extension TreeViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMin, 150)  // tree never narrower than this
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMax, splitView.bounds.width - 180)  // preview keeps ≥180
    }
}
