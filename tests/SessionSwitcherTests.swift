import XCTest

// SessionSwitcher.swift + FuzzyMatch.swift + TmuxModel.swift + SshConfig.swift
// (for Host) are compiled directly into this test target.

final class SessionSwitcherTests: XCTestCase {
    private let remote = Host(name: "devbox", sshAlias: "devbox")

    private func pane(_ id: String, _ command: String) -> TmuxPane {
        TmuxPane(id: id, index: 0, command: command, title: "", active: false)
    }

    private var tree: [(host: Host, sessions: [TmuxSession])] {
        [
            (.local, [
                TmuxSession(name: "mux", attached: true, windows: [
                    TmuxWindow(index: 1, name: "cmdk-search", active: true,
                               panes: [pane("%1", "claude")]),
                    TmuxWindow(index: 2, name: "servers", active: false,
                               panes: [pane("%2", "claude"), pane("%3", "vite")]),
                ]),
            ]),
            (remote, [
                TmuxSession(name: "api", attached: false, windows: [
                    TmuxWindow(index: 0, name: "deploy", active: true,
                               panes: [pane("%9", "zsh")]),
                ]),
            ]),
        ]
    }

    func testEntriesListWindowsAndSplitPanesInTreeOrder() {
        XCTAssertEqual(SessionSwitcher.entries(tree).map(\.candidate), [
            "mux",
            "mux/cmdk-search",
            "mux/servers",
            "mux/servers/%2 claude",
            "mux/servers/%3 vite",
            "devbox/api",
            "devbox/api/deploy",
        ])
    }

    func testSinglePaneWindowGetsNoPaneEntry() {
        let targets = SessionSwitcher.entries(tree).map(\.target)
        XCTAssertFalse(targets.contains(.pane(window: 1, pane: pane("%1", "claude"))))
        XCTAssertTrue(targets.contains(.pane(window: 2, pane: pane("%3", "vite"))))
    }

    func testNameStartPointsAtTheRowsOwnName() {
        let entries = SessionSwitcher.entries(tree)
        func start(_ candidate: String) -> Int? {
            entries.first { $0.candidate == candidate }?.nameStart
        }
        XCTAssertEqual(start("mux"), 0)
        XCTAssertEqual(start("mux/servers"), 4)
        XCTAssertEqual(start("mux/servers/%3 vite"), 12)
        XCTAssertEqual(start("devbox/api"), 7)
        XCTAssertEqual(start("devbox/api/deploy"), 11)
    }

    func testEmptyQueryListsSessionsOnly() {
        let ranked = SessionSwitcher.rank(
            SessionSwitcher.entries(tree), query: "", limit: 50, entry: \.self)
        XCTAssertEqual(ranked.map(\.item.candidate), ["mux", "devbox/api"])
    }

    func testTypingAWindowNameFindsTheWindow() {
        let ranked = SessionSwitcher.rank(
            SessionSwitcher.entries(tree), query: "cmdk", limit: 50, entry: \.self)
        XCTAssertEqual(ranked.first?.item.target, .window(1))
        XCTAssertEqual(ranked.first?.item.session, "mux")
    }

    func testTypingAPaneCommandFindsThePane() {
        let ranked = SessionSwitcher.rank(
            SessionSwitcher.entries(tree), query: "vite", limit: 50, entry: \.self)
        XCTAssertEqual(ranked.map(\.item.candidate), ["mux/servers/%3 vite"])
        XCTAssertEqual(ranked.first?.item.target, .pane(window: 2, pane: pane("%3", "vite")))
    }

    func testRemoteWindowMatchesOnHostPrefix() {
        let ranked = SessionSwitcher.rank(
            SessionSwitcher.entries(tree), query: "devbox/dep", limit: 50, entry: \.self)
        XCTAssertEqual(ranked.first?.item.candidate, "devbox/api/deploy")
    }

    func testSessionOutranksItsOwnWindows() {
        let ranked = SessionSwitcher.rank(
            SessionSwitcher.entries(tree), query: "mux", limit: 50, entry: \.self)
        XCTAssertEqual(ranked.first?.item.target, .session)
        XCTAssertEqual(ranked.first?.item.candidate, "mux")
    }
}

// Scrollback hits for ⌘K. PaneSearch.swift is compiled into this target too.
final class SessionSwitcherScrollbackTests: XCTestCase {
    private func target(_ id: String, _ session: String) -> PaneSearchTarget {
        PaneSearchTarget(paneId: id, session: session, window: 0, windowName: "w",
                         command: "zsh", host: .local)
    }

    private let panes = [
        PaneSearchTarget(paneId: "%1", session: "api", window: 0, windowName: "w",
                         command: "zsh", host: .local),
        PaneSearchTarget(paneId: "%2", session: "web", window: 1, windowName: "dev",
                         command: "vite", host: .local),
    ]

    private let captures = [
        "%1": ["deploy failed: timeout", "retrying", "deploy failed: auth", ""],
        "%2": ["ready in 120ms", "Deploy preview up"],
    ]

    func testOneHitPerPaneTakesTheNewestLine() {
        let hits = SessionSwitcher.scrollbackHits(query: "deploy", captures: captures, panes: panes)
        XCTAssertEqual(hits.map(\.pane.paneId), ["%1", "%2"])
        XCTAssertEqual(hits.map(\.lineText), ["deploy failed: auth", "Deploy preview up"])
        XCTAssertEqual(hits.first?.lineNumber, 3)
        XCTAssertEqual(hits.first?.highlights, [0..<6])
    }

    func testUppercaseQueryIsCaseSensitive() {
        let hits = SessionSwitcher.scrollbackHits(query: "Deploy", captures: captures, panes: panes)
        XCTAssertEqual(hits.map(\.pane.paneId), ["%2"])
    }

    func testShortQuerySearchesNothing() {
        XCTAssertEqual(
            SessionSwitcher.scrollbackHits(query: " de ", captures: captures, panes: panes), [])
    }

    func testPaneWithoutCaptureIsSkipped() {
        let extra = panes + [target("%9", "gone")]
        let hits = SessionSwitcher.scrollbackHits(query: "ready", captures: captures, panes: extra)
        XCTAssertEqual(hits.map(\.pane.paneId), ["%2"])
    }
}
