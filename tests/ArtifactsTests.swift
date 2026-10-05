import XCTest

// Artifacts.swift is Foundation-only and compiled directly into this test
// target. Disk access is injected, so these tests touch no files except the
// fixtures and the reader's temp transcript.

final class ArtifactsTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("fixtures/artifacts")

    private func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private func date(_ iso: String) -> Date {
        ArtifactScanner.parseTimestamp(iso)!
    }

    // MARK: Claude

    private var claudeDisk: (exists: Set<String>, mtimes: [String: Date]) {
        (["/work/repo/README.md", "/work/repo/src/chart.swift", "/work/repo/nb.ipynb",
          "/tmp/shot-1.png", "/work/repo/out/chart.svg", "/work/repo/docs/old-diagram.png"],
         ["/tmp/shot-1.png": date("2026-10-02T10:03:01Z"),
          "/work/repo/out/chart.svg": date("2026-10-02T10:03:01Z"),
          "/work/repo/docs/old-diagram.png": date("2025-01-01T00:00:00Z")])
    }

    private func scanClaude() throws -> [Artifact] {
        let disk = claudeDisk
        return ArtifactScanner.scan(
            lines: try lines("claude.jsonl"), cwd: "", threadStart: nil,
            fileExists: { disk.exists.contains($0) }, mtime: { disk.mtimes[$0] })
    }

    func testClaudeListsMadeFilesAndFreshImagesNewestFirst() throws {
        let found = try scanClaude()
        XCTAssertEqual(found.map(\.path), [
            "/work/repo/src/chart.swift",
            "/tmp/shot-1.png",
            "/work/repo/out/chart.svg",
            "/work/repo/nb.ipynb",
            "/work/repo/src/gone.swift",
            "/work/repo/README.md",
        ])
        XCTAssertEqual(found.first { $0.path == "/tmp/shot-1.png" }?.kind, .image)
        XCTAssertEqual(found.first { $0.path == "/work/repo/nb.ipynb" }?.kind, .file)
    }

    func testClaudeKeepsTheNewestMentionOfAPath() throws {
        let chart = try scanClaude().first { $0.path == "/work/repo/src/chart.swift" }
        XCTAssertEqual(chart?.at, date("2026-10-02T10:06:00Z"))
    }

    /// Read-only files, user-typed paths, URLs, old images, `.png.bak`, and
    /// image paths that are not on disk are all left out.
    func testClaudeExcludesWhatTheAgentDidNotMake() throws {
        let paths = Set(try scanClaude().map(\.path))
        for excluded in ["/work/repo/old/logo.png", "/work/repo/docs/old-diagram.png",
                         "/work/repo/out/chart.png", "/work/repo/chart.png",
                         "/a.png", "/example.com/a.png"] {
            XCTAssertFalse(paths.contains(excluded), excluded)
        }
    }

    /// A made file that is gone stays listed, marked missing.
    func testMissingMadeFileStaysListed() throws {
        let gone = try scanClaude().first { $0.path == "/work/repo/src/gone.swift" }
        XCTAssertEqual(gone?.exists, false)
        XCTAssertEqual(try scanClaude().first { $0.path == "/work/repo/README.md" }?.exists, true)
    }

    // MARK: Named files

    /// A file the agent wrote with a shell command has no edit-tool record. It
    /// lists when the agent names it in its own text and the disk shows it
    /// changed during the thread. A name with spaces counts inside backticks.
    func testClaudeListsFilesTheAgentNamedAndChanged() throws {
        let fresh = date("2026-10-02T10:01:01Z")
        let old = date("2025-01-01T00:00:00Z")
        let mtimes = ["/work/repo/tasks/report.md": fresh,
                      "/work/repo/out/Build Estimate 2026-10-02.pdf": fresh,
                      "/work/repo/build.log": fresh, "/work/repo/package.json": fresh,
                      "/work/repo/docs/brief.md": fresh, "/work/repo/src/old.ts": old]
        let found = ArtifactScanner.scan(
            lines: try lines("claude-named.jsonl"), cwd: "", threadStart: nil,
            fileExists: { mtimes[$0] != nil }, mtime: { mtimes[$0] })
        // Left out: tool output (build.log, package.json), the user's own
        // path (docs/brief.md), an unchanged file, a missing file, a URL.
        XCTAssertEqual(found.map(\.path), [
            "/work/repo/out/Build Estimate 2026-10-02.pdf",
            "/work/repo/tasks/report.md",
        ])
        XCTAssertEqual(found.map(\.kind), [.image, .file])
    }

    func testNamedPathsSkipURLsAndReadSpacesOnlyInBackticks() {
        XCTAssertEqual(
            ArtifactScanner.namedPaths(
                in: "See a/b.md, https://x.com/c.md, `My Notes.txt`, Other Notes.txt and d.swift:12."),
            ["a/b.md", "Notes.txt", "d.swift", "My Notes.txt"])
    }

    // MARK: Codex

    func testCodexListsPatchedFilesAndFreshImages() throws {
        let exists: Set<String> = ["/work/site/shots/home.png", "/work/site/new.md",
                                   "/work/site/tasks/plan.html", "/work/site/src/b.ts",
                                   "/work/site/img/hero.png", "/work/site/shots/dup.png"]
        let mtimes = ["/work/site/shots/home.png": date("2026-10-02T09:03:30Z"),
                      "/work/site/img/hero.png": date("2026-10-02T09:30:00Z"),
                      "/work/site/shots/dup.png": date("2026-10-02T09:30:00Z")]
        let found = ArtifactScanner.scan(
            lines: try lines("codex.jsonl"), cwd: "", threadStart: nil,
            fileExists: { exists.contains($0) }, mtime: { mtimes[$0] })
        XCTAssertEqual(found.map(\.path), [
            "/work/site/shots/home.png",
            "/work/site/src/b.ts",
            "/work/site/new.md",
            "/work/site/tasks/plan.html",
        ])
        XCTAssertEqual(found.first?.kind, .image)
    }

    // MARK: Pieces

    func testImagePathsSkipURLsAndLongerExtensions() {
        XCTAssertEqual(
            ArtifactScanner.imagePaths(
                in: "see https://x.com/a.png, ./b.JPG and ~/c.webp; d.png.bak /e/f.pdf."),
            ["./b.JPG", "~/c.webp", "/e/f.pdf"])
    }

    func testPatchPathsFollowMoves() {
        let patch = "*** Begin Patch\\n*** Update File: a.ts\\n*** Move to: b.ts\\n"
            + "*** Add File: c.ts\\n*** Delete File: d.ts\\n*** End Patch"
        XCTAssertEqual(ArtifactScanner.patchPaths(in: patch), ["b.ts", "c.ts"])
    }

    func testThreadStartArgumentOverridesTheFirstRecord() throws {
        let disk = claudeDisk
        let found = ArtifactScanner.scan(
            lines: try lines("claude.jsonl"), cwd: "", threadStart: date("2026-10-02T11:00:00Z"),
            fileExists: { disk.exists.contains($0) }, mtime: { disk.mtimes[$0] })
        XCTAssertFalse(found.contains { $0.kind == .image })
    }

    // MARK: Incremental reader

    func testReaderParsesOnlyAppendedWholeLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let all = try lines("claude.jsonl")
        try (all[0...3].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let reader = ArtifactTranscriptReader()
        let first = reader.mentions(transcript: file.path)
        XCTAssertEqual(first?.made.keys.sorted(), ["/work/repo/src/chart.swift"])
        XCTAssertEqual(reader.linesParsed, 4)

        // Unchanged file: nothing re-read.
        _ = reader.mentions(transcript: file.path)
        XCTAssertEqual(reader.linesParsed, 4)

        // A half-written line waits for its newline.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(all[4].prefix(20).utf8))
        _ = reader.mentions(transcript: file.path)
        XCTAssertEqual(reader.linesParsed, 4)
        try handle.write(contentsOf: Data((all[4].dropFirst(20) + "\n").utf8))
        try handle.close()
        let second = reader.mentions(transcript: file.path)
        XCTAssertEqual(reader.linesParsed, 5)
        XCTAssertEqual(second?.made.keys.sorted(),
                       ["/work/repo/README.md", "/work/repo/src/chart.swift"])
        XCTAssertEqual(second?.threadStart, date("2026-10-02T10:00:00Z"))
    }

    func testLocateFindsClaudeAndCodexTranscripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts-loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let projects = root.appendingPathComponent("projects")
        let codex = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: projects.appendingPathComponent("-work-repo"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: codex.appendingPathComponent("2026/10/02"),
                               withIntermediateDirectories: true)
        let claudeFile = projects.appendingPathComponent("-work-repo/abc.jsonl")
        let codexFile = codex.appendingPathComponent("2026/10/02/rollout-2026-10-02T09-00-00-def.jsonl")
        fm.createFile(atPath: claudeFile.path, contents: Data())
        fm.createFile(atPath: codexFile.path, contents: Data())

        XCTAssertEqual(ArtifactTranscriptReader.locate(
            claudeSessionId: "abc", codexSessionId: nil,
            claudeProjects: projects, codexSessions: codex), claudeFile.path)
        XCTAssertEqual(ArtifactTranscriptReader.locate(
            claudeSessionId: nil, codexSessionId: "def",
            claudeProjects: projects, codexSessions: codex), codexFile.path)
        XCTAssertNil(ArtifactTranscriptReader.locate(
            claudeSessionId: "nope", codexSessionId: nil,
            claudeProjects: projects, codexSessions: codex))
    }
}

final class TmuxWindowAgentPaneTests: XCTestCase {
    private func pane(_ id: String, active: Bool, claude: String? = nil, codex: String? = nil) -> TmuxPane {
        var p = TmuxPane(id: id, index: 0, command: "zsh", title: "", active: active, pid: 1)
        p.claudeSessionId = claude
        p.codexSessionId = codex
        return p
    }

    private func window(_ panes: [TmuxPane]) -> TmuxWindow {
        TmuxWindow(index: 0, name: "w", active: true, panes: panes)
    }

    func testActivePaneWithAThreadWins() {
        let w = window([pane("%1", active: false, claude: "a"), pane("%2", active: true, codex: "b")])
        XCTAssertEqual(w.agentPane?.id, "%2")
    }

    func testFallsBackToTheFirstPaneWithAThread() {
        let w = window([pane("%1", active: true), pane("%2", active: false, claude: "a")])
        XCTAssertEqual(w.agentPane?.id, "%2")
    }

    func testNoThreadAnywhereGivesTheActivePane() {
        let w = window([pane("%1", active: false), pane("%2", active: true)])
        XCTAssertEqual(w.agentPane?.id, "%2")
        XCTAssertNil(window([]).agentPane)
    }
}

final class ArtifactWebTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("fixtures/artifacts")

    private func mentions(_ name: String) throws -> ArtifactMentions {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
        var m = ArtifactMentions()
        text.split(separator: "\n").forEach { m.ingest(line: $0) }
        return m
    }

    private func date(_ iso: String) -> Date { ArtifactScanner.parseTimestamp(iso)! }

    /// Only the agent's own text counts: not tool input, not tool results, not
    /// the user's prompt.
    func testClaudeURLsComeFromAssistantTextOnly() throws {
        XCTAssertEqual(try mentions("claude.jsonl").urls.keys.sorted(),
                       ["http://localhost:5173/checkout", "https://svelte.dev/docs/kit/load"])
    }

    func testCodexURLsComeFromAssistantMessages() throws {
        XCTAssertEqual(try mentions("codex.jsonl").urls.keys.sorted(),
                       ["http://127.0.0.1:4173", "https://github.com/acme/site/pull/12"])
    }

    func testURLsStopAtMarkdownAndTrailingPunctuation() {
        XCTAssertEqual(
            ArtifactScanner.urls(in: "see [docs](https://a.com/x), <https://b.com/y>, `http://localhost:3000/`. "
                + "and https://c.com/q?a=1&b=2! not https://*.wild.com/x"),
            ["https://a.com/x", "https://b.com/y", "http://localhost:3000/", "https://c.com/q?a=1&b=2"])
    }

    func testLocalHosts() {
        for host in ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "mac.local", "app.localhost"] {
            XCTAssertTrue(ArtifactScanner.isLocalHost(host), host)
        }
        for host in ["example.com", "localhost.example.com", "10.0.0.5"] {
            XCTAssertFalse(ArtifactScanner.isLocalHost(host), host)
        }
    }

    private var urls: [String: Date] {
        ["http://localhost:5173/checkout": date("2026-10-02T10:01:00Z"),
         "http://localhost:3000/": date("2026-10-02T10:02:00Z"),
         "https://svelte.dev/docs/kit/load": date("2026-10-02T10:03:00Z"),
         "https://github.com/acme/site/pull/12": date("2026-10-02T10:04:00Z")]
    }

    func testURLsKeepIPv6HostsAndDropMarkdownEmphasis() {
        XCTAssertEqual(
            ArtifactScanner.urls(in: "Up at **http://localhost:5173/** and http://[::1]:3000/app. Not https:// alone."),
            ["http://localhost:5173/", "http://[::1]:3000/app"])
        let web = ArtifactScanner.web(
            urls: ["http://[::1]:3000/app": date("2026-10-02T10:00:00Z")], running: [], runningKnown: true)
        XCTAssertEqual(web.servers.map(\.host), ["[::1]:3000"])
        XCTAssertTrue(web.links.isEmpty)
    }

    /// A running server on a port the agent named merges into one live row
    /// that opens the page the agent named, over https when that is what the
    /// server speaks. A named port with nothing on it is dead. A running
    /// server the agent never named still lists, live.
    func testServersMergeRunningWithMentionedPorts() {
        let web = ArtifactScanner.web(
            urls: urls,
            running: [ArtifactRunningServer(port: 5173, url: "https://localhost:5173/"),
                      ArtifactRunningServer(port: 8080, url: "http://localhost:8080/")],
            runningKnown: true)
        XCTAssertEqual(web.servers.map(\.url),
                       ["https://localhost:5173/checkout", "http://localhost:8080/", "http://localhost:3000/"])
        XCTAssertEqual(web.servers.map(\.host), ["localhost:5173", "localhost:8080", "localhost:3000"])
        XCTAssertEqual(web.servers.map(\.path), ["/checkout", "", ""])
        XCTAssertEqual(web.servers.map(\.live), [true, true, false])
        XCTAssertEqual(web.links.map(\.url),
                       ["https://github.com/acme/site/pull/12", "https://svelte.dev/docs/kit/load"])
        XCTAssertEqual(web.links.first?.host, "github.com")
        XCTAssertEqual(web.links.first?.path, "/acme/site/pull/12")
    }

    /// Unknown Running state never reads as dead.
    func testUnknownRunningStateIsNotDead() {
        let web = ArtifactScanner.web(urls: urls, running: [], runningKnown: false)
        XCTAssertEqual(web.servers.map(\.live), [nil, nil])
    }

    /// Two pages on one port are one server row: the page named last. A URL
    /// with no port counts as 80 or 443. A running server with no URL opens
    /// its bare origin.
    func testOneServerRowPerPort() {
        let web = ArtifactScanner.web(
            urls: ["http://localhost:5173/": date("2026-10-02T10:01:00Z"),
                   "http://127.0.0.1:5173/cart?step=2": date("2026-10-02T10:05:00Z"),
                   "https://app.localhost/login": date("2026-10-02T10:02:00Z")],
            running: [ArtifactRunningServer(port: 9000, url: nil)],
            runningKnown: true)
        XCTAssertEqual(web.servers.map(\.url),
                       ["http://localhost:9000/", "https://app.localhost/login", "http://127.0.0.1:5173/cart?step=2"])
        XCTAssertEqual(web.servers.map(\.path), ["", "/login", "/cart?step=2"])
        XCTAssertEqual(web.servers.map(\.live), [true, false, false])
        XCTAssertEqual(web.servers.map(\.at),
                       [nil, date("2026-10-02T10:02:00Z"), date("2026-10-02T10:05:00Z")])
        XCTAssertTrue(web.links.isEmpty)
    }

    func testRepeatedLinksDedupeToTheNewestMention() {
        var m = ArtifactMentions()
        m.ingest(line: #"{"type":"assistant","timestamp":"2026-10-02T10:00:00Z","message":{"content":[{"type":"text","text":"https://a.com/x"}]}}"#)
        m.ingest(line: #"{"type":"assistant","timestamp":"2026-10-02T11:00:00Z","message":{"content":[{"type":"text","text":"again https://a.com/x"}]}}"#)
        XCTAssertEqual(m.urls, ["https://a.com/x": date("2026-10-02T11:00:00Z")])
    }

    // MARK: Markdown preview

    func testMarkdownArtifactsAreKnownByExtension() {
        func artifact(_ path: String) -> Artifact {
            Artifact(kind: .file, path: path, at: date("2026-10-02T10:00:00Z"), exists: true)
        }
        XCTAssertTrue(artifact("/work/repo/README.md").isMarkdown)
        XCTAssertTrue(artifact("/work/repo/docs/Plan.MARKDOWN").isMarkdown)
        XCTAssertTrue(artifact("/work/repo/post.mdx").isMarkdown)
        XCTAssertFalse(artifact("/work/repo/src/chart.swift").isMarkdown)
        XCTAssertFalse(artifact("/work/repo/md").isMarkdown)
    }

    func testCodeArtifactsAreKnownByExtensionOrName() {
        func artifact(_ path: String) -> Artifact {
            Artifact(kind: .file, path: path, at: date("2026-10-02T10:00:00Z"), exists: true)
        }
        for path in ["/work/repo/src/chart.swift", "/work/repo/src/lib/cart.ts",
                     "/work/repo/src/routes/+page.svelte", "/work/repo/Config.YAML",
                     "/work/repo/Makefile", "/work/repo/Dockerfile"] {
            XCTAssertTrue(artifact(path).isCode, path)
        }
        // Markdown renders, HTML and documents stay with Quick Look.
        for path in ["/work/repo/README.md", "/work/repo/report.html", "/work/repo/out/data.csv",
                     "/work/repo/notes.txt", "/work/repo/spec.pdf", "/work/repo/swift"] {
            XCTAssertFalse(artifact(path).isCode, path)
        }
    }

    func testMarkdownSourceFencesFrontMatter() {
        let text = "---\nname: demo\ntags: [a, b]\n---\n\n# Title\n\nBody\n"
        XCTAssertEqual(
            ArtifactMarkdown.source(from: text),
            "```\nname: demo\ntags: [a, b]\n```\n\n# Title\n\nBody\n")
    }

    func testMarkdownSourceLeavesOtherTextAlone() {
        // A rule at the top that never closes is not front matter.
        let rule = "---\n\n# Title\n"
        XCTAssertEqual(ArtifactMarkdown.source(from: rule), rule)
        let plain = "# Title\n\n---\n\nBody\n"
        XCTAssertEqual(ArtifactMarkdown.source(from: plain), plain)
        XCTAssertEqual(ArtifactMarkdown.source(from: ""), "")
    }

    func testMarkdownSourceNormalizesWindowsLineEndings() {
        XCTAssertEqual(
            ArtifactMarkdown.source(from: "---\r\nname: demo\r\n---\r\n# Title\r\n"),
            "```\nname: demo\n```\n# Title\n")
    }
}
