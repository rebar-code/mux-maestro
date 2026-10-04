import XCTest

// SessionRecord.swift is Foundation-only and compiled directly into this test
// target, like ClaudeSessionRecovery/TmuxCommands.

/// Records the argv sequence so `recoverTopology`'s exact tmux commands can be
/// asserted (mirrors the recorder in ClaudeSessionRecoveryTests, which is
/// file-private there).
private final class TopologyRunner: CommandRunner {
    private(set) var argSequences: [[String]] = []
    var responses: [String: String?] = [:]
    var failures: Set<String> = []

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        argSequences.append(args)
        let key = args.joined(separator: " ")
        if failures.contains(key) { return nil }
        if let scripted = responses[key] { return scripted }
        return ""
    }
}

private struct StaticStatus: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}

final class SessionRecordTests: XCTestCase {
    private let anywhere: (String) -> Bool = { _ in true }

    private func pane(_ id: String, _ cwd: String) -> TreeSnapshot.Pane {
        .init(id: id, cwd: cwd)
    }

    // MARK: parseAgents — one record per pane, last line wins

    func testParsesOneRecordPerPane() {
        let text = """
        {"pane":"%1","agent":"claude","sessionId":"aaa","cwd":"/a","at":"2026-08-28T10:00:00Z"}
        {"pane":"%2","agent":"codex","sessionId":"bbb","cwd":"/b","at":"2026-08-28T10:01:00Z"}
        """
        let records = SessionRecord.parseAgents(text)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records["%1"]?.sessionId, "aaa")
        XCTAssertEqual(records["%1"]?.agent, .claude)
        XCTAssertEqual(records["%2"]?.agent, .codex)
        XCTAssertEqual(records["%2"]?.cwd, "/b")
    }

    func testLastLineWinsForAReusedPane() {
        // A pane runs session after session over a day and there is no close
        // event, so the newest start seen on it IS the live session.
        let text = """
        {"pane":"%1","agent":"claude","sessionId":"old","cwd":"/a","at":"2026-08-28T09:00:00Z"}
        {"pane":"%1","agent":"claude","sessionId":"new","cwd":"/a","at":"2026-08-28T17:00:00Z"}
        """
        XCTAssertEqual(SessionRecord.parseAgents(text)["%1"]?.sessionId, "new")
    }

    func testSkipsMalformedAndUnknownAgentLines() {
        let text = """
        not json at all
        {"pane":"%1","agent":"gemini","sessionId":"x","cwd":"/a"}
        {"pane":"","agent":"claude","sessionId":"x","cwd":"/a"}
        {"pane":"%2","agent":"claude","cwd":"/a"}
        {"pane":"%3","agent":"claude","sessionId":"ok","cwd":"/a"}
        """
        let records = SessionRecord.parseAgents(text)
        XCTAssertEqual(Array(records.keys), ["%3"])
    }

    // MARK: The collapse case that broke transcript-scan recovery

    func testThreePanesInOneDirectoryYieldThreeRecords() {
        // The bug this feature exists to fix: `findLostSessions` takes the newest
        // transcript PER PROJECT DIRECTORY, so three acme-app panes
        // recovered as one. Keyed by pane id, all three survive.
        let dir = "/Users/j/code/github/acme-app"
        let text = (1...3).map {
            #"{"pane":"%\#($0)","agent":"claude","sessionId":"s\#($0)","cwd":"\#(dir)"}"#
        }.joined(separator: "\n")
        let records = SessionRecord.parseAgents(text)
        XCTAssertEqual(records.count, 3)

        let tree = TreeSnapshot(at: Date(), sessions: [
            .init(name: "Acme App", windows: (1...3).map {
                .init(index: $0, name: "acme-\($0)", panes: [pane("%\($0)", dir)])
            }),
        ])
        let plan = SessionRecord.restorePlan(
            tree: tree, records: records, directoryExists: anywhere)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].windows.map(\.name), ["acme-1", "acme-2", "acme-3"])
        XCTAssertEqual(
            plan[0].windows.flatMap { $0.panes.compactMap(\.resumeCommand) },
            ["claude --resume s1", "claude --resume s2", "claude --resume s3"])
    }

    // MARK: restorePlan — the join

    func testJoinsResumeCommandsPerAgent() {
        let tree = TreeSnapshot(at: Date(), sessions: [
            .init(name: "web", windows: [
                .init(index: 1, name: "server", panes: [pane("%1", "/a"), pane("%2", "/b")]),
            ]),
        ])
        let records = [
            "%1": AgentRecord(pane: "%1", agent: .claude, sessionId: "aaa", cwd: "/a"),
            "%2": AgentRecord(pane: "%2", agent: .codex, sessionId: "bbb", cwd: "/b"),
        ]
        let plan = SessionRecord.restorePlan(
            tree: tree, records: records, directoryExists: anywhere)
        XCTAssertEqual(
            plan[0].windows[0].panes.map(\.resumeCommand),
            ["claude --resume aaa", "codex resume bbb"])
    }

    func testPaneWithNoRecordStillRestoresWithNothingStaged() {
        // A plain shell / editor pane keeps the tree's shape; it just opens empty.
        let tree = TreeSnapshot(at: Date(), sessions: [
            .init(name: "web", windows: [.init(index: 1, name: "shell", panes: [pane("%9", "/a")])]),
        ])
        let plan = SessionRecord.restorePlan(tree: tree, records: [:], directoryExists: anywhere)
        XCTAssertEqual(plan[0].windows[0].panes, [RestorePane(cwd: "/a", resumeCommand: nil)])
        XCTAssertEqual(SessionRecord.stagedPaneCount(plan), 0)
    }

    func testFallbackByDirectoryFillsAnUnrecordedPane() {
        // First reboot after installing the hooks: full snapshot, thin agents.jsonl.
        let tree = TreeSnapshot(at: Date(), sessions: [
            .init(name: "web", windows: [.init(index: 1, name: "w", panes: [pane("%9", "/a")])]),
        ])
        let plan = SessionRecord.restorePlan(
            tree: tree, records: [:],
            fallbackByDirectory: [
                "/a": AgentRecord(pane: "", agent: .claude, sessionId: "old", cwd: "/a"),
            ],
            directoryExists: anywhere)
        XCTAssertEqual(plan[0].windows[0].panes[0].resumeCommand, "claude --resume old")
    }

    func testPaneRecordBeatsDirectoryFallback() {
        let tree = TreeSnapshot(at: Date(), sessions: [
            .init(name: "web", windows: [.init(index: 1, name: "w", panes: [pane("%9", "/a")])]),
        ])
        let plan = SessionRecord.restorePlan(
            tree: tree,
            records: ["%9": AgentRecord(pane: "%9", agent: .claude, sessionId: "live", cwd: "/a")],
            fallbackByDirectory: [
                "/a": AgentRecord(pane: "", agent: .claude, sessionId: "stale", cwd: "/a"),
            ],
            directoryExists: anywhere)
        XCTAssertEqual(plan[0].windows[0].panes[0].resumeCommand, "claude --resume live")
    }

    func testDropsPanesWhoseDirectoryIsGone() {
        // Same guard as ClaudeSessionRecovery: `--resume` needs somewhere to run.
        // An emptied window drops, and an emptied session with it.
        let tree = TreeSnapshot(at: Date(), sessions: [
            .init(name: "keep", windows: [
                .init(index: 1, name: "here", panes: [pane("%1", "/live"), pane("%2", "/gone")]),
                .init(index: 2, name: "vanished", panes: [pane("%3", "/gone")]),
            ]),
            .init(name: "drop", windows: [
                .init(index: 1, name: "w", panes: [pane("%4", "/gone")]),
            ]),
        ])
        let plan = SessionRecord.restorePlan(
            tree: tree, records: [:], directoryExists: { $0 == "/live" })
        XCTAssertEqual(plan.map(\.name), ["keep"])
        XCTAssertEqual(plan[0].windows.map(\.name), ["here"])
        XCTAssertEqual(plan[0].windows[0].panes.map(\.cwd), ["/live"])
    }

    func testSessionCwdIsItsFirstPane() {
        let session = RestoreSession(name: "web", windows: [
            .init(name: "w", panes: [RestorePane(cwd: "/a", resumeCommand: nil)]),
        ])
        XCTAssertEqual(session.cwd, "/a")
    }

    func testRestoreMatchRequiresSameWindowAndPaneDirectories() {
        let expected = RestoreSession(name: "web", windows: [
            .init(name: "server", panes: [
                RestorePane(cwd: "/a", resumeCommand: "claude --resume id"),
                RestorePane(cwd: "/b", resumeCommand: nil),
            ]),
        ])
        let actual = TmuxSession(name: "web", attached: false, windows: [
            TmuxWindow(index: 1, name: "server", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "zsh", title: "", active: true, path: "/a"),
                TmuxPane(id: "%2", index: 1, command: "zsh", title: "", active: false, path: "/b"),
            ]),
        ])
        XCTAssertTrue(SessionRecord.matches(expected, actual: actual))

        let wrong = TmuxSession(name: "web", attached: false, windows: [
            TmuxWindow(index: 1, name: "server", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "zsh", title: "", active: true, path: "/a"),
                TmuxPane(id: "%2", index: 1, command: "zsh", title: "", active: false, path: "/other"),
            ]),
        ])
        XCTAssertFalse(SessionRecord.matches(expected, actual: wrong))
    }

    func testSnapshotWriteGateCanBeSuspendedDuringLaunchRecovery() {
        defer { SessionRecord.resumeSnapshotWrites() }
        SessionRecord.suspendSnapshotWrites()
        XCTAssertFalse(SessionRecord.canWriteSnapshot)
        SessionRecord.resumeSnapshotWrites()
        XCTAssertTrue(SessionRecord.canWriteSnapshot)
    }

    func testEmptyPollKeepsTheLastUsefulSnapshot() throws {
        guard let url = SessionRecord.treeURL() else {
            return XCTFail("no recovery directory")
        }
        let savedSnapshot = try? Data(contentsOf: url)
        let recoveryWasEnabled = Settings.sessionRecoveryEnabled()
        defer {
            SessionRecord.resumeSnapshotWrites()
            Settings.setSessionRecoveryEnabled(recoveryWasEnabled)
            if let savedSnapshot { try? savedSnapshot.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
        }

        Settings.setSessionRecoveryEnabled(true)
        let prior = TreeSnapshot(at: Date(timeIntervalSince1970: 100), sessions: [
            .init(name: "old", windows: [
                .init(index: 1, name: "w", panes: [pane("%1", "/old")]),
            ]),
        ])
        XCTAssertTrue(SessionRecord.writeSnapshot(prior))

        let service = TmuxService(
            runner: TopologyRunner(), statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        SessionRecord.suspendSnapshotWrites()
        XCTAssertEqual(service.loadTree(), [])
        XCTAssertEqual(SessionRecord.decode(try Data(contentsOf: url)), prior)

        SessionRecord.resumeSnapshotWrites()
        XCTAssertEqual(service.loadTree(), [])
        XCTAssertEqual(SessionRecord.decode(try Data(contentsOf: url)), prior)
    }

    func testKillingLastSessionWritesTombstoneImmediately() throws {
        guard let url = SessionRecord.treeURL() else {
            return XCTFail("no recovery directory")
        }
        let savedSnapshot = try? Data(contentsOf: url)
        let recoveryWasEnabled = Settings.sessionRecoveryEnabled()
        defer {
            Settings.setSessionRecoveryEnabled(recoveryWasEnabled)
            if let savedSnapshot { try? savedSnapshot.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
        }

        Settings.setSessionRecoveryEnabled(true)
        SessionRecord.resumeSnapshotWrites()
        let prior = TreeSnapshot(at: Date(timeIntervalSince1970: 100), sessions: [
            .init(name: "only", windows: [
                .init(index: 1, name: "w", panes: [pane("%1", "/old")]),
            ]),
        ])
        XCTAssertTrue(SessionRecord.writeSnapshot(prior))

        let runner = TopologyRunner()
        runner.responses["list-sessions -F #{session_name}"] = "only"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        XCTAssertTrue(service.killSession(name: "only"))
        XCTAssertEqual(SessionRecord.decode(try Data(contentsOf: url))?.sessions, [])
    }

    func testRestoreProgressRoundTrips() throws {
        guard let url = SessionRecord.restoreProgressURL() else {
            return XCTFail("no recovery directory")
        }
        let saved = try? Data(contentsOf: url)
        defer {
            if let saved { try? saved.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
        }
        let progress = RestoreProgress(
            bootTime: Date(timeIntervalSince1970: 1_724_000_000),
            snapshotAt: Date(timeIntervalSince1970: 1_723_999_000),
            restoreToken: "4B71D1A7-24D8-4744-BBFD-19847FD0E3A5",
            uniqueNames: true,
            completed: ["web": "web", "api": "api-2"],
            inProgress: ["jobs": "mmr-4B71D1A724-2"])
        XCTAssertTrue(SessionRecord.writeRestoreProgress(progress))
        XCTAssertEqual(SessionRecord.readRestoreProgress(), progress)
        SessionRecord.clearRestoreProgress()
        XCTAssertNil(SessionRecord.readRestoreProgress())
    }

    func testRestoreProgressReadsPreJournalFormat() throws {
        let json = """
        {"bootTime":1724000000,"snapshotAt":1723999000,"completed":{"web":"web"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let progress = try decoder.decode(RestoreProgress.self, from: Data(json.utf8))
        XCTAssertEqual(progress.completed, ["web": "web"])
        XCTAssertTrue(progress.inProgress.isEmpty)
        XCTAssertFalse(progress.uniqueNames)
        XCTAssertFalse(progress.restoreToken.isEmpty)
    }

    // MARK: snapshot + codec round-trip

    func testSnapshotDropsPanesWithNoPath() {
        let sessions = [TmuxSession(name: "web", attached: false, windows: [
            TmuxWindow(index: 1, name: "server", active: true, panes: [
                TmuxPane(id: "%1", index: 0, command: "claude", title: "t", active: true, path: "/a"),
                TmuxPane(id: "%2", index: 1, command: "zsh", title: "t", active: false, path: ""),
            ]),
        ])]
        let snapshot = SessionRecord.snapshot(from: sessions, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.sessions[0].windows[0].panes, [
            .init(id: "%1", cwd: "/a", active: true),
        ])
    }

    func testSnapshotCarriesPolledAgentIdsIntoManualTreeRestore() {
        var claude = TmuxPane(
            id: "%11", index: 0, command: "claude", title: "t", active: true, path: "/repo")
        claude.claudeSessionId = "claude-session"
        var codex = TmuxPane(
            id: "%12", index: 1, command: "codex", title: "t", active: false, path: "/repo")
        codex.codexSessionId = "codex-session"
        var splitWindow = TmuxWindow(index: 1, name: "split", active: true, panes: [claude, codex])
        splitWindow.layout = "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        let sessions = [TmuxSession(name: "work", attached: true, windows: [
            splitWindow,
            TmuxWindow(index: 3, name: "logs", active: false, panes: [
                TmuxPane(id: "%13", index: 0, command: "zsh", title: "t", active: true, path: "/logs"),
            ]),
        ])]

        let snapshot = SessionRecord.snapshot(from: sessions, at: Date())
        let plan = SessionRecord.restorePlan(
            tree: snapshot, records: [:], directoryExists: anywhere)

        XCTAssertEqual(plan.map(\.name), ["work"])
        XCTAssertEqual(plan[0].windows.map(\.name), ["split", "logs"])
        XCTAssertEqual(plan[0].windows.map(\.index), [1, 3])
        XCTAssertEqual(plan[0].windows[0].layout, splitWindow.layout)
        XCTAssertTrue(plan[0].windows[0].active)
        XCTAssertEqual(plan[0].windows.map { $0.panes.count }, [2, 1])
        XCTAssertTrue(plan[0].windows[0].panes[0].active)
        XCTAssertEqual(plan[0].windows[0].panes.map(\.resumeCommand), [
            "claude --resume claude-session", "codex resume codex-session",
        ])
        XCTAssertNil(plan[0].windows[1].panes[0].resumeCommand)
    }

    func testEncodeDecodeRoundTrip() {
        let snapshot = TreeSnapshot(at: Date(timeIntervalSince1970: 1_724_000_000), sessions: [
            .init(name: "Acme App", windows: [
                .init(index: 3, name: "acme-po-import", panes: [pane("%248", "/Users/j/acme")]),
            ]),
        ])
        let data = SessionRecord.encode(snapshot)
        XCTAssertNotNil(data)
        XCTAssertEqual(SessionRecord.decode(data!), snapshot)
    }

    // MARK: TmuxService.recoverTopology — exact command sequences

    func testRecoverTopologyRebuildsSessionsWindowsAndStagesResume() {
        let runner = TopologyRunner()
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")

        let created = service.recoverTopology([
            RestoreSession(name: "Acme App", windows: [
                .init(name: "po-import", panes: [
                    RestorePane(cwd: "/acme", resumeCommand: "claude --resume aaa"),
                ]),
                .init(name: "calendar", panes: [
                    RestorePane(cwd: "/acme2", resumeCommand: "codex resume bbb"),
                ]),
            ]),
        ])

        XCTAssertEqual(created, ["Acme App"])
        XCTAssertEqual(runner.argSequences, [
            ["list-sessions", "-F", "#{session_name}"],
            ["new-session", "-d", "-s", "Acme App", "-c", "/acme"],
            ["rename-window", "-t", "=Acme App:", "--", "po-import"],
            ["set-window-option", "-t", "=Acme App:", "allow-rename", "off"],
            ["send-keys", "-t", "=Acme App:", "claude --resume aaa"],
            ["new-window", "-a", "-t", "Acme App:", "-c", "/acme2"],
            ["rename-window", "-t", "=Acme App:", "--", "calendar"],
            ["set-window-option", "-t", "=Acme App:", "allow-rename", "off"],
            ["send-keys", "-t", "=Acme App:", "codex resume bbb"],
        ])
    }

    func testRecoverTopologyNeverPressesEnter() {
        let runner = TopologyRunner()
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        service.recoverTopology([
            RestoreSession(name: "web", windows: [
                .init(name: "w", panes: [RestorePane(cwd: "/a", resumeCommand: "claude --resume x")]),
            ]),
        ])
        XCTAssertFalse(runner.argSequences.contains { $0.contains("Enter") })
    }

    func testRecoverTopologyCanResumeAgentsAfterBuildingTheirSession() {
        let runner = TopologyRunner()
        runner.responses["display-message -p -t =web: #{pane_id}"] = "%12"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")

        let report = service.recoverTopology([
            RestoreSession(name: "web", windows: [
                .init(name: "w", panes: [
                    RestorePane(cwd: "/a", resumeCommand: "claude --resume id"),
                ]),
            ]),
        ], mode: .uniqueNames, resumeAgentsImmediately: true)

        XCTAssertEqual(report.created, ["web"])
        let resume = ["send-keys", "-t", "%12", "claude --resume id", "Enter"]
        XCTAssertEqual(runner.argSequences.last, resume)
        XCTAssertTrue(runner.argSequences.firstIndex(of: resume)!
            > runner.argSequences.firstIndex(of: ["rename-window", "-t", "=web:", "--", "w"])!)
    }

    func testRecoverTopologyRestoresWindowIndicesLayoutAndActiveSelection() {
        let runner = TopologyRunner()
        runner.responses["display-message -p -t =web: #{window_index}"] = "1"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        let layout = "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"

        let report = service.recoverTopology([
            RestoreSession(name: "web", windows: [
                RestoreWindow(name: "split", panes: [
                    RestorePane(cwd: "/a", resumeCommand: nil),
                    RestorePane(cwd: "/b", resumeCommand: nil, active: true),
                ], index: 3, layout: layout, active: true),
                RestoreWindow(name: "logs", panes: [
                    RestorePane(cwd: "/logs", resumeCommand: nil),
                ], index: 7),
            ]),
        ], mode: .uniqueNames)

        XCTAssertEqual(report.created, ["web"])
        XCTAssertTrue(runner.argSequences.contains([
            "move-window", "-s", "=web:1", "-t", "=web:3",
        ]))
        XCTAssertTrue(runner.argSequences.contains([
            "new-window", "-d", "-t", "=web:7", "-c", "/logs",
        ]))
        let split = runner.argSequences.firstIndex(of: [
            "split-window", "-v", "-t", "=web:3", "-c", "/b",
        ])!
        let selectLayout = runner.argSequences.firstIndex(of: [
            "select-layout", "-t", "=web:3", layout,
        ])!
        let selectPane = runner.argSequences.firstIndex(of: [
            "select-pane", "-t", "=web:3.1",
        ])!
        let selectWindow = runner.argSequences.firstIndex(of: [
            "select-window", "-t", "=web:3",
        ])!
        XCTAssertLessThan(split, selectLayout)
        XCTAssertLessThan(selectLayout, selectPane)
        XCTAssertLessThan(selectPane, selectWindow)
    }

    func testJournaledRestoreBuildsUnderTemporaryNameBeforePublishingIt() {
        let runner = TopologyRunner()
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        let session = RestoreSession(name: "web", windows: [
            .init(name: "server", panes: [RestorePane(cwd: "/a", resumeCommand: nil)]),
        ])
        let token = "12345678-90ab-cdef"
        var journaledName: String?
        let report = service.recoverTopology(
            [session],
            mode: .resume(
                completed: [:], inProgress: [:], token: token, uniqueNames: false),
            onSessionStarting: { _, name in journaledName = name; return true })

        let temporary = "mmr-1234567890-0"
        XCTAssertEqual(journaledName, temporary)
        XCTAssertEqual(report.created, ["web"])
        let create = ["new-session", "-d", "-s", temporary, "-c", "/a"]
        let publish = ["rename-session", "-t", temporary, "web"]
        XCTAssertLessThan(
            runner.argSequences.firstIndex(of: create)!,
            runner.argSequences.firstIndex(of: ["rename-window", "-t", "=\(temporary):", "--", "server"])!)
        XCTAssertGreaterThan(
            runner.argSequences.firstIndex(of: publish)!,
            runner.argSequences.firstIndex(of: ["rename-window", "-t", "=\(temporary):", "--", "server"])!)
    }

    func testJournaledRetryPublishesACompleteTemporarySession() {
        let runner = TopologyRunner()
        let temporary = "mmr-1234567890-0"
        runner.responses["list-sessions -F #{session_name}"] = temporary
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = "\(temporary)\t0\t\t0"
        runner.responses["list-windows -a -F \(TmuxModel.allWindowsFormat)"] =
            "\(temporary)\t1\tserver\t1\t\t\t\t"
        runner.responses["list-panes -a -F \(TmuxModel.allPanesFormat)"] =
            "\(temporary)\t1\t%1\t0\tzsh\tt\t1\t/a\t0\t0\t80\t24\t10"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        let report = service.recoverTopology(
            [RestoreSession(name: "web", windows: [
                .init(name: "server", panes: [RestorePane(cwd: "/a", resumeCommand: nil)]),
            ])],
            mode: .resume(
                completed: [:], inProgress: ["web": temporary], token: "12345678-90ab-cdef",
                uniqueNames: false))

        XCTAssertEqual(report.alreadyPresent, ["web"])
        XCTAssertTrue(runner.argSequences.contains(["rename-session", "-t", temporary, "web"]))
        XCTAssertFalse(runner.argSequences.contains { $0.first == "new-session" })
        XCTAssertFalse(runner.argSequences.contains { $0.first == "kill-session" })
    }

    func testConfirmedJournaledRestoreChoosesFreeSessionName() {
        let runner = TopologyRunner()
        runner.responses["list-sessions -F #{session_name}"] = "web"
        runner.responses["list-sessions -F \(TmuxModel.sessionsFormat)"] = "web\t0\t\t0"
        runner.responses["list-windows -a -F \(TmuxModel.allWindowsFormat)"] =
            "web\t1\tserver\t1\t\t\t\t"
        runner.responses["list-panes -a -F \(TmuxModel.allPanesFormat)"] =
            "web\t1\t%1\t0\tzsh\tt\t1\t/other\t0\t0\t80\t24\t10"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        let report = service.recoverTopology(
            [RestoreSession(name: "web", windows: [
                .init(name: "server", panes: [RestorePane(cwd: "/a", resumeCommand: nil)]),
            ])],
            mode: .resume(
                completed: [:], inProgress: [:], token: "12345678-90ab-cdef",
                uniqueNames: true))

        XCTAssertEqual(report.created, ["web-2"])
        XCTAssertFalse(runner.argSequences.contains(["kill-session", "-t", "=web"]))
        XCTAssertTrue(runner.argSequences.contains([
            "rename-session", "-t", "mmr-1234567890-0", "web-2",
        ]))
    }

    func testRecoverTopologySplitsExtraPanes() {
        let runner = TopologyRunner()
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        service.recoverTopology([
            RestoreSession(name: "web", windows: [
                .init(name: "w", panes: [
                    RestorePane(cwd: "/a", resumeCommand: nil),
                    RestorePane(cwd: "/b", resumeCommand: "claude --resume x"),
                ]),
            ]),
        ])
        XCTAssertEqual(runner.argSequences.suffix(2), [
            ["split-window", "-v", "-t", "=web:", "-c", "/b"],
            ["send-keys", "-t", "=web:", "claude --resume x"],
        ])
    }

    func testRecoverTopologyDedupesAgainstLiveSessions() {
        let runner = TopologyRunner()
        runner.responses["list-sessions -F #{session_name}"] = "web"
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")
        let created = service.recoverTopology([
            RestoreSession(name: "web", windows: [
                .init(name: "w", panes: [RestorePane(cwd: "/a", resumeCommand: nil)]),
            ]),
            RestoreSession(name: "web", windows: [
                .init(name: "w", panes: [RestorePane(cwd: "/b", resumeCommand: nil)]),
            ]),
        ])
        // The live "web" is untouched; both plan rows land beside it.
        XCTAssertEqual(created, ["web-2", "web-3"])
    }

    func testRecoverTopologyReportsAndRollsBackPartialSession() {
        let runner = TopologyRunner()
        runner.failures.insert("split-window -v -t =web: -c /b")
        let service = TmuxService(
            runner: runner, statusProvider: StaticStatus(), tmuxPath: "/usr/bin/tmux")

        let report = service.recoverTopology([
            RestoreSession(name: "web", windows: [
                .init(name: "w", panes: [
                    RestorePane(cwd: "/a", resumeCommand: nil),
                    RestorePane(cwd: "/b", resumeCommand: nil),
                ]),
            ]),
        ], mode: .uniqueNames)

        XCTAssertTrue(report.created.isEmpty)
        XCTAssertEqual(report.completedCount, 0)
        XCTAssertEqual(report.failures.map(\.session), ["web"])
        XCTAssertTrue(runner.argSequences.contains(["kill-session", "-t", "=web"]))
    }

    // MARK: hasRestored — one rebuild per boot

    func testRestoredMarkerIsPerBoot() {
        // Uses the real Application Support path; restore it afterwards so a
        // developer's own marker isn't clobbered by running the tests.
        guard let url = SessionRecord.restoredMarkerURL() else {
            return XCTFail("no recovery directory")
        }
        let saved = try? Data(contentsOf: url)
        defer {
            if let saved { try? saved.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
        let boot = Date(timeIntervalSince1970: 1_724_000_000)
        SessionRecord.markRestored(bootTime: boot)
        XCTAssertTrue(SessionRecord.hasRestored(bootTime: boot))
        XCTAssertFalse(SessionRecord.hasRestored(bootTime: boot.addingTimeInterval(3600)))
    }
}
