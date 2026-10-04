import XCTest

// MobileLog.swift (Foundation only) compiles into this test target: what a
// line of the phone's log may hold, the file's size and age limits, what a
// full disk does, the route, and `mux phone-log` reading what was written.
final class MobileLogTests: XCTestCase {
    private var dir: URL!
    private var now = Date()

    override func setUpWithError() throws {
        // The file's own dates are the real clock's: the tests count from now.
        now = Date()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func object(_ line: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
    }

    private func body(_ lines: [[String: Any]], sid: String = "s1", build: String = "aaa111") -> Data {
        try! JSONSerialization.data(withJSONObject: ["sid": sid, "build": build, "lines": lines])
    }

    /// A line as the file gets it. With `bytes`, one that takes exactly that
    /// much of the file, its newline counted.
    private func line(_ msg: String = "x", bytes: Int = 0) -> Data {
        let make = { (msg: String) in
            MobileLog.line(
                at: self.now, sev: "error", kind: "error", build: "aaa111", served: "aaa111", msg: msg)!
        }
        let pad = max(0, bytes - make(msg).count - 1)
        return make(msg + String(repeating: "x", count: pad))
    }

    private func read(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: lines

    func testALineCarriesItsBuildTheBuildTheMacServesItsProjectAndItsSession() {
        let batch = MobileLog.batch(
            body([[
                "age": 4000, "sev": "error", "kind": "error", "msg": "x is not a function",
                "project": "acme-app", "host": "devbox", "stack": "f@/_app/a.js:1:2", "line": 12,
                "standalone": true, "caches": ["shell-aaa111"],
            ]]), served: "bbb222", now: now)
        XCTAssertEqual(batch.sid, "s1")
        XCTAssertEqual(batch.build, "aaa111")
        XCTAssertEqual(batch.lines.count, 1)
        let line = object(batch.lines[0])
        XCTAssertEqual(line["sev"] as? String, "error")
        XCTAssertEqual(line["kind"] as? String, "error")
        XCTAssertEqual(line["project"] as? String, "acme-app")
        XCTAssertEqual(line["host"] as? String, "devbox")
        XCTAssertEqual(line["build"] as? String, "aaa111")
        XCTAssertEqual(line["served"] as? String, "bbb222")
        XCTAssertEqual(line["sid"] as? String, "s1")
        XCTAssertEqual(line["msg"] as? String, "x is not a function")
        XCTAssertEqual(line["stack"] as? String, "f@/_app/a.js:1:2")
        XCTAssertEqual(line["line"] as? Int, 12)
        XCTAssertEqual(line["standalone"] as? Bool, true)
        XCTAssertEqual(line["caches"] as? [String], ["shell-aaa111"])
        // The time is this Mac's clock less the line's age.
        XCTAssertEqual(line["t"] as? String, MobileLog.stamp(now.addingTimeInterval(-4)))
        // One line of text, with the time first.
        let text = String(decoding: batch.lines[0], as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"t":"20"#))
        XCTAssertFalse(text.contains("\n"))
    }

    func testABatchCannotSetTheTimeTheBuildsOrTheSessionOfALine() {
        let batch = MobileLog.batch(
            body([["msg": "m", "t": "1999-01-01T00:00:00.000Z", "served": "zzz", "build": "zzz", "sid": "zzz"]]),
            served: "bbb222", now: now)
        let line = object(batch.lines[0])
        XCTAssertEqual(line["t"] as? String, MobileLog.stamp(now))
        XCTAssertEqual(line["served"] as? String, "bbb222")
        XCTAssertEqual(line["build"] as? String, "aaa111")
        XCTAssertEqual(line["sid"] as? String, "s1")
    }

    func testWhatIsNotAShortValueIsLeftOut() {
        let batch = MobileLog.batch(
            body([[
                "msg": String(repeating: "m", count: 5000), "sev": "fatal", "nested": ["a": 1],
                "Bad-Name": "x", "averyveryverylongfieldname": "x", "stack": String(repeating: "s", count: 9000),
                "list": Array(repeating: "v", count: 50),
            ]]), served: nil, now: now)
        XCTAssertEqual(batch.lines.count, 1)
        XCTAssertLessThan(batch.lines[0].count, MobileLog.maxLineBytes)
        let line = object(batch.lines[0])
        XCTAssertEqual(line["sev"] as? String, "info")
        XCTAssertEqual((line["msg"] as? String)?.count, MobileLog.textLimit + 1)
        XCTAssertEqual((line["stack"] as? String)?.count, MobileLog.stackLimit + 1)
        XCTAssertEqual((line["list"] as? [String])?.count, MobileLog.listLimit)
        XCTAssertNil(line["nested"])
        XCTAssertNil(line["Bad-Name"])
        XCTAssertNil(line["averyveryverylongfieldname"])
    }

    func testALineThatIsTooLongLosesItsStackAndThenItsOtherFields() {
        var fields: [String: Any] = ["stack": String(repeating: "s", count: 2000)]
        for index in 0..<20 { fields["f\(index)"] = String(repeating: "é", count: 300) }
        let line = MobileLog.line(
            at: now, sev: "error", kind: "error", build: "aaa111", served: "aaa111", msg: "m",
            fields: fields)!
        XCTAssertLessThan(line.count, MobileLog.maxLineBytes)
        XCTAssertEqual(object(line)["msg"] as? String, "m")
        XCTAssertNil(object(line)["stack"])
    }

    func testABodyThatIsNotABatchGivesNoLinesAndALongBatchIsCut() {
        XCTAssertEqual(MobileLog.batch(Data("not json".utf8), served: nil, now: now).lines, [])
        XCTAssertEqual(MobileLog.batch(Data("[1,2]".utf8), served: nil, now: now).lines, [])
        XCTAssertEqual(MobileLog.batch(Data(#"{"lines":"x"}"#.utf8), served: nil, now: now).lines, [])
        let many = MobileLog.batch(
            body(Array(repeating: ["msg": "m"], count: 500)), served: nil, now: now)
        XCTAssertEqual(many.lines.count, MobileLog.maxLines)
    }

    func testTheServedBuildIsReadFromTheBundle() throws {
        XCTAssertNil(MobileLog.servedBuild(staticRoot: dir))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("_app"), withIntermediateDirectories: true)
        try Data(#"{"version":"a5c3b32afc8b"}"#.utf8)
            .write(to: dir.appendingPathComponent("_app/version.json"))
        XCTAssertEqual(MobileLog.servedBuild(staticRoot: dir), "a5c3b32afc8b")
    }

    func testTheBudgetStopsAFloodAndOpensAgainTheNextMinute() {
        var budget = MobileLogBudget(perMinute: 10)
        XCTAssertEqual(budget.take(6, now: now), 6)
        XCTAssertEqual(budget.take(6, now: now.addingTimeInterval(1)), 4)
        XCTAssertEqual(budget.take(6, now: now.addingTimeInterval(2)), 0)
        // Said once in the minute.
        XCTAssertTrue(budget.shouldTell())
        XCTAssertFalse(budget.shouldTell())
        XCTAssertEqual(budget.take(6, now: now.addingTimeInterval(61)), 6)
        XCTAssertTrue(budget.shouldTell())
    }

    // MARK: the file

    func testLinesAreAppendedOneToALine() {
        let file = MobileLogFile(directory: dir)
        XCTAssertEqual(file.append([line("a"), line("b")], now: now), 2)
        XCTAssertEqual(file.append([line("c")], now: now), 1)
        XCTAssertEqual(read(file.active).map { object(Data($0.utf8))["msg"] as? String }, ["a", "b", "c"])
        XCTAssertEqual(file.all, [file.active])
    }

    func testTheLogDirectoryIsMadeWhenItIsNotThere() {
        let file = MobileLogFile(directory: dir.appendingPathComponent("a/b"))
        XCTAssertEqual(file.append([line("a")], now: now), 1)
        XCTAssertEqual(read(file.active).count, 1)
    }

    func testAFullFileIsRotatedAndTheOldestGenerationIsDeleted() {
        let limits = MobileLogFile.Limits(maxFileBytes: 1000, generations: 2)
        let file = MobileLogFile(directory: dir, limits: limits)
        // Each line takes 400 bytes: two fit a file, the third starts a new one.
        for index in 0..<7 { file.append([line("m\(index)-", bytes: 400)], now: now) }
        XCTAssertEqual(
            file.all.map(\.lastPathComponent), ["phone.2.jsonl", "phone.1.jsonl", "phone.jsonl"])
        let kept = file.all.flatMap(read).map { String((object(Data($0.utf8))["msg"] as! String).prefix(2)) }
        // Oldest first, and the first two lines went with the file that was deleted.
        XCTAssertEqual(kept, ["m2", "m3", "m4", "m5", "m6"])
    }

    func testTheLogNeverGrowsPastItsSizeLimitHoweverMuchIsWritten() {
        let limits = MobileLogFile.Limits(maxFileBytes: 4096, generations: 3)
        let file = MobileLogFile(directory: dir, limits: limits)
        XCTAssertEqual(limits.maxTotalBytes, 16_384)
        var written = 0
        // Fifty times the limit, in batches of uneven lines.
        while written < limits.maxTotalBytes * 50 {
            let batch = (0..<Int.random(in: 1...40)).map { _ in
                line("m", bytes: Int.random(in: 130...1500))
            }
            file.append(batch, now: now)
            written += batch.reduce(0) { $0 + $1.count + 1 }
            XCTAssertLessThanOrEqual(file.totalBytes, limits.maxTotalBytes)
            for url in file.all {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                XCTAssertLessThanOrEqual(size, limits.maxFileBytes)
            }
        }
        // Only the log's own files, and no more than it keeps.
        let names = try! FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["phone.1.jsonl", "phone.2.jsonl", "phone.3.jsonl", "phone.jsonl"])
        // What is left is whole lines.
        for text in file.all.flatMap(read) {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
        }
    }

    func testTheShippedLimitsAreFourMebibytesAndEightDays() {
        let limits = MobileLogFile.Limits()
        XCTAssertEqual(limits.maxTotalBytes, 4 * 1_048_576)
        XCTAssertEqual(limits.maxLineAge, 8 * 86_400)
        // A line always fits a file, and a batch is far smaller than one.
        XCTAssertLessThan(MobileLog.maxLineBytes, limits.maxFileBytes)
    }

    func testALineLongerThanAFileIsDroppedNotWritten() {
        let file = MobileLogFile(directory: dir, limits: MobileLogFile.Limits(maxFileBytes: 200))
        XCTAssertEqual(file.append([line("big", bytes: 500), line("ok", bytes: 150)], now: now), 1)
        XCTAssertLessThanOrEqual(file.totalBytes, 200)
        XCTAssertEqual(file.lost, 1)
    }

    func testAFileADayOldIsRotatedHoweverSmallItIs() {
        let file = MobileLogFile(directory: dir)
        file.append([line("monday")], now: now)
        file.append([line("same day")], now: now.addingTimeInterval(3600))
        XCTAssertEqual(file.all, [file.active])
        file.append([line("tuesday")], now: now.addingTimeInterval(86_460))
        XCTAssertEqual(file.all, [file.rotated(1), file.active])
        XCTAssertEqual(read(file.rotated(1)).count, 2)
        XCTAssertEqual(read(file.active).count, 1)
    }

    func testFilesPastTheirAgeAreDeleted() throws {
        let file = MobileLogFile(directory: dir)
        file.append([line("old")], now: now)
        file.append([line("newer")], now: now.addingTimeInterval(86_460))
        // Seven days after the last write to each, it goes.
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: file.rotated(1).path)
        file.prune(now: now.addingTimeInterval(86_461))
        XCTAssertEqual(file.all, [file.active])
        file.prune(now: now.addingTimeInterval(9 * 86_400))
        XCTAssertEqual(file.all, [])
        XCTAssertEqual(file.totalBytes, 0)
    }

    func testAppendingPrunesSoAnIdleLogDoesNotKeepOldLines() {
        let file = MobileLogFile(directory: dir)
        file.append([line("old")], now: now)
        file.append([line("new")], now: now.addingTimeInterval(9 * 86_400))
        XCTAssertEqual(file.all, [file.active])
        XCTAssertEqual(read(file.active).map { object(Data($0.utf8))["msg"] as? String }, ["new"])
    }

    func testOnlyTheLogsOwnFilesAreEverDeleted() throws {
        let other = dir.appendingPathComponent("another.log")
        let near = dir.appendingPathComponent("phone.old.jsonl")
        let extra = dir.appendingPathComponent("phone.9.jsonl")
        for url in [other, near, extra] {
            try Data("keep".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: url.path)
        }
        MobileLogFile(directory: dir).prune(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: near.path))
        // A generation past the ones kept is the log's own, and goes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra.path))
        XCTAssertEqual(MobileLogFile.generation(ofFileNamed: "phone.3.jsonl"), 3)
        XCTAssertNil(MobileLogFile.generation(ofFileNamed: "phone.jsonl"))
        XCTAssertNil(MobileLogFile.generation(ofFileNamed: "phone.0.jsonl"))
        XCTAssertNil(MobileLogFile.generation(ofFileNamed: "phone.3.jsonl.bak"))
    }

    // MARK: a disk that refuses

    private let full = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))

    func testAFullDiskGivesUpTheOldestLinesForTheNewOnes() {
        let limits = MobileLogFile.Limits(maxFileBytes: 1000, generations: 3)
        let file = MobileLogFile(directory: dir, limits: limits)
        for index in 0..<8 { file.append([line("m\(index)-", bytes: 400)], now: now) }
        XCTAssertEqual(file.all.count, 4)
        // The disk takes a write only once two of the old files are gone.
        file.write = { [full] data, url in
            guard file.all.count <= 2 else { throw full }
            try MobileLogFile.appendBytes(data, to: url)
        }
        XCTAssertEqual(file.append([line("new", bytes: 150)], now: now), 1)
        XCTAssertEqual(file.all.map(\.lastPathComponent), ["phone.1.jsonl", "phone.jsonl"])
        let last = read(file.active).last.flatMap { object(Data($0.utf8))["msg"] as? String }
        XCTAssertEqual(last?.hasPrefix("new"), true)
        XCTAssertEqual(file.lost, 0)
    }

    func testADiskThatStaysFullDropsTheNewLinesAndReturns() {
        let file = MobileLogFile(directory: dir)
        var calls = 0
        file.write = { [full] _, _ in
            calls += 1
            throw full
        }
        let began = Date()
        XCTAssertEqual(file.append([line("a"), line("b")], now: now), 0)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertEqual(file.lost, 2)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(file.totalBytes, 0)
    }

    func testAnyOtherFailureKeepsTheOldLinesAndTheNextWriteSaysWhatWasLost() {
        let file = MobileLogFile(directory: dir)
        file.append((0..<4).map { line("m\($0)") }, now: now)
        file.write = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        XCTAssertEqual(file.append([line("a"), line("b"), line("c")], now: now), 0)
        XCTAssertEqual(read(file.active).count, 4)
        XCTAssertEqual(file.lost, 3)

        file.write = MobileLogFile.appendBytes
        XCTAssertEqual(file.append([line("back")], now: now), 2)
        XCTAssertEqual(file.lost, 0)
        let tail = read(file.active).suffix(2).map { object(Data($0.utf8)) }
        XCTAssertEqual(tail[0]["kind"] as? String, "dropped")
        XCTAssertEqual(tail[0]["n"] as? Int, 3)
        XCTAssertEqual(tail[1]["msg"] as? String, "back")
    }

    func testADirectoryThatCannotBeWrittenNeverThrowsOrBlocks() {
        let file = MobileLogFile(directory: URL(fileURLWithPath: "/dev/null/phone-log"))
        XCTAssertEqual(file.append([line("a")], now: now), 0)
        XCTAssertEqual(file.lost, 1)
    }

    func testIsFullKnowsTheDiskAndTheQuota() {
        XCTAssertTrue(MobileLogFile.isFull(full))
        XCTAssertTrue(MobileLogFile.isFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))))
        XCTAssertTrue(MobileLogFile.isFull(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(MobileLogFile.isFull(NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: full])))
        XCTAssertFalse(MobileLogFile.isFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    // MARK: the sink

    private func lines(in directory: URL) -> [[String: Any]] {
        MobileLogFile(directory: directory).all.flatMap(read).map { object(Data($0.utf8)) }
    }

    func testAPhoneOnAnOldBuildIsSaidOncePerSession() {
        let sink = MobileLogSink(directory: dir, served: "bbb222")
        sink.receive(body([["msg": "one", "sev": "error"]]))
        sink.receive(body([["msg": "two", "sev": "error"]]))
        sink.receive(body([["msg": "three"]], sid: "s2"))
        sink.receive(body([["msg": "current"]], sid: "s3", build: "bbb222"))
        sink.drain()
        let written = lines(in: dir)
        let stale = written.filter { $0["kind"] as? String == "stale" }
        XCTAssertEqual(stale.map { $0["sid"] as? String }, ["s1", "s2"])
        XCTAssertEqual(stale[0]["sev"] as? String, "warn")
        XCTAssertEqual(stale[0]["build"] as? String, "aaa111")
        XCTAssertEqual(stale[0]["served"] as? String, "bbb222")
        XCTAssertEqual(stale[0]["msg"] as? String, "the phone runs build aaa111; this Mac serves bbb222")
        // It comes before the lines of the batch that showed it.
        XCTAssertEqual(written.map { $0["msg"] as? String }.prefix(2).last, "one")
        XCTAssertEqual(written.count, 6)
    }

    func testAFloodIsCutAtTheBudgetAndTheFileSaysSo() {
        let sink = MobileLogSink(directory: dir, served: "aaa111")
        for _ in 0..<5 {
            sink.receive(body((0..<100).map { ["msg": "m\($0)", "sev": "error"] }))
        }
        sink.drain()
        let written = lines(in: dir)
        XCTAssertEqual(written.filter { $0["kind"] as? String != "dropped" }.count, 300)
        let notes = written.filter { $0["kind"] as? String == "dropped" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0]["sev"] as? String, "warn")
    }

    func testTheServerStartIsALineWithTheBundleItServes() {
        let sink = MobileLogSink(directory: dir, served: "bbb222")
        sink.started(port: 7433, binary: URL(fileURLWithPath: "/bin/sh"))
        sink.drain()
        let written = lines(in: dir)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0]["kind"] as? String, "mac")
        XCTAssertEqual(written[0]["build"] as? String, "bbb222")
        XCTAssertEqual(written[0]["port"] as? Int, 7433)
        XCTAssertNotNil(written[0]["app"] as? String)
    }

    func testReceiveReturnsBeforeTheDiskIsTouched() {
        // The log's directory is under a file: every write fails, slowly or
        // not, and the caller is never held.
        let sink = MobileLogSink(directory: URL(fileURLWithPath: "/dev/null/phone-log"), served: nil)
        let began = Date()
        for _ in 0..<1000 { sink.receive(body([["msg": "m"]])) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        sink.drain()
    }

    // MARK: the route

    private func request(_ method: String, _ path: String) -> MobileRequest {
        MobileRequest(method: method, path: path)
    }

    func testTheLogRouteIsAWriteThatNeedsNoSwitch() {
        // Nothing switched on: the log still works, as the thread list does.
        XCTAssertEqual(MobileAPI.route(request("POST", "/api/log")), .api(.log))
        XCTAssertEqual(MobileAPI.route(request("GET", "/api/log")), .methodNotAllowed)
        XCTAssertEqual(MobileEndpoint.log.capability, .access)
        XCTAssertEqual(MobileHTTP.bodyLimit(method: "POST", path: "/api/log"), MobileLog.maxBodyBytes)
    }

    func testABatchPastTheBodyLimitIsRefusedBeforeItIsRead() {
        let head = "POST /api/log HTTP/1.1\r\nContent-Length: \(MobileLog.maxBodyBytes + 1)\r\n\r\n"
        XCTAssertEqual(MobileHTTP.parse(Data(head.utf8)), .invalid(413))
    }

    func testAWriteToTheLogNeedsTheTokenTheHeaderAndTheOrigin() {
        let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")
        var request = request("POST", "/api/log")
        request.headers = ["host": "devmac.example.ts.net:7433", "tailscale-user-login": "me@example.com"]
        XCTAssertNotEqual(MobileAPI.authorize(request, identity: identity), .allowed)
        request.headers["x-muxmaestro"] = "1"
        request.headers["origin"] = "https://devmac.example.ts.net:7433"
        XCTAssertEqual(MobileAPI.authorize(request, identity: identity), .allowed)
        XCTAssertTrue(MobileAPI.needsToken(request))
    }

    // MARK: the server

    func testAPostedBatchLandsInTheFileWithTheBuildTheServerServes() throws {
        let root = dir.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("_app"), withIntermediateDirectories: true)
        try Data(#"{"version":"bbb222"}"#.utf8).write(to: root.appendingPathComponent("_app/version.json"))
        let logs = dir.appendingPathComponent("logs")
        let server = MobileServer(
            staticRoot: root,
            sources: MobileServer.Sources(screen: { _, _ in nil }, transcript: { _ in nil }),
            logDirectory: logs)
        defer { server.stop() }
        var port = 0
        let started = expectation(description: "listening")
        server.start(
            port: 0, identity: MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net"),
            token: "demo-token"
        ) { result in
            if case .success(let bound) = result { port = bound }
            started.fulfill()
        }
        wait(for: [started], timeout: 5)

        let json = String(decoding: body([[
            "age": 0, "sev": "error", "kind": "error", "msg": "boom", "project": "acme-app",
        ]]), as: UTF8.self)
        func post(token: String?) -> Int {
            var raw = "POST /api/log HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
                + "Tailscale-User-Login: me@example.com\r\nContent-Type: application/json\r\n"
                + "Origin: https://devmac.example.ts.net:7433\r\nX-MuxMaestro: 1\r\n"
                + "Content-Length: \(json.utf8.count)\r\n"
            if let token { raw += "X-MuxMaestro-Token: \(token)\r\n" }
            raw += "\r\n" + json
            let reply = LoopbackClient.exchange(
                port: port, send: Data(raw.utf8), label: "mobile-log-tests"
            ) { String(decoding: $0, as: UTF8.self).contains("\r\n\r\n{") }
            return Int(String(decoding: reply, as: UTF8.self).split(separator: " ").dropFirst().first ?? "") ?? 0
        }
        XCTAssertEqual(post(token: nil), 401)
        XCTAssertEqual(post(token: "demo-token"), 200)

        // The file is written on the log's queue, after the answer.
        let deadline = Date().addingTimeInterval(5)
        var written: [[String: Any]] = []
        while Date() < deadline {
            written = lines(in: logs)
            if written.contains(where: { $0["msg"] as? String == "boom" }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(written.map { $0["kind"] as? String }, ["mac", "stale", "error"])
        XCTAssertEqual(written[0]["msg"] as? String, "phone server started")
        XCTAssertEqual(written[2]["project"] as? String, "acme-app")
        XCTAssertEqual(written[2]["build"] as? String, "aaa111")
        XCTAssertEqual(written[2]["served"] as? String, "bbb222")
    }

    // MARK: settings

    func testTheLogDirectoryIsUnderApplicationSupportUnlessASettingMovesIt() throws {
        let suite = "phone-log-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        XCTAssertEqual(
            Settings.phoneLogDirectory(defaults: defaults, support: support)?.path,
            "/Users/me/Library/Application Support/MuxMaestro/logs")
        defaults.set("/Users/me/logs", forKey: "phone.logDir")
        XCTAssertEqual(
            Settings.phoneLogDirectory(defaults: defaults, support: support)?.path, "/Users/me/logs")
        defaults.set("~/logs", forKey: "phone.logDir")
        XCTAssertEqual(
            Settings.phoneLogDirectory(defaults: defaults, support: support)?.path,
            NSHomeDirectory() + "/logs")
    }

    // MARK: mux phone-log

    private var muxPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../app/MuxMaestro/Resources/manager/mux").standardizedFileURL.path
    }

    private func mux(_ args: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [muxPath, "phone-log"] + args
        var env = ProcessInfo.processInfo.environment
        env["MUX_PHONE_LOG_DIR"] = dir.appendingPathComponent("log dir").path
        // A DB path that must stay untouched: the command never opens one.
        env["MUX_MANAGER_DB"] = dir.appendingPathComponent("manager.db").path
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self))
    }

    /// A log as the server writes it: two projects, three severities, an old
    /// file and the active one, and a phone on a stale build.
    private func writeLog() {
        let logs = dir.appendingPathComponent("log dir")
        let sink = MobileLogSink(
            directory: logs, served: "bbb222", limits: MobileLogFile.Limits(maxFileBytes: 700))
        sink.receive(body([
            ["age": 3 * 3_600_000, "sev": "error", "kind": "error", "msg": "old boom",
             "project": "acme-app", "src": "/_app/a.js", "line": 7],
            ["age": 60_000, "sev": "info", "kind": "life", "msg": "hidden"],
            ["age": 50_000, "sev": "warn", "kind": "fetch", "msg": "GET /api/hosts answered 404 after 12 ms",
             "project": "Storefront", "status": 404],
        ], build: "bbb222"))
        sink.receive(body([
            ["age": 2000, "sev": "error", "kind": "rejection", "msg": "a | b \"quoted\"\nsecond line",
             "project": "Storefront", "n": 4, "stack": "f@/_app/b.js:1:2"],
        ], sid: "s2"))
        sink.drain()
        XCTAssertGreaterThan(MobileLogFile(directory: logs).all.count, 1, "the log spans files")
    }

    func testMuxPrintsTheLastProblemsOldestFirstWithTheBuild() {
        writeLog()
        let result = mux([])
        XCTAssertEqual(result.status, 0, result.err)
        let rows = result.out.split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.count, 4)
        // time|severity|project|build|kind|message — info lines are left out.
        XCTAssertEqual(rows.map { $0[1] }, ["error", "warn", "warn", "error"])
        XCTAssertEqual(rows.map { $0[2] }, ["acme-app", "Storefront", "-", "Storefront"])
        XCTAssertEqual(rows[0][3], "bbb222")
        XCTAssertEqual(rows[0][5], "old boom @ /_app/a.js:7")
        XCTAssertEqual(rows[2][4], "stale")
        XCTAssertEqual(rows[3][3], "aaa111 (stale: Mac serves bbb222)")
        XCTAssertEqual(rows[3][4], "rejection")
        // One row per line, whatever the message holds.
        XCTAssertTrue(result.out.contains("a | b \"quoted\" second line (x4)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manager.db").path))
    }

    func testMuxFiltersBySeverityTimeProjectAndCount() {
        writeLog()
        XCTAssertEqual(mux(["--severity", "error"]).out.split(separator: "\n").count, 2)
        XCTAssertEqual(mux(["--severity", "info"]).out.split(separator: "\n").count, 5)
        XCTAssertEqual(mux(["--severity", "info", "--since", "1h"]).out.split(separator: "\n").count, 4)
        XCTAssertEqual(mux(["--since", "10s"]).out.split(separator: "\n").count, 2)
        // A project is a tmux session; its name is matched without case.
        let storefront = mux(["--project", "storefront"]).out.split(separator: "\n")
        XCTAssertEqual(storefront.count, 2)
        XCTAssertTrue(storefront.allSatisfy { $0.contains("|Storefront|") })
        XCTAssertEqual(mux(["--project", "o'brien"]).out, "")
        let last = mux(["--last", "1"]).out.split(separator: "\n")
        XCTAssertEqual(last.count, 1)
        XCTAssertTrue(last[0].contains("|rejection|"))
    }

    func testMuxPrintsWholeLinesAsJSONAndCountsByProject() throws {
        writeLog()
        let json = mux(["--json", "--severity", "error"]).out.split(separator: "\n")
        XCTAssertEqual(json.count, 2)
        let line = object(Data(json[1].utf8))
        XCTAssertEqual(line["stack"] as? String, "f@/_app/b.js:1:2")
        XCTAssertEqual(line["project"] as? String, "Storefront")
        XCTAssertEqual(line["build"] as? String, "aaa111")

        // project|errors|warnings|last — most errors first.
        let projects = mux(["--projects"]).out.split(separator: "\n").map { $0.split(separator: "|").map(String.init) }
        XCTAssertEqual(projects.map { Array($0.prefix(3)) }, [
            ["Storefront", "1", "1"], ["acme-app", "1", "0"], ["-", "0", "1"],
        ])
    }

    func testMuxSaysWhenThereIsNoLogAndRefusesABadArgument() {
        let none = mux([])
        XCTAssertEqual(none.status, 0)
        XCTAssertEqual(none.out, "")
        XCTAssertTrue(none.err.contains("no phone log"))
        XCTAssertEqual(mux(["--severity", "loud"]).status, 2)
        XCTAssertEqual(mux(["--since", "soon"]).status, 2)
        XCTAssertEqual(mux(["--last", "x"]).status, 2)
        XCTAssertEqual(mux(["--bogus"]).status, 2)
    }
}
