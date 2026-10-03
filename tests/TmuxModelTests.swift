import XCTest

// TmuxModel.swift (pure logic, no AppKit) is compiled directly into this test
// target, so no app host / @testable import is required.

final class TmuxModelTests: XCTestCase {
    private let US = TmuxModel.fieldSep

    // MARK: Parsing

    func testParseSessions() {
        let out = [
            "my-site\(US)1",
            "front-range\(US)0",
            "pastors-workshop\(US)0",
        ].joined(separator: "\n") + "\n"

        let rows = TmuxModel.parseSessions(out)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].name, "my-site")
        XCTAssertTrue(rows[0].attached)
        XCTAssertFalse(rows[1].attached)
    }

    func testParseSessionsSkipsBlankLines() {
        let out = "\nalpha\(US)1\n\nbeta\(US)0\n"
        let rows = TmuxModel.parseSessions(out)
        XCTAssertEqual(rows.map(\.name), ["alpha", "beta"])
    }

    func testParseWindows() {
        let out = [
            "0\(US)edit\(US)0",
            "1\(US)server\(US)1",
        ].joined(separator: "\n")

        let windows = TmuxModel.parseWindows(out)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].index, 0)
        XCTAssertEqual(windows[0].name, "edit")
        XCTAssertFalse(windows[0].active)
        XCTAssertEqual(windows[1].name, "server")
        XCTAssertTrue(windows[1].active)
        // The old 3-field format still parses, with no declared metadata.
        XCTAssertEqual(windows[0].declaredPRs, [])
        XCTAssertEqual(windows[0].declaredRepo, "")
    }

    func testParseWindowsReadsDeclaredPRMetadata() {
        let out = [
            "0\(US)watch\(US)1\(US)1082 1085\(US)rebar-code/mux-maestro",
            "1\(US)edit\(US)0\(US)\(US)",
        ].joined(separator: "\n")

        let windows = TmuxModel.parseWindows(out)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].declaredPRs, [1082, 1085])
        XCTAssertEqual(windows[0].declaredRepo, "rebar-code/mux-maestro")
        // Unset options expand to empty fields.
        XCTAssertEqual(windows[1].declaredPRs, [])
        XCTAssertEqual(windows[1].declaredRepo, "")
    }

    func testParseWindowsDeclaredPRsAreLenient() {
        // One leading `#` per token is allowed; junk, signs, zero and `##` are
        // skipped; repeats dedupe in order; the repo is trimmed.
        let line = ["0", "w", "1", "  #1082 junk ##7 +5 -3 0 1085 #1082  1085 ", " o/r "]
            .joined(separator: US)

        let window = TmuxModel.parseWindows(line).first
        XCTAssertEqual(window?.declaredPRs, [1082, 1085])
        XCTAssertEqual(window?.declaredRepo, "o/r")
    }

    func testParseWindowsReadsTmuxNameOptions() {
        let out = [
            "0\(US)pw 👀590 💤\(US)1\(US)590\(US)\(US)pw\(US)👀590 💤",
            "1\(US)edit\(US)0\(US)\(US)",
        ].joined(separator: "\n")

        let windows = TmuxModel.parseWindows(out)
        XCTAssertEqual(windows[0].nameBase, "pw")
        XCTAssertEqual(windows[0].nameTags, "👀590 💤")
        XCTAssertEqual(windows[1].nameBase, "")
        XCTAssertEqual(windows[1].nameTags, "")
    }

    func testParseWindowsKeepsLayoutStringForRecovery() {
        let layout = "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        let line = ["2", "server", "1", "", "", "", "", layout]
            .joined(separator: US)

        XCTAssertEqual(TmuxModel.parseWindows(line).first?.layout, layout)
    }

    func testParseAllWindowsCarriesDeclaredPRMetadata() {
        let out = "api\(US)0\(US)watch\(US)1\(US)#393 394\(US)rebar-code/acme-app\n"
            + "api\(US)1\(US)edit\(US)0\n"

        let windows = TmuxModel.parseAllWindows(out)["api"] ?? []
        XCTAssertEqual(windows.map(\.index), [0, 1])
        XCTAssertEqual(windows[0].declaredPRs, [393, 394])
        XCTAssertEqual(windows[0].declaredRepo, "rebar-code/acme-app")
        XCTAssertEqual(windows[1].declaredPRs, [])
        XCTAssertEqual(windows[1].declaredRepo, "")
    }

    func testParsePanes() {
        let out = [
            "%12\(US)0\(US)nvim\(US)~/proj\(US)0",
            "%13\(US)1\(US)node\(US)pnpm dev\(US)1",
        ].joined(separator: "\n")

        let panes = TmuxModel.parsePanes(out)
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].id, "%12")
        XCTAssertEqual(panes[0].index, 0)
        XCTAssertEqual(panes[0].command, "nvim")
        XCTAssertEqual(panes[0].title, "~/proj")
        XCTAssertFalse(panes[0].active)
        XCTAssertEqual(panes[1].id, "%13")
        XCTAssertTrue(panes[1].active)
    }

    func testParsePanesToleratesSpacesInFields() {
        // Spaces are common in pane titles/commands; the US separator must keep
        // them intact (spaces are NOT separators).
        let out = "%99\(US)0\(US)pnpm dev\(US)my title here\(US)1"
        let panes = TmuxModel.parsePanes(out)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].command, "pnpm dev")
        XCTAssertEqual(panes[0].title, "my title here")
    }

    func testParsePanesCapturesCurrentPath() {
        let out = "%12\(US)0\(US)nvim\(US)~/proj\(US)1\(US)/Users/me/code/sidekick"
        let panes = TmuxModel.parsePanes(out)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].path, "/Users/me/code/sidekick")
    }

    func testParsePanesPathEmptyWhenOmitted() {
        // Older 5-field lines (no path) still parse; path falls back to empty.
        let out = "%12\(US)0\(US)nvim\(US)~/proj\(US)1"
        XCTAssertEqual(TmuxModel.parsePanes(out).first?.path, "")
    }

    func testParsePanesCapturesGeometry() {
        // id, index, command, title, active, path, left, top, width, height.
        let out = "%12\(US)0\(US)nvim\(US)t\(US)1\(US)/w\(US)0\(US)0\(US)80\(US)24"
        let p = TmuxModel.parsePanes(out).first
        XCTAssertEqual(p?.left, 0)
        XCTAssertEqual(p?.top, 0)
        XCTAssertEqual(p?.width, 80)
        XCTAssertEqual(p?.height, 24)
    }

    func testParsePanesGeometryDefaultsZeroWhenOmitted() {
        // A line without the geometry fields still parses; geometry falls back to 0.
        let out = "%12\(US)0\(US)nvim\(US)t\(US)1\(US)/w"
        let p = TmuxModel.parsePanes(out).first
        XCTAssertEqual(p?.width, 0)
        XCTAssertEqual(p?.height, 0)
    }

    func testParsePanesCapturesPanePid() {
        // …, path, left, top, width, height, pane_pid — the last field anchors the
        // codex-session-id lookup (a codex process's ancestor is this pid).
        let out = "%12\(US)0\(US)zsh\(US)t\(US)1\(US)/w\(US)0\(US)0\(US)80\(US)24\(US)65439"
        XCTAssertEqual(TmuxModel.parsePanes(out).first?.pid, 65439)
    }

    func testParsePanesPidDefaultsZeroWhenOmitted() {
        // The pre-pane_pid format (10 fields) still parses; pid falls back to 0,
        // which `paneCodexIds` never matches.
        let out = "%12\(US)0\(US)zsh\(US)t\(US)1\(US)/w\(US)0\(US)0\(US)80\(US)24"
        XCTAssertEqual(TmuxModel.parsePanes(out).first?.pid, 0)
    }

    // MARK: paneCodexIds (codex pid → pane, by process ancestry)

    func testPaneCodexIdsMatchesDirectChildOfPaneShell() {
        let ids = TmuxModel.paneCodexIds(
            panePidToId: [65439: "%47"],
            codexByPid: [66143: "sid-a"],
            ppids: [66143: 65439, 65439: 47194])
        XCTAssertEqual(ids, ["%47": "sid-a"])
    }

    func testPaneCodexIdsWalksUpToGrandparentPane() {
        // codex under a wrapper (a login shell, `bun x`, a `sh -c`): the walk must
        // keep climbing rather than give up at the first non-pane parent.
        let ids = TmuxModel.paneCodexIds(
            panePidToId: [65439: "%47"],
            codexByPid: [70000: "sid-b"],
            ppids: [70000: 69000, 69000: 66143, 66143: 65439])
        XCTAssertEqual(ids, ["%47": "sid-b"])
    }

    func testPaneCodexIdsIgnoresCodexWithNoPaneAncestor() {
        // codex started outside tmux (a plain Terminal window) has no pane to
        // attach to — it must not be mis-assigned to some other pane.
        let ids = TmuxModel.paneCodexIds(
            panePidToId: [65439: "%47"],
            codexByPid: [90000: "sid-c"],
            ppids: [90000: 88000, 88000: 1])
        XCTAssertTrue(ids.isEmpty)
    }

    func testPaneCodexIdsTerminatesOnPpidCycle() {
        // A malformed process table must not spin the poll queue forever.
        let ids = TmuxModel.paneCodexIds(
            panePidToId: [65439: "%47"],
            codexByPid: [100: "sid-d"],
            ppids: [100: 200, 200: 300, 300: 100])
        XCTAssertTrue(ids.isEmpty)
    }

    func testSortedJoinsCodexSessionIdOntoPane() {
        // End to end through `sorted`: pane pid → codex pid → pane's codexSessionId.
        let panes = [
            TmuxPane(id: "%47", index: 0, command: "codex", title: "", active: true, pid: 65439),
            TmuxPane(id: "%48", index: 1, command: "zsh", title: "", active: false, pid: 70000),
        ]
        let sessions = [TmuxSession(
            name: "widget", attached: true,
            windows: [TmuxWindow(index: 0, name: "w", active: true, panes: panes)])]
        let out = TmuxModel.sorted(
            sessions: sessions, statuses: [:],
            codexByPid: [66143: "01a04e9e-978c-7e52-aaa5-41eb8c269564"],
            ppids: [66143: 65439])
        let joined = out[0].windows[0].panes
        XCTAssertEqual(joined[0].codexSessionId, "01a04e9e-978c-7e52-aaa5-41eb8c269564")
        XCTAssertNil(joined[1].codexSessionId, "a pane with no codex under it stays nil")
    }

    // MARK: Drag-to-rearrange geometry

    func testPaneRectsMapCellsToPoints() {
        let panes = [
            TmuxPane(id: "%1", index: 0, command: "z", title: "", active: true,
                     left: 0, top: 0, width: 40, height: 24),
            TmuxPane(id: "%2", index: 1, command: "z", title: "", active: false,
                     left: 41, top: 0, width: 39, height: 24),
        ]
        let rects = TmuxModel.paneRects(panes, cellW: 10, cellH: 20)
        XCTAssertEqual(rects[0].rect, CGRect(x: 0, y: 0, width: 400, height: 480))
        XCTAssertEqual(rects[1].rect, CGRect(x: 410, y: 0, width: 390, height: 480))
    }

    func testDropZoneClassifiesCenterAndEdges() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(TmuxModel.dropZone(for: CGPoint(x: 50, y: 50), in: r), .center)
        XCTAssertEqual(TmuxModel.dropZone(for: CGPoint(x: 5, y: 50), in: r), .left)
        XCTAssertEqual(TmuxModel.dropZone(for: CGPoint(x: 95, y: 50), in: r), .right)
        XCTAssertEqual(TmuxModel.dropZone(for: CGPoint(x: 50, y: 5), in: r), .top)
        XCTAssertEqual(TmuxModel.dropZone(for: CGPoint(x: 50, y: 95), in: r), .bottom)
    }

    func testDropTargetFindsContainingPaneOrNil() {
        let rects: [(id: String, rect: CGRect)] = [
            ("%1", CGRect(x: 0, y: 0, width: 100, height: 100)),
            ("%2", CGRect(x: 110, y: 0, width: 100, height: 100)),
        ]
        XCTAssertEqual(TmuxModel.dropTarget(at: CGPoint(x: 195, y: 50), in: rects)?.id, "%2")
        XCTAssertEqual(TmuxModel.dropTarget(at: CGPoint(x: 195, y: 50), in: rects)?.zone, .right)
        // The 10pt gutter between panes belongs to neither → no target.
        XCTAssertNil(TmuxModel.dropTarget(at: CGPoint(x: 105, y: 50), in: rects))
    }

    func testColumnCountFromPaneLeftOffsets() {
        // Two side-by-side panes (distinct lefts) → 2 columns.
        let sideBySide = [
            TmuxPane(id: "%1", index: 0, command: "z", title: "", active: true, left: 0),
            TmuxPane(id: "%2", index: 1, command: "z", title: "", active: false, left: 41),
        ]
        XCTAssertEqual(TmuxModel.columnCount(of: sideBySide), 2)
        // Two stacked panes (same left) → 1 column.
        let stacked = [
            TmuxPane(id: "%1", index: 0, command: "z", title: "", active: true, left: 0, top: 0),
            TmuxPane(id: "%2", index: 1, command: "z", title: "", active: false, left: 0, top: 13),
        ]
        XCTAssertEqual(TmuxModel.columnCount(of: stacked), 1)
        // A 2×2 grid still has 2 distinct lefts → 2 columns.
        let grid = stacked + sideBySide
        XCTAssertEqual(TmuxModel.columnCount(of: grid), 2)
        // No panes (or no geometry) → a single column, never 0.
        XCTAssertEqual(TmuxModel.columnCount(of: []), 1)
    }

    func testJoinArgsPerZone() {
        XCTAssertEqual(TmuxModel.joinArgs(for: .left).map { [$0.horizontal, $0.before] }, [true, true])
        XCTAssertEqual(TmuxModel.joinArgs(for: .right).map { [$0.horizontal, $0.before] }, [true, false])
        XCTAssertEqual(TmuxModel.joinArgs(for: .top).map { [$0.horizontal, $0.before] }, [false, true])
        XCTAssertEqual(TmuxModel.joinArgs(for: .bottom).map { [$0.horizontal, $0.before] }, [false, false])
        XCTAssertNil(TmuxModel.joinArgs(for: .center))  // center = swap, not a join
    }

    func testSessionCwdUsesActiveWindowsActivePane() {
        let session = TmuxSession(
            name: "demo", attached: true,
            windows: [
                TmuxWindow(index: 0, name: "idle", active: false, panes: [
                    TmuxPane(id: "%1", index: 0, command: "zsh", title: "", active: true, path: "/wrong"),
                ]),
                TmuxWindow(index: 1, name: "work", active: true, panes: [
                    TmuxPane(id: "%2", index: 0, command: "zsh", title: "", active: false, path: "/other"),
                    TmuxPane(id: "%3", index: 1, command: "nvim", title: "", active: true, path: "/repo"),
                ]),
            ])
        XCTAssertEqual(session.cwd, "/repo")
    }

    func testSessionCwdEmptyWithNoWindows() {
        XCTAssertEqual(TmuxSession(name: "x", attached: false, windows: []).cwd, "")
    }

    // MARK: Attention status parsing

    func testParseStatusesFromSessionsJSON() {
        let json = """
        [
          {"tmuxSession": "alpha", "status": "waiting"},
          {"tmuxSession": "beta", "status": "busy"},
          {"tmuxSession": "gamma", "status": "idle"},
          {"tmuxSession": "delta", "status": "something-weird"},
          {"status": "busy"},
          {"tmuxSession": "", "status": "busy"}
        ]
        """.data(using: .utf8)!

        let map = TmuxModel.parseStatuses(fromSessionsJSON: json)
        XCTAssertEqual(map["alpha"], .waiting)
        XCTAssertEqual(map["beta"], .busy)
        XCTAssertEqual(map["gamma"], .idle)
        // Unknown status strings fall back to idle.
        XCTAssertEqual(map["delta"], .idle)
        // Entries without (or with empty) tmuxSession are dropped.
        XCTAssertNil(map[""])
        XCTAssertEqual(map.count, 4)
    }

    func testParsePaneStatusSinceFromUpdatedAt() {
        let json = """
        [
          {"pane": "%1", "status": "idle", "updatedAt": 1783015682417},
          {"pane": "%2", "status": "idle", "updatedAt": 1783000000000},
          {"pane": "%2", "status": "busy", "updatedAt": 1783000500000},
          {"pane": "%3", "status": "idle"},
          {"status": "idle", "updatedAt": 1783099999000}
        ]
        """.data(using: .utf8)!
        let map = TmuxModel.parsePaneStatusSince(fromSessionsJSON: json)
        XCTAssertEqual(map["%1"], 1783015682)
        XCTAssertEqual(map["%2"], 1783000500, "the busiest session's time, matching its status")
        XCTAssertNil(map["%3"])
        XCTAssertEqual(map.count, 2)
    }

    func testParseActivityFromUpdatedAt() {
        let json = """
        [
          {"tmuxSession": "alpha", "updatedAt": 1783015682417},
          {"tmuxSession": "beta", "updatedAt": 1783000000000},
          {"tmuxSession": "gamma"},
          {"tmuxSession": "alpha", "updatedAt": 1783015999000},
          {"updatedAt": 1783099999000}
        ]
        """.data(using: .utf8)!
        let map = TmuxModel.parseActivity(fromSessionsJSON: json)
        // Milliseconds → seconds.
        XCTAssertEqual(map["beta"], 1783000000)
        // Most-recent wins when a tmux name has multiple Claude sessions.
        XCTAssertEqual(map["alpha"], 1783015999)
        // Missing updatedAt / missing tmuxSession are dropped.
        XCTAssertNil(map["gamma"])
        XCTAssertEqual(map.count, 2)
    }

    func testSortedPrefersClaudeActivityOverTmux() {
        let sessions = [
            TmuxSession(name: "a", attached: false, windows: [], activity: 100),
            TmuxSession(name: "b", attached: false, windows: [], activity: 200),
        ]
        let joined = TmuxModel.sorted(
            sessions: sessions, statuses: [:], activity: ["a": 5000])
        // "a" takes the Claude activity; "b" keeps its tmux value.
        XCTAssertEqual(joined.first(where: { $0.name == "a" })?.activity, 5000)
        XCTAssertEqual(joined.first(where: { $0.name == "b" })?.activity, 200)
    }

    func testParseStatusesMostAttentionWorthyWins() {
        // Two Claude sessions on the same tmux session: the more urgent should
        // win regardless of order.
        let json = """
        [
          {"tmuxSession": "shared", "status": "idle"},
          {"tmuxSession": "shared", "status": "waiting"},
          {"tmuxSession": "shared", "status": "busy"}
        ]
        """.data(using: .utf8)!
        let map = TmuxModel.parseStatuses(fromSessionsJSON: json)
        XCTAssertEqual(map["shared"], .waiting)
    }

    func testParseStatusesEmptyOnGarbage() {
        XCTAssertTrue(TmuxModel.parseStatuses(fromSessionsJSON: Data("not json".utf8)).isEmpty)
    }

    func testParsePaneStatusesFromSessionsJSON() {
        let json = """
        [
          {"pane": "%30", "status": "busy"},
          {"pane": "%31", "status": "waiting"},
          {"pane": "%32", "status": "idle"},
          {"pane": "%33", "status": "weird"},
          {"pane": null, "status": "busy"},
          {"status": "busy"},
          {"pane": "", "status": "busy"}
        ]
        """.data(using: .utf8)!
        let map = TmuxModel.parsePaneStatuses(fromSessionsJSON: json)
        XCTAssertEqual(map["%30"], .busy)
        XCTAssertEqual(map["%31"], .waiting)
        XCTAssertEqual(map["%32"], .idle)
        XCTAssertEqual(map["%33"], .idle)  // unknown status → idle
        // null / missing / empty pane are dropped.
        XCTAssertEqual(map.count, 4)
    }

    func testParsePaneStatusesMostAttentionWorthyWins() {
        let json = """
        [
          {"pane": "%9", "status": "idle"},
          {"pane": "%9", "status": "waiting"},
          {"pane": "%9", "status": "busy"}
        ]
        """.data(using: .utf8)!
        XCTAssertEqual(TmuxModel.parsePaneStatuses(fromSessionsJSON: json)["%9"], .waiting)
    }

    func testSortedAppliesPaneAttentionAndRollsUpToWindow() {
        // A session with one window of two panes: %1 waiting, %2 idle. The panes
        // take their per-pane status; the window rolls up to the most urgent.
        let session = TmuxSession(
            name: "s", attached: false,
            windows: [TmuxWindow(index: 0, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "node", title: "", active: true),
                TmuxPane(id: "%2", index: 1, command: "zsh", title: "", active: false),
            ])])
        let joined = TmuxModel.sorted(
            sessions: [session], statuses: [:],
            paneStatuses: ["%1": .waiting, "%2": .idle])
        let window = joined[0].windows[0]
        XCTAssertEqual(window.panes[0].attention, .waiting)
        XCTAssertEqual(window.panes[1].attention, .idle)
        // Rollup: waiting outranks idle.
        XCTAssertEqual(window.attention, .waiting)
    }

    func testWindowAttentionUnknownWhenNoPaneStatuses() {
        // With no pane map, panes stay .unknown and the window rolls up to .unknown
        // (so no dot renders) rather than mislabeling anything.
        let window = TmuxWindow(index: 0, name: "w", active: true, panes: [
            TmuxPane(id: "%1", index: 0, command: "zsh", title: "", active: true),
        ])
        XCTAssertEqual(window.attention, .unknown)
    }

    // MARK: Sort / join

    func testSortIsStableAlphabeticalRegardlessOfAttention() {
        // Order must NOT depend on attention — a session never jumps position when
        // its activity changes; the dot conveys status in place.
        let sessions = [
            TmuxSession(name: "idle-one", attached: false, windows: []),
            TmuxSession(name: "running-one", attached: false, windows: []),
            TmuxSession(name: "needs-one", attached: false, windows: []),
            TmuxSession(name: "unknown-one", attached: false, windows: []),
        ]
        let statuses: [String: AttentionStatus] = [
            "idle-one": .idle,
            "running-one": .busy,
            "needs-one": .waiting,
        ]
        let sorted = TmuxModel.sorted(sessions: sessions, statuses: statuses)
        XCTAssertEqual(sorted.map(\.name), ["idle-one", "needs-one", "running-one", "unknown-one"])
        // Attention is still joined, just not used for ordering.
        XCTAssertEqual(sorted.first { $0.name == "needs-one" }?.attention, .waiting)
        XCTAssertEqual(sorted.first { $0.name == "unknown-one" }?.attention, .unknown)
    }

    func testDedupeGroupsKeepsOnePerGroup() {
        let rows: [(name: String, attached: Bool, group: String, activity: Int)] = [
            ("host3", true, "host3", 0),
            ("host3-26386", true, "host3", 0),
            ("host3-35826", true, "host3", 0),
            ("solo", false, "", 0),
            ("devbox-33511", true, "devbox", 0),   // no namesake → first kept
            ("devbox-99000", true, "devbox", 0),
        ]
        let out = TmuxModel.dedupeGroups(rows)
        XCTAssertEqual(out.map(\.name), ["host3", "solo", "devbox-33511"])
    }

    func testSortTieBreaksAlphabetically() {
        let sessions = [
            TmuxSession(name: "Zebra", attached: false, windows: []),
            TmuxSession(name: "apple", attached: false, windows: []),
            TmuxSession(name: "Mango", attached: false, windows: []),
        ]
        let statuses: [String: AttentionStatus] = [
            "Zebra": .waiting, "apple": .waiting, "Mango": .waiting,
        ]
        let sorted = TmuxModel.sorted(sessions: sessions, statuses: statuses)
        XCTAssertEqual(sorted.map(\.name), ["apple", "Mango", "Zebra"])
    }

    func testAttentionDotsAndRanks() {
        XCTAssertEqual(AttentionStatus.waiting.dot, "🔴")
        XCTAssertEqual(AttentionStatus.busy.dot, "🟢")
        XCTAssertEqual(AttentionStatus.idle.dot, "⚪")
        XCTAssertEqual(AttentionStatus.unknown.dot, "⚪")
        XCTAssertLessThan(AttentionStatus.waiting.sortRank, AttentionStatus.busy.sortRank)
        XCTAssertLessThan(AttentionStatus.busy.sortRank, AttentionStatus.idle.sortRank)
        XCTAssertLessThan(AttentionStatus.idle.sortRank, AttentionStatus.unknown.sortRank)
    }

    // MARK: Custom session order (drag-to-reorder)

    func testApplyCustomOrderEmptyIsIdentity() {
        let sessions = [
            TmuxSession(name: "alpha", attached: false, windows: []),
            TmuxSession(name: "beta", attached: false, windows: []),
        ]
        let out = TmuxModel.applyCustomOrder(sessions, order: [])
        XCTAssertEqual(out.map(\.name), ["alpha", "beta"])
    }

    func testApplyCustomOrderPinsListedFirst() {
        // Incoming alpha order: apple, mango, zebra. Pin zebra then apple; mango is
        // unpinned and keeps its alpha position after the pinned ones.
        let sessions = [
            TmuxSession(name: "apple", attached: false, windows: []),
            TmuxSession(name: "mango", attached: false, windows: []),
            TmuxSession(name: "zebra", attached: false, windows: []),
        ]
        let out = TmuxModel.applyCustomOrder(sessions, order: ["zebra", "apple"])
        XCTAssertEqual(out.map(\.name), ["zebra", "apple", "mango"])
    }

    func testApplyCustomOrderIgnoresStaleNames() {
        // "ghost" is in the saved order but no longer exists — it's skipped, and the
        // remaining pinned name still leads.
        let sessions = [
            TmuxSession(name: "apple", attached: false, windows: []),
            TmuxSession(name: "beta", attached: false, windows: []),
        ]
        let out = TmuxModel.applyCustomOrder(sessions, order: ["ghost", "beta"])
        XCTAssertEqual(out.map(\.name), ["beta", "apple"])
    }

    func testApplyCustomOrderAppendsNewSessions() {
        // A freshly-created session not in the saved order is appended after the
        // pinned ones, in its incoming (alpha) position among the unpinned.
        let sessions = [
            TmuxSession(name: "apple", attached: false, windows: []),
            TmuxSession(name: "fresh", attached: false, windows: []),
            TmuxSession(name: "zebra", attached: false, windows: []),
        ]
        let out = TmuxModel.applyCustomOrder(sessions, order: ["zebra"])
        XCTAssertEqual(out.map(\.name), ["zebra", "apple", "fresh"])
    }

    // MARK: Host-row attention rollup

    private func session(_ name: String, _ attention: AttentionStatus) -> TmuxSession {
        var s = TmuxSession(name: name, attached: false, windows: [])
        s.attention = attention
        return s
    }

    func testRollupNilWithNoSessions() {
        XCTAssertNil(TmuxModel.rollupAttention([]))
    }

    func testRollupPicksMostUrgent() {
        let sessions = [
            session("a", .idle), session("b", .busy), session("c", .waiting),
        ]
        XCTAssertEqual(TmuxModel.rollupAttention(sessions), .waiting)
    }

    func testRollupBusyBeatsIdleAndUnknown() {
        let sessions = [session("a", .unknown), session("b", .idle), session("c", .busy)]
        XCTAssertEqual(TmuxModel.rollupAttention(sessions), .busy)
    }

    func testRollupAllIdleStaysIdle() {
        XCTAssertEqual(
            TmuxModel.rollupAttention([session("a", .idle), session("b", .idle)]), .idle)
    }

    // MARK: Full pipeline against canned tmux output

    func testEndToEndTreeFromCannedOutput() {
        let sessOut = "web\(US)1\nworker\(US)0\n"
        let rows = TmuxModel.parseSessions(sessOut)
        XCTAssertEqual(rows.count, 2)

        let winOut = "0\(US)edit\(US)1\n1\(US)server\(US)0\n"
        let windows = TmuxModel.parseWindows(winOut)
        let paneOut = "%1\(US)0\(US)nvim\(US)t\(US)1\n%2\(US)1\(US)zsh\(US)t\(US)0\n"
        let panes = TmuxModel.parsePanes(paneOut)

        var web = TmuxSession(
            name: "web", attached: true,
            windows: windows.map { TmuxWindow(index: $0.index, name: $0.name, active: $0.active, panes: panes) })
        web.attention = .busy

        XCTAssertEqual(web.windows.count, 2)
        XCTAssertEqual(web.windows[0].panes.count, 2)
        XCTAssertEqual(web.windows[0].panes[0].command, "nvim")
    }

    // MARK: directoryOrder (pinned dirs in the sidebar's directory mode)

    /// Mirrors `SidebarNode.directoryLabel` closely enough for ordering, without
    /// pulling AppKit into this target.
    private func label(_ path: String) -> String { path }

    func testDirectoryOrderSortsByLabelWhenNothingPinned() {
        let out = TmuxModel.directoryOrder(
            sessionDirs: ["/c", "/a", "/B"], pinned: [], label: label)
        XCTAssertEqual(out, ["/a", "/B", "/c"])
    }

    func testDirectoryOrderPutsPinnedFirstInPinOrder() {
        let out = TmuxModel.directoryOrder(
            sessionDirs: ["/a", "/z"], pinned: ["/z", "/a"], label: label)
        XCTAssertEqual(out, ["/z", "/a"])
    }

    func testDirectoryOrderKeepsPinnedDirWithNoSessions() {
        // The whole point of a pin: the project stays listed at zero sessions.
        let out = TmuxModel.directoryOrder(
            sessionDirs: ["/a"], pinned: ["/gone"], label: label)
        XCTAssertEqual(out, ["/gone", "/a"])
    }

    func testDirectoryOrderNeverDuplicatesAPinnedDirThatHasSessions() {
        let out = TmuxModel.directoryOrder(
            sessionDirs: ["/a", "/b"], pinned: ["/a"], label: label)
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testDirectoryOrderDedupesRepeatedInputs() {
        let out = TmuxModel.directoryOrder(
            sessionDirs: ["/a", "/a", "/b"], pinned: ["/c", "/c"], label: label)
        XCTAssertEqual(out, ["/c", "/a", "/b"])
    }

    func testDirectoryOrderSortsByLabelNotRawPath() {
        // The real label abbreviates $HOME to "~", which changes the sort order.
        let out = TmuxModel.directoryOrder(
            sessionDirs: ["/Users/j/zeta", "/aaa"], pinned: [],
            label: { $0.hasPrefix("/Users/j") ? "~" + $0.dropFirst(8) : $0 })
        XCTAssertEqual(out, ["/aaa", "/Users/j/zeta"])
    }
}
