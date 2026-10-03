import XCTest

// LinkRoute.swift and ThreadLinks.swift are compiled directly into this bundle
// (no @testable import), same as the other logic tests.
final class LinkRouteTests: XCTestCase {
    private let home = "/Users/me"

    private func route(_ url: String, cwd: String? = nil) -> LinkRoute {
        LinkRoute.route(url, cwd: cwd, home: home)
    }

    // MARK: Web

    func testHTTPAndHTTPSGoToTheBrowser() {
        XCTAssertEqual(route("https://example.com/a?b=1"), .browser(URL(string: "https://example.com/a?b=1")!))
        XCTAssertEqual(route("http://localhost:5173/"), .browser(URL(string: "http://localhost:5173/")!))
        XCTAssertEqual(route("HTTPS://Example.com"), .browser(URL(string: "HTTPS://Example.com")!))
    }

    func testOtherSchemesGoToTheSystem() {
        XCTAssertEqual(route("mailto:a@b.com"), .system(URL(string: "mailto:a@b.com")!))
        XCTAssertEqual(route("ssh://nas"), .system(URL(string: "ssh://nas")!))
    }

    // MARK: muxmaestro://

    func testThreadLinkOpensInApp() {
        let id = "3f2c9a1e-0000-4000-8000-a0b1c2d3e4f5"
        XCTAssertEqual(route("muxmaestro://thread/\(id)"), .thread(.thread(id: id)))
        XCTAssertEqual(
            route("muxmaestro://open?session=web&window=2"),
            .thread(.open(session: "web", window: 2, pane: nil, host: "localhost")))
    }

    func testBrokenThreadLinkSaysSo() {
        XCTAssertEqual(route("muxmaestro://close?session=web"), .badLink("muxmaestro://close?session=web"))
    }

    // MARK: Files

    func testAbsolutePathOpensTheFile() {
        XCTAssertEqual(route("/repo/app/Main.swift"), .file(path: "/repo/app/Main.swift", line: nil))
    }

    func testLineSuffixIsSplitOff() {
        XCTAssertEqual(route("/repo/Main.swift:42"), .file(path: "/repo/Main.swift", line: 42))
        XCTAssertEqual(route("/repo/Main.swift:42:7"), .file(path: "/repo/Main.swift", line: 42))
    }

    func testFileURLBecomesAPath() {
        XCTAssertEqual(route("file:///tmp/shot%201.png"), .file(path: "/tmp/shot 1.png", line: nil))
    }

    func testTildeExpandsToHome() {
        XCTAssertEqual(route("~/notes/todo.md"), .file(path: "/Users/me/notes/todo.md", line: nil))
    }

    func testRelativePathResolvesAgainstThePaneCwd() {
        XCTAssertEqual(route("./src/a.ts", cwd: "/repo"), .file(path: "/repo/src/a.ts", line: nil))
        XCTAssertEqual(route("src/a.ts:9", cwd: "/repo"), .file(path: "/repo/src/a.ts", line: 9))
        XCTAssertEqual(route("../other/b.md", cwd: "/repo/sub"), .file(path: "/repo/other/b.md", line: nil))
    }

    func testRelativePathWithoutCwdIsUnresolved() {
        XCTAssertEqual(route("src/a.ts"), .unresolved("src/a.ts"))
    }

    func testSurroundingWhitespaceIsIgnored() {
        // Ghostty's path regex can keep trailing spaces at end of line.
        XCTAssertEqual(route("/repo/a.txt  "), .file(path: "/repo/a.txt", line: nil))
    }

    func testEmptyIsUnresolved() {
        XCTAssertEqual(route(""), .unresolved(""))
    }

    // MARK: ⌘-hover under tmux mouse mode

    func testHoverAddsShiftOnlyWhenTheTerminalCapturesTheMouse() {
        XCTAssertTrue(LinkGesture.hoverAddsShift(command: true, overLink: false, mouseCaptured: true))
        XCTAssertFalse(LinkGesture.hoverAddsShift(command: true, overLink: false, mouseCaptured: false),
                       "without mouse reporting Ghostty matches ⌘ alone; Shift would break it")
        XCTAssertFalse(LinkGesture.hoverAddsShift(command: false, overLink: false, mouseCaptured: true),
                       "plain moves stay plain")
    }

    func testHoverKeepsShiftUntilALeftoverLinkHoverClears() {
        // ⌘ released over a link: one more Shift move lets Ghostty clear the hover.
        XCTAssertTrue(LinkGesture.hoverAddsShift(command: false, overLink: true, mouseCaptured: true))
    }

    func testClickAddsShiftOnlyForCommandClickOnALink() {
        XCTAssertTrue(LinkGesture.clickAddsShift(command: true, overLink: true, mouseCaptured: true))
        XCTAssertFalse(LinkGesture.clickAddsShift(command: true, overLink: false, mouseCaptured: true),
                       "⌘-click off a link still goes to tmux")
        XCTAssertFalse(LinkGesture.clickAddsShift(command: false, overLink: true, mouseCaptured: true))
        XCTAssertFalse(LinkGesture.clickAddsShift(command: true, overLink: true, mouseCaptured: false))
    }

    func testShiftedHoverForgetsGhosttysLastLookupWhenModsChange() {
        // Ghostty caches the last cell it looked up and ignores mod changes, so
        // ⌘ pressed over a cell it already checked would find nothing.
        XCTAssertTrue(LinkGesture.hoverResetsLookup(addsShift: true, modsChanged: true),
                      "plain → ⌘, and ⌘ released over a link (Shift kept)")
        XCTAssertFalse(LinkGesture.hoverResetsLookup(addsShift: true, modsChanged: false),
                       "⌘ held while moving: Ghostty sees each new cell")
        XCTAssertFalse(LinkGesture.hoverResetsLookup(addsShift: false, modsChanged: true),
                       "no lookup happens without Shift")
    }
}
