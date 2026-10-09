import XCTest

/// The status dot: what each pane draws, when a thread counts as viewed, and
/// what a window, session and host show for the panes under them.
final class StatusIndicatorTests: XCTestCase {
    private func pane(
        _ id: String, _ attention: AttentionStatus, hook: AgentStateRow.State? = nil,
        finishedAt: Int? = nil, viewed: Bool = true
    ) -> TmuxPane {
        var p = TmuxPane(id: id, index: 0, command: "claude", title: "", active: true)
        p.attention = attention
        p.agentState = hook.map { AgentPaneState(sessionId: "s", state: $0, since: finishedAt ?? 0) }
        p.finishedAt = finishedAt
        p.viewed = viewed
        return p
    }

    private func session(_ panes: [TmuxPane], attention: AttentionStatus = .unknown) -> TmuxSession {
        var s = TmuxSession(name: "acme-app", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: panes),
        ])
        s.attention = attention
        return s
    }

    // MARK: one pane

    func testEachStateHasItsDot() {
        XCTAssertEqual(pane("%1", .waiting).indicator, .needsYou)
        XCTAssertEqual(pane("%1", .busy).indicator, .working)
        XCTAssertEqual(pane("%1", .unknown).indicator, .none)
        XCTAssertEqual(pane("%1", .idle, hook: .done, finishedAt: 100, viewed: false).indicator, .unviewed)
        XCTAssertEqual(pane("%1", .idle, hook: .done, finishedAt: 100, viewed: true).indicator, .viewed)
    }

    func testAnAgentWithNoTurnYetIsAGreyRingWhateverTheStoreSays() {
        XCTAssertEqual(pane("%1", .idle, hook: .idle, viewed: false).indicator, .idle)
    }

    // MARK: finish time

    func testOnlyAnIdlePaneHasAFinishTime() {
        let done = AgentPaneState(sessionId: "s", state: .done, since: 500)
        XCTAssertEqual(AgentState.finishedAt(attention: .idle, hook: done, scanSince: 100), 500)
        XCTAssertNil(AgentState.finishedAt(attention: .busy, hook: done, scanSince: 100))
        XCTAssertNil(AgentState.finishedAt(attention: .waiting, hook: nil, scanSince: 100))
        XCTAssertNil(AgentState.finishedAt(attention: .unknown, hook: nil, scanSince: 100))
    }

    func testWithNoHookTheScanTimeIsTheFinishTime() {
        XCTAssertEqual(AgentState.finishedAt(attention: .idle, hook: nil, scanSince: 100), 100)
        XCTAssertNil(AgentState.finishedAt(attention: .idle, hook: nil, scanSince: nil))
    }

    func testAStartedAgentWithNoTurnHasNoFinishTime() {
        let started = AgentPaneState(sessionId: "s", state: .idle, since: 500)
        XCTAssertNil(AgentState.finishedAt(attention: .idle, hook: started, scanSince: 100))
    }

    func testSortedGivesADonePaneItsFinishTime() {
        let sessions = [TmuxSession(name: "work", attached: false, windows: [
            TmuxWindow(index: 1, name: "w", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "", active: true),
                TmuxPane(id: "%2", index: 1, command: "claude", title: "", active: false),
            ]),
        ])]
        let sorted = TmuxModel.sorted(
            sessions: sessions, statuses: [:],
            paneStatuses: ["%1": .idle, "%2": .busy],
            paneStatusSince: ["%1": 700, "%2": 800], now: 1000)
        XCTAssertEqual(sorted[0].windows[0].panes.map(\.finishedAt), [700, nil])
    }

    // MARK: viewed

    func testAThreadIsViewedOnceItWasOpenedAfterItFinished() {
        var store = ViewedThreads(baseline: 0)
        XCTAssertFalse(store.isViewed("devbox:1", finishedAt: 100))
        XCTAssertTrue(store.mark("devbox:1", finishedAt: 100, now: 150))
        XCTAssertTrue(store.isViewed("devbox:1", finishedAt: 100))
        XCTAssertFalse(store.isViewed("devbox:1", finishedAt: 200), "a later turn is new again")
    }

    func testMarkingAViewedThreadChangesNothing() {
        var store = ViewedThreads(baseline: 0, viewedAt: ["devbox:1": 150])
        XCTAssertFalse(store.mark("devbox:1", finishedAt: 100, now: 300))
        XCTAssertEqual(store.viewedAt["devbox:1"], 150)
        XCTAssertFalse(store.mark("devbox:2", finishedAt: nil, now: 300))
        XCTAssertNil(store.viewedAt["devbox:2"])
    }

    func testAFinishTimeAheadOfThisClockStillCountsAsViewed() {
        var store = ViewedThreads(baseline: 0)
        store.mark("devbox:1", finishedAt: 500, now: 400)
        XCTAssertTrue(store.isViewed("devbox:1", finishedAt: 500))
    }

    func testWhatFinishedBeforeTheStoreBeganIsViewed() {
        let store = ViewedThreads(baseline: 1000)
        XCTAssertTrue(store.isViewed("devbox:1", finishedAt: 900))
        XCTAssertFalse(store.isViewed("devbox:1", finishedAt: 1100))
        XCTAssertTrue(store.isViewed("devbox:1", finishedAt: nil))
    }

    func testPruneDropsOnlyTheGoneThreadsOfThatHost() {
        var store = ViewedThreads(
            baseline: 0, viewedAt: ["devbox:1": 5, "devbox:2": 6, "localhost:1": 7])
        store.prune(host: "devbox", live: ["devbox:2"])
        XCTAssertEqual(store.viewedAt, ["devbox:2": 6, "localhost:1": 7])
    }

    func testTheStoreSurvivesItsStoredForm() throws {
        let store = ViewedThreads(baseline: 1000, viewedAt: ["devbox:1": 1500])
        let data = try JSONSerialization.data(withJSONObject: store.json)
        let back = ViewedThreads(json: try JSONSerialization.jsonObject(with: data), now: 9)
        XCTAssertEqual(back, store)
        XCTAssertEqual(ViewedThreads(json: nil, now: 9), ViewedThreads(baseline: 9))
    }

    func testStampedSetsEachPaneFromTheStore() {
        let store = ViewedThreads(baseline: 0, viewedAt: ["devbox:1": 150])
        let stamped = session([
            pane("%1", .idle, hook: .done, finishedAt: 100),
            pane("%2", .idle, hook: .done, finishedAt: 100),
        ]).stamped(store) { "devbox:" + $0.dropFirst() }
        XCTAssertEqual(stamped.windows[0].panes.map(\.indicator), [.viewed, .unviewed])
    }

    // MARK: rollup

    func testTheMostUrgentDotWins() {
        let order: [StatusIndicator] = [.needsYou, .unviewed, .working, .viewed, .idle, .none]
        XCTAssertEqual(order.map(\.rank), order.map(\.rank).sorted())
        XCTAssertEqual(StatusIndicator.rollup([.viewed, .working, .unviewed]), .unviewed)
        XCTAssertEqual(StatusIndicator.rollup([.working, .needsYou, .unviewed]), .needsYou)
        XCTAssertEqual(StatusIndicator.rollup([]), StatusIndicator.none)
    }

    func testAWindowAndSessionRollUpTheirPanes() {
        let s = session([
            pane("%1", .busy),
            pane("%2", .idle, hook: .done, finishedAt: 100, viewed: false),
        ])
        XCTAssertEqual(s.windows[0].indicator, .unviewed)
        XCTAssertEqual(s.indicator, .unviewed)
    }

    func testASessionWithNoPaneStatusUsesItsOwn() {
        XCTAssertEqual(session([pane("%1", .unknown)], attention: .busy).indicator, .working)
        XCTAssertEqual(session([pane("%1", .unknown)], attention: .idle).indicator, .viewed)
    }
}
