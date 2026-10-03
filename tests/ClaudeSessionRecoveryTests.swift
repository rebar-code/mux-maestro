import XCTest

// ClaudeSessionRecovery.swift is Foundation-only and compiled directly into
// this test target, like TmuxCommands/TmuxService.

/// Mirrors TmuxServiceTests' FakeRunner (that one is file-private): records the
/// argv sequence so the recover flow's exact tmux commands can be asserted.
private final class RecordingRunner: CommandRunner {
    private(set) var argSequences: [[String]] = []
    var responses: [String: String?] = [:]

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        argSequences.append(args)
        if let scripted = responses[args.joined(separator: " ")] { return scripted }
        return ""
    }
}

private struct StaticStatusProvider: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}

final class ClaudeSessionRecoveryTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_000_000)
    private func transcript(_ id: String, secondsBeforeCutoff: TimeInterval)
        -> ClaudeSessionRecovery.Transcript
    {
        .init(id: id, mtime: cutoff.addingTimeInterval(-secondsBeforeCutoff))
    }

    // MARK: newestInWindow — the "which session was open when tmux died" rule

    func testPicksNewestTranscriptInsideWindow() {
        let result = ClaudeSessionRecovery.newestInWindow(
            [
                transcript("old", secondsBeforeCutoff: 7200),
                transcript("newest", secondsBeforeCutoff: 60),
                transcript("middle", secondsBeforeCutoff: 3600),
            ],
            cutoff: cutoff, window: 12 * 3600)
        XCTAssertEqual(result?.transcript.id, "newest")
        XCTAssertEqual(result?.hasNewerActivity, false)
    }

    func testIgnoresTranscriptsOutsideWindow() {
        XCTAssertNil(ClaudeSessionRecovery.newestInWindow(
            [transcript("ancient", secondsBeforeCutoff: 13 * 3600)],
            cutoff: cutoff, window: 12 * 3600))
    }

    func testPostCutoffActivityFlagsButNeverWins() {
        // A transcript written AFTER the boot is this morning's new session — it
        // must not be offered for recovery, but its existence is flagged.
        let result = ClaudeSessionRecovery.newestInWindow(
            [
                transcript("lost", secondsBeforeCutoff: 600),
                transcript("this-morning", secondsBeforeCutoff: -3600),
            ],
            cutoff: cutoff, window: 12 * 3600)
        XCTAssertEqual(result?.transcript.id, "lost")
        XCTAssertEqual(result?.hasNewerActivity, true)
    }

    func testOnlyPostCutoffActivityMeansNothingLost() {
        XCTAssertNil(ClaudeSessionRecovery.newestInWindow(
            [transcript("this-morning", secondsBeforeCutoff: -3600)],
            cutoff: cutoff, window: 12 * 3600))
    }

    // MARK: extractCwd — first "cwd" value in the transcript head

    func testExtractsCwdFromTranscriptLine() {
        let head = #"{"type":"user","cwd":"/Users/j/code/app","sessionId":"abc"}"#
        XCTAssertEqual(
            ClaudeSessionRecovery.extractCwd(fromTranscriptHead: head),
            "/Users/j/code/app")
    }

    func testExtractsCwdUnescapesJsonEscapes() {
        let head = #"{"cwd":"\/Users\/j\/it\"s here"}"#
        XCTAssertEqual(
            ClaudeSessionRecovery.extractCwd(fromTranscriptHead: head),
            #"/Users/j/it"s here"#)
    }

    func testExtractCwdNilWhenAbsentOrUnterminated() {
        XCTAssertNil(ClaudeSessionRecovery.extractCwd(fromTranscriptHead: "{}"))
        XCTAssertNil(ClaudeSessionRecovery.extractCwd(fromTranscriptHead: #"{"cwd":"/trunc"#))
    }

    // MARK: suggestedSessionName

    func testSuggestedNameIsDirectoryBasename() {
        XCTAssertEqual(
            ClaudeSessionRecovery.suggestedSessionName(
                forDirectory: "/Users/j/code/my-site", home: "/Users/j"),
            "my-site")
    }

    func testSuggestedNameForDotClaudeHome() {
        XCTAssertEqual(
            ClaudeSessionRecovery.suggestedSessionName(
                forDirectory: "/Users/j/.claude", home: "/Users/j"),
            "_claude")
    }

    func testSuggestedNameForRepoWorktree() {
        XCTAssertEqual(
            ClaudeSessionRecovery.suggestedSessionName(
                forDirectory: "/Users/j/code/mux-maestro/.claude/worktrees/feat-x",
                home: "/Users/j"),
            "mux-maestro-feat-x")
    }

    func testSuggestedNamePrefixesParentForGenericBasename() {
        XCTAssertEqual(
            ClaudeSessionRecovery.suggestedSessionName(
                forDirectory: "/Users/j/.claude/skills/rebar-audit/data", home: "/Users/j"),
            "rebar-audit-data")
    }

    // MARK: findLostSessions — against a fixture projects dir on disk

    func testFindLostSessionsScansFixture() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "recovery-test-\(UUID().uuidString)")
        let cwdDir = root.appendingPathComponent("worktree")
        let projects = root.appendingPathComponent("projects")
        let project = projects.appendingPathComponent("-Users-j-worktree")
        try fm.createDirectory(at: cwdDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func writeTranscript(_ id: String, cwd: String, mtime: Date) throws {
            let file = project.appendingPathComponent("\(id).jsonl")
            try #"{"type":"user","cwd":"\#(cwd)"}"#.write(
                to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        let lostId = "11111111-2222-3333-4444-555555555555"
        let oldId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let goneId = "99999999-8888-7777-6666-555555555555"
        // Winner: newest pre-cutoff transcript, cwd exists.
        try writeTranscript(lostId, cwd: cwdDir.path, mtime: cutoff.addingTimeInterval(-60))
        // Older sibling in the same project: superseded, not returned.
        try writeTranscript(oldId, cwd: cwdDir.path, mtime: cutoff.addingTimeInterval(-3600))
        // Second project whose cwd no longer exists: dropped.
        let goneProject = projects.appendingPathComponent("-Users-j-gone")
        try fm.createDirectory(at: goneProject, withIntermediateDirectories: true)
        let goneFile = goneProject.appendingPathComponent("\(goneId).jsonl")
        try #"{"cwd":"/nonexistent/path"}"#.write(
            to: goneFile, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(-60)], ofItemAtPath: goneFile.path)
        // Non-session file in the project dir: ignored.
        try "{}".write(
            to: project.appendingPathComponent("sessions-index.json"),
            atomically: true, encoding: .utf8)

        let found = ClaudeSessionRecovery.findLostSessions(
            projectsDir: projects, cutoff: cutoff, window: 12 * 3600)

        XCTAssertEqual(found.map(\.id), [lostId])
        XCTAssertEqual(found.first?.cwd, cwdDir.path)
        XCTAssertEqual(found.first?.hasNewerActivity, false)
    }

    // MARK: TmuxCommands.sendKeysText — staged typing, no Enter

    func testSendKeysTextHasNoEnter() {
        XCTAssertEqual(
            TmuxCommands.sendKeysText(session: "web", text: "claude --resume abc"),
            ["send-keys", "-t", "web", "claude --resume abc"])
    }

    // MARK: TmuxService.recoverSession — exact command sequences

    private func makeService(_ runner: RecordingRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: "/usr/bin/tmux")
    }

    func testRecoverSessionAutostartSendsEnter() {
        let runner = RecordingRunner()
        let service = makeService(runner)

        let created = service.recoverSession(
            name: "my-site", dir: "/Users/j/code/my-site",
            claudeSessionId: "abc-123", autostart: true)

        XCTAssertEqual(created, "my-site")
        XCTAssertEqual(runner.argSequences, [
            ["list-sessions", "-F", "#{session_name}"],
            ["new-session", "-d", "-s", "my-site", "-c", "/Users/j/code/my-site"],
            ["send-keys", "-t", "my-site", "claude --resume abc-123", "Enter"],
        ])
    }

    func testRecoverSessionStagedTypesWithoutEnter() {
        let runner = RecordingRunner()
        let service = makeService(runner)

        let created = service.recoverSession(
            name: "sidekick", dir: "/Users/j/code/sidekick",
            claudeSessionId: "def-456", autostart: false)

        XCTAssertEqual(created, "sidekick")
        XCTAssertEqual(runner.argSequences.last,
            ["send-keys", "-t", "sidekick", "claude --resume def-456"])
    }

    func testRecoverSessionDedupesExistingName() {
        let runner = RecordingRunner()
        // A session with the desired name already exists (e.g. the user already
        // started fresh work there) — recovery must land beside it, not fail.
        runner.responses["list-sessions -F #{session_name}"] = "sidekick"
        let service = makeService(runner)

        let created = service.recoverSession(
            name: "sidekick", dir: "/Users/j/code/sidekick",
            claudeSessionId: "def-456", autostart: true)

        XCTAssertEqual(created, "sidekick-2")
    }
}
