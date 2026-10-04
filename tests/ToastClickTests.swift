import XCTest

final class ToastClickTests: XCTestCase {
    private let link = ThreadLink.thread(id: "abc")

    // The × click reaches the toast's click gesture, never the button (see
    // `ManagerToastOverlay.clicked`), so this answer is the only thing that
    // dismisses the toast. Returning nothing here shipped a dead × in #124.
    func testClickOnCloseButtonDismisses() {
        XCTAssertEqual(ToastClick.action(inCloseButton: true, link: nil), .dismiss)
    }

    func testCloseButtonWinsOverALinkUnderIt() {
        XCTAssertEqual(ToastClick.action(inCloseButton: true, link: link), .dismiss)
    }

    func testClickOnALinkOpensIt() {
        XCTAssertEqual(ToastClick.action(inCloseButton: false, link: link), .openLink(link))
    }

    func testClickOnTheActionButtonRunsIt() {
        XCTAssertEqual(
            ToastClick.action(inCloseButton: false, inActionButton: true, link: nil), .action)
        XCTAssertEqual(
            ToastClick.action(inCloseButton: true, inActionButton: true, link: nil), .dismiss)
    }

    func testClickElsewhereOpensTheTarget() {
        XCTAssertEqual(ToastClick.action(inCloseButton: false, link: nil), .open)
    }
}
