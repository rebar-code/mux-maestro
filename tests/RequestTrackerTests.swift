import XCTest

// RequestTracker.swift (Foundation only) compiles into this test target: the
// read, the two-value edit, the rename and the retry are asserted on a
// temporary directory, with no app and no socket.
final class RequestTrackerTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent(RequestTracker.fileName) }
    private var tracker: RequestTracker {
        var tracker = RequestTracker(url: file)
        tracker.now = { Date(timeIntervalSince1970: 1_791_100_800) }
        tracker.readPause = 0.005
        return tracker
    }
    /// What `now` above writes into `updated`.
    private let stamp = "2026-10-04T08:00:00Z"

    /// The list as the agent writes it: two-space indent, newest first.
    private static let list = """
    {
      "schema": 1,
      "note": "What the human asked for. 'project' groups by tmux session.",
      "updated": "2026-10-03T16:20:00Z",
      "requests": [
        {
          "id": "req-004",
          "title": "Search across every session",
          "project": "acme-app",
          "asked": "2026-10-03",
          "state": "in_progress",
          "detail": "A \\"quoted\\" word, a brace } and a bracket ] in the text.",
          "blocked_by": null
        },
        {
          "id": "req-003",
          "title": "Dark mode for the settings page ✨",
          "project": "acme-app",
          "asked": "2026-10-03",
          "state": "blocked",
          "detail": "Waits on the theme tokens.",
          "blocked_by": "req-001"
        },
        {
          "id": "req-002",
          "title": "Nightly backup of devbox",
          "project": "devbox",
          "asked": "2026-10-02",
          "state": "done",
          "detail": "",
          "blocked_by": null
        },
        {
          "id": "req-001",
          "title": "Theme tokens",
          "project": "acme-app",
          "asked": "2026-10-01",
          "state": "todo",
          "detail": "",
          "blocked_by": null
        }
      ],
      "blockers": [
        { "id": "tokens", "title": "Theme tokens are not merged", "needs": "a review" }
      ],
      "open_questions": ["Keep the old search box?"]
    }

    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("request-tracker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try put(Self.list)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func put(_ text: String) throws {
        try Data(text.utf8).write(to: file)
    }

    private var onDisk: String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? "<no file>"
    }

    private func states(_ data: Data? = nil) -> [String: String] {
        let data = data ?? (try? Data(contentsOf: file)) ?? Data()
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let requests = list?["requests"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: requests.compactMap {
            guard let id = $0["id"] as? String, let state = $0["state"] as? String else { return nil }
            return (id, state)
        })
    }

    /// Files a write left behind beside the list.
    private var leftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0 != RequestTracker.fileName }
    }

    private func value<T>(_ result: Result<T, RequestTrackerError>, line: UInt = #line) -> T? {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            XCTFail("failed: \(error)", line: line)
            return nil
        }
    }

    private func failure<T>(_ result: Result<T, RequestTrackerError>, line: UInt = #line)
        -> RequestTrackerError? {
        if case .failure(let error) = result { return error }
        XCTFail("did not fail", line: line)
        return nil
    }

    // MARK: Read

    func testReadAnswersTheFileAsItIs() {
        XCTAssertEqual(value(tracker.read()), Data(Self.list.utf8))
    }

    func testNoFileReadsAsAnEmptyListAndHasNoRequestToChange() throws {
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(value(tracker.read()), RequestTracker.empty)
        XCTAssertNil(RequestTracker.fault(in: RequestTracker.empty))
        XCTAssertEqual(failure(tracker.setState(.done, of: "req-001")), .unknownRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a tick made a file")
    }

    func testAFileThatIsNotTheListIsAnErrorNotAnEmptyList() throws {
        let half = String(Self.list.prefix(Self.list.count / 2))
        for (text, word) in [
            (half, "not valid JSON"),
            ("", "not valid JSON"),
            ("[]", "not valid JSON"),
            (#"{"requests":[]}"#, "names no schema"),
            (#"{"schema":2,"requests":[]}"#, "schema 2"),
            (#"{"schema":1}"#, "no list of requests"),
            (#"{"schema":1,"requests":[{"id":"a","title":"t"}]}"#, "without an id, a title or a state"),
        ] {
            try put(text)
            guard case .corrupt(let message)? = failure(tracker.read()) else {
                return XCTFail("not corrupt: \(text.prefix(30))")
            }
            XCTAssertTrue(message.contains(word), "\(message) / \(word)")
            // A tick on that file is refused and writes nothing.
            guard case .corrupt? = failure(tracker.setState(.done, of: "req-001")) else {
                return XCTFail("a tick was taken: \(text.prefix(30))")
            }
            XCTAssertEqual(onDisk, text)
            XCTAssertEqual(leftovers, [])
        }
    }

    func testAReadWaitsOutAWriterThatIsHalfWayThrough() throws {
        try put(String(Self.list.prefix(300)))
        var patient = tracker
        patient.readAttempts = 40
        patient.readPause = 0.01
        let file = file
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            try? Data(Self.list.utf8).write(to: file)
        }
        XCTAssertEqual(value(patient.read()), Data(Self.list.utf8))
    }

    // MARK: Write

    func testATickChangesTheStateAndTheTimeAndNoOtherByte() {
        let after = value(tracker.setState(.done, of: "req-004"))
        let expected = Self.list
            .replacingOccurrences(of: #""state": "in_progress""#, with: #""state": "done""#)
            .replacingOccurrences(of: "2026-10-03T16:20:00Z", with: stamp)
        XCTAssertEqual(onDisk, expected)
        XCTAssertEqual(after, Data(expected.utf8))
        XCTAssertEqual(value(tracker.read()), after)
    }

    func testRoundTripThroughEveryState() {
        for state in RequestState.allCases + [.todo] {
            XCTAssertNotNil(value(tracker.setState(state, of: "req-001")))
            XCTAssertEqual(states()["req-001"], state.rawValue)
            XCTAssertEqual(states(value(tracker.read())), states())
        }
        // Back where it started: the text is the first one again, but for the time.
        XCTAssertEqual(onDisk, Self.list.replacingOccurrences(of: "2026-10-03T16:20:00Z", with: stamp))
        XCTAssertEqual(leftovers, [])
    }

    func testTheSameStateWritesNothing() throws {
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(value(tracker.setState(.done, of: "req-002")), Data(Self.list.utf8))
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(onDisk, Self.list)
        XCTAssertEqual(
            before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber,
            "the file was replaced")
    }

    func testAnUnknownRequestLeavesTheFile() {
        XCTAssertEqual(failure(tracker.setState(.done, of: "req-999")), .unknownRequest)
        XCTAssertEqual(onDisk, Self.list)
        XCTAssertEqual(leftovers, [])
    }

    func testTwoRequestsWithOneIDAreRefused() throws {
        let twice = Self.list.replacingOccurrences(of: "req-003", with: "req-004")
        try put(twice)
        guard case .corrupt(let message)? = failure(tracker.setState(.done, of: "req-004")) else {
            return XCTFail("not refused")
        }
        XCTAssertTrue(message.contains("2 requests with the id req-004"), message)
        XCTAssertEqual(onDisk, twice)
    }

    func testTheWriteIsARenameOfAWholeFile() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        var seen: [String] = []
        var watched = tracker
        watched.beforeCommit = { [self] in
            // The new list is whole in a file of its own; the list is still the old one.
            seen = leftovers
            XCTAssertEqual(onDisk, Self.list)
            let temporary = directory.appendingPathComponent(seen.first ?? "")
            XCTAssertEqual(states(try? Data(contentsOf: temporary))["req-001"], "done")
        }
        XCTAssertNotNil(value(watched.setState(.done, of: "req-001")))
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen.first?.hasPrefix(".requests.json.") == true, "\(seen)")

        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotEqual(
            before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber,
            "the file was written in place")
        XCTAssertEqual(after[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(leftovers, [])
    }

    func testALinkStaysALink() throws {
        let real = directory.appendingPathComponent("real.json")
        try FileManager.default.moveItem(at: file, to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        XCTAssertNotNil(value(tracker.setState(.done, of: "req-001")))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), real.path)
        XCTAssertEqual(states()["req-001"], "done")
    }

    // MARK: Two writers

    func testAWriteByTheAgentBetweenTheReadAndTheRenameIsKept() throws {
        // The agent adds a request and finishes another while the tick is on its way.
        let agents = Self.list
            .replacingOccurrences(of: #""state": "blocked""#, with: #""state": "review""#)
            .replacingOccurrences(
                of: "  \"requests\": [\n",
                with: "  \"requests\": [\n    { \"id\": \"req-005\", \"title\": \"New ask\","
                    + " \"project\": \"devbox\", \"asked\": \"2026-10-04\", \"state\": \"todo\" },\n")
        var commits = 0
        var raced = tracker
        raced.beforeCommit = { [self] in
            commits += 1
            if commits == 1 { try? put(agents) }
        }
        XCTAssertNotNil(value(raced.setState(.done, of: "req-001")))

        XCTAssertEqual(commits, 2, "the tick was not made again on the agent's text")
        XCTAssertEqual(
            states(),
            ["req-005": "todo", "req-004": "in_progress", "req-003": "review", "req-002": "done",
             "req-001": "done"])
        XCTAssertEqual(
            onDisk,
            agents.replacingOccurrences(
                of: "\"req-001\",\n      \"title\": \"Theme tokens\",\n      \"project\": \"acme-app\","
                    + "\n      \"asked\": \"2026-10-01\",\n      \"state\": \"todo\"",
                with: "\"req-001\",\n      \"title\": \"Theme tokens\",\n      \"project\": \"acme-app\","
                    + "\n      \"asked\": \"2026-10-01\",\n      \"state\": \"done\"")
                .replacingOccurrences(of: "2026-10-03T16:20:00Z", with: stamp))
        XCTAssertEqual(leftovers, [])
    }

    func testAFileThatChangesUnderEveryAttemptAnswersBusyAndKeepsTheAgentsText() {
        var writes = 0
        var raced = tracker
        raced.beforeCommit = { [self] in
            writes += 1
            try? put(Self.list.replacingOccurrences(of: "Theme tokens", with: "Theme tokens v\(writes)"))
        }
        XCTAssertEqual(failure(raced.setState(.done, of: "req-001")), .busy)
        XCTAssertEqual(writes, raced.writeAttempts)
        XCTAssertEqual(states()["req-001"], "todo")
        XCTAssertTrue(onDisk.contains("Theme tokens v\(writes)"))
        XCTAssertEqual(leftovers, [])
    }

    func testTheAgentRemovingTheRequestMeanwhileIsNotUndone() throws {
        var raced = tracker
        raced.beforeCommit = { [self] in
            try? put(#"{"schema":1,"requests":[]}"#)
        }
        XCTAssertEqual(failure(raced.setState(.done, of: "req-001")), .unknownRequest)
        XCTAssertEqual(onDisk, #"{"schema":1,"requests":[]}"#)
    }

    func testTicksFromManyThreadsAllLandAndAReaderNeverSeesHalfAFile() throws {
        let count = 24
        let rows = (1...count).map {
            #"    { "id": "r\#($0)", "title": "Ask \#($0)", "project": "acme-app", "state": "todo" }"#
        }
        try put("{\n  \"schema\": 1,\n  \"updated\": \"x\",\n  \"requests\": [\n"
            + rows.joined(separator: ",\n") + "\n  ]\n}\n")

        let file = file
        let stop = NSLock()
        var stopped = false
        var reads = 0
        var broken: [String] = []
        let finished = expectation(description: "reader stopped")
        Thread.detachNewThread {
            while true {
                stop.lock()
                let done = stopped
                stop.unlock()
                if done { break }
                // One read with no second try: what any other reader would get.
                if let data = try? Data(contentsOf: file) {
                    reads += 1
                    if let fault = RequestTracker.fault(in: data) { broken.append(fault) }
                } else {
                    broken.append("no file")
                }
            }
            finished.fulfill()
        }

        let tracker = tracker
        var failures: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            if case .failure(let error) = tracker.setState(.done, of: "r\(index + 1)") {
                lock.lock()
                failures.append("r\(index + 1): \(error)")
                lock.unlock()
            }
        }
        stop.lock()
        stopped = true
        stop.unlock()
        wait(for: [finished], timeout: 10)

        XCTAssertEqual(failures, [])
        XCTAssertEqual(states().values.filter { $0 == "done" }.count, count)
        XCTAssertEqual(broken, [])
        XCTAssertGreaterThan(reads, 0)
        XCTAssertEqual(leftovers, [])
    }

    // MARK: The edit

    private func edit(_ text: String, id: String = "a", state: RequestState = .done)
        -> Result<String, RequestTrackerError> {
        RequestTracker.edit(Data(text.utf8), id: id, state: state, stamp: "NOW")
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func testTheEditFindsTheStateInAnyLayout() {
        // Minified, and the state before the id.
        XCTAssertEqual(
            value(edit(#"{"schema":1,"requests":[{"state":"todo","title":"t","id":"a"}],"updated":"then"}"#)),
            #"{"schema":1,"requests":[{"state":"done","title":"t","id":"a"}],"updated":"NOW"}"#)
        // Windows line ends, tabs and a byte order mark stay.
        XCTAssertEqual(
            value(edit("\u{FEFF}{\r\n\t\"schema\": 1,\r\n\t\"requests\": [ {\"id\": \"a\",\t\"title\": \"t\", \"state\"\t:\t\"review\"} ]\r\n}\r\n")),
            "\u{FEFF}{\r\n\t\"schema\": 1,\r\n\t\"requests\": [ {\"id\": \"a\",\t\"title\": \"t\", \"state\"\t:\t\"done\"} ]\r\n}\r\n")
        // An id written with an escape is the same id.
        XCTAssertEqual(
            value(edit(#"{"schema":1,"requests":[{"id":"\u0061","title":"t","state":"todo"}]}"#)),
            #"{"schema":1,"requests":[{"id":"\u0061","title":"t","state":"done"}]}"#)
    }

    func testTheEditIsNotFooledByTextThatLooksLikeTheList() {
        // A "state" in a nested object, in a string, and in another request stay.
        let text = #"""
        {"schema":1,"updated":7,"note":"\"id\":\"a\",\"state\":\"todo\" }]",
         "blockers":[{"id":"a","state":"todo"}],
         "requests":[
          {"id":"b","title":"{\"id\":\"a\"}","state":"todo"},
          {"id":"a","title":"t [","meta":{"id":"z","state":"todo","deep":[{"state":"todo"}]},"state":"todo"}
         ]}
        """#
        let expected = text.replacingOccurrences(
            of: #"[{"state":"todo"}]},"state":"todo"}"#, with: #"[{"state":"todo"}]},"state":"done"}"#)
        XCTAssertNotEqual(expected, text)
        // `updated` is not a string here: it is left as it is.
        XCTAssertEqual(value(edit(text)), expected)
    }

    func testTheEditAddsNoTimeToAListWithoutOne() {
        XCTAssertEqual(
            value(edit(#"{"schema":1,"requests":[{"id":"a","title":"t","state":"todo"}]}"#)),
            #"{"schema":1,"requests":[{"id":"a","title":"t","state":"done"}]}"#)
    }

    func testEveryCutOfTheListIsRefusedAndNoneCrashes() {
        let bytes = Array(Self.list.utf8)
        // The whole text less its last line end is still the list.
        for length in 0..<(bytes.count - 2) {
            let cut = Data(bytes[0..<length])
            guard case .failure = RequestTracker.edit(cut, id: "req-001", state: .done, stamp: "NOW") else {
                return XCTFail("a list cut at byte \(length) was changed")
            }
            XCTAssertNotNil(RequestTracker.fault(in: cut), "cut at \(length)")
        }
        // Bytes that are no text at all.
        var noise = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let junk = Data((0..<64).map { _ in UInt8.random(in: 0...255, using: &noise) })
            let spans = JSONSpans(junk)
            if let root = spans.root() {
                _ = spans.members(of: root)
                _ = spans.elements(of: root)
                _ = spans.string(root)
            }
            guard case .failure = RequestTracker.edit(junk, id: "a", state: .done, stamp: "NOW") else {
                return XCTFail("noise was changed")
            }
        }
    }

    // MARK: The phone API

    private func request(_ target: String, method: String = "GET") -> MobileRequest {
        guard case .request(let request, _) = MobileHTTP.parse(
            Data("\(method) \(target) HTTP/1.1\r\n\r\n".utf8))
        else {
            XCTFail("did not parse: \(target)")
            return MobileRequest(method: method, path: "/")
        }
        return request
    }

    func testTheRoutesBelongToTheManagerSwitch() {
        let on = MobileConfig(capabilities: [.manager])
        XCTAssertEqual(MobileAPI.route(request("/api/requests"), config: on), .api(.requests))
        XCTAssertEqual(
            MobileAPI.route(request("/api/requests/state", method: "POST"), config: on),
            .api(.requestState))
        XCTAssertEqual(MobileAPI.route(request("/api/requests/state"), config: on), .methodNotAllowed)
        XCTAssertEqual(
            MobileAPI.route(request("/api/requests", method: "POST"), config: on), .methodNotAllowed)
        XCTAssertEqual(MobileAPI.route(request("/api/requests/nope"), config: on), .notFound)
        // Off: refused, built or not.
        XCTAssertEqual(MobileAPI.route(request("/api/requests")), .disabled(.manager))
        XCTAssertEqual(
            MobileAPI.route(request("/api/requests/state", method: "POST")), .disabled(.manager))
        // The page itself is a client route: the shell answers it.
        XCTAssertEqual(MobileAPI.route(request("/requests")), .asset("requests"))
        XCTAssertTrue(MobileAPI.isClientRoute("requests"))
    }

    func testAStateChangeNamesARequestAndAKnownState() {
        let change = MobileRequests.change(in: Data(#"{"id":"req-001","state":"in_progress"}"#.utf8))
        XCTAssertEqual(change?.id, "req-001")
        XCTAssertEqual(change?.state, .inProgress)
        for body in [
            #"{"id":"req-001","state":"finished"}"#, #"{"id":"req-001"}"#, #"{"state":"done"}"#,
            #"{"id":"","state":"done"}"#, #"{"id":7,"state":"done"}"#, "[]", "",
        ] {
            XCTAssertNil(MobileRequests.change(in: Data(body.utf8)), body)
        }
    }

    func testAFailureIsAnErrorThePhoneShowsAndNeverAnEmptyList() {
        let list = Data(Self.list.utf8)
        XCTAssertEqual(MobileRequests.response(.success(list)), .json(data: list))
        XCTAssertEqual(
            MobileRequests.response(.failure(.corrupt("requests.json is not valid JSON"))),
            .error(500, "corrupt", message: "requests.json is not valid JSON"))
        XCTAssertEqual(MobileRequests.response(.failure(.io("denied"))).status, 500)
        XCTAssertEqual(MobileRequests.response(.failure(.unknownRequest)), .error(404, "not_found"))
        XCTAssertEqual(MobileRequests.response(.failure(.busy)).status, 409)
    }

    // MARK: The agent's read: `mux requests`

    private func mux(_ arguments: [String]) -> (status: Int32, out: String, error: String) {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../app/MuxMaestro/Resources/manager/mux").standardizedFileURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["MUX_MANAGER_REQUESTS"] = file.path
        // A read of the list must never make or open the DB.
        environment["MUX_MANAGER_DB"] = directory.appendingPathComponent("manager.db").path
        process.environment = environment
        let (out, error) = (Pipe(), Pipe())
        process.standardOutput = out
        process.standardError = error
        do { try process.run() } catch { return (-1, "", "\(error)") }
        let said = out.fileHandleForReading.readDataToEndOfFile()
        let complained = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: said, as: UTF8.self),
            String(decoding: complained, as: UTF8.self)
        )
    }

    func testMuxPrintsTheListNewestFirst() {
        let all = mux(["requests"])
        XCTAssertEqual(all.status, 0, all.error)
        XCTAssertEqual(all.out, """
        in_progress|req-004|acme-app|2026-10-03|Search across every session
        blocked|req-003|acme-app|2026-10-03|Dark mode for the settings page ✨
        done|req-002|devbox|2026-10-02|Nightly backup of devbox
        todo|req-001|acme-app|2026-10-01|Theme tokens

        """)
        XCTAssertEqual(mux(["requests", "--done"]).out, "done|req-002|devbox|2026-10-02|Nightly backup of devbox\n")
        XCTAssertEqual(mux(["requests", "--open"]).out.split(separator: "\n").count, 3)
        XCTAssertEqual(leftovers, [], "the read made a file")
    }

    func testMuxSeesATickTheAppWrote() throws {
        XCTAssertNotNil(value(tracker.setState(.done, of: "req-001")))
        XCTAssertTrue(
            mux(["requests", "--done"]).out.contains("done|req-001|acme-app|2026-10-01|Theme tokens\n"))

        let json = mux(["requests", "--json", "--open"])
        XCTAssertEqual(json.status, 0, json.error)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        XCTAssertEqual(object["updated"] as? String, stamp)
        XCTAssertEqual(
            (object["requests"] as? [[String: Any]])?.compactMap { $0["id"] as? String },
            ["req-004", "req-003"])
        XCTAssertEqual((object["blockers"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(object["open_questions"] as? [String], ["Keep the old search box?"])
    }

    func testMuxRefusesAFileThatIsNotTheListAndReadsNoFileAsEmpty() throws {
        try put(String(Self.list.prefix(400)))
        let half = mux(["requests"])
        XCTAssertEqual(half.status, 2)
        XCTAssertEqual(half.out, "")
        XCTAssertTrue(half.error.contains("is not a readable list"), half.error)

        try FileManager.default.removeItem(at: file)
        let none = mux(["requests"])
        XCTAssertEqual(none.status, 0, none.error)
        XCTAssertEqual(none.out, "")
        XCTAssertEqual(mux(["requests", "--json"]).out, "{\"requests\":[]}\n")
        XCTAssertEqual(mux(["requests", "--nope"]).status, 2)
        XCTAssertEqual(leftovers, [])
    }
}
