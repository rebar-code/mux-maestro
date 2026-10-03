import XCTest

// CodeSearch.swift + TmuxService.swift (Foundation-only, no AppKit) are compiled
// directly into this test target, so the pure rg-argv + JSON-parse core AND the
// service's local/remote routing can be asserted against a fake CommandRunner
// with no real rg/ssh spawned — mirroring GitDiffTests.

/// Records every command and replies from a scripted table — same shape as the
/// FakeRunner in GitDiffTests/TmuxServiceTests (each is file-private).
private final class FakeRunner: CommandRunner {
    private let lock = NSLock()
    private var _calls: [(path: String, args: [String], hadStdin: Bool)] = []
    var calls: [(path: String, args: [String], hadStdin: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var responses: [String: String?] = [:]
    var defaultResponse: String? = ""

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        _calls.append((path, args, stdin != nil))
        lock.unlock()
        let key = args.joined(separator: " ")
        if let scripted = responses[key] { return scripted }
        return defaultResponse
    }

    var argSequences: [[String]] { calls.map(\.args) }
}

private struct StaticStatusProvider: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}

final class CodeSearchTests: XCTestCase {

    // MARK: argv shape

    func testSearchArgvShape() {
        XCTAssertEqual(
            CodeSearch.searchArgv(cwd: "/repo", query: "foo"),
            ["--json", "--smart-case", "-F", "--max-count", "\(CodeSearch.perFileCap)",
             "--max-columns", "300", "--", "foo", "/repo"])
    }

    func testSearchArgvKeepsQueryLiteralAndAfterDashDash() {
        // A query starting with `-` (or containing regex metachars) is passed
        // verbatim after `--`, never read as a flag.
        let argv = CodeSearch.searchArgv(cwd: "/r", query: "-n.*[x]")
        let ddIndex = argv.firstIndex(of: "--")!
        XCTAssertEqual(argv[ddIndex + 1], "-n.*[x]")
        XCTAssertEqual(argv.last, "/r")
    }

    // MARK: parse — canned rg --json → matches

    private let cannedJSON = """
    {"type":"begin","data":{"path":{"text":"/repo/src/app.ts"}}}
    {"type":"match","data":{"path":{"text":"/repo/src/app.ts"},"lines":{"text":"const foo = 1\\n"},"line_number":3,"absolute_offset":40,"submatches":[{"match":{"text":"foo"},"start":6,"end":9}]}}
    {"type":"match","data":{"path":{"text":"/repo/src/app.ts"},"lines":{"text":"foo(foo)\\n"},"line_number":7,"absolute_offset":80,"submatches":[{"match":{"text":"foo"},"start":0,"end":3},{"match":{"text":"foo"},"start":4,"end":7}]}}
    {"type":"end","data":{"path":{"text":"/repo/src/app.ts"}}}
    {"type":"summary","data":{"elapsed_total":{"secs":0}}}
    """

    func testParseExtractsMatchesWithLineTextAndHighlights() {
        let result = CodeSearch.parse(cannedJSON)
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.rgAvailable)
        XCTAssertEqual(result.matches.count, 2)

        let first = result.matches[0]
        XCTAssertEqual(first.path, "/repo/src/app.ts")
        XCTAssertEqual(first.lineNumber, 3)
        XCTAssertEqual(first.lineText, "const foo = 1")  // trailing newline stripped
        XCTAssertEqual(first.highlights, [6..<9])
        // Byte offsets 6..<9 land on "foo" in the line text.
        let slice = Array(first.lineText.utf8)[6..<9]
        XCTAssertEqual(String(decoding: slice, as: UTF8.self), "foo")

        let second = result.matches[1]
        XCTAssertEqual(second.lineNumber, 7)
        XCTAssertEqual(second.highlights, [0..<3, 4..<7])
    }

    func testParseSkipsNonMatchAndGarbageLines() {
        let input = "not json\n{\"type\":\"summary\",\"data\":{}}\n{bad json}\n"
        let result = CodeSearch.parse(input)
        XCTAssertEqual(result.matches.count, 0)
        XCTAssertFalse(result.truncated)
    }

    func testParseEmptyInput() {
        XCTAssertEqual(CodeSearch.parse("").matches.count, 0)
    }

    func testParseMissingLineTextStillRecordsMatch() {
        // An over-long line: rg omits `lines.text`. We still record the hit (path
        // + line), with empty text and no highlights, rather than dropping it.
        let line = """
        {"type":"match","data":{"path":{"text":"/r/min.js"},"line_number":1,"submatches":[]}}
        """
        let result = CodeSearch.parse(line)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].lineText, "")
        XCTAssertEqual(result.matches[0].highlights, [])
    }

    // MARK: parse — total cap

    func testParseCapsTotalMatches() {
        let one = """
        {"type":"match","data":{"path":{"text":"/r/f"},"lines":{"text":"x\\n"},"line_number":1,"submatches":[]}}
        """
        let many = Array(repeating: one, count: CodeSearch.maxMatches + 5).joined(separator: "\n")
        let result = CodeSearch.parse(many)
        XCTAssertEqual(result.matches.count, CodeSearch.maxMatches)
        XCTAssertTrue(result.truncated)
    }

    // MARK: group — by file, order preserved

    func testGroupBucketsByFilePreservingOrder() {
        let m = { (p: String, n: Int) in
            SearchMatch(path: p, lineNumber: n, lineText: "", highlights: [])
        }
        let groups = CodeSearch.group([m("b", 1), m("a", 2), m("b", 3), m("a", 4)])
        XCTAssertEqual(groups.map(\.path), ["b", "a"])  // first-seen file order
        XCTAssertEqual(groups[0].matches.map(\.lineNumber), [1, 3])
        XCTAssertEqual(groups[1].matches.map(\.lineNumber), [2, 4])
    }

    // MARK: TmuxService.search — local routing + parse

    private func makeLocalService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: "/usr/bin/tmux")
    }

    func testSearchLocalRunsRgAndParses() {
        let runner = FakeRunner()
        runner.defaultResponse = nil  // unmatched commands return nil (rg no-match)
        let argvKey = CodeSearch.searchArgv(cwd: "/repo", query: "foo").joined(separator: " ")
        runner.responses[argvKey] = cannedJSON

        let result = makeLocalService(runner).search(cwd: "/repo", query: "foo")
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertTrue(result.rgAvailable)
        // rg ran locally (path resolves to an rg binary, not ssh).
        let call = runner.calls.first { $0.args == CodeSearch.searchArgv(cwd: "/repo", query: "foo") }
        XCTAssertNotNil(call)
        XCTAssertTrue(call!.path.hasSuffix("rg"))
    }

    func testSearchEmptyQuerySkipsExec() {
        let runner = FakeRunner()
        let result = makeLocalService(runner).search(cwd: "/repo", query: "   ")
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.rgAvailable)
        XCTAssertTrue(runner.calls.isEmpty)  // no rg spawned for an empty query
    }

    func testSearchNoMatchesIsAvailableWhenRgVersionSucceeds() {
        let runner = FakeRunner()
        runner.defaultResponse = nil  // search returns nil (rg exit 1, no matches)
        runner.responses["--version"] = "ripgrep 14.0.0"  // probe succeeds → installed
        let result = makeLocalService(runner).search(cwd: "/repo", query: "zzz")
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.rgAvailable)
    }

    func testSearchReportsRgMissingWhenProbeFails() {
        let runner = FakeRunner()
        runner.defaultResponse = nil  // both the search and the --version probe fail
        let result = makeLocalService(runner).search(cwd: "/repo", query: "zzz")
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertFalse(result.rgAvailable)
    }

    // MARK: TmuxService.search — remote routes rg over ssh

    private func makeRemoteService(_ runner: FakeRunner, host: String = "buildbox") -> TmuxService {
        TmuxService(
            host: Host(name: host, sshAlias: host),
            transport: SshTmuxTransport(host: host),
            runner: runner,
            statusProvider: StaticStatusProvider())
    }

    func testSearchRemoteRoutesRgThroughSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = ""  // empty stdout → no matches, but rg "ran"
        _ = makeRemoteService(runner).search(cwd: "/repo", query: "foo")
        // The search went over ssh, quoted token-by-token, starting with rg.
        let call = runner.calls.first {
            $0.path == "/usr/bin/ssh" && $0.args.contains("'rg'") && $0.args.contains("'foo'")
        }
        XCTAssertNotNil(call)
        XCTAssertTrue(call!.args.contains("buildbox"))
    }
}
