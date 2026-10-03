import AppKit
import XCTest

// SidebarDiff.swift (Foundation-only) is compiled directly into this test
// target. We assert the diff with a lightweight DiffableTreeNode so the test
// doesn't need AppKit / NSOutlineView.

/// A minimal diffable node mirroring SidebarNode's identity/display/children.
private struct FakeNode: DiffableTreeNode {
    let diffIdentity: String
    let diffDisplay: String
    let diffChildren: [FakeNode]

    init(_ identity: String, display: String? = nil, children: [FakeNode] = []) {
        self.diffIdentity = identity
        self.diffDisplay = display ?? identity
        self.diffChildren = children
    }
}

final class SidebarDiffTests: XCTestCase {

    func testEqualTreesAreEqual() {
        let a = [
            FakeNode("S:web", children: [FakeNode("W:web:0", children: [FakeNode("P:%1")])]),
            FakeNode("S:api"),
        ]
        let b = [
            FakeNode("S:web", children: [FakeNode("W:web:0", children: [FakeNode("P:%1")])]),
            FakeNode("S:api"),
        ]
        XCTAssertTrue(SidebarDiff.treesEqual(a, b))
    }

    func testDifferentCountsAreUnequal() {
        XCTAssertFalse(SidebarDiff.treesEqual([FakeNode("S:web")], [FakeNode("S:web"), FakeNode("S:api")]))
    }

    func testDifferentIdentityIsUnequal() {
        XCTAssertFalse(SidebarDiff.treesEqual([FakeNode("S:web")], [FakeNode("S:api")]))
    }

    func testDifferentDisplayIsUnequal() {
        // Same identity, different display (e.g. attention dot changed) must
        // trigger a reload — this is what keeps the dot live.
        let a = [FakeNode("S:web", display: "🟢 web running")]
        let b = [FakeNode("S:web", display: "🔴 web needs you")]
        XCTAssertFalse(SidebarDiff.treesEqual(a, b))
    }

    func testDifferentChildOrderIsUnequal() {
        let a = [FakeNode("S:web", children: [FakeNode("W:web:0"), FakeNode("W:web:1")])]
        let b = [FakeNode("S:web", children: [FakeNode("W:web:1"), FakeNode("W:web:0")])]
        XCTAssertFalse(SidebarDiff.treesEqual(a, b))
    }

    func testDeepChildDisplayChangeIsUnequal() {
        // A change buried in a pane's display still propagates to unequal so the
        // outline reloads and the expansion/selection restore runs.
        let a = [FakeNode("S:web", children: [FakeNode("W:web:0", children: [FakeNode("P:%1", display: "%1 zsh")])])]
        let b = [FakeNode("S:web", children: [FakeNode("W:web:0", children: [FakeNode("P:%1", display: "%1 nvim")])])]
        XCTAssertFalse(SidebarDiff.treesEqual(a, b))
    }

    func testEmptyTreesAreEqual() {
        XCTAssertTrue(SidebarDiff.treesEqual([] as [FakeNode], [] as [FakeNode]))
    }

    // MARK: - levelDelta (animated insert/remove planning)

    private func delta(_ old: [String], _ new: [String]) -> (removes: [Int], inserts: [Int])? {
        guard let d = SidebarDiff.levelDelta(oldIDs: old, newIDs: new) else { return nil }
        return (Array(d.removes), Array(d.inserts))
    }

    func testNoChangeYieldsEmptyDelta() {
        let d = delta(["a", "b", "c"], ["a", "b", "c"])
        XCTAssertEqual(d?.removes, [])
        XCTAssertEqual(d?.inserts, [])
    }

    func testInsertAtEnd() {
        // A new session appended: insert at the new list's last index.
        let d = delta(["a", "b"], ["a", "b", "c"])
        XCTAssertEqual(d?.removes, [])
        XCTAssertEqual(d?.inserts, [2])
    }

    func testInsertInMiddle() {
        let d = delta(["a", "c"], ["a", "b", "c"])
        XCTAssertEqual(d?.removes, [])
        XCTAssertEqual(d?.inserts, [1])
    }

    func testRemoveInMiddle() {
        // A killed window: remove at its position in the OLD list.
        let d = delta(["a", "b", "c"], ["a", "c"])
        XCTAssertEqual(d?.removes, [1])
        XCTAssertEqual(d?.inserts, [])
    }

    func testCombinedInsertAndRemove() {
        // b leaves, x/y arrive — removes index into old, inserts into new.
        let d = delta(["a", "b", "c"], ["a", "x", "c", "y"])
        XCTAssertEqual(d?.removes, [1])
        XCTAssertEqual(d?.inserts, [1, 3])
    }

    func testFullReplaceIsValid() {
        // No survivors ⇒ not a reorder ⇒ remove all old, insert all new.
        let d = delta(["a", "b"], ["c", "d"])
        XCTAssertEqual(d?.removes, [0, 1])
        XCTAssertEqual(d?.inserts, [0, 1])
    }

    func testGrowFromEmpty() {
        let d = delta([], ["a", "b"])
        XCTAssertEqual(d?.removes, [])
        XCTAssertEqual(d?.inserts, [0, 1])
    }

    func testShrinkToEmpty() {
        let d = delta(["a", "b"], [])
        XCTAssertEqual(d?.removes, [0, 1])
        XCTAssertEqual(d?.inserts, [])
    }

    func testReorderOfSurvivorsReturnsNil() {
        // Swapping two surviving rows can't be expressed as insert+remove — the
        // planner bails so the caller reloads instead of crashing the outline.
        XCTAssertNil(SidebarDiff.levelDelta(oldIDs: ["a", "b"], newIDs: ["b", "a"]))
    }

    func testReorderWithSimultaneousInsertReturnsNil() {
        // a and b survive but swap order while c is added — still a move, still nil.
        XCTAssertNil(SidebarDiff.levelDelta(oldIDs: ["a", "b"], newIDs: ["b", "a", "c"]))
    }

    func testMoveDisguisedByRemovalReturnsNil() {
        // a,b,c → c,b: b and c both survive but their relative order flips (b,c → c,b).
        XCTAssertNil(SidebarDiff.levelDelta(oldIDs: ["a", "b", "c"], newIDs: ["c", "b"]))
    }
}

/// TmuxColor.swift (AppKit) is compiled directly into this test target, so its
/// hex/xterm/named → NSColor mapping is asserted here without an app host.
final class TmuxColorTests: XCTestCase {

    private func rgb(_ c: NSColor?) -> (Int, Int, Int)? {
        guard let c = c?.usingColorSpace(.sRGB) else { return nil }
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }

    func testHex() {
        XCTAssertEqual(rgb(TmuxColor.parse("#3b2f5e")).map { [$0.0, $0.1, $0.2] }, [59, 47, 94])
    }

    func testXtermCube() {
        // colour100 sits in the 6×6×6 cube → non-nil, mid-range olive.
        XCTAssertEqual(rgb(TmuxColor.parse("colour100")).map { [$0.0, $0.1, $0.2] }, [135, 135, 0])
    }

    func testXtermGrayscale() {
        // colour232 is the first grayscale rung: 8 + 10·0 = 8.
        XCTAssertEqual(rgb(TmuxColor.parse("colour232")).map { [$0.0, $0.1, $0.2] }, [8, 8, 8])
    }

    func testNamed() {
        XCTAssertEqual(rgb(TmuxColor.parse("red")).map { [$0.0, $0.1, $0.2] }, [128, 0, 0])
    }

    func testBrightNamed() {
        XCTAssertEqual(rgb(TmuxColor.parse("brightred")).map { [$0.0, $0.1, $0.2] }, [255, 0, 0])
    }

    func testDefaultIsNil() {
        XCTAssertNil(TmuxColor.parse("default"))
    }

    func testGarbageIsNil() {
        XCTAssertNil(TmuxColor.parse("notacolor"))
        XCTAssertNil(TmuxColor.parse("#12"))
        XCTAssertNil(TmuxColor.parse("colour999"))
        XCTAssertNil(TmuxColor.parse(""))
    }
}

/// `HostColor` derives the default per-server tint. The critical property is
/// stability: the same host name must map to the same color on every launch.
final class HostColorTests: XCTestCase {

    func testDefaultIsStableForTheSameName() {
        // Would fail if this used String.hashValue (Swift seeds it per process).
        XCTAssertEqual(HostColor.defaultHex(for: "buildbox1"),
                       HostColor.defaultHex(for: "buildbox1"))
    }

    func testDefaultIsAlwaysFromThePalette() {
        for name in ["localhost", "buildbox", "devbox1", "host3", "", "🙂"] {
            XCTAssertTrue(HostColor.palette.contains(HostColor.defaultHex(for: name)),
                          "\(name) produced an off-palette color")
        }
    }

    func testDefaultsSpreadAcrossDistinctNames() {
        // The real server list should not collapse onto a single color.
        let names = ["localhost", "buildbox", "buildbox1", "devbox",
                     "devbox1", "host3", "host3-server", "sftp.example.com"]
        let distinct = Set(names.map(HostColor.defaultHex(for:)))
        XCTAssertGreaterThanOrEqual(distinct.count, 5,
                                    "8 hosts collapsed to \(distinct.count) colors")
    }

    func testPaletteHasNoRed() {
        // Red is the attention state's; a red tint would read as a false alarm.
        for hex in HostColor.palette {
            guard let c = TmuxColor.parse(hex)?.usingColorSpace(.sRGB) else {
                return XCTFail("unparseable palette entry \(hex)")
            }
            XCTAssertFalse(c.redComponent > 0.75 && c.greenComponent < 0.35 && c.blueComponent < 0.35,
                           "\(hex) reads as red")
        }
    }

    func testPaletteEntriesAreAllParseable() {
        for hex in HostColor.palette { XCTAssertNotNil(TmuxColor.parse(hex), hex) }
    }
}

// SidebarCard.swift is Foundation-only and compiled into this target too.
final class CardSegmentTests: XCTestCase {
    /// Segments for a run of visible rows, each `(card, isHead)`.
    private func segments(_ rows: [(String?, Bool)]) -> [CardSegment?] {
        rows.indices.map { i in
            CardSegment.of(
                card: rows[i].0, isHead: rows[i].1,
                nextCard: i + 1 < rows.count ? rows[i + 1].0 : nil)
        }
    }

    func testAnExpandedSessionIsOneCard() {
        XCTAssertEqual(
            segments([(nil, false), ("A", true), ("A", false), ("A", false), ("A", false)]),
            [nil, .top, .middle, .middle, .bottom])
    }

    func testACollapsedSessionIsASingleCard() {
        XCTAssertEqual(segments([("A", true), ("B", true), ("B", false)]), [.single, .top, .bottom])
    }

    func testACardEndsAtARowOutsideIt() {
        // An expanded last session followed by a section header.
        XCTAssertEqual(segments([("A", true), ("A", false), (nil, false)]), [.top, .bottom, nil])
    }

    func testRowsNeverJoinAnotherSessionsCard() {
        XCTAssertEqual(
            segments([("A", true), ("A", false), ("B", true), ("B", false), ("C", true)]),
            [.top, .bottom, .top, .bottom, .single])
    }

    func testTwoCardsAreTwelvePointsApart() {
        XCTAssertEqual(CardSegment.bottom.bottomGap + CardSegment.top.topGap, 12)
        XCTAssertEqual(CardSegment.single.bottomGap + CardSegment.single.topGap, 12)
    }

    func testTheFirstCardHasAHalfGapAboveIt() {
        XCTAssertEqual(CardSegment.top.topGap, 6)
        XCTAssertEqual(CardSegment.single.topGap, 6)
    }

    func testRowsInsideACardHaveNoGap() {
        XCTAssertEqual(CardSegment.middle.topGap, 0)
        XCTAssertEqual(CardSegment.middle.bottomGap, 0)
        XCTAssertEqual(CardSegment.top.bottomGap, 0)
        XCTAssertEqual(CardSegment.bottom.topGap, 0)
    }

    func testTheGapAndPaddingAddToTheRowHeight() {
        XCTAssertEqual(CardSegment.single.rowHeight(content: 34), 48)
        XCTAssertEqual(CardSegment.top.rowHeight(content: 34), 42)
        XCTAssertEqual(CardSegment.middle.rowHeight(content: 24), 26)
        XCTAssertEqual(CardSegment.bottom.rowHeight(content: 24), 32)
        XCTAssertEqual(CardSegment.middle.rowHeight(content: 38), 40)
    }

    func testTheContentKeepsItsHeightCentredInItsPadding() {
        for segment in [CardSegment.single, .top, .middle, .bottom] {
            let height = segment.rowHeight(content: 24)
            let insets = segment.contentInsets
            XCTAssertEqual(height - insets.top - insets.bottom, 24, "\(segment)")
        }
        XCTAssertEqual(CardSegment.top.contentInsets.top, 7)
        XCTAssertEqual(CardSegment.top.contentInsets.bottom, 1)
        XCTAssertEqual(CardSegment.bottom.contentInsets.bottom, 7)
    }

    func testTheCardFillsTheRowButItsGaps() {
        let insets = CardSegment.single.cardInsets
        XCTAssertEqual(insets.top, 6)
        XCTAssertEqual(insets.bottom, 6)
        XCTAssertEqual(CardSegment.middle.cardInsets.top, 0)
        XCTAssertEqual(CardSegment.middle.cardInsets.bottom, 0)
    }
}


/// Regression: #121 ("flat gray cards, no border") also dropped the server colour
/// on the session card header, so Set Color… wrote a colour nothing drew.
final class CardHeaderServerColorTests: XCTestCase {
    func testSessionCardHeaderTakesTheServerColor() {
        XCTAssertEqual(CardTint.accentHex(segment: .top, isSession: true, hostHex: "#f4422b"), "#f4422b")
        XCTAssertEqual(CardTint.accentHex(segment: .single, isSession: true, hostHex: "#8b5cf6"), "#8b5cf6")
    }

    func testWindowAndPaneRowsStayPlain() {
        // Window/pane rows are middle or bottom segments and are not session rows.
        XCTAssertNil(CardTint.accentHex(segment: .middle, isSession: false, hostHex: "#f4422b"))
        XCTAssertNil(CardTint.accentHex(segment: .bottom, isSession: false, hostHex: "#f4422b"))
    }

    func testOnlyTheHeaderSegmentIsTinted() {
        XCTAssertNil(CardTint.accentHex(segment: .middle, isSession: true, hostHex: "#f4422b"))
        XCTAssertNil(CardTint.accentHex(segment: .bottom, isSession: true, hostHex: "#f4422b"))
        XCTAssertNil(CardTint.accentHex(segment: nil, isSession: true, hostHex: "#f4422b"))
    }

    func testHerdrSessionsHaveNoTint() {
        // A herdr session heads a card but has no server, so no colour.
        XCTAssertNil(CardTint.accentHex(segment: .top, isSession: false, hostHex: nil))
        XCTAssertNil(CardTint.accentHex(segment: .single, isSession: true, hostHex: nil))
    }
}
