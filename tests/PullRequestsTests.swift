import XCTest

// PullRequests.swift (Foundation-only) is compiled directly into this test
// target, so the pure slug/JSON parsing + gh argv construction can be asserted
// without spawning git or gh.
final class PullRequestsTests: XCTestCase {
    // MARK: slug(fromRemoteURL:)

    func testSlugFromScpStyleRemote() {
        XCTAssertEqual(GitHubPR.slug(fromRemoteURL: "git@github.com:rebar-code/my-site.git"),
                       "rebar-code/my-site")
    }

    func testSlugFromHttpsRemote() {
        XCTAssertEqual(GitHubPR.slug(fromRemoteURL: "https://github.com/rebar-code/mux-maestro.git"),
                       "rebar-code/mux-maestro")
    }

    func testSlugFromHttpsRemoteWithoutDotGit() {
        XCTAssertEqual(GitHubPR.slug(fromRemoteURL: "https://github.com/owner/repo"),
                       "owner/repo")
    }

    func testSlugFromSshSchemeRemote() {
        XCTAssertEqual(GitHubPR.slug(fromRemoteURL: "ssh://git@github.com/owner/repo.git"),
                       "owner/repo")
    }

    func testSlugTrimsWhitespace() {
        XCTAssertEqual(GitHubPR.slug(fromRemoteURL: "  git@github.com:o/r.git\n"), "o/r")
    }

    func testSlugRejectsNonGitHub() {
        XCTAssertNil(GitHubPR.slug(fromRemoteURL: "git@gitlab.com:owner/repo.git"))
        XCTAssertNil(GitHubPR.slug(fromRemoteURL: "https://bitbucket.org/owner/repo.git"))
    }

    func testSlugRejectsGarbage() {
        XCTAssertNil(GitHubPR.slug(fromRemoteURL: ""))
        XCTAssertNil(GitHubPR.slug(fromRemoteURL: "github.com/onlyowner"))
    }

    // MARK: parse(json:)

    func testParseValidPayloadSortsByNumber() {
        let json = """
        [{"number":240,"title":"Contact sheet","url":"https://github.com/x/y/pull/240","isDraft":false},
         {"number":12,"title":"Earlier","url":"https://github.com/x/y/pull/12","isDraft":true}]
        """
        let prs = GitHubPR.parse(json: json)
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[0].number, 12)
        XCTAssertTrue(prs[0].isDraft)
        XCTAssertEqual(prs[1].number, 240)
        XCTAssertEqual(prs[1].title, "Contact sheet")
        XCTAssertEqual(prs[1].url, "https://github.com/x/y/pull/240")
    }

    func testParseEmptyArray() {
        XCTAssertEqual(GitHubPR.parse(json: "[]"), [])
    }

    func testParseInvalidJSON() {
        XCTAssertEqual(GitHubPR.parse(json: "not json"), [])
        XCTAssertEqual(GitHubPR.parse(json: ""), [])
    }

    func testParseSkipsRowsMissingRequiredFields() {
        // Missing url → skipped; the valid row survives.
        let json = """
        [{"number":1,"title":"no url","isDraft":false},
         {"number":2,"title":"ok","url":"https://github.com/x/y/pull/2","isDraft":false}]
        """
        let prs = GitHubPR.parse(json: json)
        XCTAssertEqual(prs.map(\.number), [2])
    }

    // MARK: argv builders

    func testBranchAndRemoteArgv() {
        XCTAssertEqual(GitHubPR.branchArgv(cwd: "/repo"),
                       ["-C", "/repo", "rev-parse", "--abbrev-ref", "HEAD"])
        XCTAssertEqual(GitHubPR.remoteArgv(cwd: "/repo"),
                       ["-C", "/repo", "remote", "get-url", "origin"])
    }

    func testPRListArgv() {
        XCTAssertEqual(
            GitHubPR.prListArgv(slug: "o/r", branch: "feat/x"),
            ["pr", "list", "-R", "o/r", "--head", "feat/x", "--state", "open",
             "--json", "number,title,url,isDraft", "--limit", "20"])
    }
}
