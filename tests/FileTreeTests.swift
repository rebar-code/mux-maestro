import XCTest

// FileTree.swift + TmuxService.swift (Foundation-only, no AppKit) are compiled
// directly into this test target, so the pure tree-construction core AND the
// service's local/remote routing can be asserted against a fake CommandRunner —
// mirroring GitDiffTests.

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

final class FileTreeTests: XCTestCase {

    // MARK: argv shape

    func testListArgvShape() {
        XCTAssertEqual(
            FileTree.listArgv(cwd: "/repo"),
            ["-C", "/repo", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    }

    // MARK: build — nesting + folders-first + case-insensitive sort

    func testBuildNestsFoldersAndSortsFoldersFirst() {
        // NUL-separated, deliberately out of order: a file at root, a nested file,
        // a folder whose name sorts after the root file.
        let (root, truncated) = FileTree.build(
            fromNulList: "readme.md\u{0}src/app.ts\u{0}src/util/x.ts\u{0}")
        XCTAssertFalse(truncated)

        // Top level: the `src` folder sorts before the `readme.md` file.
        XCTAssertEqual(root.map(\.name), ["src", "readme.md"])
        XCTAssertTrue(root[0].isDir)
        XCTAssertEqual(root[0].relativePath, "src")
        XCTAssertFalse(root[1].isDir)

        // `src` children: the `util` folder before the `app.ts` file.
        let src = root[0]
        XCTAssertEqual(src.children.map(\.name), ["util", "app.ts"])
        XCTAssertTrue(src.children[0].isDir)

        // Leaf carries the full repo-relative path for opening.
        let appFile = src.children[1]
        XCTAssertEqual(appFile.relativePath, "src/app.ts")
        let nested = src.children[0].children
        XCTAssertEqual(nested.map(\.relativePath), ["src/util/x.ts"])
    }

    func testBuildSortsCaseInsensitively() {
        let (root, _) = FileTree.build(fromNulList: "Zebra.txt\u{0}apple.txt\u{0}")
        XCTAssertEqual(root.map(\.name), ["apple.txt", "Zebra.txt"])
    }

    func testBuildEmptyInput() {
        let (root, truncated) = FileTree.build(fromNulList: "")
        XCTAssertTrue(root.isEmpty)
        XCTAssertFalse(truncated)
    }

    // MARK: build — cap / truncation

    func testBuildCapsFileCount() {
        let many = (0..<(FileTree.maxFiles + 5))
            .map { "f\($0).txt" }.joined(separator: "\u{0}")
        let (root, truncated) = FileTree.build(fromNulList: many)
        XCTAssertEqual(root.count, FileTree.maxFiles)
        XCTAssertTrue(truncated)
    }

    // MARK: TmuxService.fileTree — local probe + list + build

    private func makeLocalService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: "/usr/bin/tmux")
    }

    func testFileTreeLocalRunsGitAndBuilds() {
        let runner = FakeRunner()
        runner.responses["-C /repo rev-parse --is-inside-work-tree"] = "true\n"
        runner.responses["-C /repo ls-files --cached --others --exclude-standard -z"] =
            "src/app.ts\u{0}readme.md\u{0}"

        let result = makeLocalService(runner).fileTree(cwd: "/repo")
        XCTAssertTrue(result.isRepo)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.root.map(\.name), ["src", "readme.md"])
        // The list ran as a local `git -C /repo …` (path resolves to git).
        let call = runner.calls.first { $0.args == FileTree.listArgv(cwd: "/repo") }
        XCTAssertNotNil(call)
        XCTAssertTrue(call!.path.hasSuffix("git"))
    }

    func testFileTreeNonRepoReturnsIsRepoFalse() {
        let runner = FakeRunner()
        runner.responses["-C /tmp rev-parse --is-inside-work-tree"] = String?.none  // not a repo
        let result = makeLocalService(runner).fileTree(cwd: "/tmp")
        XCTAssertFalse(result.isRepo)
        XCTAssertTrue(result.root.isEmpty)
        // No ls-files once the repo probe fails.
        XCTAssertFalse(runner.argSequences.contains { $0.contains("ls-files") })
    }

    // MARK: TmuxService.fileTree — remote routes git over ssh

    private func makeRemoteService(_ runner: FakeRunner, host: String = "buildbox") -> TmuxService {
        TmuxService(
            host: Host(name: host, sshAlias: host),
            transport: SshTmuxTransport(host: host),
            runner: runner,
            statusProvider: StaticStatusProvider())
    }

    func testFileTreeRemoteRoutesGitThroughSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = "true"  // repo probe true; ls-files returns "true" (harmless)
        _ = makeRemoteService(runner).fileTree(cwd: "/repo")
        let call = runner.calls.first {
            $0.path == "/usr/bin/ssh" && $0.args.contains("'git'") && $0.args.contains("'ls-files'")
        }
        XCTAssertNotNil(call)
        XCTAssertTrue(call!.args.contains("buildbox"))
    }
}
