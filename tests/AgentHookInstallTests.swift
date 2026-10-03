import XCTest

// AgentHookInstall.swift is Foundation-only and compiled directly into this test
// target. Only the pure `apply`/`isInstalled` core is exercised here — the
// filesystem half writes to the user's real ~/.claude and ~/.codex.

final class AgentHookInstallTests: XCTestCase {
    private let command = "'/Users/j/Library/Application Support/MuxMaestro/recovery/"
        + "record-agent-session.sh' claude # muxmaestro-recovery"

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func sessionStart(_ data: Data?) -> [[String: Any]] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (root["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        else { return [] }
        return entries
    }

    private func commands(_ data: Data?) -> [String] {
        sessionStart(data).flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// A config with two unrelated SessionStart hooks, matching the real files.
    private var populated: Data {
        json([
            "hooks": [
                "SessionStart": [
                    ["matcher": "", "hooks": [["type": "command", "command": "bash session-start.sh"]]],
                    ["hooks": [["type": "command", "command": "moshi-hook claude-hook # moshi-hooks"]]],
                ],
                "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "guard"]]]],
            ],
            "model": "opus",
        ])
    }

    // MARK: install

    func testInstallAppendsOneEntryAndPreservesTheRest() {
        let out = try! AgentHookInstall.apply(data: populated, install: true, command: command)
        XCTAssertEqual(commands(out), [
            "bash session-start.sh",
            "moshi-hook claude-hook # moshi-hooks",
            command,
        ])
    }

    func testInstallAppendsNeverPrepends() {
        // Codex keys each hook's trusted_hash by its INDEX in the array, so
        // inserting at the front would shift every existing hook onto the wrong
        // key and silently untrust the lot.
        let out = try! AgentHookInstall.apply(data: populated, install: true, command: command)
        XCTAssertEqual(commands(out).last, command)
    }

    func testInstallPreservesUnrelatedKeys() {
        let out = try! AgentHookInstall.apply(data: populated, install: true, command: command)
        let root = try! JSONSerialization.jsonObject(with: out!) as? [String: Any]
        XCTAssertEqual(root?["model"] as? String, "opus")
        XCTAssertNotNil((root?["hooks"] as? [String: Any])?["PreToolUse"])
    }

    func testInstallCreatesTheStructureInAnEmptyConfig() {
        let out = try! AgentHookInstall.apply(data: Data(), install: true, command: command)
        XCTAssertEqual(commands(out), [command])
    }

    func testInstallIsIdempotent() {
        let once = try! AgentHookInstall.apply(data: populated, install: true, command: command)
        // Second install: no change needed, so no rewrite.
        XCTAssertNil(try! AgentHookInstall.apply(data: once, install: true, command: command))
    }

    func testInstallReplacesAnEntryWithAStalePath() {
        // The script path changed (a different home, an older install). The old
        // marked entry is replaced, not duplicated.
        let stale = try! AgentHookInstall.apply(
            data: populated, install: true, command: "'/old/path.sh' claude # muxmaestro-recovery")
        let fresh = try! AgentHookInstall.apply(data: stale, install: true, command: command)
        XCTAssertEqual(commands(fresh), [
            "bash session-start.sh",
            "moshi-hook claude-hook # moshi-hooks",
            command,
        ])
    }

    // MARK: uninstall

    func testUninstallRemovesOnlyOurEntry() {
        let installed = try! AgentHookInstall.apply(
            data: populated, install: true, command: command)
        let removed = try! AgentHookInstall.apply(
            data: installed, install: false, command: command)
        XCTAssertEqual(commands(removed), [
            "bash session-start.sh",
            "moshi-hook claude-hook # moshi-hooks",
        ])
    }

    func testUninstallIsIdempotent() {
        XCTAssertNil(try! AgentHookInstall.apply(data: populated, install: false, command: command))
    }

    func testUninstallOfAMissingConfigDoesNothing() {
        XCTAssertNil(try! AgentHookInstall.apply(data: nil, install: false, command: command))
    }

    func testUninstallDropsAnEmptiedSessionStartKey() {
        let only = json(["hooks": ["SessionStart": [
            ["matcher": "", "hooks": [["type": "command", "command": command]]],
        ]]])
        let out = try! AgentHookInstall.apply(data: only, install: false, command: command)
        let root = try! JSONSerialization.jsonObject(with: out!) as? [String: Any]
        XCTAssertNil(root?["hooks"])
    }

    func testInstallUninstallCyclesBackToTheOriginal() {
        var data = populated
        for _ in 0..<3 {
            data = try! AgentHookInstall.apply(data: data, install: true, command: command)!
            data = try! AgentHookInstall.apply(data: data, install: false, command: command)!
        }
        XCTAssertEqual(commands(data), [
            "bash session-start.sh",
            "moshi-hook claude-hook # moshi-hooks",
        ])
    }

    // MARK: detection + command shape

    func testIsInstalledTracksTheMarker() {
        XCTAssertFalse(AgentHookInstall.isInstalled(data: populated))
        let installed = try! AgentHookInstall.apply(
            data: populated, install: true, command: command)
        XCTAssertTrue(AgentHookInstall.isInstalled(data: installed))
        XCTAssertFalse(AgentHookInstall.isInstalled(data: nil))
    }

    func testCommandQuotesThePathAndNamesTheAgent() {
        let path = "/Users/j/Library/Application Support/MuxMaestro/recovery/record-agent-session.sh"
        XCTAssertEqual(
            AgentHookInstall.command(scriptPath: path, target: .codex),
            "'\(path)' codex # muxmaestro-recovery")
        XCTAssertEqual(
            AgentHookInstall.command(scriptPath: path, target: .claude),
            "'\(path)' claude # muxmaestro-recovery")
    }

    func testRejectsAConfigThatIsNotAnObject() {
        let array = try! JSONSerialization.data(withJSONObject: [1, 2, 3])
        XCTAssertThrowsError(
            try AgentHookInstall.apply(data: array, install: true, command: command))
    }

    // MARK: events hook set

    private let muxPath = "/Users/j/Library/Application Support/MuxMaestro/manager/bin/mux"

    private func commands(_ data: Data?, event: String) -> [String] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]]
        else { return [] }
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testEventsInstallAppendsOneEntryPerClaudeEvent() throws {
        let cmd = AgentHookInstall.eventsCommand(muxPath: muxPath, target: .claude)
        let out = try AgentHookInstall.apply(
            data: populated, hook: .events, target: .claude, install: true, command: cmd)
        for event in AgentHookInstall.Hook.events.events(for: .claude) {
            XCTAssertEqual(commands(out, event: event).last, cmd, event)
        }
        XCTAssertEqual(commands(out, event: "PreToolUse"), ["guard", cmd])
        let root = try JSONSerialization.jsonObject(with: XCTUnwrap(out)) as? [String: Any]
        let stop = ((root?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.last
        XCTAssertEqual((stop?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 5)
    }

    func testEventsInstallForCodexCoversItsSixEvents() throws {
        let cmd = AgentHookInstall.eventsCommand(muxPath: muxPath, target: .codex)
        let out = try AgentHookInstall.apply(
            data: Data(), hook: .events, target: .codex, install: true, command: cmd)
        let root = try JSONSerialization.jsonObject(with: XCTUnwrap(out)) as? [String: Any]
        XCTAssertEqual(
            Set(((root?["hooks"] as? [String: Any]) ?? [:]).keys),
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"])
        XCTAssertTrue(AgentHookInstall.isInstalled(data: out, hook: .events, target: .codex))
        XCTAssertFalse(AgentHookInstall.isInstalled(data: out, hook: .events, target: .claude),
                       "Claude Code has events Codex doesn't")
    }

    func testRecoveryAndEventsAreIndependent() throws {
        let events = AgentHookInstall.eventsCommand(muxPath: muxPath, target: .claude)
        var data = try XCTUnwrap(AgentHookInstall.apply(data: populated, install: true, command: command))
        data = try XCTUnwrap(AgentHookInstall.apply(
            data: data, hook: .events, target: .claude, install: true, command: events))
        XCTAssertEqual(commands(data), [
            "bash session-start.sh", "moshi-hook claude-hook # moshi-hooks", command, events,
        ])
        XCTAssertTrue(AgentHookInstall.isInstalled(data: data))
        XCTAssertNil(try AgentHookInstall.apply(
            data: data, hook: .events, target: .claude, install: true, command: events))

        data = try XCTUnwrap(AgentHookInstall.apply(
            data: data, hook: .events, target: .claude, install: false, command: ""))
        XCTAssertEqual(commands(data), [
            "bash session-start.sh", "moshi-hook claude-hook # moshi-hooks", command,
        ])
        XCTAssertFalse(AgentHookInstall.isInstalled(data: data, hook: .events, target: .claude))
        XCTAssertTrue(AgentHookInstall.isInstalled(data: data))
    }

    func testEventsCommandCannotFailTheAgent() throws {
        XCTAssertEqual(
            AgentHookInstall.eventsCommand(muxPath: "/a b/mux", target: .codex),
            "'/a b/mux' event codex 2>/dev/null || true # muxmaestro-events")

        // A missing mux, and a mux older than `event` (usage exits 2, which would
        // block the agent), both come out as a silent exit 0.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldMux = dir.appendingPathComponent("mux")
        try "#!/bin/sh\necho 'usage: mux' >&2\nexit 2\n".write(to: oldMux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldMux.path)

        for path in [dir.appendingPathComponent("missing").path, oldMux.path] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", AgentHookInstall.eventsCommand(muxPath: path, target: .claude)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, path)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "", path)
        }
    }

    func testChangedEventsIsTheAlertsDiff() throws {
        let cmd = AgentHookInstall.eventsCommand(muxPath: muxPath, target: .codex)
        let codexEvents = Set(AgentHookInstall.Hook.events.events(for: .codex))
        XCTAssertEqual(Set(AgentHookInstall.changedEvents(
            data: populated, hook: .events, target: .codex, install: true, command: cmd)), codexEvents)
        let installed = try AgentHookInstall.apply(
            data: populated, hook: .events, target: .codex, install: true, command: cmd)
        XCTAssertEqual(AgentHookInstall.changedEvents(
            data: installed, hook: .events, target: .codex, install: true, command: cmd), [])
        XCTAssertEqual(Set(AgentHookInstall.changedEvents(
            data: installed, hook: .events, target: .codex, install: false, command: "")), codexEvents)
    }

    // MARK: layout

    /// The layout both agents write (`JSON.stringify(v, null, 2)`), keys in the
    /// file's own order — not sorted — with escapes and odd number spellings.
    private let agentStyle = """
    {
      "env": {
        "A": "1"
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "guard \\"x\\" — é \\\\ \\u001b",
                "timeout": 5
              }
            ]
          }
        ]
      },
      "cleanupPeriodDays": 3650,
      "ratio": 1.50,
      "flag": true,
      "none": null,
      "empty": [],
      "blank": {}
    }

    """

    func testJSONRendersTheAgentsLayoutByteForByte() throws {
        let parsed = try AgentHookInstall.JSON.parse(Data(agentStyle.utf8))
        XCTAssertEqual(parsed.rendered() + "\n", agentStyle)
        XCTAssertEqual(
            try AgentHookInstall.JSON.parse(Data(#"["😀"]"#.utf8)), .array([.string("😀")]))
        XCTAssertThrowsError(try AgentHookInstall.JSON.parse(Data(#"{"a": }"#.utf8)))
        XCTAssertThrowsError(try AgentHookInstall.JSON.parse(Data(#"{"a": 1} x"#.utf8)))
    }

    func testInstallOnlyAddsLinesAndUninstallRestoresTheFile() throws {
        let original = Data(agentStyle.utf8)
        let cmd = AgentHookInstall.eventsCommand(muxPath: muxPath, target: .claude)
        let installed = try XCTUnwrap(AgentHookInstall.apply(
            data: original, hook: .events, target: .claude, install: true, command: cmd))

        // Every original line survives, in order (an array's last element gains a
        // trailing comma when ours is appended after it).
        let lines = { (data: Data) in
            String(decoding: data, as: UTF8.self).split(separator: "\n").map {
                $0.hasSuffix(",") ? String($0.dropLast()) : String($0)
            }
        }
        var remaining = lines(installed).makeIterator()
        for line in lines(original) {
            var found = false
            while !found, let next = remaining.next() { found = next == line }
            XCTAssertTrue(found, "lost or reordered: \(line)")
        }

        let removed = try XCTUnwrap(AgentHookInstall.apply(
            data: installed, hook: .events, target: .claude, install: false, command: ""))
        XCTAssertEqual(String(decoding: removed, as: UTF8.self), agentStyle)
    }
}
