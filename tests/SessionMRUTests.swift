import XCTest

// SessionMRU.swift + SshConfig.swift (for Host) are compiled directly into this
// test target.

final class SessionMRUTests: XCTestCase {
    private func ref(_ name: String, _ host: Host = .local) -> SessionRef {
        SessionRef(name: name, host: host)
    }

    func testMruFirstThenSeedRemaining() {
        let existing = [ref("a"), ref("b"), ref("c"), ref("d")]
        let mru = [ref("c"), ref("a")]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [ref("c"), ref("a"), ref("b"), ref("d")])
    }

    func testSeedsFromExistingWhenMruEmpty() {
        let existing = [ref("a"), ref("b")]
        XCTAssertEqual(SessionMRU.order(mru: [], existing: existing), existing)
    }

    func testDropsKilledSessionFromMru() {
        // "gone" is in the MRU stack but no longer exists — it's filtered out.
        let existing = [ref("a"), ref("b")]
        let mru = [ref("gone"), ref("b")]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [ref("b"), ref("a")])
    }

    func testDedupesRepeatedMruEntries() {
        let existing = [ref("a"), ref("b")]
        let mru = [ref("b"), ref("b"), ref("a")]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [ref("b"), ref("a")])
    }

    func testSameNameDifferentHostsAreDistinct() {
        let remote = Host(name: "box", sshAlias: "box")
        let existing = [ref("a", .local), ref("a", remote)]
        let mru = [ref("a", remote)]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [ref("a", remote), ref("a", .local)])
    }

    // MARK: - Windows (the ⌘` stack)

    private func win(_ session: String, _ index: Int, _ host: Host = .local) -> WindowRef {
        WindowRef(session: session, window: index, host: host)
    }

    func testWindowsOrderMruFirstAcrossSessions() {
        // The stack is flat: a window in another session outranks a window in
        // the one you're attached to, if that's where you were last.
        let existing = [win("app", 0), win("app", 1), win("docs", 0), win("docs", 1)]
        let mru = [win("docs", 1), win("app", 1)]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [win("docs", 1), win("app", 1), win("app", 0), win("docs", 0)])
    }

    func testDropsClosedWindowFromMru() {
        // Window 2 was closed; tmux renumbered the rest. The stale entry goes.
        let existing = [win("app", 0), win("app", 1)]
        let mru = [win("app", 2), win("app", 0)]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [win("app", 0), win("app", 1)])
    }

    func testSameWindowIndexInDifferentSessionsIsDistinct() {
        let existing = [win("app", 0), win("docs", 0)]
        let mru = [win("docs", 0)]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [win("docs", 0), win("app", 0)])
    }

    func testSameWindowOnDifferentHostsIsDistinct() {
        let remote = Host(name: "box", sshAlias: "box")
        let existing = [win("app", 0, .local), win("app", 0, remote)]
        let mru = [win("app", 0, remote)]
        XCTAssertEqual(
            SessionMRU.order(mru: mru, existing: existing),
            [win("app", 0, remote), win("app", 0, .local)])
    }

    func testWindowRefCarriesItsSession() {
        XCTAssertEqual(win("app", 3).sessionRef, ref("app"))
    }
}
