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
    // MARK: batched head lookups (one GraphQL document per repo)

    func testHeadsArgvPassesBranchesAsVariablesNotInlined() {
        let argv = GitHubPR.headsArgv(slug: "o/r", branches: ["feat/x", "fix/\"quote"])
        XCTAssertEqual(Array(argv?.prefix(2) ?? []), ["api", "graphql"])
        XCTAssertTrue(argv?.contains("owner=o") ?? false)
        XCTAssertTrue(argv?.contains("name=r") ?? false)
        XCTAssertTrue(argv?.contains("h0=feat/x") ?? false)
        XCTAssertTrue(argv?.contains("h1=fix/\"quote") ?? false)
        let query = argv?.first { $0.hasPrefix("query=") } ?? ""
        // A branch name never reaches the document itself, so no escaping can break it.
        XCTAssertFalse(query.contains("feat/x"))
        XCTAssertTrue(query.contains("h1: pullRequests(headRefName: $h1, states: OPEN"))
        XCTAssertTrue(query.contains("rateLimit"))
    }

    func testHeadsArgvRejectsBadSlugOrNoBranches() {
        XCTAssertNil(GitHubPR.headsArgv(slug: "noslash", branches: ["b"]))
        XCTAssertNil(GitHubPR.headsArgv(slug: "o/r", branches: []))
    }

    func testParseHeadsMapsAliasesBackToBranches() {
        let json = #"""
        {"data":{"rateLimit":{"remaining":4321,"resetAt":"2026-10-15T15:04:02Z"},
         "repository":{
           "h0":{"nodes":[{"number":12,"title":"b","url":"u12","isDraft":true,"state":"OPEN"},
                          {"number":7,"title":"a","url":"u7","isDraft":false,"state":"OPEN"}]},
           "h1":{"nodes":[]}}}}
        """#
        let out = GitHubPR.parseHeads(json: json, branches: ["feat/x", "main"])
        XCTAssertEqual(out?.prsByBranch["feat/x"]?.map(\.number), [7, 12])
        XCTAssertEqual(out?.prsByBranch["feat/x"]?.last?.isDraft, true)
        XCTAssertEqual(out?.prsByBranch["main"], [])
        XCTAssertEqual(out?.rate?.remaining, 4321)
        XCTAssertEqual(out?.rate?.resetAt, ISO8601DateFormatter().date(from: "2026-10-15T15:04:02Z"))
    }

    /// A missing alias or repository is a partial answer; trusting it would blank
    /// that branch's chip, so the whole answer is refused.
    func testParseHeadsRefusesPartialAnswers() {
        XCTAssertNil(GitHubPR.parseHeads(json: "", branches: ["a"]))
        XCTAssertNil(GitHubPR.parseHeads(json: #"{"data":{"repository":null}}"#, branches: ["a"]))
        XCTAssertNil(GitHubPR.parseHeads(
            json: #"{"data":{"repository":{"h0":{"nodes":[]}}}}"#, branches: ["a", "b"]))
    }
}

/// When the sidebar asks GitHub about a repo's branches, and what it keeps.
/// The bug this guards: one `gh pr list` per window cwd every 20s spent ~5,400
/// GraphQL points an hour against a 5,000 budget shared by every tool on the Mac.
final class BranchPRCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func pr(_ n: Int) -> PullRequest {
        PullRequest(number: n, title: "t", url: "u\(n)", isDraft: false)
    }

    func testFirstSightOfARepoIsDue() {
        let cache = BranchPRCache()
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/r", signatures: ["a": "s1"], now: t0))
    }

    /// The fix itself: an unchanged repo is not re-asked on every 20s scan.
    func testUnchangedRepoWaitsForTheRefreshInterval() {
        let cache = BranchPRCache()
        cache.record(host: "local", slug: "o/r", signatures: ["a": "s1"],
                     prs: ["a": [pr(1)]], rate: nil, now: t0)
        for s in stride(from: 20.0, to: BranchPRCache.refreshInterval, by: 20) {
            XCTAssertFalse(cache.isDue(host: "local", slug: "o/r", signatures: ["a": "s1"],
                                       now: t0 + s), "re-asked at +\(s)s")
        }
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/r", signatures: ["a": "s1"],
                                  now: t0 + BranchPRCache.refreshInterval))
        XCTAssertEqual(cache.prs(host: "local", slug: "o/r", branch: "a"), [pr(1)])
    }

    /// A push moves the origin ref. `gh pr create` lands seconds later, so the repo
    /// stays hot (asked every scan) for a while, then cools.
    func testPushMakesTheRepoHotThenItCools() {
        let cache = BranchPRCache()
        cache.record(host: "local", slug: "o/r", signatures: ["a": "s1"],
                     prs: ["a": []], rate: nil, now: t0)
        let pushed = ["a": "s2"]
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/r", signatures: pushed, now: t0 + 30))
        cache.record(host: "local", slug: "o/r", signatures: pushed, prs: ["a": []],
                     rate: nil, now: t0 + 30)
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/r", signatures: pushed, now: t0 + 50))
        let cooled = t0 + 30 + BranchPRCache.hotWindow + 1
        cache.record(host: "local", slug: "o/r", signatures: pushed, prs: ["a": [pr(5)]],
                     rate: nil, now: cooled - 5)
        XCTAssertFalse(cache.isDue(host: "local", slug: "o/r", signatures: pushed, now: cooled))
    }

    /// First sight (app launch, a new window) is asked once, not kept hot: only
    /// a push of a branch already asked about can mean a PR is about to appear.
    func testFirstSightIsAskedOnceNotKeptHot() {
        let cache = BranchPRCache()
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/r", signatures: ["a": "s1"], now: t0))
        cache.record(host: "local", slug: "o/r", signatures: ["a": "s1"],
                     prs: ["a": []], rate: nil, now: t0)
        XCTAssertFalse(cache.isDue(host: "local", slug: "o/r", signatures: ["a": "s1"],
                                   now: t0 + 20))
    }

    func testANewBranchMakesTheRepoDue() {
        let cache = BranchPRCache()
        cache.record(host: "local", slug: "o/r", signatures: ["a": "s1"],
                     prs: ["a": []], rate: nil, now: t0)
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/r",
                                  signatures: ["a": "s1", "b": ""], now: t0 + 20))
    }

    /// Low budget pauses the host until GitHub's reset; other hosts are unaffected.
    func testLowBudgetPausesTheHostUntilReset() {
        let cache = BranchPRCache()
        let reset = t0 + 1800
        cache.record(host: "local", slug: "o/r", signatures: ["a": "s1"], prs: ["a": []],
                     rate: RateReading(remaining: BranchPRCache.reserve - 1, resetAt: reset),
                     now: t0)
        XCTAssertFalse(cache.isDue(host: "local", slug: "o/new", signatures: ["x": "1"],
                                   now: t0 + 60))
        XCTAssertTrue(cache.isDue(host: "devbox", slug: "o/new", signatures: ["x": "1"],
                                  now: t0 + 60))
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/new", signatures: ["x": "1"],
                                  now: reset))
    }

    /// A failed ask (rate limited, no access) keeps the last answer and backs off
    /// for a full interval instead of retrying every scan.
    func testFailureKeepsLastAnswerAndBacksOff() {
        let cache = BranchPRCache()
        cache.record(host: "local", slug: "o/r", signatures: ["a": "s1"],
                     prs: ["a": [pr(1)]], rate: nil, now: t0)
        cache.recordFailure(host: "local", slug: "o/r", signatures: ["a": "s2"], now: t0 + 20)
        XCTAssertEqual(cache.prs(host: "local", slug: "o/r", branch: "a"), [pr(1)])
        XCTAssertFalse(cache.isDue(host: "local", slug: "o/r", signatures: ["a": "s2"],
                                   now: t0 + 40))
        XCTAssertTrue(cache.isDue(host: "local", slug: "o/r", signatures: ["a": "s2"],
                                  now: t0 + 20 + BranchPRCache.refreshInterval))
    }
}
