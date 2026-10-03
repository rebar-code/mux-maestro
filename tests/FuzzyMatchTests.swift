import XCTest

// FuzzyMatch.swift (Foundation-only) is compiled directly into this test target.

final class FuzzyMatchTests: XCTestCase {

    // MARK: match — subsequence + indices

    func testMatchesInOrderSubsequence() {
        let r = FuzzyMatch.match(query: "app", candidate: "src/app.ts")
        XCTAssertNotNil(r)
        // Indices point at the matched chars; here the contiguous "app" basename.
        let chars = Array("src/app.ts")
        XCTAssertEqual(r!.indices.map { chars[$0] }, ["a", "p", "p"])
    }

    func testNonSubsequenceDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.match(query: "xyz", candidate: "src/app.ts"))
        // Out-of-order: "pa" can't match "app" (no p before a).
        XCTAssertNil(FuzzyMatch.match(query: "zzzz", candidate: "a"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.match(query: "APP", candidate: "src/app.ts"))
        XCTAssertNotNil(FuzzyMatch.match(query: "app", candidate: "SRC/APP.TS"))
    }

    func testEmptyQueryMatchesWithZeroScore() {
        let r = FuzzyMatch.match(query: "", candidate: "anything")
        XCTAssertEqual(r, FuzzyMatch.Result(score: 0, indices: []))
    }

    func testQueryLongerThanCandidateFails() {
        XCTAssertNil(FuzzyMatch.match(query: "abcd", candidate: "abc"))
    }

    // MARK: scoring — basename + boundary + contiguity beat scattered matches

    func testBasenameMatchScoresHigherThanDirectoryMatch() {
        let basename = FuzzyMatch.match(query: "app", candidate: "x/app.ts")!.score
        let scattered = FuzzyMatch.match(query: "app", candidate: "apate/zzp.ts")!.score
        XCTAssertGreaterThan(basename, scattered)
    }

    func testContiguousBeatsGappy() {
        let contiguous = FuzzyMatch.match(query: "abc", candidate: "abc.ts")!.score
        let gappy = FuzzyMatch.match(query: "abc", candidate: "a_b_c.ts")!.score
        XCTAssertGreaterThan(contiguous, gappy)
    }

    // MARK: rank — ordering, cap, empty query

    func testRankOrdersBestFirstAndCaps() {
        let candidates = [
            "src/apptastic/helper.ts",
            "src/app.ts",
            "docs/readme.md",
            "app.ts",
        ]
        let ranked = FuzzyMatch.rank(query: "app", candidates: candidates, limit: 10)
        // "readme.md" has no a/p/p subsequence → filtered out.
        XCTAssertFalse(ranked.contains { $0.path == "docs/readme.md" })
        // Exact short basename "app.ts" should rank first.
        XCTAssertEqual(ranked.first?.path, "app.ts")
    }

    func testRankCapLimitsResults() {
        let candidates = (0..<50).map { "file\($0).ts" }
        let ranked = FuzzyMatch.rank(query: "file", candidates: candidates, limit: 5)
        XCTAssertEqual(ranked.count, 5)
    }

    func testRankEmptyQueryReturnsNaturalOrderCapped() {
        let candidates = ["b.ts", "a.ts", "c.ts"]
        let ranked = FuzzyMatch.rank(query: "", candidates: candidates, limit: 2)
        XCTAssertEqual(ranked.map { $0.path }, ["b.ts", "a.ts"])  // natural order, capped
    }
}
