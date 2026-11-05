import XCTest

final class ChatRowsTests: XCTestCase {
    /// `u`: user, `a`: assistant, `r`: reasoning, `t`: tool. Row `n` is its place.
    private func chat(_ roles: String) -> [MobileChatMessage] {
        roles.enumerated().map { n, role in
            let kind: MobileChatMessage.Role
            switch role {
            case "u": kind = .user
            case "a": kind = .assistant
            case "r": kind = .reasoning
            default: kind = .tool
            }
            return MobileChatMessage(n: UInt64(n), role: kind, text: "\(role)\(n)")
        }
    }

    /// A message as its `n`; a fold as `[key:hidden]`, `+` when open.
    private func drawn(_ rows: [ChatRow]) -> String {
        rows.map { row in
            switch row {
            case .message(let message): return String(message.n)
            case .fold(let key, let hidden, let open): return "[\(key):\(hidden)]" + (open ? "+" : "")
            }
        }.joined(separator: " ")
    }

    func testARunOfThreeToolCallsOrFewerIsLeftAsItIs() {
        XCTAssertEqual(drawn(ChatRows.rows(chat("uattta"), open: [])), "0 1 2 3 4 5")
        XCTAssertEqual(drawn(ChatRows.rows(chat("t"), open: [])), "0")
        XCTAssertEqual(drawn(ChatRows.rows([], open: [])), "")
    }

    func testALongerRunIsCutToItsLastThreeBehindAFold() {
        XCTAssertEqual(drawn(ChatRows.rows(chat("utttttta"), open: [])), "0 [1:3] 4 5 6 7")
    }

    func testAnOpenFoldShowsTheWholeRun() {
        XCTAssertEqual(
            drawn(ChatRows.rows(chat("utttttta"), open: [1])), "0 [1:3]+ 1 2 3 4 5 6 7")
    }

    func testARunEndsAtAnythingTheAgentSaysOrThinks() {
        XCTAssertEqual(drawn(ChatRows.rows(chat("ttattrtttt"), open: [])), "0 1 2 3 4 5 [6:1] 7 8 9")
    }

    func testEachRunFoldsByItself() {
        XCTAssertEqual(
            drawn(ChatRows.rows(chat("ttttattttt"), open: [5])), "[0:1] 1 2 3 4 [5:2]+ 5 6 7 8 9")
    }

    func testAFoldStaysOpenWhileItsRunGrows() {
        XCTAssertEqual(drawn(ChatRows.rows(chat("utttt"), open: [1])), "0 [1:1]+ 1 2 3 4")
        XCTAssertEqual(drawn(ChatRows.rows(chat("utttttt"), open: [1])), "0 [1:3]+ 1 2 3 4 5 6")
    }

    func testTheFoldLabelCountsTheHiddenRows() {
        XCTAssertEqual(ChatRows.foldLabel(hidden: 1, open: false), "1 more tool call")
        XCTAssertEqual(ChatRows.foldLabel(hidden: 7, open: false), "7 more tool calls")
        XCTAssertEqual(ChatRows.foldLabel(hidden: 7, open: true), "Show last 3")
    }

    // MARK: feed

    private func message(_ n: UInt64, _ role: MobileChatMessage.Role, _ text: String) -> MobileChatMessage {
        MobileChatMessage(n: n, role: role, text: text)
    }

    private func page(
        _ messages: [MobileChatMessage], next: UInt64, session: String = "s1", reset: Bool = false
    ) -> MobileChatPage {
        MobileChatPage(messages: messages, next: next, reset: reset, session: session)
    }

    func testTheFirstPageIsTheChatAndLaterPagesAppend() {
        var feed = ChatFeed()
        XCTAssertNil(feed.next)
        XCTAssertTrue(feed.merge(page([message(0, .user, "hi")], next: 10)))
        XCTAssertEqual(feed.next, 10)
        XCTAssertEqual(feed.session, "s1")
        XCTAssertTrue(feed.merge(page([message(10, .assistant, "hello")], next: 20)))
        XCTAssertEqual(feed.messages.map(\.n), [0, 10])
        // Nothing new: nothing to draw again.
        XCTAssertFalse(feed.merge(page([], next: 20)))
    }

    func testAResetReplacesWhatTheFeedHolds() {
        var feed = ChatFeed()
        feed.merge(page([message(0, .user, "old")], next: 10))
        XCTAssertTrue(feed.merge(page([message(0, .user, "new")], next: 5, session: "s2", reset: true)))
        XCTAssertEqual(feed.messages.map(\.text), ["new"])
        XCTAssertEqual(feed.session, "s2")
    }

    func testTheFeedKeepsOnlyTheNewestRows() {
        var feed = ChatFeed()
        let many = (0..<UInt64(ChatFeed.limit + 50)).map { message($0, .assistant, "m\($0)") }
        feed.merge(page(many, next: 1_000))
        XCTAssertEqual(feed.messages.count, ChatFeed.limit)
        XCTAssertEqual(feed.messages.first?.n, 50)
        feed.merge(page([message(2_000, .user, "last")], next: 2_010))
        XCTAssertEqual(feed.messages.count, ChatFeed.limit)
        XCTAssertEqual(feed.messages.last?.text, "last")
    }

    func testAPendingRowGoesWhenTheTranscriptShowsItsWords() {
        var feed = ChatFeed()
        // The same words earlier in the transcript are not this send.
        feed.merge(page([message(0, .user, "run the tests")], next: 10))
        feed.addPending("run the\ntests")
        XCTAssertEqual(feed.pending.map(\.text), ["run the\ntests"])
        XCTAssertFalse(feed.merge(page([], next: 10)))
        XCTAssertEqual(feed.pending.count, 1)
        // Another prompt does not take it.
        feed.merge(page([message(10, .user, "something else")], next: 20))
        XCTAssertEqual(feed.pending.count, 1)
        XCTAssertTrue(feed.merge(page([message(20, .user, "run the tests")], next: 30)))
        XCTAssertEqual(feed.pending, [])
    }

    func testAPendingRowThatNeverShowsIsDroppedInTime() {
        var feed = ChatFeed()
        let sent = Date(timeIntervalSince1970: 1_000)
        feed.merge(page([], next: 0), now: sent)
        feed.addPending("hello", now: sent)
        feed.merge(page([], next: 0), now: sent.addingTimeInterval(60))
        XCTAssertEqual(feed.pending.count, 1)
        XCTAssertTrue(feed.merge(page([], next: 0), now: sent.addingTimeInterval(ChatFeed.pendingLifetime + 1)))
        XCTAssertEqual(feed.pending, [])
    }

    func testARefusedSendDropsItsPendingRowAndClearStartsOver() {
        var feed = ChatFeed()
        feed.merge(page([message(0, .user, "hi")], next: 10))
        feed.addPending("a")
        feed.addPending("b")
        feed.dropPending("a")
        XCTAssertEqual(feed.pending.map(\.text), ["b"])
        feed.clear()
        XCTAssertEqual(feed, ChatFeed())
        XCTAssertNil(feed.next)
    }

    // MARK: text length

    func testTheMacReadsLongerRowsThanThePhone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-rows-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let long = String(repeating: "x", count: MobileChat.maxTextLength + 100)
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": long]]],
        ])
        try (line + Data("\n".utf8)).write(to: url)
        let phone = try XCTUnwrap(
            MobileChat.page(file: (url.path, false), after: nil, session: nil))
        XCTAssertEqual(phone.messages.first?.text.count, MobileChat.maxTextLength + 1)
        let mac = try XCTUnwrap(
            MobileChat.page(file: (url.path, false), after: nil, session: nil, maxText: 50_000))
        XCTAssertEqual(mac.messages.first?.text, long)
    }
}
