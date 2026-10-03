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
