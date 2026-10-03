import XCTest

// GitCommit.swift (Foundation-only) is compiled directly into this test target,
// so the porcelain-status parsing + write-op argv construction can be asserted
// without spawning git.
final class GitCommitTests: XCTestCase {
    // MARK: parseStatus

    func testParsesStagedUnstagedUntracked() {
        // "M " staged-modify, " M" unstaged-modify, "??" untracked, "A " added.
        let z = "M \(sp)app/App.swift\0 M\(sp)README.md\0??\(sp)new.txt\0A \(sp)added.swift\0"
        let files = GitCommit.parseStatus(z)
        XCTAssertEqual(files.map(\.path), ["app/App.swift", "README.md", "new.txt", "added.swift"])
        XCTAssertEqual(files.map(\.staged), [true, false, false, true])
        XCTAssertEqual(files[2].isUntracked, true)
        XCTAssertEqual(files.map(\.glyph), ["M", "M", "A", "A"])
    }

    func testRenameConsumesOriginRecord() {
        // A rename record is followed by a NUL-separated origin path we must skip.
        let z = "R \(sp)new/name.swift\0old/name.swift\0 M\(sp)other.swift\0"
        let files = GitCommit.parseStatus(z)
        XCTAssertEqual(files.map(\.path), ["new/name.swift", "other.swift"])
        XCTAssertEqual(files[0].glyph, "R")
        XCTAssertTrue(files[0].staged)
    }

    func testPartiallyStagedCountsAsStaged() {
        let files = GitCommit.parseStatus("MM\(sp)both.swift\0")
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].staged)  // index has changes → staged
    }

    func testDeletion() {
        let files = GitCommit.parseStatus("D \(sp)gone.swift\0")
        XCTAssertEqual(files[0].glyph, "D")
        XCTAssertTrue(files[0].staged)
    }

    func testEmptyAndTrailingRecords() {
        XCTAssertEqual(GitCommit.parseStatus(""), [])
        // Trailing NUL yields an empty record that must be ignored.
        XCTAssertEqual(GitCommit.parseStatus(" M\(sp)a.txt\0").count, 1)
    }

    // MARK: argv builders

    func testStatusArgv() {
        XCTAssertEqual(GitCommit.statusArgv(cwd: "/r"),
                       ["-C", "/r", "status", "--porcelain=v1", "-z", "--untracked-files=all"])
    }

    func testAddAndUnstageArgv() {
        XCTAssertEqual(GitCommit.addArgv(cwd: "/r", path: "a b.txt"),
                       ["-C", "/r", "add", "--", "a b.txt"])
        XCTAssertEqual(GitCommit.unstageArgv(cwd: "/r", path: "a b.txt"),
                       ["-C", "/r", "reset", "-q", "HEAD", "--", "a b.txt"])
    }

    func testCommitArgvSubjectOnly() {
        XCTAssertEqual(GitCommit.commitArgv(cwd: "/r", subject: "fix: x", body: "  "),
                       ["-C", "/r", "commit", "-m", "fix: x"])
    }

    func testCommitArgvWithBody() {
        XCTAssertEqual(GitCommit.commitArgv(cwd: "/r", subject: "feat: y", body: "why\ndetails"),
                       ["-C", "/r", "commit", "-m", "feat: y", "-m", "why\ndetails"])
    }

    func testPushArgv() {
        XCTAssertEqual(GitCommit.pushArgv(cwd: "/r", branch: "feat/x", setUpstream: false),
                       ["-C", "/r", "push"])
        XCTAssertEqual(GitCommit.pushArgv(cwd: "/r", branch: "feat/x", setUpstream: true),
                       ["-C", "/r", "push", "-u", "origin", "feat/x"])
    }

    func testUpstreamArgv() {
        XCTAssertEqual(GitCommit.upstreamArgv(cwd: "/r"),
                       ["-C", "/r", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    }

    func testPRCreateArgv() {
        XCTAssertEqual(
            GitHubPR.prCreateArgv(slug: "o/r", branch: "feat/x", title: "T", body: "B"),
            ["pr", "create", "-R", "o/r", "--head", "feat/x", "--title", "T", "--body", "B"])
    }

    /// A space constant keeps the porcelain "XY<space>path" records readable above.
    private let sp = " "
}
