import XCTest

// GitDiff.swift + TmuxService.swift (Foundation-only, no AppKit) are compiled
// directly into this test target, so the pure patch-synthesis core AND the
// service's git-argv sequence can be asserted against a fake CommandRunner with
// no real git/ssh/cat spawned.

/// Records every command and replies from a scripted table — same shape as the
/// FakeRunner in TmuxServiceTests/BrowserPortsTests (each is file-private, so
/// this target keeps its own copy).
private final class FakeRunner: CommandRunner {
    // gitDiff now runs commands concurrently, so guard the recorded calls.
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

final class GitDiffTests: XCTestCase {

    // MARK: untrackedFilePatch — exact unified-patch fixtures

    func testUntrackedSingleLineWithTrailingNewline() {
        let patch = GitDiff.untrackedFilePatch(path: "a.txt", contents: "hello\n")
        XCTAssertEqual(patch, """
        diff --git a/a.txt b/a.txt
        new file mode 100644
        --- /dev/null
        +++ b/a.txt
        @@ -0,0 +1,1 @@
        +hello

        """)
    }

    func testUntrackedMultiLineWithTrailingNewline() {
        let patch = GitDiff.untrackedFilePatch(path: "src/x.js", contents: "const a = 1\nconst b = 2\n")
        XCTAssertEqual(patch, """
        diff --git a/src/x.js b/src/x.js
        new file mode 100644
        --- /dev/null
        +++ b/src/x.js
        @@ -0,0 +1,2 @@
        +const a = 1
        +const b = 2

        """)
    }

    func testUntrackedNoTrailingNewline() {
        let patch = GitDiff.untrackedFilePatch(path: "a.txt", contents: "one\ntwo")
        XCTAssertEqual(patch, """
        diff --git a/a.txt b/a.txt
        new file mode 100644
        --- /dev/null
        +++ b/a.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        \\ No newline at end of file

        """)
    }

    func testUntrackedEmptyFileIsHeaderOnly() {
        let patch = GitDiff.untrackedFilePatch(path: "empty", contents: "")
        XCTAssertEqual(patch, """
        diff --git a/empty b/empty
        new file mode 100644

        """)
        // No hunk, no /dev/null lines for an empty new file (matches git).
        XCTAssertFalse(patch.contains("@@"))
        XCTAssertFalse(patch.contains("/dev/null"))
    }

    // MARK: argv shape + HEAD-vs-empty selection

    func testArgvShapes() {
        XCTAssertEqual(GitDiff.isRepoArgv(cwd: "/r"),
            ["-C", "/r", "rev-parse", "--is-inside-work-tree"])
        XCTAssertEqual(GitDiff.hasHEADArgv(cwd: "/r"),
            ["-C", "/r", "rev-parse", "--verify", "-q", "HEAD"])
        XCTAssertEqual(GitDiff.branchHeaderArgv(cwd: "/r"),
            ["-C", "/r", "rev-parse", "--abbrev-ref", "HEAD"])
        XCTAssertEqual(GitDiff.headDiffArgv(cwd: "/r"),
            ["-C", "/r", "--no-pager", "diff", "--no-color", "HEAD"])
        XCTAssertEqual(GitDiff.noHeadDiffArgv(cwd: "/r"),
            ["-C", "/r", "--no-pager", "diff", "--no-color"])
        XCTAssertEqual(GitDiff.untrackedListArgv(cwd: "/r"),
            ["-C", "/r", "ls-files", "--others", "--exclude-standard", "-z"])
    }

    func testTrackedDiffArgvSelectsByHasHEAD() {
        XCTAssertEqual(GitDiff.trackedDiffArgv(cwd: "/r", hasHEAD: true), GitDiff.headDiffArgv(cwd: "/r"))
        XCTAssertEqual(GitDiff.trackedDiffArgv(cwd: "/r", hasHEAD: false), GitDiff.noHeadDiffArgv(cwd: "/r"))
    }

    // MARK: parseUntrackedList — order + cap

    func testParseUntrackedListSplitsOnNulAndPreservesOrder() {
        let (paths, dropped) = GitDiff.parseUntrackedList("b.txt\u{0}a/c.txt\u{0}d\u{0}")
        XCTAssertEqual(paths, ["b.txt", "a/c.txt", "d"])
        XCTAssertEqual(dropped, 0)
    }

    func testParseUntrackedListCaps() {
        let many = (0..<(GitDiff.maxUntrackedFiles + 5))
            .map { "f\($0).txt" }.joined(separator: "\u{0}")
        let (paths, dropped) = GitDiff.parseUntrackedList(many)
        XCTAssertEqual(paths.count, GitDiff.maxUntrackedFiles)
        XCTAssertEqual(dropped, 5)
    }

    // MARK: combine — tracked first, untracked in order, newline-separated

    func testCombineOrdersAndSeparates() {
        let tracked = "diff --git a/t b/t\n@@ -1 +1 @@\n-a\n+b\n"
        let u1 = GitDiff.untrackedFilePatch(path: "u1", contents: "x\n")
        let u2 = GitDiff.untrackedFilePatch(path: "u2", contents: "y\n")
        let combined = GitDiff.combine(tracked: tracked, untracked: [u1, u2])
        // Tracked block precedes both untracked blocks, in list order.
        let iT = combined.range(of: "a/t b/t")!.lowerBound
        let i1 = combined.range(of: "a/u1 b/u1")!.lowerBound
        let i2 = combined.range(of: "a/u2 b/u2")!.lowerBound
        XCTAssertTrue(iT < i1 && i1 < i2)
        XCTAssertEqual(GitDiff.changedFileCount(in: combined), 3)
    }

    func testCombineSkipsEmptyPieces() {
        let u1 = GitDiff.untrackedFilePatch(path: "u1", contents: "x\n")
        let combined = GitDiff.combine(tracked: "", untracked: [u1])
        XCTAssertTrue(combined.hasPrefix("diff --git a/u1 b/u1"))
        XCTAssertEqual(GitDiff.changedFileCount(in: combined), 1)
    }

    func testJoinPathNormalizesTrailingSlash() {
        XCTAssertEqual(GitDiff.joinPath(cwd: "/repo", relative: "a/b.txt"), "/repo/a/b.txt")
        XCTAssertEqual(GitDiff.joinPath(cwd: "/repo/", relative: "a/b.txt"), "/repo/a/b.txt")
    }

    // MARK: TmuxService.gitDiff — local path runs `git -C <cwd> …` + cat

    private func makeLocalService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: StaticStatusProvider(), tmuxPath: "/usr/bin/tmux")
    }

    func testGitDiffLocalRunsGitAndSynthesizesUntracked() {
        let runner = FakeRunner()
        runner.responses["-C /repo rev-parse --is-inside-work-tree"] = "true\n"
        runner.responses["-C /repo rev-parse --verify -q HEAD"] = "deadbeef\n"
        runner.responses["-C /repo rev-parse --abbrev-ref HEAD"] = "main\n"
        runner.responses["-C /repo --no-pager diff --no-color HEAD"] =
            "diff --git a/tracked.txt b/tracked.txt\n@@ -1 +1 @@\n-old\n+new\n"
        runner.responses["-C /repo ls-files --others --exclude-standard -z"] = "new.txt\u{0}"
        runner.responses["/repo/new.txt"] = "hello\n"

        let result = makeLocalService(runner).gitDiff(cwd: "/repo")

        XCTAssertTrue(result.isRepo)
        XCTAssertFalse(result.isEmptyRepo)
        XCTAssertEqual(result.branch, "main")
        // Tracked diff + synthesized untracked addition both present.
        XCTAssertTrue(result.patch.contains("a/tracked.txt b/tracked.txt"))
        XCTAssertTrue(result.patch.contains("diff --git a/new.txt b/new.txt"))
        XCTAssertTrue(result.patch.contains("+hello"))
        XCTAssertEqual(GitDiff.changedFileCount(in: result.patch), 2)

        // The repo probe ran as a local `git -C /repo …` (path resolves to git).
        let probe = runner.calls.first { $0.args == GitDiff.isRepoArgv(cwd: "/repo") }
        XCTAssertNotNil(probe)
        XCTAssertTrue(probe!.path.hasSuffix("git"))
        // The untracked contents were fetched by cat at the joined absolute path.
        let cat = runner.calls.first { $0.args == ["/repo/new.txt"] }
        XCTAssertNotNil(cat)
        XCTAssertTrue(cat!.path.hasSuffix("cat"))
    }

    func testGitDiffNonRepoReturnsIsRepoFalse() {
        let runner = FakeRunner()
        runner.responses["-C /tmp rev-parse --is-inside-work-tree"] = String?.none  // not a repo
        let result = makeLocalService(runner).gitDiff(cwd: "/tmp")
        XCTAssertFalse(result.isRepo)
        XCTAssertTrue(result.patch.isEmpty)
        // No diff/ls-files calls once the repo probe fails.
        XCTAssertFalse(runner.argSequences.contains { $0.contains("diff") })
        XCTAssertFalse(runner.argSequences.contains { $0.contains("ls-files") })
    }

    func testGitDiffEmptyRepoUsesNoHeadForm() {
        let runner = FakeRunner()
        runner.responses["-C /repo rev-parse --is-inside-work-tree"] = "true\n"
        runner.responses["-C /repo rev-parse --verify -q HEAD"] = String?.none  // no commits → no HEAD
        runner.responses["-C /repo ls-files --others --exclude-standard -z"] = ""
        let result = makeLocalService(runner).gitDiff(cwd: "/repo")
        XCTAssertTrue(result.isRepo)
        XCTAssertTrue(result.isEmptyRepo)
        // The empty-tree diff form ran; the HEAD form did not.
        XCTAssertTrue(runner.argSequences.contains(GitDiff.noHeadDiffArgv(cwd: "/repo")))
        XCTAssertFalse(runner.argSequences.contains(GitDiff.headDiffArgv(cwd: "/repo")))
    }

    // MARK: TmuxService.gitDiff — remote path runs `ssh <opts> <host> git -C <cwd> …`

    private func makeRemoteService(_ runner: FakeRunner, host: String = "buildbox") -> TmuxService {
        TmuxService(
            host: Host(name: host, sshAlias: host),
            transport: SshTmuxTransport(host: host),
            runner: runner,
            statusProvider: StaticStatusProvider())
    }

    func testGitDiffRemoteRoutesGitAndCatThroughSsh() {
        let runner = FakeRunner()
        runner.defaultResponse = "true"  // every probe non-nil → repo, one untracked path
        _ = makeRemoteService(runner).gitDiff(cwd: "/repo")

        // The repo probe went over ssh, quoted token-by-token, ending with the git argv.
        let probe = runner.calls.first {
            $0.path == "/usr/bin/ssh"
                && Array($0.args.suffix(5)) == ["'git'", "'-C'", "'/repo'", "'rev-parse'", "'--is-inside-work-tree'"]
        }
        XCTAssertNotNil(probe)
        XCTAssertTrue(probe!.args.contains("ControlMaster=auto"))
        XCTAssertTrue(probe!.args.contains("buildbox"))
        // Untracked contents were fetched with a remote `cat` over ssh.
        XCTAssertTrue(runner.calls.contains {
            $0.path == "/usr/bin/ssh" && $0.args.contains("'cat'")
        })
    }
}
