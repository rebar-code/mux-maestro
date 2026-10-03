import Cocoa

/// Read-only text that shows each `muxmaestro://` link as a short, clickable
/// label (`ThreadLinks.label(for:)`) — the manager rail's review rows and its
/// toast.
///
/// It never takes a mouse event itself (`hitTest` returns nil). The row or toast
/// hosting it keeps its one click handler and asks `link(at:)` whether the click
/// landed on a link. That also works in the toast's panel, which never becomes
/// key — a selectable text view would never see the click there.
final class LinkLabel: NSTextView {
    /// TextKit 1, built by hand so glyph hit-testing is available. The storage
    /// roots the text system and is not retained by the view — keep it here.
    private let storage: NSTextStorage
    private let maxLines: Int
    private let bodyFont: NSFont
    private let bodyColor: NSColor

    init(font: NSFont, color: NSColor, maxLines: Int) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byTruncatingTail
        layout.addTextContainer(container)
        self.storage = storage
        self.maxLines = maxLines
        self.bodyFont = font
        self.bodyColor = color
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Show `text` with every parseable link replaced by its label.
    func setText(_ text: String) {
        let plain: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: bodyColor]
        var linked = plain
        linked[.foregroundColor] = SidebarPalette.accent
        linked[.underlineStyle] = NSUnderlineStyle.single.rawValue

        let ns = text as NSString
        let out = NSMutableAttributedString()
        var cursor = 0
        for match in ThreadLinks.matches(in: text) {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            out.append(NSAttributedString(string: ns.substring(with: before), attributes: plain))
            linked[.muxLink] = ThreadLinks.url(for: match.link)
            out.append(NSAttributedString(string: ThreadLinks.label(for: match.link), attributes: linked))
            cursor = match.range.upperBound
        }
        out.append(NSAttributedString(string: ns.substring(from: cursor), attributes: plain))
        setAttributedText(out)
    }

    /// Show text already styled, links marked with `.muxLink` (`ChatMarkdown`).
    func setAttributedText(_ text: NSAttributedString) {
        storage.setAttributedString(text)
        window?.invalidateCursorRects(for: self)
    }

    /// The link drawn under `point`, in this view's coordinates.
    func link(at point: NSPoint) -> ThreadLink? {
        linkTarget(at: point).flatMap(ThreadLinks.parse)
    }

    /// The URL string of any link drawn under `point`: a `muxmaestro://` link or
    /// a web link from markdown.
    func linkTarget(at point: NSPoint) -> String? {
        guard let layout = layoutManager, let container = textContainer, storage.length > 0
        else { return nil }
        let origin = textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: p, in: container)
        let glyphRect = layout.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.contains(p) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              let url = storage.attribute(.muxLink, at: index, effectiveRange: nil) as? String
        else { return nil }
        return url
    }

    /// The link under a point in window coordinates (an event's `locationInWindow`).
    func link(atWindowPoint point: NSPoint) -> ThreadLink? {
        link(at: convert(point, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        let line = layoutManager?.defaultLineHeight(for: bodyFont) ?? ceil(bodyFont.pointSize * 1.2)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(line * CGFloat(maxLines)))
    }

    /// A pointing hand over each link; nothing elsewhere (the text isn't selectable).
    override func resetCursorRects() {
        guard let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.muxLink, in: all) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
            }
        }
    }
}
