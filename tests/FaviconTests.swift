import XCTest

// Favicon.swift is compiled directly into this test target; only the pure
// `candidatePath` logic is exercised here (no disk I/O, injected `exists`).

final class FaviconTests: XCTestCase {
    func testPicksHighestPriorityExistingCandidate() {
        // A SvelteKit static/favicon.png and a root favicon.ico both exist — the
        // higher-priority static/ candidate wins.
        let present: Set<String> = ["/repo/static/favicon.png", "/repo/favicon.ico"]
        XCTAssertEqual(
            Favicon.candidatePath(in: "/repo", exists: { present.contains($0) }),
            "/repo/static/favicon.png")
    }

    func testPublicFaviconWhenNoStatic() {
        let present: Set<String> = ["/repo/public/favicon.ico"]
        XCTAssertEqual(
            Favicon.candidatePath(in: "/repo", exists: { present.contains($0) }),
            "/repo/public/favicon.ico")
    }

    func testMissReturnsNil() {
        XCTAssertNil(Favicon.candidatePath(in: "/repo", exists: { _ in false }))
    }

    func testEmptyDirReturnsNil() {
        // No dir → no candidates probed, even if everything "exists".
        XCTAssertNil(Favicon.candidatePath(in: "", exists: { _ in true }))
    }
}
