import XCTest

// ThreadLinks.swift, TmuxModel.swift, TmuxCommands.swift and SshConfig.swift are
// compiled directly into this bundle (no @testable import), same as the other
// logic tests. `mux link` is exercised through the real script.
final class ThreadLinksTests: XCTestCase {
    private let claudeId = "3f2c9a1e-0000-4000-8000-a0b1c2d3e4f5"
    private let codexId = "01a04e9e-1111-7000-8000-000000000047"

    // MARK: Parse

    func testParseOpenWithEveryField() {
        XCTAssertEqual(
            ThreadLinks.parse("muxmaestro://open?session=web&window=2&pane=%2512&host=nas"),
            .open(session: "web", window: 2, pane: "%12", host: "nas"))
    }

    func testParseOpenSessionOnlyIsLocal() {
        XCTAssertEqual(
            ThreadLinks.parse("muxmaestro://open?session=Acme%20App"),
            .open(session: "Acme App", window: nil, pane: nil, host: "localhost"))
    }

    func testParseRejectsWhatCannotBeOpened() {
        XCTAssertNil(ThreadLinks.parse("muxmaestro://open?window=1"), "no session")
        XCTAssertNil(ThreadLinks.parse("muxmaestro://open?session="), "empty session")
        XCTAssertNil(ThreadLinks.parse("muxmaestro://open?session=web&window=two"))
        XCTAssertNil(ThreadLinks.parse("muxmaestro://open?session=web&window=-1"))
        XCTAssertNil(ThreadLinks.parse("https://open?session=web"), "other scheme")
        XCTAssertNil(ThreadLinks.parse("muxmaestro://close?session=web"), "unknown action")
        XCTAssertNil(ThreadLinks.parse("muxmaestro://thread/"), "no id")
        XCTAssertNil(ThreadLinks.parse("muxmaestro://thread/a/b"), "extra path")
        XCTAssertNil(ThreadLinks.parse("muxmaestro://thread/abc%20def"), "not an id")
    }

    func testParseThread() {
        XCTAssertEqual(ThreadLinks.parse("muxmaestro://thread/\(claudeId)"), .thread(id: claudeId))
        XCTAssertEqual(ThreadLinks.parse("MuxMaestro://thread/\(claudeId)"), .thread(id: claudeId))
    }

    // MARK: Build

    func testBuildRoundTripsAwkwardValues() {
        let links: [ThreadLink] = [
            .open(session: "Acme & Co", window: 3, pane: "%12", host: "nas"),
            .open(session: "a=b+c?d#e/f", window: nil, pane: nil, host: "localhost"),
            .open(session: "ünïcødé 🤖", window: 0, pane: nil, host: "user@box"),
            .thread(id: codexId),
        ]
        for link in links {
            XCTAssertEqual(ThreadLinks.parse(ThreadLinks.url(for: link)), link)
        }
    }

    func testBuildShape() {
        XCTAssertEqual(
            ThreadLinks.url(for: .open(session: "a b", window: 1, pane: "%3", host: "nas")),
            "muxmaestro://open?session=a%20b&window=1&pane=%253&host=nas")
        XCTAssertEqual(
            ThreadLinks.url(for: .open(session: "web", window: nil, pane: nil, host: "localhost")),
            "muxmaestro://open?session=web", "local host is the default and is left out")
        XCTAssertEqual(ThreadLinks.thread(claudeId), "muxmaestro://thread/\(claudeId)")
    }

    // MARK: Resolve

    private func pane(_ id: String, claude: String? = nil, codex: String? = nil) -> TmuxPane {
        var p = TmuxPane(id: id, index: 0, command: "zsh", title: "", active: true)
        p.claudeSessionId = claude
        p.codexSessionId = codex
        return p
    }

    private var tree: [String: [TmuxSession]] {
        [
            "localhost": [
                TmuxSession(name: "web", attached: true, windows: [
                    TmuxWindow(index: 1, name: "dev", active: true, panes: [pane("%1")]),
                    TmuxWindow(index: 2, name: "agents", active: false, panes: [
                        pane("%2", claude: claudeId), pane("%3", codex: codexId),
                    ]),
                ]),
            ],
            "nas": [
                TmuxSession(name: "backup", attached: false, windows: [
                    TmuxWindow(index: 0, name: "zsh", active: true, panes: [
                        pane("%9", claude: "remote-only-id"),
                    ]),
                ]),
            ],
        ]
    }

    func testResolveThreadFindsClaudeAndCodexPanes() {
        XCTAssertEqual(
            ThreadLinks.resolve(.thread(id: claudeId), in: tree),
            .success(.init(host: "localhost", session: "web", window: 2, pane: "%2")))
        XCTAssertEqual(
            ThreadLinks.resolve(.thread(id: codexId.uppercased()), in: tree),
            .success(.init(host: "localhost", session: "web", window: 2, pane: "%3")))
    }

    func testResolveThreadOnRemoteHost() {
        XCTAssertEqual(
            ThreadLinks.resolve(.thread(id: "remote-only-id"), in: tree),
            .success(.init(host: "nas", session: "backup", window: 0, pane: "%9")))
    }

    func testResolveThreadPrefersLocalHost() {
        var t = tree
        t["aaa"] = [TmuxSession(name: "dup", attached: false, windows: [
            TmuxWindow(index: 5, name: "x", active: true, panes: [pane("%50", claude: claudeId)]),
        ])]
        XCTAssertEqual(
            ThreadLinks.resolve(.thread(id: claudeId), in: t),
            .success(.init(host: "localhost", session: "web", window: 2, pane: "%2")))
    }

    func testResolveUnknownThreadNamesTheId() {
        let result = ThreadLinks.resolve(.thread(id: "no-such-thread"), in: tree)
        XCTAssertEqual(result, .failure(.unknownThread("no-such-thread")))
        XCTAssertEqual(ThreadLinks.LinkError.unknownThread("no-such-thread").message,
                       "No pane is running thread no-such-thread")
    }

    func testResolveOpen() {
        XCTAssertEqual(
            ThreadLinks.resolve(.open(session: "web", window: nil, pane: nil, host: "localhost"), in: tree),
            .success(.init(host: "localhost", session: "web", window: nil, pane: nil)))
        XCTAssertEqual(
            ThreadLinks.resolve(.open(session: "web", window: 1, pane: nil, host: "localhost"), in: tree),
            .success(.init(host: "localhost", session: "web", window: 1, pane: nil)))
        XCTAssertEqual(
            ThreadLinks.resolve(.open(session: "backup", window: nil, pane: "%9", host: "nas"), in: tree),
            .success(.init(host: "nas", session: "backup", window: 0, pane: "%9")),
            "a pane without a window resolves to the window that holds it")
    }

    func testResolveOpenFailures() {
        XCTAssertEqual(
            ThreadLinks.resolve(.open(session: "gone", window: nil, pane: nil, host: "localhost"), in: tree),
            .failure(.unknownSession("gone", host: "localhost")))
        XCTAssertEqual(
            ThreadLinks.resolve(.open(session: "web", window: nil, pane: nil, host: "nas"), in: tree),
            .failure(.unknownSession("web", host: "nas")), "same name, wrong host")
        XCTAssertEqual(
            ThreadLinks.resolve(.open(session: "web", window: 7, pane: nil, host: "localhost"), in: tree),
            .failure(.unknownWindow(session: "web", window: 7, host: "localhost")))
        XCTAssertEqual(
            ThreadLinks.resolve(.open(session: "web", window: 1, pane: "%2", host: "localhost"), in: tree),
            .failure(.unknownPane("%2", host: "localhost")), "pane lives in window 2, not 1")
    }

    func testErrorMessages() {
        XCTAssertEqual(ThreadLinks.LinkError.unknownSession("web", host: "localhost").message,
                       "No session “web”")
        XCTAssertEqual(ThreadLinks.LinkError.unknownWindow(session: "web", window: 7, host: "nas").message,
                       "No window web:7 on nas")
        XCTAssertEqual(ThreadLinks.LinkError.malformed("muxmaestro://nope").message,
                       "Not a MuxMaestro link: muxmaestro://nope")
    }

    // MARK: Render

    func testMatchesFindLinksAndLeavePunctuationOut() {
        let link = ThreadLinks.thread(claudeId)
        let text = "web is blocked (\(link)). Also muxmaestro://open?session=web&window=1, and https://x.y"
        let found = ThreadLinks.matches(in: text)
        XCTAssertEqual(found.map(\.link), [
            .thread(id: claudeId),
            .open(session: "web", window: 1, pane: nil, host: "localhost"),
        ])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: found[0].range), link)
        XCTAssertEqual(ns.substring(with: found[1].range), "muxmaestro://open?session=web&window=1")
    }

    func testMatchesSkipMalformedLinks() {
        XCTAssertTrue(ThreadLinks.matches(in: "see muxmaestro://thread/ and muxmaestro://open?x=1").isEmpty)
    }

    func testMatchesCountUTF16() {
        let text = "🤖 muxmaestro://open?session=web"
        let found = ThreadLinks.matches(in: text)
        XCTAssertEqual(found.first?.range, NSRange(location: 3, length: 29))
    }

    func testLabels() {
        XCTAssertEqual(ThreadLinks.label(for: .thread(id: claudeId)), "thread\u{00A0}3f2c9a1e…d3e4f5")
        XCTAssertEqual(ThreadLinks.label(for: .open(session: "web", window: 2, pane: "%3", host: "localhost")),
                       "web:2")
        XCTAssertEqual(ThreadLinks.label(for: .open(session: "backup", window: nil, pane: nil, host: "nas")),
                       "nas/backup")
    }

    // MARK: mux link

    func testMuxLinkThread() throws {
        let result = runMux(["link", claudeId])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, ThreadLinks.thread(claudeId) + "\n")
    }

    func testMuxLinkRejectsWhatIsNotAnId() {
        XCTAssertEqual(runMux(["link", "abc def"]).status, 2)
        XCTAssertEqual(runMux(["link"]).status, 2)
        XCTAssertEqual(runMux(["link", "--host", "nas", claudeId]).status, 2)
    }

    /// Resolves a real tmux target on a private server, and the link the sh
    /// script prints is byte-for-byte what the Swift builder writes.
    func testMuxLinkTargetMatchesSwiftBuilder() throws {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("tmux is not installed") }

        // A short socket dir: tmux socket paths are capped near 104 bytes.
        let socketDir = "/tmp/mmlink-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        env["TMUX_TMPDIR"] = socketDir
        env["PATH"] = (tmux as NSString).deletingLastPathComponent + ":/usr/bin:/bin"
        defer {
            _ = run(tmux, ["kill-server"], env: env)
            try? FileManager.default.removeItem(atPath: socketDir)
        }

        let session = "Acme & Co+1"
        XCTAssertEqual(run(tmux, ["-f", "/dev/null", "new-session", "-d", "-s", session, "sleep 60"],
                           env: env).status, 0)
        let created = run(tmux, ["new-window", "-t", session, "-P", "-F", "#{window_index} #{pane_id}",
                                 "sleep 60"], env: env)
        XCTAssertEqual(created.status, 0, created.output)
        let fields = created.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let window = try XCTUnwrap(Int(fields.first ?? ""))
        let paneId = String(try XCTUnwrap(fields.last))

        let result = runMux(["link", "--target", "\(session):\(window)"], env: env)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            result.output,
            ThreadLinks.url(for: .open(session: session, window: window, pane: paneId, host: "localhost"))
                + "\n")

        XCTAssertEqual(runMux(["link", "--target", "no-such-session"], env: env).status, 2)
    }

    // MARK: CLI helpers

    private var muxPath: String {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("../app/MuxMaestro/Resources/manager/mux")
            .standardizedFileURL.path
    }

    private func runMux(
        _ args: [String], env: [String: String] = ProcessInfo.processInfo.environment
    ) -> (status: Int32, output: String) {
        var env = env
        env["MUX_MANAGER_DB"] = NSTemporaryDirectory() + "mux-link-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: env["MUX_MANAGER_DB"]!) }
        return run("/bin/sh", [muxPath] + args, env: env)
    }

    private func run(
        _ executable: String, _ args: [String], env: [String: String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "spawn failed: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
