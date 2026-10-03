import AppKit

extension NSAttributedString.Key {
    /// A link `LinkLabel` draws and hit-tests: a `muxmaestro://` or web URL string.
    static let muxLink = NSAttributedString.Key("MuxMaestroLink")
}

/// Markdown in a manager reply, as attributed text for `LinkLabel`.
///
/// Foundation parses the markdown (`AttributedString(markdown:)` with `.full`
/// syntax). It drops the block structure from the characters and keeps it in
/// each run's `presentationIntent`, so this rebuilds it: one line per block,
/// paragraph styles for headings, lists and quotes, and one shared `NSTextBlock`
/// per fence so a code block draws as a single tinted box (TextKit 1, which
/// `LinkLabel` uses, draws text blocks). Links carry `.muxLink`, never `.link`:
/// the label is not selectable, and its host does the click.
enum ChatMarkdown {
    struct Style {
        let font: NSFont
        let color: NSColor
        let muted: NSColor
        let link: NSColor
        let codeBackground: NSColor
    }

    /// `streaming` is a reply still arriving: its tail is settled first, so a
    /// half-typed marker never flashes as literal text or the wrong block.
    static func render(_ markdown: String, style: Style, streaming: Bool = false) -> NSAttributedString {
        let source = streaming ? settle(markdown) : markdown
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        else { return Renderer(style: style).plain(source) }
        return Renderer(style: style).render(parsed)
    }

    // MARK: Streaming

    /// Close or hold back what a cut-off reply leaves open: a dangling `**` or
    /// backtick, a half-typed link, a last line that is only markup. An open
    /// fence needs nothing — markdown already runs it to the end as code.
    static func settle(_ partial: String) -> String {
        var lines = partial.components(separatedBy: "\n")
        if lines.filter(isFence).count % 2 == 1 { return partial }

        // A marker-only last line ("-", "##", "1.", "```") is half a block.
        if let last = lines.last, last.range(of: markerOnlyLine, options: .regularExpression) != nil {
            lines.removeLast()
        }
        var text = lines.joined(separator: "\n")
        while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }

        let paragraphStart = text.range(of: "\n\n", options: .backwards)?.upperBound ?? text.startIndex
        let tail = text[paragraphStart...]
        var openTicks = 0
        var strongOpen = false
        var index = tail.startIndex
        while index < tail.endIndex {
            let char = tail[index]
            let run = tail[index...].prefix { $0 == char }
            if char == "`" {
                if openTicks == 0 { openTicks = run.count } else if run.count == openTicks { openTicks = 0 }
            } else if char == "*", openTicks == 0, run.count >= 2 {
                strongOpen.toggle()
            }
            index = run.endIndex
        }

        if openTicks > 0 { text = closing(text, with: String(repeating: "`", count: openTicks)) }
        if strongOpen { text = closing(text, with: "**") }
        if text.range(of: #"\[[^\]\n]*\]\([^)\s]*$"#, options: .regularExpression) != nil {
            text += ")"
        }
        return text
    }

    /// Close an open marker, or drop it when nothing follows it yet.
    private static func closing(_ text: String, with marker: String) -> String {
        guard text.hasSuffix(marker) else { return text + marker }
        var trimmed = String(text.dropLast(marker.count))
        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
        return trimmed
    }

    private static let markerOnlyLine = #"^ {0,3}([-*+=_#>`~]+|\d{1,9}[.)])\s*$"#

    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return line.count - trimmed.count <= 3 && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
    }
}

/// One render pass: Foundation runs in, block-separated attributed text out.
private struct Renderer {
    let style: ChatMarkdown.Style

    private static let indentStep: CGFloat = 18
    private static let quoteStep: CGFloat = 10

    /// The parse failed: the text as is, links still labeled.
    func plain(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        appendLinkingMuxURLs(text, attributes: [.font: style.font, .foregroundColor: style.color], to: out)
        return out
    }

    func render(_ parsed: AttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var block: (id: Int, intent: PresentationIntent?, start: Int, marked: Bool)?
        var seenItems = Set<Int>()
        var code: NSTextBlock?

        func close(before next: PresentationIntent?) {
            guard let block else { return }
            let range = NSRange(location: block.start, length: out.length - block.start)
            out.addAttribute(
                .paragraphStyle,
                value: paragraphStyle(block.intent, marked: block.marked, code: code, next: next),
                range: range)
        }

        for run in parsed.runs {
            let intent = run.presentationIntent
            let id = blockID(intent)
            let text = String(parsed[run.range].characters)

            if block?.id != id {
                close(before: intent)
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: base)) }
                code = isCode(intent) ? codeBlock() : nil
                let marker = listMarker(intent, seen: &seenItems)
                block = (id, intent, out.length, marker != nil)
                if let marker {
                    out.append(NSAttributedString(string: marker, attributes: attributes(for: intent)))
                }
            } else if isTableCell(intent) {
                out.append(NSAttributedString(string: "   ", attributes: base))
            }

            var attrs = attributes(for: intent)
            applyInline(run.inlinePresentationIntent, to: &attrs)
            if isCode(intent) {
                out.append(NSAttributedString(string: trimmingFinalNewline(text), attributes: attrs))
            } else if let url = run.link {
                attrs[.foregroundColor] = style.link
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.muxLink] = url.absoluteString
                let shown = text == url.absoluteString ? ThreadLinks.parse(text).map(ThreadLinks.label) ?? text : text
                out.append(NSAttributedString(string: shown, attributes: attrs))
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                out.append(NSAttributedString(string: text, attributes: attrs))
            } else {
                appendLinkingMuxURLs(text, attributes: attrs, to: out)
            }
        }
        close(before: nil)
        return out
    }

    // MARK: Blocks

    private var base: [NSAttributedString.Key: Any] {
        [.font: style.font, .foregroundColor: style.color]
    }

    /// The innermost block a run belongs to. Cells of one table row share a line.
    private func blockID(_ intent: PresentationIntent?) -> Int {
        guard let components = intent?.components, let inner = components.first else { return -1 }
        if case .tableCell = inner.kind, components.count > 1 { return components[1].identity }
        return inner.identity
    }

    private func isCode(_ intent: PresentationIntent?) -> Bool {
        guard case .codeBlock = intent?.components.first?.kind else { return false }
        return true
    }

    private func isTableCell(_ intent: PresentationIntent?) -> Bool {
        guard case .tableCell = intent?.components.first?.kind else { return false }
        return true
    }

    private func listDepth(_ intent: PresentationIntent?) -> Int {
        intent?.components.filter {
            if case .listItem = $0.kind { return true } else { return false }
        }.count ?? 0
    }

    private func quoteDepth(_ intent: PresentationIntent?) -> Int {
        intent?.components.filter { $0.kind == .blockQuote }.count ?? 0
    }

    /// "•\t" or "3.\t" on the first block of a list item; nil on any later one.
    private func listMarker(_ intent: PresentationIntent?, seen: inout Set<Int>) -> String? {
        guard let components = intent?.components,
              let at = components.firstIndex(where: {
                  if case .listItem = $0.kind { return true } else { return false }
              }),
              case .listItem(let ordinal) = components[at].kind,
              seen.insert(components[at].identity).inserted
        else { return nil }
        let ordered = components.dropFirst(at + 1).first?.kind == .orderedList
        return ordered ? "\(ordinal).\t" : "•\t"
    }

    private func attributes(for intent: PresentationIntent?) -> [NSAttributedString.Key: Any] {
        var attrs = base
        guard let components = intent?.components else { return attrs }
        if quoteDepth(intent) > 0 { attrs[.foregroundColor] = style.muted }
        switch components.first?.kind {
        case .header(let level):
            let bump: CGFloat = level == 1 ? 3 : level == 2 ? 1.5 : 0
            attrs[.font] = NSFont.boldSystemFont(ofSize: style.font.pointSize + bump)
        case .codeBlock:
            attrs[.font] = monospaced(bold: false)
        case .thematicBreak:
            attrs[.foregroundColor] = style.muted
        case .tableCell where components.dropFirst().first?.kind == .tableHeaderRow:
            attrs[.font] = NSFont.boldSystemFont(ofSize: style.font.pointSize)
        default:
            break
        }
        return attrs
    }

    /// `marked` is the block that carries its list item's marker; a later block
    /// of the same item hangs with the item's text instead. `next` is the block
    /// that follows: list items sit tight, but a list ends with full spacing.
    private func paragraphStyle(
        _ intent: PresentationIntent?, marked: Bool, code: NSTextBlock?, next: PresentationIntent?
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let depth = CGFloat(listDepth(intent))
        let quote = CGFloat(quoteDepth(intent)) * Self.quoteStep
        paragraph.firstLineHeadIndent = quote + max(0, depth - 1) * Self.indentStep
        paragraph.headIndent = quote + depth * Self.indentStep
        if depth > 0 {
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
        }
        if depth > 0, !marked { paragraph.firstLineHeadIndent = paragraph.headIndent }
        paragraph.paragraphSpacing = depth > 0 && listDepth(next) > 0 ? 3 : 6
        if case .header = intent?.components.first?.kind { paragraph.paragraphSpacingBefore = 4 }
        if let code {
            paragraph.textBlocks = [code]
            paragraph.paragraphSpacing = 0
        }
        return paragraph
    }

    private func codeBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.backgroundColor = style.codeBackground
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    private func trimmingFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: Inline

    private func monospaced(bold: Bool) -> NSFont {
        .monospacedSystemFont(ofSize: style.font.pointSize - 1, weight: bold ? .semibold : .regular)
    }

    private func applyInline(_ inline: InlinePresentationIntent?, to attrs: inout [NSAttributedString.Key: Any]) {
        guard let inline, let font = attrs[.font] as? NSFont else { return }
        let strong = inline.contains(.stronglyEmphasized)
        if inline.contains(.code) {
            attrs[.font] = monospaced(bold: strong)
            attrs[.backgroundColor] = style.codeBackground
            return
        }
        var traits = font.fontDescriptor.symbolicTraits
        if strong { traits.insert(.bold) }
        if inline.contains(.emphasized) { traits.insert(.italic) }
        if traits != font.fontDescriptor.symbolicTraits {
            attrs[.font] = NSFont(
                descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        }
        if inline.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
    }

    /// Append `text`, each bare `muxmaestro://` URL in it shown as its label.
    private func appendLinkingMuxURLs(
        _ text: String, attributes: [NSAttributedString.Key: Any], to out: NSMutableAttributedString
    ) {
        var linked = attributes
        linked[.foregroundColor] = style.link
        linked[.underlineStyle] = NSUnderlineStyle.single.rawValue
        let ns = text as NSString
        var cursor = 0
        for match in ThreadLinks.matches(in: text) {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            out.append(NSAttributedString(string: ns.substring(with: before), attributes: attributes))
            linked[.muxLink] = ThreadLinks.url(for: match.link)
            out.append(NSAttributedString(string: ThreadLinks.label(for: match.link), attributes: linked))
            cursor = match.range.upperBound
        }
        out.append(NSAttributedString(string: ns.substring(from: cursor), attributes: attributes))
    }
}
