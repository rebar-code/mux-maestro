import XCTest

// LinkHover.swift is compiled directly into this bundle (no @testable import).
final class LinkHoverTests: XCTestCase {
    private func url(_ row: String, _ column: Int) -> String? {
        LinkHover.url(inRow: row, column: column)?.absoluteString
    }

    func testURLMidRow() {
        let row = "see https://example.com/a/b for details"
        XCTAssertEqual(url(row, 4), "https://example.com/a/b")
        XCTAssertEqual(url(row, 15), "https://example.com/a/b")
        XCTAssertEqual(url(row, 26), "https://example.com/a/b")
    }

    func testColumnOffURLIsNil() {
        let row = "see https://example.com/a/b for details"
        XCTAssertNil(url(row, 0))
        XCTAssertNil(url(row, 3))
        XCTAssertNil(url(row, 27))
        XCTAssertNil(url(row, 200))
        XCTAssertNil(url(row, -1))
        XCTAssertNil(url("no links here", 3))
    }

    func testTrailingPunctuationTrimmed() {
        XCTAssertEqual(url("Open https://example.com/pr/1.", 10), "https://example.com/pr/1")
        XCTAssertEqual(url("at https://example.com/x, then", 5), "https://example.com/x")
        XCTAssertEqual(url("\"https://example.com/q\"", 3), "https://example.com/q")
        // The trimmed period is not part of the link.
        XCTAssertNil(url("Open https://example.com/pr/1.", 29))
    }

    func testParens() {
        XCTAssertEqual(url("(see https://example.com/a)", 8), "https://example.com/a")
        XCTAssertEqual(
            url("https://en.wikipedia.org/wiki/Swift_(programming_language)", 3),
            "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        XCTAssertEqual(url("[link](https://example.com/b)", 10), "https://example.com/b")
    }

    func testTwoURLsOnOneRow() {
        let row = "https://a.example.com and http://b.example.com/x"
        XCTAssertEqual(url(row, 2), "https://a.example.com")
        XCTAssertEqual(url(row, 30), "http://b.example.com/x")
        XCTAssertNil(url(row, 23))
    }

    func testTmuxBorderStopsURL() {
        let row = "https://example.com/left│right pane text"
        XCTAssertEqual(url(row, 3), "https://example.com/left")
        XCTAssertNil(url(row, 26))
        let right = "left pane text      │https://example.com/r"
        XCTAssertEqual(url(right, 25), "https://example.com/r")
    }

    func testWideCharsBeforeURL() {
        // "日本" takes 4 cells, so the URL starts at cell 5, not 3.
        let row = "日本 https://example.com/j"
        XCTAssertNil(url(row, 3))
        XCTAssertEqual(url(row, 5), "https://example.com/j")
        XCTAssertEqual(url(row, 25), "https://example.com/j")
        XCTAssertNil(url(row, 26))
        // An emoji is wide too.
        XCTAssertEqual(url("🚀 https://example.com", 3), "https://example.com")
    }

    func testSchemeOnlyIsNil() {
        XCTAssertNil(url("https:// nothing", 2))
    }
}
