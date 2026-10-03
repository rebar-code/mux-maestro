import XCTest

/// Ports of an earlier voice prototype (`tests/regressions.py`) check 2 ("no markdown notation
/// reaches the synthesizer") plus the fence-filter and chunker rules that
/// `VoiceEngine.speak` relies on.
final class SpeechifyTests: XCTestCase {
    private static let markdownLeak = try! NSRegularExpression(
        pattern: "[*_`#|]|^\\s*[-–]\\s", options: [.anchorsMatchLines])

    private func leaks(_ s: String) -> Bool {
        Self.markdownLeak.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Speechify.clean

    func testSplitEmphasisPairsAreSpeakable() {
        // Sentence chunking cuts "**Deploy.** PR" in two; each half must still clean.
        for raw in ["**Deploy.", "** PR #136 merged", "## The big idea", "`db push`", "- one point"] {
            let clean = Speechify.clean(raw)
            XCTAssertFalse(leaks(clean), "\(raw.debugDescription) -> \(clean.debugDescription)")
        }
        XCTAssertEqual(Speechify.clean("**Deploy."), "Deploy.")
        XCTAssertEqual(Speechify.clean("## The big idea"), "The big idea")
        XCTAssertEqual(Speechify.clean("- one point"), "one point")
        XCTAssertEqual(Speechify.clean("`db push`"), "db push")
    }

    func testStructuralRules() {
        XCTAssertEqual(Speechify.clean("See [the PR](https://x/1) now"), "See the PR now")
        XCTAssertEqual(Speechify.clean("> quoted\n> more"), "quoted\nmore")
        XCTAssertEqual(Speechify.clean("snake_case | pipe"), "snake case   pipe")
        XCTAssertEqual(
            Speechify.clean("Before ```py\nprint(1)\n``` after"),
            "Before " + Speechify.codeOmitted + " after")
        XCTAssertEqual(Speechify.clean("  \n  "), "")
    }

    // MARK: streaming path (FenceFilter + drain + clean), as VoiceEngine.speak runs it

    private func spoken(from deltas: [String]) -> [String] {
        var out: [String] = []
        var buffer = ""
        var started = false
        let fence = FenceFilter()
        for delta in deltas {
            buffer += fence.feed(delta)
            let (chunks, rest) = SpeechChunker.drain(buffer, started: started)
            buffer = rest
            for chunk in chunks {
                let clean = Speechify.clean(chunk)
                if clean.isEmpty { continue }
                started = true
                out.append(clean)
            }
        }
        let tail = Speechify.clean(buffer + fence.flush())
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    func testStreamingPathSpeaksNoMarkdown() {
        let deltas = [
            "**The big idea is** a CMS list. ",
            "Run `supabase db push`.\n\n## Next\n\n- ship it.\n",
            "```python\nprint('hello')\n```\n",
            "Done.",
        ]
        let out = spoken(from: deltas)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.filter(leaks).isEmpty, "\(out)")
        XCTAssertFalse(out.contains { $0.contains("print(") }, "fenced code is not read aloud: \(out)")
        XCTAssertEqual(out.first, "The big idea is a CMS list.")
        // The placeholder and "Done." share the tail chunk, as in the prototype.
        XCTAssertEqual(out.last, "— code omitted — \nDone.")
    }

    func testFenceSplitAcrossDeltas() {
        let fence = FenceFilter()
        var text = fence.feed("Look: `")
        XCTAssertEqual(text, "Look: ", "a trailing partial marker is held back")
        text += fence.feed("``\ncode\n``")
        text += fence.feed("` after")
        text += fence.flush()
        XCTAssertEqual(text, "Look: " + Speechify.codeOmitted + " after")
    }

    func testFenceClosedAtDeltaEndStillCloses() {
        // "```\n" ends a delta; the marker is complete, so nothing is held back.
        let fence = FenceFilter()
        XCTAssertEqual(fence.feed("a ```\ncode\n```\n"), "a " + Speechify.codeOmitted + "\n")
        XCTAssertEqual(fence.feed("Done."), "Done.")
        XCTAssertEqual(fence.flush(), "")
    }

    func testFlushDropsAnUnclosedFence() {
        let fence = FenceFilter()
        XCTAssertEqual(fence.feed("a ```code"), "a " + Speechify.codeOmitted)
        XCTAssertEqual(fence.feed("more `"), "")
        XCTAssertEqual(fence.flush(), "")
    }

    func testFlushReturnsHeldTicksWhenNotInCode() {
        let fence = FenceFilter()
        XCTAssertEqual(fence.feed("x `"), "x ")
        XCTAssertEqual(fence.flush(), "`")
    }

    // MARK: SpeechChunker

    func testDrainEmitsWholeSentencesOnce() {
        let (chunks, rest) = SpeechChunker.drain("One. Two! Thr", started: true)
        XCTAssertEqual(chunks, ["One.", "Two!"])
        XCTAssertEqual(rest, "Thr")
    }

    func testDrainKeepsTerminatorWithoutWhitespace() {
        let (chunks, rest) = SpeechChunker.drain("Version 1.2 of", started: true)
        XCTAssertEqual(chunks, [])
        XCTAssertEqual(rest, "Version 1.2 of")
    }

    func testDrainPeelsOpeningClauseBeforeFirstChunk() {
        let text = "Okay, I checked pull request one oh two, and it is going"
        let (chunks, rest) = SpeechChunker.drain(text, started: false)
        XCTAssertEqual(chunks, ["Okay, I checked pull request one oh two,"])
        XCTAssertEqual(rest, "and it is going")
        let (again, same) = SpeechChunker.drain(text, started: true)
        XCTAssertEqual(again, [])
        XCTAssertEqual(same, text)
    }

    func testDrainNeedsTwentyCharsBeforeTheComma() {
        let (chunks, rest) = SpeechChunker.drain("Okay, so the thing is", started: false)
        XCTAssertEqual(chunks, [])
        XCTAssertEqual(rest, "Okay, so the thing is")
    }

    func testChunksPeelLongFirstSentence() {
        let text = "Okay, I checked pull request one oh two, and CI is green so I merged it. Then I looked at the import job."
        XCTAssertEqual(SpeechChunker.chunks(for: text), [
            "Okay, I checked pull request one oh two,",
            "and CI is green so I merged it.",
            "Then I looked at the import job.",
        ])
    }

    func testChunksLeaveShortFirstSentence() {
        XCTAssertEqual(SpeechChunker.chunks(for: " Yes, done. Next? "), ["Yes, done.", "Next?"])
        XCTAssertEqual(SpeechChunker.chunks(for: "   "), [])
    }
}
