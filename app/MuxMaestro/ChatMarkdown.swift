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
        /// The pull requests the sidebar shows on its windows, by `PRLinks.key`.
        /// A link to one of them takes its colour, and its icon before the text.
        var pullRequests: [String: PullRequest] = [:]
        /// The colour and SF Symbol for a pull request's state.
        var pullRequestLook: ((PullRequest) -> (color: NSColor, symbol: String))?
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
                appendLink(shown, to: url.absoluteString, attributes: attrs, out: out)
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

    /// Append `text`, each bare `muxmaestro://` URL in it shown as its label,
    /// and each bare pull request URL made a link.
    private func appendLinkingMuxURLs(
        _ text: String, attributes: [NSAttributedString.Key: Any], to out: NSMutableAttributedString
    ) {
        var linked = attributes
        linked[.foregroundColor] = style.link
        linked[.underlineStyle] = NSUnderlineStyle.single.rawValue
        let ns = text as NSString
        let threads = ThreadLinks.matches(in: text).map {
            (range: $0.range, url: ThreadLinks.url(for: $0.link), label: ThreadLinks.label(for: $0.link))
        }
        let prs = PRLinks.matches(in: text).filter { pr in
            !threads.contains { NSIntersectionRange($0.range, pr).length > 0 }
        }.map { (range: $0, url: ns.substring(with: $0), label: ns.substring(with: $0)) }
        var cursor = 0
        for match in (threads + prs).sorted(by: { $0.range.location < $1.range.location }) {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            out.append(NSAttributedString(string: ns.substring(with: before), attributes: attributes))
            linked[.muxLink] = match.url
            appendLink(match.label, to: match.url, attributes: linked, out: out)
            cursor = match.range.upperBound
        }
        out.append(NSAttributedString(string: ns.substring(from: cursor), attributes: attributes))
    }

    /// Append a link. One to a pull request the sidebar knows takes the colour
    /// of its state, behind the icon for it; the icon opens the link too.
    private func appendLink(
        _ text: String, to url: String, attributes: [NSAttributedString.Key: Any], out: NSMutableAttributedString
    ) {
        var attrs = attributes
        if let key = PRLinks.key(url), let pr = style.pullRequests[key], let look = style.pullRequestLook?(pr) {
            attrs[.foregroundColor] = look.color
            let font = attrs[.font] as? NSFont ?? style.font
            if let image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [look.color])))
            {
                let attachment = NSTextAttachment()
                attachment.image = image
                // The symbol's own size for the font, centred on the capitals.
                let size = image.size
                attachment.bounds = CGRect(
                    x: 0, y: ((font.capHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
                var iconAttrs = attrs
                iconAttrs[.underlineStyle] = nil
                let icon = NSMutableAttributedString(attachment: attachment)
                icon.addAttributes(iconAttrs, range: NSRange(location: 0, length: icon.length))
                out.append(icon)
                out.append(NSAttributedString(string: "\u{2009}", attributes: iconAttrs))
            }
        }
        out.append(NSAttributedString(string: text, attributes: attrs))
    }
}

/// Links to GitHub pull requests, and the ones the sidebar knows.
enum PRLinks {
    /// A pull request page, or a tab of one: `/files`, `/commits`, `#diff-…`.
    private static let pattern = #"https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)(?:/[\w/-]*)?(?:[?#][^\s)\]>]*)?"#

    /// `owner/repo#n`, in lower case, for a pull request URL; nil for any other.
    static func key(_ url: String) -> String? {
        let ns = url as NSString
        guard let match = try? NSRegularExpression(pattern: "^" + pattern + "$", options: .caseInsensitive)
            .firstMatch(in: url, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let part = { ns.substring(with: match.range(at: $0)) }
        guard let number = Int(part(3)) else { return nil }
        return "\(part(1))/\(part(2))#\(number)".lowercased()
    }

    /// The ranges of bare pull request URLs in `text`. A full stop or comma that
    /// ends a sentence is not part of the URL.
    static func matches(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            var range = match.range
            while range.length > 0, ".,;:!?".contains(ns.substring(with: NSRange(location: range.upperBound - 1, length: 1))) {
                range.length -= 1
            }
            return range
        }
    }

    /// Pull requests by `key`.
    static func index(_ prs: [PullRequest]) -> [String: PullRequest] {
        var out: [String: PullRequest] = [:]
        for pr in prs { if let key = key(pr.url) { out[key] = pr } }
        return out
    }
}

/// The pull requests the sidebar shows on its windows, for the links to them in
/// a chat. Set on the main thread after each PR scan; `changed` is posted only
/// when a state or a PR changed.
enum KnownPullRequests {
    static let changed = Notification.Name("MuxMaestroKnownPullRequestsChanged")
    private(set) static var byKey: [String: PullRequest] = [:]

    static func update(_ byWindow: [String: [PullRequest]]) {
        let next = PRLinks.index(byWindow.values.flatMap { $0 })
        guard next != byKey else { return }
        byKey = next
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
