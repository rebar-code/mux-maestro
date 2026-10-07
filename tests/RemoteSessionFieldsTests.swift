import XCTest

/// What a remote host says about its agents' transcripts: the bundled
/// `sessions.py list --full`, run here for real against a scratch HOME, and
/// the app's reading of its output.
final class RemoteSessionFieldsTests: XCTestCase {
    private let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("app/MuxMaestro/Resources/tools/sessions.py").path
    private let python = "/usr/bin/python3"

    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }

    private let claudeId = "0f8fad5b-d9cb-469f-a165-70867728950e"
    private let codexId = "01a04e9e-1111-4222-8333-444455556666"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The script, run for real

    /// `sessions.py <args>` with the scratch HOME and no tmux server to ask.
    private func list(_ args: [String]) throws -> [[String: Any]] {
        try python([script] + args)
    }

    private func python(_ arguments: [String]) throws -> [[String: Any]] {
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("no python3") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["TMUX"] = nil
        environment["TMUX_TMPDIR"] = root.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private var claudeTranscript: URL {
        home.appendingPathComponent(".claude/projects/-Users-me-acme-app/\(claudeId).jsonl")
    }

    /// A live Claude session (this test's own process) in `/Users/me/acme-app`.
    private func claudeSession(_ lines: [String]) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try write(
            [#"{"pid":\#(pid),"sessionId":"\#(claudeId)","cwd":"/Users/me/acme-app","status":"busy"}"#],
            to: home.appendingPathComponent(".claude/sessions/1.json"))
        try write(lines, to: claudeTranscript)
    }

    private func prompt(_ row: [String: Any]?) -> LastPrompt? {
        guard let prompt = row?["lastPrompt"] as? [String: Any], let text = prompt["text"] as? String,
              let at = prompt["at"] as? Int else { return nil }
        return LastPrompt(text: text, at: at)
    }

    func testTheScriptReportsAClaudeTranscriptsLastPromptAndLastWriteAsTheAppReadsThem() throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-10-02T09:00:00.000Z","message":{"role":"user","content":"  deploy the api\nthen tell me"}}"#,
            // None of these is a prompt: a tool result, a slash command, a meta
            // entry, a compact summary, an interrupt, a reminder block.
            #"{"type":"user","timestamp":"2026-10-02T09:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"user","timestamp":"2026-10-02T09:00:03.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","isMeta":true,"timestamp":"2026-10-02T09:00:04.000Z","message":{"role":"user","content":"Caveat: ignore"}}"#,
            #"{"type":"user","isCompactSummary":true,"timestamp":"2026-10-02T09:00:05.000Z","message":{"role":"user","content":"This session is being continued"}}"#,
            #"{"type":"user","timestamp":"2026-10-02T09:00:06.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            #"{"type":"user","timestamp":"2026-10-02T09:00:07.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-02T11:00:08.500+02:00","message":{"role":"assistant","content":[]}}"#,
            // Bookkeeping with no time: not a write of the thread.
            #"{"type":"last-prompt","lastPrompt":"deploy the api"}"#,
        ]
        try claudeSession(lines)
        let tail = try Data(contentsOf: claudeTranscript)

        let rows = try list(["list", "--full"])
        let row = rows.first { $0["sessionId"] as? String == claudeId }
        XCTAssertEqual(prompt(row), LastPrompt(text: "deploy the api", at: 1_790_931_600))
        XCTAssertEqual(row?["lastWriteAt"] as? Int, 1_790_931_608)
        // The same as the reader of this Mac's transcripts says.
        XCTAssertEqual(prompt(row), LastPrompt.parse(claudeTail: tail))
        XCTAssertEqual(row?["lastWriteAt"] as? Int, TranscriptTailReader.newestTimestamp(in: tail))
        // The row is still the Claude row it was.
        XCTAssertEqual(row?["status"] as? String, "busy")
        XCTAssertEqual(row?["cwd"] as? String, "/Users/me/acme-app")
        // The copy says it knows `--full`, in a row no reader of Claude rows takes.
        let meta = rows.first { $0["agent"] as? String == "meta" }
        XCTAssertEqual(meta?["schema"] as? Int, 2)
        XCTAssertNil(meta?["sessionId"])
        XCTAssertNil(meta?["pane"])
        XCTAssertNil(meta?["tmuxSession"])

        // What it found is kept, private to the user.
        let cache = home.appendingPathComponent(".muxmaestro/cache/tails.json").path
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: cache))[.posixPermissions] as? Int, 0o600)

        // More is written: a shell command, then a message typed while the agent was busy.
        let more = [
            #"{"type":"user","timestamp":"2026-10-02T09:10:00.000Z","message":{"role":"user","content":"<bash-input>git status</bash-input>"}}"#,
        ]
        let handle = try FileHandle(forWritingTo: claudeTranscript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((more[0] + "\n").utf8))
        try handle.close()
        let later = try list(["list", "--full"]).first { $0["sessionId"] as? String == claudeId }
        XCTAssertEqual(prompt(later), LastPrompt(text: "! git status", at: 1_790_932_200))
        XCTAssertEqual(later?["lastWriteAt"] as? Int, 1_790_932_200)
    }

    func testAQueuedMessageIsAPromptAndALongOneIsCut() throws {
        let long = String(repeating: "a", count: 500)
        try claudeSession([
            #"{"type":"attachment","timestamp":"2026-10-02T09:00:00.000Z","attachment":{"type":"queued_command","commandMode":"prompt","origin":{"kind":"human"},"prompt":"\#(long)"},"userType":"external"}"#,
            #"{"type":"attachment","timestamp":"2026-10-02T09:00:01.000Z","attachment":{"type":"queued_command","commandMode":"prompt","origin":{"kind":"task"},"prompt":"a task said this"},"userType":"external"}"#,
        ])
        let row = try list(["list", "--full"]).first { $0["sessionId"] as? String == claudeId }
        XCTAssertEqual(prompt(row)?.text.count, LastPrompt.maxLength)
        XCTAssertEqual(prompt(row), LastPrompt.parse(claudeTail: try Data(contentsOf: claudeTranscript)))
    }

    func testPlainListPrintsWhatItAlwaysDid() throws {
        try claudeSession([
            #"{"type":"user","timestamp":"2026-10-02T09:00:00.000Z","message":{"role":"user","content":"deploy the api"}}"#,
        ])
        let rows = try list(["list"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            Set(rows[0].keys),
            ["sessionId", "pid", "cwd", "gitBranch", "status", "kind", "summary", "firstPrompt",
             "messageCount", "tmuxSession", "pane", "updatedAt"])
        // Nothing was written to the host for it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".muxmaestro").path))
    }

    /// A process named `codex` that holds `file` open, as a codex TUI holds its
    /// rollout. `tail` under that name: a copy of a system tool runs only signed again.
    private func fakeCodex(holding file: URL) throws -> Process {
        let binary = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/tail"), to: binary)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", binary.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        guard (try? sign.run()) != nil else { throw XCTSkip("no codesign") }
        sign.waitUntilExit()
        let codex = Process()
        codex.executableURL = binary
        codex.arguments = ["-f", file.path]
        codex.standardOutput = FileHandle.nullDevice
        codex.standardError = FileHandle.nullDevice
        guard (try? codex.run()) != nil else { throw XCTSkip("a copied tool does not run here") }
        Thread.sleep(forTimeInterval: 0.5)
        guard codex.isRunning else { throw XCTSkip("a copied tool does not run here") }
        return codex
    }

    func testOnLinuxTheScriptReadsTheOpenFilesOfCodexProcessesFromProc() throws {
        // A Linux host has no `lsof` to rely on: /proc names each process's
        // open files. Here a folder stands in for /proc.
        let rollout = home.appendingPathComponent(
            ".codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-\(codexId).jsonl")
        try write([
            #"{"timestamp":"2026-10-02T10:00:00.000Z","type":"session_meta","payload": {"session_id": "\#(codexId)"}}"#,
            #"{"timestamp":"2026-10-02T10:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"fix the build"}}"#,
        ], to: rollout)
        let fm = FileManager.default
        let proc = root.appendingPathComponent("proc")
        func process(_ pid: String, command: String, files: [String]) throws {
            let fd = proc.appendingPathComponent("\(pid)/fd")
            try fm.createDirectory(at: fd, withIntermediateDirectories: true)
            try Data((command + "\n").utf8).write(to: proc.appendingPathComponent("\(pid)/comm"))
            for (n, file) in files.enumerated() {
                try fm.createSymbolicLink(atPath: fd.appendingPathComponent("\(n)").path, withDestinationPath: file)
            }
        }
        // The kernel names an open file by its real path, past every link.
        let held = try XCTUnwrap(rollout.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        try process("self", command: "python3", files: [])
        try process("4242", command: "codex", files: ["/dev/null", held, held + " (deleted)", "/etc/passwd"])
        // Not codex, whatever it holds; and a codex with no rollout.
        try process("77", command: "bash", files: [held])
        try process("4300", command: "codex", files: ["/dev/null"])
        try Data().write(to: proc.appendingPathComponent("meminfo"))

        let program = [
            "import json, sys", "sys.path.insert(0, sys.argv[1])", "import sessions",
            "sessions.PROC_DIR = sys.argv[2]", "print(json.dumps(sessions.enrich(full=True)))",
        ].joined(separator: "\n")
        let rows = try python(
            ["-c", program, (script as NSString).deletingLastPathComponent, proc.path])
            .filter { $0["agent"] as? String == "codex" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["codexSessionId"] as? String, codexId)
        XCTAssertEqual(rows.first?["codexPid"] as? Int, 4242)
        XCTAssertEqual(rows.first?["rolloutPath"] as? String, rollout.path)
        XCTAssertEqual(prompt(rows.first), LastPrompt(text: "fix the build", at: 1_790_935_205))
        XCTAssertEqual(prompt(rows.first), LastPrompt.parse(codexTail: try Data(contentsOf: rollout)))
    }

    func testTheScriptFindsALiveCodexProcessItsRolloutAndItsLastPrompt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { throw XCTSkip("no lsof") }
        let rollout = home.appendingPathComponent(
            ".codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-\(codexId).jsonl")
        try write([
            #"{"timestamp":"2026-10-02T10:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(codexId)","id":"\#(codexId)"}}"#,
            #"{"timestamp":"2026-10-02T10:00:05.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the build\nplease"}]}}"#,
            #"{"timestamp":"2026-10-02T10:00:06.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"timestamp":"2026-10-02T10:00:09.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#,
        ], to: rollout)
        // A file of the same process that is no rollout of this user.
        let other = root.appendingPathComponent("elsewhere/.codex/sessions/rollout-x-\(codexId).jsonl")
        try write(["{}"], to: other)
        let codex = try fakeCodex(holding: rollout)
        defer { codex.terminate() }

        let rows = try list(["list", "--full"]).filter { $0["agent"] as? String == "codex" }
        let row = try XCTUnwrap(rows.first { $0["codexSessionId"] as? String == codexId })
        // The path is under the HOME the script was given, not the linked
        // folder the system names open files by.
        XCTAssertEqual(row["rolloutPath"] as? String, rollout.path)
        XCTAssertEqual(row["codexPid"] as? Int, Int(codex.processIdentifier))
        XCTAssertTrue(row["codexPane"] is NSNull)
        XCTAssertEqual(prompt(row), LastPrompt(text: "fix the build", at: 1_790_935_205))
        XCTAssertEqual(prompt(row), LastPrompt.parse(codexTail: try Data(contentsOf: rollout)))
        XCTAssertEqual(row["lastWriteAt"] as? Int, 1_790_935_209)
        // Nothing a reader of Claude rows takes.
        for key in ["sessionId", "pane", "tmuxSession", "status", "updatedAt"] { XCTAssertNil(row[key], key) }

        // Plain `list` does not look for Codex at all.
        XCTAssertTrue(try list(["list"]).isEmpty)
    }

    // MARK: The app's reading of the output

    /// What a host with a Claude pane and a Codex pane answers.
    private var canned: String {
        """
        [
          {"sessionId": "\(claudeId)", "pid": 4100, "cwd": "/home/me/acme-app", "status": "busy",
           "tmuxSession": "infra", "pane": "%3", "updatedAt": 1790931600000,
           "lastPrompt": {"text": "deploy the api", "at": 1790931600}, "lastWriteAt": 1790931608},
          {"agent": "codex", "codexSessionId": "\(codexId)", "codexPid": 4200, "codexPane": "%4",
           "rolloutPath": "/home/me/.codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-\(codexId).jsonl",
           "lastPrompt": {"text": "fix the build", "at": 1790935205}, "lastWriteAt": 1790935209},
          {"agent": "meta", "schema": 2}
        ]
        """
    }

    private var rolloutPath: String {
        "/home/me/.codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-\(codexId).jsonl"
    }

    func testTheOutputParsesToTheFieldsOfARemoteHost() {
        let fields = TmuxModel.parseRemoteFields(fromSessionsJSON: Data(canned.utf8))
        XCTAssertEqual(fields, RemoteSessionFields(
            paneCodexSessionIds: ["%4": codexId],
            codexRollouts: [codexId: rolloutPath],
            lastPrompts: [
                claudeId: LastPrompt(text: "deploy the api", at: 1_790_931_600),
                codexId: LastPrompt(text: "fix the build", at: 1_790_935_205),
            ],
            lastWrites: [claudeId: 1_790_931_608, codexId: 1_790_935_209],
            schema: 2))
    }

    func testEveryReaderOfClaudeRowsSkipsTheCodexAndSchemaRows() {
        let data = Data(canned.utf8)
        XCTAssertEqual(TmuxModel.parseStatuses(fromSessionsJSON: data), ["infra": .busy])
        XCTAssertEqual(TmuxModel.parsePaneStatuses(fromSessionsJSON: data), ["%3": .busy])
        XCTAssertEqual(TmuxModel.parsePaneSessionIds(fromSessionsJSON: data), ["%3": claudeId])
        XCTAssertEqual(TmuxModel.parseActivity(fromSessionsJSON: data), ["infra": 1_790_931_600])
        XCTAssertEqual(TmuxModel.parseSessionCwds(fromSessionsJSON: data), [claudeId: "/home/me/acme-app"])
        XCTAssertEqual(TmuxModel.parsePaneStatusSince(fromSessionsJSON: data), ["%3": 1_790_931_600])
    }

    func testOutputOfAnOlderScriptStillParses() {
        // No `--full` fields at all: the rows are what they always were.
        let old = Data(#"""
        [{"sessionId": "c1", "pid": 4100, "cwd": "/home/me/acme-app", "gitBranch": null, "status": "waiting",
          "kind": null, "summary": null, "firstPrompt": "hi", "messageCount": 2, "tmuxSession": "infra",
          "pane": "%3", "updatedAt": 1790931600000}]
        """#.utf8)
        XCTAssertEqual(TmuxModel.parseRemoteFields(fromSessionsJSON: old), RemoteSessionFields())
        XCTAssertEqual(TmuxModel.parsePaneSessionIds(fromSessionsJSON: old), ["%3": "c1"])
        XCTAssertEqual(TmuxModel.parsePaneStatuses(fromSessionsJSON: old), ["%3": .waiting])
        XCTAssertEqual(TmuxModel.parseRemoteFields(fromSessionsJSON: Data("not json".utf8)), RemoteSessionFields())
    }

    func testWhatAHostSaysIsDataAndIsCheckedAndCut() {
        let long = String(repeating: "a", count: 500)
        let hostile = Data(#"""
        [
          {"agent": "codex", "codexSessionId": "../../etc", "codexPane": "%1", "rolloutPath": "/etc/passwd",
           "lastPrompt": {"text": "x", "at": 5}},
          {"agent": "codex", "codexSessionId": "a b", "codexPane": "%2"},
          {"agent": "codex", "codexSessionId": 7, "codexPane": "%2"},
          {"agent": "codex", "codexSessionId": "older", "codexPid": 10, "codexPane": "%5"},
          {"agent": "codex", "codexSessionId": "newer", "codexPid": 20, "codexPane": "%5",
           "lastPrompt": {"text": "\n\n  \#(long)\nsecond line", "at": "soon"}, "lastWriteAt": "now"},
          {"agent": "codex", "codexSessionId": "nopane", "codexPane": null, "rolloutPath": 3},
          {"agent": "other", "sessionId": "zz", "lastPrompt": {"text": "x", "at": 1}},
          {"sessionId": "c1", "lastPrompt": {"text": "<system-reminder>not a prompt</system-reminder>", "at": 1}},
          {"sessionId": "c2", "lastPrompt": "text", "lastWriteAt": -4},
          {"sessionId": "c3", "lastPrompt": {"text": 9}}
        ]
        """#.utf8)
        let fields = TmuxModel.parseRemoteFields(fromSessionsJSON: hostile)
        XCTAssertEqual(fields.paneCodexSessionIds, ["%5": "newer"])
        XCTAssertEqual(fields.codexRollouts, [:])
        XCTAssertEqual(fields.lastPrompts, ["newer": LastPrompt(text: String(long.prefix(200)), at: 0)])
        XCTAssertEqual(fields.lastWrites, [:])
        XCTAssertEqual(fields.schema, 0)
    }

    // MARK: A remote host's tree

    private let devbox = Host(name: "devbox", sshAlias: "devbox")

    /// A remote host: its tmux server, its `sessions.py`, and its files.
    private final class FakeHost: CommandRunner {
        var sessions: String?
        var found: String? = ""
        private(set) var calls: [[String]] = []
        func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
            calls.append(args)
            let US = TmuxModel.fieldSep
            let command = args.joined(separator: " ")
            if command.contains("sessions.py") { return sessions }
            if command.contains("list-sessions") { return "infra\(US)0\n" }
            if command.contains("list-windows") {
                return "infra\(US)0\(US)api\(US)1\ninfra\(US)1\(US)worker\(US)0\n"
            }
            if command.contains("list-panes") {
                return "infra\(US)0\(US)%3\(US)0\(US)claude\(US)t\(US)1\n"
                    + "infra\(US)1\(US)%4\(US)0\(US)codex\(US)t\(US)1\n"
                    + "infra\(US)1\(US)%5\(US)1\(US)zsh\(US)t\(US)0\n"
            }
            if args.contains("'pwd'") { return "/home/me\n" }
            if args.contains("'find'") { return found }
            return nil
        }
    }

    private func service(_ host: FakeHost, transcripts: (([String: String], [String: String]) -> TranscriptTails)? = nil)
        -> TmuxService {
        TmuxService(
            host: devbox, transport: SshTmuxTransport(host: "devbox"), runner: host,
            statusProvider: RemoteSessionsPyStatusProvider(host: "devbox", runner: host, script: nil),
            transcripts: transcripts)
    }

    func testARemotePaneHasItsCodexIdItsLastPromptAndItsLastActivityAsALocalOneHas() throws {
        let host = FakeHost()
        host.sessions = canned
        let tree = try XCTUnwrap(service(host).loadTree())
        let panes = tree.flatMap(\.windows).flatMap(\.panes)
        let claude = try XCTUnwrap(panes.first { $0.id == "%3" })
        XCTAssertEqual(claude.claudeSessionId, claudeId)
        XCTAssertNil(claude.codexSessionId)
        XCTAssertEqual(claude.lastPrompt, LastPrompt(text: "deploy the api", at: 1_790_931_600))
        XCTAssertEqual(claude.lastActivityAt, 1_790_931_608)
        XCTAssertEqual(claude.attention, .busy)
        let codex = try XCTUnwrap(panes.first { $0.id == "%4" })
        XCTAssertNil(codex.claudeSessionId)
        XCTAssertEqual(codex.codexSessionId, codexId)
        XCTAssertEqual(codex.lastPrompt, LastPrompt(text: "fix the build", at: 1_790_935_205))
        XCTAssertEqual(codex.lastActivityAt, 1_790_935_209)
        // The scan has no status for a Codex pane and no hook reaches this
        // Mac from there: it is never idle, so never 🥱 or 💤.
        XCTAssertEqual(codex.attention, .unknown)
        XCTAssertEqual(codex.idleStage, .awake)
        let shell = try XCTUnwrap(panes.first { $0.id == "%5" })
        XCTAssertNil(shell.codexSessionId)
        XCTAssertNil(shell.lastPrompt)

        // The phone's rows carry them.
        let threads = MobileSnapshot.build([MobileHostInput(
            host: devbox, colorHex: "#f5a623", reachability: .reachable, stats: nil, sessions: tree)]).threads
        let row = try XCTUnwrap(threads.first { $0.pane == "%4" })
        XCTAssertEqual(row.codexSessionId, codexId)
        XCTAssertEqual(row.lastPrompt?.text, "fix the build")
        XCTAssertEqual(row.lastActivityAt, 1_790_935_209)
        XCTAssertTrue(row.hasChat)
        XCTAssertEqual(threads.first { $0.pane == "%3" }?.lastActivityAt, 1_790_931_608)
    }

    func testARemoteTreeFromAnOlderScriptIsWhatItWas() throws {
        let host = FakeHost()
        host.sessions = #"[{"sessionId":"c1","status":"waiting","tmuxSession":"infra","pane":"%3","updatedAt":5000}]"#
        let panes = try XCTUnwrap(service(host).loadTree()).flatMap(\.windows).flatMap(\.panes)
        XCTAssertEqual(panes.first { $0.id == "%3" }?.claudeSessionId, "c1")
        XCTAssertEqual(panes.first { $0.id == "%3" }?.attention, .waiting)
        XCTAssertTrue(panes.allSatisfy { $0.codexSessionId == nil && $0.lastPrompt == nil && $0.lastActivityAt == nil })
    }

    func testALocalPaneStillReadsThisMacsDiskAndThatWinsOverAStatusField() {
        // The local provider fills none of the remote fields. Were both
        // there, what this Mac read from its own transcript stands.
        var pane = TmuxPane(id: "%1", index: 0, command: "codex", title: "", active: true)
        pane.pid = 100
        let sessions = [TmuxSession(name: "acme-app", attached: true, windows: [
            TmuxWindow(index: 0, name: "w", active: true, panes: [pane])])]
        let tree = TmuxModel.sorted(
            sessions: sessions, statuses: [:], codexByPid: [200: "here"], ppids: [200: 100],
            paneCodexSessionIds: ["%1": "there"], lastPrompts: ["here": LastPrompt(text: "local", at: 1)])
        XCTAssertEqual(tree[0].windows[0].panes[0].codexSessionId, "here")
        XCTAssertEqual(tree[0].windows[0].panes[0].lastPrompt?.text, "local")
        XCTAssertEqual(StatusSnapshot().paneCodexSessionIds, [:])
    }

    // MARK: Where a remote Codex rollout is

    func testTheRolloutPathTheHostGaveIsTakenAfterACheckElseFound() throws {
        let host = FakeHost()
        host.sessions = canned
        let remote = service(host)
        // The path of the scan: under ~/.codex/sessions, named for the id. No `find`.
        XCTAssertEqual(remote.codexRolloutPath(sessionId: codexId), rolloutPath)
        XCTAssertFalse(host.calls.contains { $0.contains("'find'") })

        // A path outside ~/.codex/sessions is refused: `find` is asked, by name.
        host.sessions = canned.replacingOccurrences(of: rolloutPath, with: "/etc/passwd")
        host.found = rolloutPath + "\n"
        XCTAssertEqual(remote.codexRolloutPath(sessionId: codexId), rolloutPath)
        let find = try XCTUnwrap(host.calls.last { $0.contains("'find'") })
        XCTAssertEqual(Array(find.suffix(8)), [
            "'find'", "'/home/me/.codex/sessions'", "'-type'", "'f'", "'-name'",
            "'rollout-*-\(codexId).jsonl'", "'-print'", "'-quit'",
        ])
        // So is one that leaves the folder by `..`, and what `find` answers is checked too.
        host.sessions = canned.replacingOccurrences(
            of: rolloutPath, with: "/home/me/.codex/sessions/../../.ssh/rollout-x-\(codexId).jsonl")
        host.found = "/home/me/.ssh/id_ed25519\n"
        XCTAssertNil(remote.codexRolloutPath(sessionId: codexId))
        host.found = ""
        XCTAssertNil(remote.codexRolloutPath(sessionId: codexId))

        // An id that is not one never reaches the host.
        let asked = host.calls.count
        for id in ["../../etc/passwd", "a/b", "..", "*", "x; rm -rf ~", ""] {
            XCTAssertNil(remote.codexRolloutPath(sessionId: id), id)
            XCTAssertNil(remote.transcriptCopy(
                sessionId: id, codex: true, in: RemoteTranscriptMirror(root: root)), id)
        }
        XCTAssertEqual(host.calls.count, asked)
    }

    /// A host that also answers `wc` and `tail` for one file.
    private final class RolloutHost: CommandRunner {
        let path: String
        var file = Data()
        private(set) var calls: [[String]] = []
        init(path: String) { self.path = path }
        func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
            runData(path, args, stdin: stdin).flatMap { String(data: $0, encoding: .utf8) }
        }
        func runData(_ path: String, _ args: [String], stdin: Data?) -> Data? {
            calls.append(args)
            let quoted = Ssh.shellQuote(self.path)
            if args.contains("'pwd'") { return Data("/home/me\n".utf8) }
            if args.contains("'find'") { return Data((self.path + "\n").utf8) }
            if args.contains("'wc'") { return args.last == quoted ? Data(" \(file.count)\n".utf8) : nil }
            guard let tail = args.firstIndex(of: "'tail'"), args.last == quoted,
                  let from = Int(args[tail + 2].trimmingCharacters(in: CharacterSet(charactersIn: "'+")))
            else { return nil }
            return Data(file.dropFirst(from - 1))
        }
    }

    func testARemoteCodexRolloutIsCopiedHereAndAClaudeSessionWinsOverIt() throws {
        let host = RolloutHost(path: rolloutPath)
        host.file = Data("{\"n\":1}\n".utf8)
        let remote = TmuxService(
            host: devbox, transport: SshTmuxTransport(host: "devbox"), runner: host,
            statusProvider: StaticProvider())
        let mirror = RemoteTranscriptMirror(root: root.appendingPathComponent("copies"))

        let copy = try XCTUnwrap(remote.transcriptCopy(claudeSessionId: nil, codexSessionId: codexId, in: mirror))
        XCTAssertTrue(copy.codex)
        XCTAssertEqual(copy.path, root.appendingPathComponent("copies/devbox/codex.\(codexId).jsonl").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy.path)), host.file)
        // The path went to the host as one quoted word, after `--`.
        XCTAssertEqual(host.calls.last?.suffix(5), ["'tail'", "'-c'", "'+1'", "'--'", Ssh.shellQuote(rolloutPath)])

        XCTAssertNil(remote.transcriptCopy(claudeSessionId: nil, codexSessionId: nil, in: mirror))
        // A pane with both ids reads as Claude, as on this Mac: the Codex
        // rollout is not asked for.
        let claude = RolloutHost(path: "/home/me/.claude/projects/-home-me-acme-app/\(claudeId).jsonl")
        claude.file = Data("{\"c\":1}\n".utf8)
        let both = TmuxService(
            host: devbox, transport: SshTmuxTransport(host: "devbox"), runner: claude,
            statusProvider: StaticProvider())
        let first = try XCTUnwrap(both.transcriptCopy(claudeSessionId: claudeId, codexSessionId: codexId, in: mirror))
        XCTAssertFalse(first.codex)
        XCTAssertEqual(first.path, root.appendingPathComponent("copies/devbox/\(claudeId).jsonl").path)
    }
}

private struct StaticProvider: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}
