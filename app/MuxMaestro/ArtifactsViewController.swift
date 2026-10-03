import Cocoa
import Quartz
import QuickLookThumbnailing

/// What the Artifacts panel shows for the current selection.
enum ArtifactsState: Equatable {
    case noSelection
    /// The pane is on a remote host. Its transcript is not read yet, so the
    /// panel says so rather than showing a fake "nothing made".
    case remote
    /// The pane runs no Claude or Codex thread.
    case noThread
    case list(ArtifactsContent)
}

/// Everything the panel lists for one pane.
struct ArtifactsContent: Equatable {
    var artifacts: [Artifact] = []
    var servers: [ArtifactWebItem] = []
    var links: [ArtifactWebItem] = []

    var isEmpty: Bool { artifacts.isEmpty && servers.isEmpty && links.isEmpty }
}

protocol ArtifactsPaneDelegate: AnyObject {
    /// Double-click or ↩ on an artifact.
    func artifactsPaneDidActivate(_ artifact: Artifact)
    /// Click or ↩ on a server or link row.
    func artifactsPaneDidOpenURL(_ url: String)
}

/// The right sidebar's Artifacts item: what the selected pane's agent made.
/// Images as a thumbnail grid, files as rows, and a Quick Look preview of the
/// selection below. Click previews; Space opens the Quick Look panel; arrows
/// step; double-click opens. Local servers and links are rows that open in
/// the browser on click; right-click copies.
final class ArtifactsViewController: NSViewController {
    weak var delegate: ArtifactsPaneDelegate?

    private(set) var state: ArtifactsState = .noSelection
    private var images: [Artifact] = []
    private var files: [Artifact] = []
    private var servers: [ArtifactWebItem] = []
    private var links: [ArtifactWebItem] = []

    private enum Section: Int, CaseIterable { case images, files, servers, links }

    private let collection = ArtifactCollectionView()
    private let scroll = NSScrollView()
    private let split = NSSplitView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var preview: QLPreviewView?
    private var lastWidth: CGFloat = 0

    private var thumbnails: [String: NSImage] = [:]
    private let hoverPopover = NSPopover()
    private var hoverWork: DispatchWorkItem?

    static let thumbSide: CGFloat = 72

    override func loadView() {
        let container = NSView()

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        collection.collectionViewLayout = layout
        collection.register(ArtifactImageItem.self, forItemWithIdentifier: ArtifactImageItem.id)
        collection.register(ArtifactFileItem.self, forItemWithIdentifier: ArtifactFileItem.id)
        collection.register(ArtifactWebItemView.self, forItemWithIdentifier: ArtifactWebItemView.id)
        collection.register(
            ArtifactSectionHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: ArtifactSectionHeader.id)
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.allowsEmptySelection = true
        collection.backgroundColors = [SidebarPalette.bg]
        collection.dataSource = self
        collection.delegate = self
        collection.onActivate = { [weak self] in self?.activateSelected() }
        collection.onSpace = { [weak self] in self?.toggleQuickLook() }
        collection.onClick = { [weak self] path in
            if let web = self?.web(at: path) { self?.delegate?.artifactsPaneDidOpenURL(web.url) }
        }
        collection.menuFor = { [weak self] path in self?.copyMenu(for: path) }

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = SidebarPalette.bg

        split.isVertical = false
        split.dividerStyle = .thin
        split.autosaveName = "SidekickArtifactsSplit"
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(scroll)
        if let ql = QLPreviewView(frame: .zero, style: .compact) {
            ql.shouldCloseWithWindow = false
            ql.autostarts = true
            split.addArrangedSubview(ql)
            preview = ql
        }
        container.addSubview(split)

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = SidebarPalette.muted
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
        ])

        hoverPopover.behavior = .applicationDefined
        hoverPopover.animates = false

        self.view = container
        applyState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // File rows span the width, so a width change re-lays them out.
        let width = scroll.contentSize.width
        if width != lastWidth {
            lastWidth = width
            collection.collectionViewLayout?.invalidateLayout()
        }
        // The preview has no intrinsic height, so the split first hands it
        // nothing. Give it the lower ~45% once there is room, and stop once it
        // has a height (after that the divider is the user's). Placed after
        // this layout pass: a divider set mid-layout lands in the wrong place.
        if !didPlaceDivider, let preview, split.bounds.height > 200 {
            didPlaceDivider = true
            if preview.frame.height < 1 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.split.setPosition(self.split.bounds.height * 0.55, ofDividerAt: 0)
                }
            }
        }
    }
    private var didPlaceDivider = false

    // MARK: Render

    /// Show `state`. A repeat of what is shown is a no-op, so the 1.5s poll can
    /// call this freely without resetting selection or scroll.
    func render(_ new: ArtifactsState) {
        guard new != state else { return }
        let keep = selectedKey
        state = new
        guard isViewLoaded else { return }
        applyState()
        if let keep, let path = indexPath(ofKey: keep) {
            collection.selectItems(at: [path], scrollPosition: [])
        }
        updatePreview()
    }

    private func applyState() {
        var content = ArtifactsContent()
        switch state {
        case .noSelection: emptyLabel.stringValue = "Select a pane"
        case .remote: emptyLabel.stringValue = "Local panes only"
        case .noThread: emptyLabel.stringValue = "No agent thread in this pane"
        case .list(let c): content = c; emptyLabel.stringValue = c.isEmpty ? "Nothing made yet" : ""
        }
        emptyLabel.isHidden = emptyLabel.stringValue.isEmpty
        images = content.artifacts.filter { $0.kind == .image }
        files = content.artifacts.filter { $0.kind == .file }
        servers = content.servers
        links = content.links
        collection.reloadData()
    }

    private func count(_ section: Int) -> Int {
        switch Section(rawValue: section) {
        case .images: return images.count
        case .files: return files.count
        case .servers: return servers.count
        case .links: return links.count
        case nil: return 0
        }
    }

    private func artifact(at path: IndexPath) -> Artifact? {
        let list: [Artifact]
        switch Section(rawValue: path.section) {
        case .images: list = images
        case .files: list = files
        default: return nil
        }
        return list.indices.contains(path.item) ? list[path.item] : nil
    }

    private func web(at path: IndexPath) -> ArtifactWebItem? {
        let list: [ArtifactWebItem]
        switch Section(rawValue: path.section) {
        case .servers: list = servers
        case .links: list = links
        default: return nil
        }
        return list.indices.contains(path.item) ? list[path.item] : nil
    }

    /// What identifies the selection across a re-render: a path or a URL.
    private var selectedKey: String? {
        guard let path = collection.selectionIndexPaths.first else { return nil }
        return artifact(at: path)?.path ?? web(at: path).map { "\(path.section)|\($0.url)" }
    }

    private func indexPath(ofKey key: String) -> IndexPath? {
        if let i = images.firstIndex(where: { $0.path == key }) { return IndexPath(item: i, section: 0) }
        if let i = files.firstIndex(where: { $0.path == key }) { return IndexPath(item: i, section: 1) }
        if let i = servers.firstIndex(where: { "2|\($0.url)" == key }) { return IndexPath(item: i, section: 2) }
        if let i = links.firstIndex(where: { "3|\($0.url)" == key }) { return IndexPath(item: i, section: 3) }
        return nil
    }

    var selectedWebItem: ArtifactWebItem? {
        collection.selectionIndexPaths.first.flatMap(web(at:))
    }

    private func copyMenu(for path: IndexPath) -> NSMenu? {
        guard let url = web(at: path)?.url ?? artifact(at: path)?.path else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: web(at: path) != nil ? "Copy Link" : "Copy Path",
            action: #selector(copyString(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.addItem(item)
        return menu
    }

    @objc private func copyString(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Link favicons

    private var favicons: [String: NSImage] = [:]
    private var faviconMisses: Set<String> = []
    private var faviconLoads: [String: [(NSImage?) -> Void]] = [:]

    /// The site's own `/favicon.ico`, fetched once per host per run without
    /// cookies; nil (the row keeps its globe) on any failure.
    fileprivate func favicon(host: String, completion: @escaping (NSImage?) -> Void) {
        if let hit = favicons[host] { completion(hit); return }
        if faviconMisses.contains(host) { completion(nil); return }
        if faviconLoads[host] != nil { faviconLoads[host]?.append(completion); return }
        guard let url = URL(string: "https://\(host)/favicon.ico") else { completion(nil); return }
        faviconLoads[host] = [completion]
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpShouldHandleCookies = false
        Self.faviconSession.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let image = ok ? data.flatMap(NSImage.init(data:)) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.favicons[host] = image } else { self.faviconMisses.insert(host) }
                self.faviconLoads.removeValue(forKey: host)?.forEach { $0(image) }
            }
        }.resume()
    }

    private static let faviconSession = URLSession(configuration: .ephemeral)

    var selectedArtifact: Artifact? {
        collection.selectionIndexPaths.first.flatMap(artifact(at:))
    }

    private func updatePreview() {
        let item = selectedArtifact.flatMap { $0.exists ? URL(fileURLWithPath: $0.path) as NSURL : nil }
        if (preview?.previewItem as? NSURL) != item { preview?.previewItem = item }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    private func activateSelected() {
        if let web = selectedWebItem { delegate?.artifactsPaneDidOpenURL(web.url); return }
        guard let a = selectedArtifact, a.exists else { return }
        delegate?.artifactsPaneDidActivate(a)
    }

    // MARK: Thumbnails

    fileprivate func thumbnail(for a: Artifact, side: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = "\(a.path)#\(Int(side))"
        if let hit = thumbnails[key] { completion(hit); return }
        guard a.exists else { completion(nil); return }
        let scale = view.window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: a.path), size: CGSize(width: side, height: side),
            scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                let image = rep?.nsImage
                if let image { self?.thumbnails[key] = image }
                completion(image)
            }
        }
    }

    // MARK: Hover (images only)

    fileprivate func hoverChanged(_ item: ArtifactImageItem, inside: Bool) {
        hoverWork?.cancel()
        guard inside, let a = item.artifact, a.exists else {
            if hoverPopover.isShown { hoverPopover.close() }
            return
        }
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, item.view.window != nil else { return }
            self.thumbnail(for: a, side: 360) { image in
                guard let image, item.artifact == a, item.isHovered else { return }
                self.showHover(image, from: item.view)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func showHover(_ image: NSImage, from anchor: NSView) {
        let size = image.size
        let fit = min(360 / max(size.width, 1), 360 / max(size.height, 1), 1)
        let frame = NSRect(x: 0, y: 0, width: max(60, size.width * fit), height: max(60, size.height * fit))
        let imageView = NSImageView(frame: frame)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let vc = NSViewController()
        vc.view = imageView
        hoverPopover.contentViewController = vc
        hoverPopover.contentSize = frame.size
        hoverPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
    }

    // MARK: Quick Look panel (Space)

    private func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible { panel.orderOut(nil) } else if selectedArtifact?.exists == true {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - Collection data

extension ArtifactsViewController: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { Section.allCases.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        count(section)
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        if let web = web(at: indexPath) {
            let item = collectionView.makeItem(
                withIdentifier: ArtifactWebItemView.id, for: indexPath) as! ArtifactWebItemView
            item.configure(web, isServer: indexPath.section == Section.servers.rawValue, owner: self)
            return item
        }
        guard let a = artifact(at: indexPath) else { return NSCollectionViewItem() }
        if indexPath.section == 0 {
            let item = collectionView.makeItem(
                withIdentifier: ArtifactImageItem.id, for: indexPath) as! ArtifactImageItem
            item.configure(a, owner: self)
            return item
        }
        let item = collectionView.makeItem(
            withIdentifier: ArtifactFileItem.id, for: indexPath) as! ArtifactFileItem
        item.configure(a)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind, withIdentifier: ArtifactSectionHeader.id, for: indexPath) as! ArtifactSectionHeader
        let titles = ["Images", "Files", "Servers", "Links"]
        header.set(title: titles[indexPath.section], count: count(indexPath.section))
        return header
    }

    func collectionView(
        _ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> NSSize {
        return count(section) == 0 ? .zero : NSSize(width: collectionView.bounds.width, height: 24)
    }

    func collectionView(
        _ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        return count(section) == 0 ? NSEdgeInsetsZero : NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
    }

    func collectionView(
        _ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        if indexPath.section == 0 { return NSSize(width: Self.thumbSide, height: Self.thumbSide) }
        let height: CGFloat = indexPath.section == Section.files.rawValue ? 34 : 28
        return NSSize(width: max(60, collectionView.bounds.width - 16), height: height)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
    }
}

// MARK: - Quick Look panel data

extension ArtifactsViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedArtifact?.exists == true ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedArtifact.map { URL(fileURLWithPath: $0.path) as NSURL }
    }

    /// Arrow keys in the panel step the panel's own selection, which is ours.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        collection.keyDown(with: event)
        return true
    }
}

// MARK: - Views

/// Reports ↩ (activate), Space (Quick Look) and double-click. Arrow keys keep
/// the collection view's own stepping.
final class ArtifactCollectionView: NSCollectionView {
    var onActivate: (() -> Void)?
    var onSpace: (() -> Void)?
    /// A single click on an item (servers and links open on it).
    var onClick: ((IndexPath) -> Void)?
    var menuFor: ((IndexPath) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onActivate?()  // return, keypad enter
        case 49: onSpace?()         // space
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return }
        if event.clickCount == 1 { onClick?(path) } else if event.clickCount == 2 { onActivate?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return nil }
        selectionIndexPaths = [path]
        return menuFor?(path)
    }
}

final class ArtifactSectionHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("ArtifactSectionHeader")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func set(title: String, count: Int) {
        let s = NSMutableAttributedString(
            string: title, attributes: [.foregroundColor: SidebarPalette.text])
        s.append(NSAttributedString(
            string: "  \(count)", attributes: [.foregroundColor: SidebarPalette.muted]))
        label.attributedStringValue = s
    }
}

/// A view that reports the pointer entering and leaving it.
final class ArtifactHoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

final class ArtifactImageItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ArtifactImageItem")
    private(set) var artifact: Artifact?
    private(set) var isHovered = false
    private let thumb = NSImageView()

    override func loadView() {
        let v = ArtifactHoverView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 2
        v.layer?.borderColor = NSColor.clear.cgColor
        v.layer?.backgroundColor = SidebarPalette.card.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
            thumb.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 3),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -3),
        ])
        view = v
    }

    func configure(_ a: Artifact, owner: ArtifactsViewController) {
        artifact = a
        view.toolTip = a.exists ? a.name : "\(a.name) — missing"
        thumb.image = NSImage(
            systemSymbolName: a.exists ? "photo" : "photo.badge.exclamationmark",
            accessibilityDescription: nil)
        thumb.contentTintColor = SidebarPalette.muted
        (view as? ArtifactHoverView)?.onHover = { [weak self, weak owner] inside in
            guard let self else { return }
            self.isHovered = inside
            owner?.hoverChanged(self, inside: inside)
        }
        owner.thumbnail(for: a, side: ArtifactsViewController.thumbSide) { [weak self] image in
            guard let self, let image, self.artifact == a else { return }
            self.thumb.image = image
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderColor = (isSelected ? SidebarPalette.accent : NSColor.clear).cgColor
        }
    }
}

final class ArtifactFileItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ArtifactFileItem")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let dir = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 5
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        dir.font = .systemFont(ofSize: 10)
        dir.textColor = SidebarPalette.muted
        dir.lineBreakMode = .byTruncatingHead
        let text = NSStackView(views: [name, dir])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false
        [name, dir].forEach { $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        v.addSubview(icon)
        v.addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        view = v
    }

    func configure(_ a: Artifact) {
        icon.image = a.exists
            ? NSWorkspace.shared.icon(forFile: a.path)
            : NSImage(systemSymbolName: "doc.badge.ellipsis", accessibilityDescription: "Missing")
        icon.contentTintColor = SidebarPalette.muted
        name.stringValue = a.name
        name.textColor = a.exists ? SidebarPalette.text : SidebarPalette.muted
        dir.stringValue = a.exists
            ? (a.parentDir as NSString).abbreviatingWithTildeInPath
            : "missing · " + (a.parentDir as NSString).abbreviatingWithTildeInPath
        view.toolTip = a.path
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? SidebarPalette.accent.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        }
    }
}

/// A Servers or Links row: a live/dead dot (servers) or the site's favicon
/// (links), then host and path.
final class ArtifactWebItemView: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ArtifactWebItemView")
    private(set) var item: ArtifactWebItem?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 5
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.addSubview(icon)
        v.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        view = v
    }

    func configure(_ web: ArtifactWebItem, isServer: Bool, owner: ArtifactsViewController) {
        item = web
        let text = NSMutableAttributedString(string: web.host, attributes: [
            .foregroundColor: web.live == false ? SidebarPalette.muted : SidebarPalette.text,
            .font: NSFont.systemFont(ofSize: 12),
        ])
        text.append(NSAttributedString(string: web.path, attributes: [
            .foregroundColor: SidebarPalette.muted, .font: NSFont.systemFont(ofSize: 12),
        ]))
        label.attributedStringValue = text
        if isServer {
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            icon.image = NSImage(
                systemSymbolName: web.live == nil ? "circle" : "circle.fill",
                accessibilityDescription: web.live == true ? "Running" : web.live == false ? "Stopped" : "Unknown"
            )?.withSymbolConfiguration(config)
            icon.contentTintColor = web.live == true ? SidebarPalette.green : SidebarPalette.muted
            view.toolTip = web.live == true ? "Running · \(web.url)" : web.live == false ? "Stopped · \(web.url)" : web.url
        } else {
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = SidebarPalette.muted
            view.toolTip = web.url
            let host = URLComponents(string: web.url)?.host ?? web.host
            owner.favicon(host: host) { [weak self] image in
                guard let self, let image, self.item == web else { return }
                self.icon.image = image
                self.icon.contentTintColor = nil
            }
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? SidebarPalette.accent.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        }
    }
}
