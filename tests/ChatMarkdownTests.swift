import AppKit
import XCTest

// ChatMarkdown.swift and ThreadLinks.swift are compiled directly into this bundle.
final class ChatMarkdownTests: XCTestCase {
    private let style = ChatMarkdown.Style(
        font: .systemFont(ofSize: 12),
        color: .white,
        muted: .gray,
        link: .blue,
        codeBackground: .darkGray)

    private func render(_ markdown: String, streaming: Bool = false) -> NSAttributedString {
        ChatMarkdown.render(markdown, style: style, streaming: streaming)
    }

    private func font(_ text: NSAttributedString, at needle: String) -> NSFont? {
        let range = (text.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    private func paragraph(_ text: NSAttributedString, at needle: String) -> NSParagraphStyle? {
        let range = (text.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    }

    private func linkTarget(_ text: NSAttributedString, at needle: String) -> String? {
        let range = (text.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.muxLink, at: range.location, effectiveRange: nil) as? String
    }

    private func isBold(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    private func isMono(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
    }

    // MARK: Blocks

    func testPlainTextPassesThrough() {
        let text = render("Nothing to see here.")
        XCTAssertEqual(text.string, "Nothing to see here.")
        XCTAssertEqual(font(text, at: "Nothing")?.pointSize, 12)
    }

    func testHeadingIsBoldAndLargerAndOnItsOwnLine() {
        let text = render("# Status\nAll green.")
        XCTAssertEqual(text.string, "Status\nAll green.")
        XCTAssertTrue(isBold(font(text, at: "Status")))
        XCTAssertGreaterThan(font(text, at: "Status")?.pointSize ?? 0, 12)
        XCTAssertFalse(isBold(font(text, at: "All green")))
    }

    func testParagraphsAreSeparateLines() {
        XCTAssertEqual(render("one\n\ntwo").string, "one\ntwo")
    }

    func testFencedCodeIsMonospacedOnATintedBlock() {
        let text = render("Run:\n\n```sh\nmake test\nmake app\n```\nDone.")
        XCTAssertEqual(text.string, "Run:\nmake test\nmake app\nDone.")
        XCTAssertTrue(isMono(font(text, at: "make test")))
        XCTAssertFalse(isMono(font(text, at: "Done")))
        let blocks = paragraph(text, at: "make app")?.textBlocks ?? []
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.backgroundColor, style.codeBackground)
        XCTAssertTrue(
            paragraph(text, at: "make test")?.textBlocks.first === blocks.first,
            "every line of one fence shares one block, so it draws as one tint")
        XCTAssertEqual(paragraph(text, at: "Done")?.textBlocks.count, 0)
    }

    func testBulletListHasMarkersAndHangingIndent() {
        let text = render("- one\n- two")
        XCTAssertEqual(text.string, "•\tone\n•\ttwo")
        let style = paragraph(text, at: "two")
        XCTAssertNotNil(style)
        XCTAssertGreaterThan(style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
        XCTAssertEqual(style?.tabStops.first?.location, style?.headIndent)
    }

    func testListItemsSitTightButTheListEndsWithFullSpacing() {
        let text = render("- one\n- two\n\nAfter.")
        let inside = paragraph(text, at: "one")?.paragraphSpacing ?? 0
        let last = paragraph(text, at: "two")?.paragraphSpacing ?? 0
        XCTAssertLessThan(inside, last)
        XCTAssertEqual(last, paragraph(text, at: "After")?.paragraphSpacing)
    }

    func testNumberedAndNestedLists() {
        let text = render("1. first\n2. second\n   - inner")
        XCTAssertEqual(text.string, "1.\tfirst\n2.\tsecond\n•\tinner")
        let outer = paragraph(text, at: "second")?.headIndent ?? 0
        let inner = paragraph(text, at: "inner")?.headIndent ?? 0
        XCTAssertGreaterThan(inner, outer)
    }

    // MARK: Inline

    func testBoldItalicAndInlineCode() {
        let text = render("a **bold** and *soft* with `code`")
        XCTAssertEqual(text.string, "a bold and soft with code")
        XCTAssertTrue(isBold(font(text, at: "bold")))
        XCTAssertTrue(font(text, at: "soft")?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertTrue(isMono(font(text, at: "code")))
        XCTAssertFalse(isBold(font(text, at: "a ")))
    }

    // MARK: Links

    func testMarkdownLinkKeepsItsTextAndCarriesTheURL() {
        let text = render("See [the PR](https://github.com/rebar-code/mux-maestro/pull/1).")
        XCTAssertEqual(text.string, "See the PR.")
        XCTAssertEqual(linkTarget(text, at: "the PR"), "https://github.com/rebar-code/mux-maestro/pull/1")
        XCTAssertNil(linkTarget(text, at: "See"))
    }

    func testBareMuxLinkBecomesItsLabel() {
        let url = "muxmaestro://open?session=my_web_app&window=2"
        let text = render("Look at \(url) now")
        let link = ThreadLinks.parse(url)!
        let label = ThreadLinks.label(for: link)
        XCTAssertEqual(text.string, "Look at \(label) now")
        XCTAssertEqual(linkTarget(text, at: label), ThreadLinks.url(for: link))
    }

    func testMuxLinkInsideCodeIsLeftAlone() {
        let url = "muxmaestro://open?session=web"
        let text = render("`\(url)`")
        XCTAssertEqual(text.string, url)
        XCTAssertNil(linkTarget(text, at: url))
    }

    // MARK: Streaming

    func testStreamingUnclosedBoldRendersBoldWithoutStars() {
        let text = render("a **bol", streaming: true)
        XCTAssertEqual(text.string, "a bol")
        XCTAssertTrue(isBold(font(text, at: "bol")))
    }

    func testStreamingDanglingOpenerIsHidden() {
        XCTAssertEqual(render("a **", streaming: true).string, "a")
        XCTAssertEqual(render("see `", streaming: true).string, "see")
    }

    func testStreamingUnclosedInlineCode() {
        let text = render("run `make te", streaming: true)
        XCTAssertEqual(text.string, "run make te")
        XCTAssertTrue(isMono(font(text, at: "make te")))
    }

    func testStreamingUnclosedFenceIsAlreadyCode() {
        let text = render("Run:\n```sh\nmake te", streaming: true)
        XCTAssertEqual(text.string, "Run:\nmake te")
        XCTAssertTrue(isMono(font(text, at: "make te")))
    }

    func testStreamingHalfTypedMarkerLineIsHeld() {
        // A lone "-" under a line is a setext heading in full markdown: it would
        // flash the line above as a heading until the next character arrives.
        let text = render("Some text\n-", streaming: true)
        XCTAssertEqual(text.string, "Some text")
        XCTAssertEqual(font(text, at: "Some")?.pointSize, 12)
        XCTAssertFalse(isBold(font(text, at: "Some")))
    }

    func testStreamingHalfTypedLinkShowsItsText() {
        let text = render("see [the PR](https://github.com/acme", streaming: true)
        XCTAssertEqual(text.string, "see the PR")
    }

    func testFinishedTextIsNotSettled() {
        XCTAssertEqual(render("2 ** 3").string, "2 ** 3")
    }
}
