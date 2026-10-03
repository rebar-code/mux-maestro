import XCTest

// PaneSearch.swift + SshConfig.swift (for Host) are compiled directly into this
// test target.

final class PaneSearchTests: XCTestCase {
    private let marker = PaneSearch.marker

    private func target(_ id: String, _ session: String = "app", _ window: Int = 0)
        -> PaneSearchTarget {
        PaneSearchTarget(
            paneId: id, session: session, window: window, windowName: "dev",
            command: "zsh", host: .local)
    }

    // MARK: list-panes

    func testListPanesArgvAsksForEveryPaneOnTheServer() {
        let argv = PaneSearch.listPanesArgv()
        XCTAssertEqual(argv[0], "list-panes")
        XCTAssertTrue(argv.contains("-a"), "must sweep every session, not just the current one")
        XCTAssertTrue(argv.last!.contains("#{pane_id}"))
        XCTAssertTrue(argv.last!.contains("#{pane_current_command}"))
    }

    func testParsePanes() {
        let out = """
        %1\tapp\t0\tdev\tzsh
        %7\tdocs\t2\tbuild\tclaude
        """
        let panes = PaneSearch.parsePanes(out, host: .local)
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[1].paneId, "%7")
        XCTAssertEqual(panes[1].session, "docs")
        XCTAssertEqual(panes[1].window, 2)
        XCTAssertEqual(panes[1].windowName, "build")
        XCTAssertEqual(panes[1].command, "claude")
    }

    func testParsePanesSkipsMalformedLinesAndKeepsTheRest() {
        let out = """
        %1\tapp\t0\tdev\tzsh
        garbage
        %2\tapp\tNaN\tdev\tzsh
        %3\tapp\t1\tlogs\ttail
        """
        let panes = PaneSearch.parsePanes(out, host: .local)
        XCTAssertEqual(panes.map(\.paneId), ["%1", "%3"])
    }

    func testParsePanesCarriesTheHost() {
        let box = Host(name: "box", sshAlias: "box")
        let panes = PaneSearch.parsePanes("%1\tapp\t0\tdev\tzsh", host: box)
        XCTAssertEqual(panes.first?.host, box)
    }

    // MARK: capture

    func testCaptureArgvIsOneInvocationWithAMarkerPerPane() {
        let argv = PaneSearch.captureArgv(panes: ["%1", "%2"], lines: 500)
        XCTAssertEqual(argv, [
            "display-message", "-p", "-t", "%1", "\(marker)#{pane_id}",
            ";", "capture-pane", "-p", "-S", "-500", "-t", "%1",
            ";",
            "display-message", "-p", "-t", "%2", "\(marker)#{pane_id}",
            ";", "capture-pane", "-p", "-S", "-500", "-t", "%2",
        ])
    }

    func testMarkerCarriesNoPercentSoStrftimeCannotEatIt() {
        // tmux runs a display-message string through strftime; a literal "%12" in
        // the marker would come back mangled (observed: "%158" → "158"). The pane
        // id is appended by tmux via #{pane_id} instead.
        XCTAssertFalse(PaneSearch.marker.contains("%"))
        XCTAssertFalse(PaneSearch.marker.contains("#"))
    }

    func testCaptureArgvIsEmptyForNoPanes() {
        XCTAssertTrue(PaneSearch.captureArgv(panes: []).isEmpty)
    }

    func testParseCapturesSplitsOnMarkers() {
        let blob = """
        \(marker)%1
        one
        two
        \(marker)%2
        three
        """
        let captures = PaneSearch.parseCaptures(blob)
        XCTAssertEqual(captures["%1"], ["one", "two"])
        XCTAssertEqual(captures["%2"], ["three"])
    }

    func testParseCapturesDropsOutputBeforeTheFirstMarker() {
        let captures = PaneSearch.parseCaptures("stray tmux warning\n\(marker)%1\nhit")
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures["%1"], ["hit"])
    }

    // MARK: matching

    func testMatchFindsLinesAndByteRanges() {
        let captures = ["%1": ["all quiet", "connection refused here"]]
        let result = PaneSearch.match(
            query: "refused", captures: captures, panes: [target("%1")])
        XCTAssertEqual(result.matches.count, 1)
        let m = result.matches[0]
        XCTAssertEqual(m.lineNumber, 2)
        XCTAssertEqual(m.lineText, "connection refused here")
        XCTAssertEqual(m.highlights, [11..<18])
        XCTAssertFalse(result.truncated)
    }

    func testMatchHighlightsEveryOccurrenceOnALine() {
        let captures = ["%1": ["err err err"]]
        let result = PaneSearch.match(query: "err", captures: captures, panes: [target("%1")])
        XCTAssertEqual(result.matches.first?.highlights, [0..<3, 4..<7, 8..<11])
    }

    func testByteRangesAreUtf8OffsetsNotCharacterOffsets() {
        // "→ " is 3 UTF-8 bytes; a character-offset range would report 2..<7.
        let captures = ["%1": ["→ error here"]]
        let result = PaneSearch.match(query: "error", captures: captures, panes: [target("%1")])
        XCTAssertEqual(result.matches.first?.highlights, [4..<9])
    }

    func testSmartCaseLowercaseQueryIsCaseInsensitive() {
        let captures = ["%1": ["ERROR: boom"]]
        let result = PaneSearch.match(query: "error", captures: captures, panes: [target("%1")])
        XCTAssertEqual(result.matches.count, 1)
    }

    func testSmartCaseUppercaseQueryIsCaseSensitive() {
        let captures = ["%1": ["error: boom"]]
        let result = PaneSearch.match(query: "ERROR", captures: captures, panes: [target("%1")])
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testEmptyQueryMatchesNothing() {
        let result = PaneSearch.match(
            query: "   ", captures: ["%1": ["anything"]], panes: [target("%1")])
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testPerPaneCapMarksTruncatedAndLetsOtherPanesThrough() {
        let noisy = Array(repeating: "boom", count: PaneSearch.perPaneCap + 5)
        let captures = ["%1": noisy, "%2": ["boom"]]
        let result = PaneSearch.match(
            query: "boom", captures: captures,
            panes: [target("%1"), target("%2", "docs", 1)])
        XCTAssertEqual(result.matches.filter { $0.pane.paneId == "%1" }.count,
                       PaneSearch.perPaneCap)
        XCTAssertEqual(result.matches.filter { $0.pane.paneId == "%2" }.count, 1,
                       "one loud pane must not crowd out the others")
        XCTAssertTrue(result.truncated)
    }

    func testMatchesFollowPaneOrder() {
        let captures = ["%1": ["hit"], "%2": ["hit"]]
        let panes = [target("%2", "docs", 1), target("%1")]
        let result = PaneSearch.match(query: "hit", captures: captures, panes: panes)
        XCTAssertEqual(result.matches.map(\.pane.paneId), ["%2", "%1"])
    }

    func testPanesWithNoCaptureAreSkipped() {
        let result = PaneSearch.match(
            query: "hit", captures: ["%1": ["hit"]], panes: [target("%1"), target("%9")])
        XCTAssertEqual(result.matches.count, 1)
    }

    func testOverLongLineIsTrimmedForDisplay() {
        let long = String(repeating: "x", count: PaneSearch.maxLineLength + 50) + " needle"
        let result = PaneSearch.match(
            query: "needle", captures: ["%1": [long]], panes: [target("%1")])
        let m = try? XCTUnwrap(result.matches.first)
        XCTAssertEqual(m?.lineText.count, PaneSearch.maxLineLength)
        XCTAssertEqual(m?.highlights, [], "a highlight past the cut must not survive it")
    }

    func testHighlightsSurviveWhenTheLineFitsUnderTheCap() {
        let line = String(repeating: "x", count: 10) + "needle"
        let result = PaneSearch.match(
            query: "needle", captures: ["%1": [line]], panes: [target("%1")])
        XCTAssertEqual(result.matches.first?.highlights, [10..<16])
    }

    // MARK: grouping

    func testGroupKeepsFirstAppearanceOrder() {
        let captures = ["%1": ["hit", "hit"], "%2": ["hit"]]
        let panes = [target("%1"), target("%2", "docs", 1)]
        let groups = PaneSearch.group(
            PaneSearch.match(query: "hit", captures: captures, panes: panes).matches)
        XCTAssertEqual(groups.map(\.pane.paneId), ["%1", "%2"])
        XCTAssertEqual(groups[0].matches.count, 2)
    }

    // MARK: scope

    func testScopeRoundTripsThroughItsRawValue() {
        XCTAssertEqual(TreeSearchScope(rawValue: "panes"), .panes)
        XCTAssertEqual(TreeSearchScope(rawValue: "repo"), .repo)
        XCTAssertNil(TreeSearchScope(rawValue: "files"))
    }
}
