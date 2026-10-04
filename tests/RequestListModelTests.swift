import XCTest

// RequestListModel.swift (Foundation only) compiles into this test target. The
// ordering and grouping cases are the ones in `mobile/src/lib/requests.test.ts`,
// so the Mac's list and the phone's cannot disagree.
final class RequestListModelTests: XCTestCase {
    private func request(
        _ id: String = "req-1", project: String = "acme-app", asked: String = "2026-10-03",
        state: String = "todo"
    ) -> TrackedRequest {
        TrackedRequest(
            id: id, title: "Fix the checkout test", project: project, asked: asked, state: state,
            history: [])
    }

    private var rows: [TrackedRequest] {
        [
            request("a", project: "acme-app", asked: "2026-10-03"),
            request("b", project: "devbox", asked: "2026-10-04", state: "in_progress"),
            request("c", project: "acme-app", asked: "2026-10-04", state: "blocked"),
            request("d", project: "devbox", asked: "2026-10-03", state: "done"),
            request("e", project: "acme-app", asked: "2026-10-03", state: "review"),
            request("f", project: "", asked: "2026-10-02"),
            request("g", project: "acme-app", asked: "2026-10-04", state: "done"),
        ]
    }

    /// Each group as "project: id id id".
    private func ids(_ groups: [RequestGroup]) -> [String] {
        groups.map { "\($0.project): \($0.requests.map(\.id).joined(separator: " "))" }
    }

    /// The rows as the list the agent writes.
    private func json(_ requests: [TrackedRequest]) -> Data {
        let list: [String: Any] = [
            "schema": 2,
            "requests": requests.map {
                [
                    "id": $0.id, "title": $0.title, "project": $0.project, "asked": $0.asked,
                    "state": $0.state, "history": [[String: Any]](),
                ] as [String: Any]
            },
        ]
        return try! JSONSerialization.data(withJSONObject: list)
    }

    private func loaded(_ requests: [TrackedRequest]) -> RequestListModel {
        var model = RequestListModel()
        model.loaded(.success(json(requests)), writes: model.writes)
        return model
    }

    // MARK: isDone, askedKey

    func testOnlyDoneIsDone() {
        XCTAssertTrue(request(state: "done").isDone)
        for state in ["todo", "in_progress", "blocked", "review", "parked"] {
            XCTAssertFalse(request(state: state).isDone, state)
        }
    }

    func testAskedKeyIsTheLastDateInTheText() {
        XCTAssertEqual(RequestList.askedKey("2026-10-04"), "2026-10-04")
        XCTAssertEqual(RequestList.askedKey("earlier, restated 2026-10-04"), "2026-10-04")
        XCTAssertEqual(RequestList.askedKey("2026-09-30, restated 2026-10-02"), "2026-10-02")
    }

    func testAskedKeyIsEmptyWhenTheTextHoldsNoDate() {
        XCTAssertEqual(RequestList.askedKey("earlier"), "")
        XCTAssertEqual(RequestList.askedKey(""), "")
        XCTAssertEqual(RequestList.askedKey("2026-10"), "")
    }

    // MARK: groups

    func testSortsByTheLastDateInAFreeFormAskedRowsWithNoDateLast() {
        let free = [
            request("n", asked: "earlier"),
            request("r", asked: "earlier, restated 2026-10-04"),
            request("o", asked: "2026-10-03"),
            request("s", asked: "2026-10-04"),
            request("m", asked: "some time ago"),
        ]
        XCTAssertEqual(ids(RequestList.groups(free, done: false)), ["acme-app: r s o n m"])
    }

    func testGroupsAProjectWhoseOnlyDatedRowWasRestatedByThatDate() {
        let free = [
            request("a", project: "devbox", asked: "2026-10-03"),
            request("b", project: "acme-app", asked: "earlier, restated 2026-10-04"),
        ]
        XCTAssertEqual(ids(RequestList.groups(free, done: false)), ["acme-app: b", "devbox: a"])
    }

    func testKeepsTheOpenRowsNewestFirstGroupedByTheNewestRowOfEachProject() {
        XCTAssertEqual(
            ids(RequestList.groups(rows, done: false)),
            ["devbox: b", "acme-app: c a e", "Other: f"])
    }

    func testKeepsTheDoneRowsOnly() {
        XCTAssertEqual(ids(RequestList.groups(rows, done: true)), ["acme-app: g", "devbox: d"])
    }

    func testKeepsTheFileOrderForRowsOfOneDay() {
        let same = ["x", "y", "z"].map { request($0) }
        XCTAssertEqual(ids(RequestList.groups(same, done: false)), ["acme-app: x y z"])
    }

    func testCountsAnUnknownStateAsOpen() {
        XCTAssertEqual(
            ids(RequestList.groups([request("p", state: "parked")], done: false)), ["acme-app: p"])
    }

    func testIsEmptyForNoRows() {
        XCTAssertEqual(RequestList.groups([], done: false), [])
    }

    // MARK: counts, stateLabel

    func testCountsOpenAndDone() {
        XCTAssertEqual(RequestList.counts(rows).open, 5)
        XCTAssertEqual(RequestList.counts(rows).done, 2)
        XCTAssertEqual(RequestList.counts([]).open, 0)
        XCTAssertEqual(RequestList.counts([]).done, 0)
    }

    func testStateLabelNamesTheStatesTheCheckboxDoesNotShow() {
        XCTAssertEqual(RequestList.stateLabel("in_progress"), "in progress")
        XCTAssertEqual(RequestList.stateLabel("blocked"), "blocked")
        XCTAssertEqual(RequestList.stateLabel("review"), "review")
        XCTAssertEqual(RequestList.stateLabel("todo"), "")
        XCTAssertEqual(RequestList.stateLabel("done"), "")
        XCTAssertEqual(RequestList.stateLabel("parked"), "parked")
    }

    // MARK: parse

    func testParseReadsARequestAndItsHistoryOldestFirst() {
        let text = """
        { "schema": 2, "requests": [
          { "id": "req-1", "title": "Search across every session", "project": "acme-app",
            "asked": "2026-10-03", "state": "in_progress", "detail": "Not shown.",
            "history": [
              { "at": "2026-10-03", "by": "me", "verbatim": "search everything" },
              { "at": "2026-10-04", "by": "maestro", "note": "Scoped to open sessions." }
            ] }
        ] }
        """
        XCTAssertEqual(RequestList.parse(Data(text.utf8)), [
            TrackedRequest(
                id: "req-1", title: "Search across every session", project: "acme-app",
                asked: "2026-10-03", state: "in_progress",
                history: [
                    RequestHistoryEntry(at: "2026-10-03", by: "me", note: "", verbatim: "search everything"),
                    RequestHistoryEntry(
                        at: "2026-10-04", by: "maestro", note: "Scoped to open sessions.", verbatim: ""),
                ]),
        ])
    }

    func testParseReadsASchema1RequestWithNoHistoryProjectOrAsked() {
        let text = #"{ "schema": 1, "requests": [ { "id": "a", "title": "T", "state": "todo" } ] }"#
        XCTAssertEqual(RequestList.parse(Data(text.utf8)), [
            TrackedRequest(id: "a", title: "T", project: "", asked: "", state: "todo", history: []),
        ])
    }

    func testParseIsNilForTextThatIsNotAList() {
        XCTAssertNil(RequestList.parse(Data("{".utf8)))
        XCTAssertNil(RequestList.parse(Data(#"{ "schema": 2 }"#.utf8)))
        XCTAssertNil(RequestList.parse(Data(#"{ "requests": [ { "id": "a" } ] }"#.utf8)))
    }

    func testTheAgentsEntriesAreToldFromTheHumans() {
        XCTAssertTrue(RequestHistoryEntry(at: "", by: "maestro", note: "", verbatim: "").isAgent)
        XCTAssertFalse(RequestHistoryEntry(at: "", by: "me", note: "", verbatim: "").isAgent)
    }

    // MARK: what the view draws

    func testNothingIsDrawnBeforeTheFirstRead() {
        let model = RequestListModel()
        XCTAssertEqual(model.content, .loading)
        XCTAssertEqual(model.filterTitle(done: false), "Open", "never a wrong 0")
        XCTAssertEqual(model.filterTitle(done: true), "Done")
    }

    func testTheFilterShowsTheOpenRowsThenTheDoneOnes() {
        var model = loaded(rows)
        XCTAssertEqual(model.content, .groups(RequestList.groups(rows, done: false)))
        XCTAssertEqual(model.filterTitle(done: false), "Open 5")
        XCTAssertEqual(model.filterTitle(done: true), "Done 2")
        model.done = true
        XCTAssertEqual(model.content, .groups(RequestList.groups(rows, done: true)))
    }

    func testAnEmptyFilterIsOneShortLabel() {
        var model = loaded([request("a")])
        model.done = true
        XCTAssertEqual(model.content, .empty("Nothing done"))
        model = loaded([request("a", state: "done")])
        XCTAssertEqual(model.content, .empty("Nothing open"))
    }

    func testAListThatDoesNotReadIsAnErrorAndNeverAnEmptyList() {
        var model = loaded(rows)
        XCTAssertTrue(model.loaded(.failure(.corrupt("requests.json is not valid JSON")), writes: model.writes))
        XCTAssertEqual(model.content, .failed("requests.json is not valid JSON"))
        XCTAssertNil(model.requests, "rows that may be stale are not shown")
        XCTAssertEqual(model.filterTitle(done: false), "Open")
        XCTAssertEqual(RequestListModel.unreadable, "Can't read the request list")
    }

    func testTextThatPassedTheTrackerButDoesNotParseIsAnErrorToo() {
        var model = RequestListModel()
        model.loaded(.success(Data("[]".utf8)), writes: model.writes)
        XCTAssertEqual(model.content, .failed(""))
    }

    func testRetryShowsNothingUntilTheAnswerAndARereadRecovers() {
        var model = RequestListModel()
        model.loaded(.failure(.io("Permission denied")), writes: model.writes)
        model.retry()
        XCTAssertEqual(model.content, .loading)
        model.loaded(.success(json(rows)), writes: model.writes)
        XCTAssertEqual(model.content, .groups(RequestList.groups(rows, done: false)))
    }

    func testAReadThatChangesNothingSaysSo() {
        var model = loaded(rows)
        XCTAssertFalse(model.loaded(.success(json(rows)), writes: model.writes))
        XCTAssertTrue(model.loaded(.success(json([request("a")])), writes: model.writes))
    }

    func testAHistoryStaysOpenAcrossAReadAndATick() {
        var model = loaded(rows)
        model.toggleHistory("a")
        XCTAssertEqual(model.expanded, ["a"])
        model.loaded(.success(json(rows + [request("z")])), writes: model.writes)
        XCTAssertEqual(model.tick("c"), .done)
        model.ticked(.success(json(rows)))
        XCTAssertEqual(model.expanded, ["a"])
        model.toggleHistory("a")
        XCTAssertEqual(model.expanded, [])
    }

    // MARK: a tick

    func testATickShowsAtOnceAndTheAnswerReplacesIt() {
        var model = loaded(rows)
        XCTAssertEqual(model.tick("a"), .done, "an open row is ticked done")
        XCTAssertEqual(model.busy, "a")
        XCTAssertEqual(model.requests?.first { $0.id == "a" }?.state, "done")

        var after = rows
        after[0].state = "done"
        after[1].state = "review"
        model.ticked(.success(json(after)))
        XCTAssertNil(model.busy)
        XCTAssertEqual(model.note, "")
        XCTAssertEqual(model.requests, RequestList.parse(json(after)), "the file's answer, whole")
    }

    func testATickOnADoneRowSetsItBackToTodo() {
        var model = loaded(rows)
        XCTAssertEqual(model.tick("d"), .todo)
        XCTAssertEqual(model.requests?.first { $0.id == "d" }?.state, "todo")
    }

    func testATickOnAnyOpenStateIsDone() {
        var model = loaded(rows)
        XCTAssertEqual(model.tick("c"), .done, "blocked")
    }

    func testOneWriteAtATime() {
        var model = loaded(rows)
        XCTAssertEqual(model.tick("a"), .done)
        XCTAssertNil(model.tick("b"))
        XCTAssertEqual(model.requests?.first { $0.id == "b" }?.state, "in_progress")
    }

    func testNoTickBeforeTheListIsReadOrOnAnUnknownRow() {
        var model = RequestListModel()
        XCTAssertNil(model.tick("a"))
        model = loaded(rows)
        XCTAssertNil(model.tick("nope"))
        XCTAssertNil(model.busy)
    }

    func testAFailedTickPutsTheRowBackAndSaysWhy() {
        var model = loaded(rows)
        XCTAssertEqual(model.tick("c"), .done)
        model.ticked(.failure(.busy))
        XCTAssertNil(model.busy)
        XCTAssertEqual(model.requests?.first { $0.id == "c" }?.state, "blocked", "not todo: what it was")
        XCTAssertEqual(model.note, "The list is being written. Try again.")
        model.clearNote()
        XCTAssertEqual(model.note, "")
    }

    func testWhyATickFailed() {
        XCTAssertEqual(RequestListModel.reason(.busy), MobileRequests.busyMessage)
        XCTAssertEqual(RequestListModel.reason(.corrupt("requests.json is not valid JSON")),
                       "requests.json is not valid JSON")
        XCTAssertEqual(RequestListModel.reason(.io("Permission denied")), "Permission denied")
        XCTAssertEqual(RequestListModel.reason(.unknownRequest), "Not saved")
    }

    func testANewTickClearsTheLastNote() {
        var model = loaded(rows)
        _ = model.tick("a")
        model.ticked(.failure(.unknownRequest))
        XCTAssertEqual(model.note, "Not saved")
        _ = model.tick("a")
        XCTAssertEqual(model.note, "")
    }

    func testAReadThatStartedBeforeATickDoesNotUndoIt() {
        var model = loaded(rows)
        let started = model.writes
        _ = model.tick("a")
        XCTAssertFalse(model.loaded(.success(json(rows)), writes: started), "while the write runs")
        XCTAssertEqual(model.requests?.first { $0.id == "a" }?.state, "done")

        var after = rows
        after[0].state = "done"
        model.ticked(.success(json(after)))
        XCTAssertFalse(model.loaded(.success(json(rows)), writes: started), "and after it")
        XCTAssertEqual(model.requests?.first { $0.id == "a" }?.state, "done")
        XCTAssertFalse(model.loaded(.failure(.corrupt("x")), writes: started))
        XCTAssertEqual(model.content, .groups(RequestList.groups(after, done: false)))
    }

    // MARK: the watcher

    func testTheWatcherReportsAFileRenamedIntoTheDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("request-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changed = expectation(description: "the directory changed")
        changed.assertForOverFulfill = false
        let watcher = DirectoryWatcher(url: directory, queue: .global()) { changed.fulfill() }
        XCTAssertNotNil(watcher)

        // As both writers of the list do: a temporary file, renamed over it.
        let temporary = directory.appendingPathComponent(".requests.json.tmp")
        try Data("{}".utf8).write(to: temporary)
        try FileManager.default.moveItem(
            at: temporary, to: directory.appendingPathComponent(RequestTracker.fileName))
        wait(for: [changed], timeout: 5)
        watcher?.cancel()
    }

    func testThereIsNoWatcherForADirectoryThatDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("request-watcher-\(UUID().uuidString)")
        XCTAssertNil(DirectoryWatcher(url: missing, queue: .global()) {})
    }
}
