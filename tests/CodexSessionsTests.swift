import XCTest

// CodexSessions.swift is Foundation-only and compiled directly into this test
// target, like TmuxCommands/TmuxService/ClaudeSessionRecovery.

final class CodexSessionsTests: XCTestCase {

    // MARK: parseProcessTable

    /// Real `ps -Ao pid=,ppid=` output: right-aligned columns, leading spaces,
    /// variable column widths.
    private let psOutput = """
              1     0
            208 47194
          47194     1
          65439 47194
          66143 65439
          88937 80983
        """

    func testParseProcessTableReadsPidAndPpid() {
        let table = CodexSessions.parseProcessTable(psOutput)
        XCTAssertEqual(table[1], 0)
        XCTAssertEqual(table[66143], 65439)
        XCTAssertEqual(table[65439], 47194)
        XCTAssertEqual(table.count, 6)
    }

    func testParseProcessTableSkipsMalformedLines() {
        let table = CodexSessions.parseProcessTable("  1 0\nnot a row\n\n  9\n  7 3\n")
        XCTAssertEqual(table, [1: 0, 7: 3])
    }

    // MARK: parseOpenRollouts

    /// Abridged from a real `/usr/sbin/lsof -c codex -Fpn` capture: `p<pid>`
    /// opens a process block, `f<fd>`/`n<name>` fill it. Includes p69200 and
    /// p72423 — codex processes with no open rollout at all — plus the non-rollout
    /// paths (binary, sqlite, tty, pipes) that must be filtered out.
    private let lsofOutput = """
        p66143
        fcwd
        n/Users/me/code/github/widget
        ftxt
        n/Users/me/.bun/install/global/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex
        ftxt
        n/Users/me/.codex/logs_2.sqlite-shm
        f0
        n/dev/ttys056
        f7
        n->0xcfe4e390c5d17d9f
        f21
        n/Users/me/.codex/sessions/2026/08/29/rollout-2026-08-29T12-43-31-01a04e9e-978c-7e52-aaa5-41eb8c269564.jsonl
        f22
        n/Users/me/.codex/sessions/2026/08/29/rollout-2026-08-29T13-09-55-01a04eb6-c47f-78c0-baf7-10d36a202e5f.jsonl
        p69200
        fcwd
        n/Users/me
        f0
        n/dev/ttys012
        p72423
        fcwd
        n/Users/me
        p88937
        f19
        n/Users/me/.codex/sessions/2026/08/29/rollout-2026-08-29T01-09-15-01a04c22-fa42-7db3-8353-1a7870b41df6.jsonl
        """

    func testParseOpenRolloutsGroupsRolloutPathsByPid() {
        let byPid = CodexSessions.parseOpenRollouts(lsofOutput)
        XCTAssertEqual(byPid[66143]?.count, 2)
        XCTAssertEqual(
            byPid[66143]?.last,
            "/Users/me/.codex/sessions/2026/08/29/"
                + "rollout-2026-08-29T13-09-55-01a04eb6-c47f-78c0-baf7-10d36a202e5f.jsonl")
        XCTAssertEqual(byPid[88937]?.count, 1)
    }

    func testParseOpenRolloutsOmitsProcessesWithNoRollout() {
        // A codex process that holds no transcript simply has no entry — the scan
        // must not invent an empty one and then treat it as a session.
        let byPid = CodexSessions.parseOpenRollouts(lsofOutput)
        XCTAssertNil(byPid[69200])
        XCTAssertNil(byPid[72423])
        XCTAssertEqual(Set(byPid.keys), [66143, 88937])
    }

    func testParseOpenRolloutsFiltersNonRolloutPaths() {
        // The binary, the sqlite files, the tty and the pipes all live in the same
        // block as the rollouts; only `~/.codex/sessions/…jsonl` may survive.
        let paths = CodexSessions.parseOpenRollouts(lsofOutput).values.flatMap { $0 }
        XCTAssertEqual(paths.count, 3)
        for path in paths {
            XCTAssertTrue(path.contains("/.codex/sessions/"))
            XCTAssertTrue(path.hasSuffix(".jsonl"))
        }
    }

    func testParseOpenRolloutsIgnoresNamesBeforeAnyPid() {
        // Defensive: a truncated capture that starts mid-block has no owning pid.
        let out = "n/Users/me/.codex/sessions/2026/08/29/rollout-x.jsonl\np1\n"
        XCTAssertTrue(CodexSessions.parseOpenRollouts(out).isEmpty)
    }

    // MARK: sessionId(fromRolloutHead:)

    /// The first 400 bytes of a real top-level rollout.
    private let mainHead = """
        {"timestamp":"2026-08-29T17:43:53.857Z","ordinal":0,"type":"session_meta",\
        "payload":{"session_id":"01a04e9e-978c-7e52-aaa5-41eb8c269564",\
        "id":"01a04e9e-978c-7e52-aaa5-41eb8c269564","timestamp":"2026-08-29T17:43:31.518Z",\
        "cwd":"/Users/me/code/github/widget","originator":"codex-tui",\
        "cli_version":"0.150.1","source":"cli","thread_source":"user","model_provider":"openai"
        """

    /// The first 400 bytes of a real **subagent** rollout of that same
    /// conversation: its own `id` differs, but `session_id` is the top-level one.
    private let subagentHead = """
        {"timestamp":"2026-08-29T17:45:23.407Z","type":"session_meta",\
        "payload":{"session_id":"01a04e9e-978c-7e52-aaa5-41eb8c269564",\
        "id":"01a04e9e-984e-7d83-8125-f1d60e5d8ac0",\
        "parent_thread_id":"01a04e9e-978c-7e52-aaa5-41eb8c269564",\
        "timestamp":"2026-08-29T17:43:31.719Z","cwd":"/Users/me/code/github/widget",\
        "originator":"codex-tui","cli_version":"0.150.1","source":{"subagent":{"other":"guardian"}}
        """

    func testSessionIdFromRolloutHead() {
        XCTAssertEqual(
            CodexSessions.sessionId(fromRolloutHead: mainHead),
            "01a04e9e-978c-7e52-aaa5-41eb8c269564")
    }

    func testSessionIdFromSubagentHeadReturnsTopLevelConversation() {
        // This is the whole reason the scan can ignore which rollout it reads: a
        // subagent's file records the PARENT conversation in `session_id`, and its
        // own thread id in `id`. Returning `id` here would copy an unresumable id.
        XCTAssertEqual(
            CodexSessions.sessionId(fromRolloutHead: subagentHead),
            "01a04e9e-978c-7e52-aaa5-41eb8c269564")
    }

    func testSessionIdNilWhenKeyAbsent() {
        XCTAssertNil(CodexSessions.sessionId(fromRolloutHead: #"{"type":"turn","payload":{}}"#))
        XCTAssertNil(CodexSessions.sessionId(fromRolloutHead: ""))
    }

    func testSessionIdNilWhenValueEmpty() {
        XCTAssertNil(CodexSessions.sessionId(fromRolloutHead: #"{"session_id":"","id":"x"}"#))
    }

    func testSessionIdNilWhenHeadTruncatedMidValue() {
        // A 4 KB read that lands inside the value must not return a partial id.
        XCTAssertNil(CodexSessions.sessionId(fromRolloutHead: #"{"session_id":"01a04e9e-978c"#))
    }

    // MARK: mainRollout

    func testTheMainRolloutIsTheOneNamedForTheConversation() {
        // A TUI holds its own rollout plus guardian subagents' — which carry the
        // same session_id but their own file id.
        let paths = [
            "/h/.codex/sessions/2026/09/03/rollout-2026-09-03T08-59-37-01a06791-6739-79b1-b206-2c0f1fa82e18.jsonl",
            "/h/.codex/sessions/2026/09/03/rollout-2026-09-03T08-59-37-01a06791-663b-71c3-90b5-ad6b1b52d92d.jsonl",
        ]
        XCTAssertEqual(
            CodexSessions.mainRollout(sessionId: "01a06791-663b-71c3-90b5-ad6b1b52d92d", paths: paths),
            paths[1])
        XCTAssertNil(CodexSessions.mainRollout(sessionId: "01a0ffff-0000", paths: paths))
    }
}
