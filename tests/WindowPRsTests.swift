import XCTest

// WindowPRs.swift + PullRequests.swift + TmuxService.swift are Foundation-only
// and compiled into this test target, so the window-name parser, the slug
// fallback, the chip layout, the identity cache and the service's gh-argv are
// all asserted with no real git/gh spawned.

/// Records every command and replies from a scripted table — same shape as the
/// FakeRunner in GitDiffTests/WorktreesTests (each is file-private, so this
/// target keeps its own copy).
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

private struct WindowPRStaticStatusProvider: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}

// MARK: - Name parsing

final class WindowPRNameParsingTests: XCTestCase {
    private func numbers(_ name: String) -> [Int] { WindowPRs.numbers(inName: name) }

    // The five marker forms named in the bug report, each from a real window on
    // this machine.

    func testBareHash() {
        XCTAssertEqual(numbers("#411"), [411])
    }

    func testPrSpaceNumber() {
        XCTAssertEqual(numbers("monitor PR 410"), [410])
    }

    func testPrHashNumber() {
        XCTAssertEqual(numbers("monitor PR#411"), [411])
    }

    func testPrDashNumber() {
        XCTAssertEqual(numbers("monitor-pr-405"), [405])
    }

    func testPrGluedToNumber() {
        XCTAssertEqual(numbers("pr1026-review-fixes"), [1026])
    }

    func testMultiplePRsInOneName() {
        XCTAssertEqual(numbers("watch PR #393 #394 CI"), [393, 394])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(numbers("PR-405"), [405])
        XCTAssertEqual(numbers("Pr 405"), [405])
        XCTAssertEqual(numbers("pR#405"), [405])
    }

    func testUnderscoreAndColonSeparators() {
        XCTAssertEqual(numbers("pr_405"), [405])
        XCTAssertEqual(numbers("pr:405"), [405])
    }

    func testDedupesRepeatsAndKeepsOrderOfAppearance() {
        XCTAssertEqual(numbers("PR #394 then #393 again #394"), [394, 393])
    }

    func testDisplayIndexPrefixIsNotAPRNumber() {
        // The sidebar shows "17: <name>"; a leading index must never chip.
        XCTAssertEqual(numbers("17: watch PR #393 #394 CI"), [393, 394])
    }

    // MARK: negatives — every one of these is a real window name on this machine

    func testVersionNumberIsNotAPR() {
        XCTAssertEqual(numbers("2.1.238"), [])
    }

    func testBareNumbersWithoutAMarkerAreNotPRs() {
        XCTAssertEqual(numbers("data-17-19-3-pms-vendors"), [])
    }

    func testNamesWithoutDigitsOrMarkers() {
        XCTAssertEqual(numbers("po-delivery-db-diagram"), [])
        XCTAssertEqual(numbers("acme-app-scraper"), [])
        XCTAssertEqual(numbers("worktree-cleanup"), [])
        XCTAssertEqual(numbers("paycom-api-quote"), [])
        XCTAssertEqual(numbers("po-merge-into-parent"), [])
        XCTAssertEqual(numbers("voice-portal-bugfix"), [])
    }

    /// "pr" only counts on a word boundary, which is the whole reason these
    /// don't match.
    func testPrInsideAWordIsNotAMarker() {
        XCTAssertEqual(numbers("expression-42"), [])
        XCTAssertEqual(numbers("sprint-3"), [])
        XCTAssertEqual(numbers("approve-12"), [])
        XCTAssertEqual(numbers("compress 500"), [])
    }

    func testNumberGluedToLettersIsNotAReference() {
        XCTAssertEqual(numbers("#3rd-attempt"), [])
        XCTAssertEqual(numbers("pr12ab"), [])
    }

    func testLeadingZeroAndOversizedRunsRejected() {
        XCTAssertEqual(numbers("#0405"), [])
        XCTAssertEqual(numbers("#1234567"), [])
        XCTAssertEqual(numbers("#123456"), [123456])
    }

    func testMarkerWithNoNumberIsIgnored() {
        XCTAssertEqual(numbers("pr"), [])
        XCTAssertEqual(numbers("pr-review"), [])
        XCTAssertEqual(numbers("#tag"), [])
        XCTAssertEqual(numbers(""), [])
    }

    /// Documented limit: one number per marker. A second bare number needs its
    /// own `#`.
    func testOneNumberPerMarker() {
        XCTAssertEqual(numbers("PR 393 394"), [393])
    }

    // MARK: metadata + name

    func testMetadataNumbersComeBeforeNameNumbers() {
        XCTAssertEqual(
            WindowPRs.declaredNumbers(metadata: [1085], name: "watch PR #393"), [1085, 393])
    }

    func testMetadataAndNameAreDedupedInOrder() {
        XCTAssertEqual(
            WindowPRs.declaredNumbers(metadata: [394, 1085], name: "PR #393 #394"),
            [394, 1085, 393])
    }

    func testEmptyMetadataIsExactlyTheNameNumbers() {
        for name in ["watch PR #393 #394 CI", "pr1026-review-fixes", "2.1.238", ""] {
            XCTAssertEqual(WindowPRs.declaredNumbers(metadata: [], name: name), numbers(name))
        }
    }
}

// MARK: - Slug fallback

final class WindowPRSlugTests: XCTestCase {
    func testWindowSlugWinsWhenPresent() {
        XCTAssertEqual(
            WindowPRs.slugForDeclared(windowSlug: "rebar-code/acme-app",
                                      sessionSlugs: ["rebar-code/other"]),
            "rebar-code/acme-app")
    }

    /// The real case: `monitor-pr-405` runs in `~/code/github/acme-app`, which is
    /// a plain folder of clones, not a checkout — the session's other windows
    /// supply the repo.
    func testFallsBackToTheSessionsOneAgreedSlug() {
        XCTAssertEqual(
            WindowPRs.slugForDeclared(
                windowSlug: nil,
                sessionSlugs: [nil, "rebar-code/acme-app", "rebar-code/acme-app", nil]),
            "rebar-code/acme-app")
    }

    func testNoFallbackWhenTheSessionSpansTwoRepos() {
        XCTAssertNil(WindowPRs.slugForDeclared(
            windowSlug: nil,
            sessionSlugs: ["rebar-code/acme-app", "rebar-code/widget-shop"]))
    }

    /// `@mm_repo` is the agent saying which repo it means — it beats the cwd.
    func testDeclaredRepoWinsOverTheWindowSlug() {
        XCTAssertEqual(
            WindowPRs.slugForDeclared(declaredRepo: "rebar-code/mux-maestro",
                                      windowSlug: "rebar-code/acme-app",
                                      sessionSlugs: ["rebar-code/acme-app"]),
            "rebar-code/mux-maestro")
    }

    func testDeclaredRepoWinsOverTheSessionAgreement() {
        XCTAssertEqual(
            WindowPRs.slugForDeclared(declaredRepo: " o/declared ",
                                      windowSlug: nil,
                                      sessionSlugs: ["o/session", "o/session"]),
            "o/declared")
    }

    func testEmptyOrWhitespaceDeclaredRepoFallsThrough() {
        XCTAssertEqual(
            WindowPRs.slugForDeclared(declaredRepo: "", windowSlug: "o/window", sessionSlugs: []),
            "o/window")
        XCTAssertEqual(
            WindowPRs.slugForDeclared(declaredRepo: "  ", windowSlug: nil,
                                      sessionSlugs: ["o/session"]),
            "o/session")
    }

    func testNoFallbackWhenNothingResolved() {
        XCTAssertNil(WindowPRs.slugForDeclared(windowSlug: nil, sessionSlugs: [nil, nil]))
        XCTAssertNil(WindowPRs.slugForDeclared(windowSlug: "", sessionSlugs: []))
    }
}

// MARK: - Union + chip layout

final class WindowPRMergeTests: XCTestCase {
    private func pr(_ n: Int, _ state: PRState = .open) -> PullRequest {
        PullRequest(number: n, title: "t\(n)", url: "https://github.com/o/r/pull/\(n)",
                    isDraft: false, state: state)
    }

    func testNameDeclaredPRsComeFirst() {
        let out = WindowPRs.merge(declared: [pr(393), pr(394)], branch: [pr(411)])
        XCTAssertEqual(out.map(\.number), [393, 394, 411])
    }

    func testDedupesWhenTheBranchPRIsAlsoNamed() {
        let out = WindowPRs.merge(declared: [pr(411)], branch: [pr(411)])
        XCTAssertEqual(out.map(\.number), [411])
    }

    /// Declared numbers are sticky, so a merged one can sit ahead of the current
    /// open PR. The single chip must go to the open one; order is otherwise kept.
    func testOpenPRsComeBeforeMergedAndClosedStably() {
        let out = WindowPRs.merge(
            declared: [pr(393, .merged), pr(394), pr(395, .closed)],
            branch: [pr(411), pr(393)])
        XCTAssertEqual(out.map(\.number), [394, 411, 393, 395])
    }

    // MARK: allMerged — the row's trash shows without hover

    func testAllMergedWhenTheOnlyPRMerged() {
        XCTAssertTrue(WindowPRs.allMerged([pr(393, .merged)]))
    }

    /// A closed PR beside a merged one is still finished work.
    func testAllMergedIgnoresClosedPRsBesideAMergedOne() {
        XCTAssertTrue(WindowPRs.allMerged([pr(393, .merged), pr(395, .closed)]))
    }

    /// Declared numbers are sticky: a merged PR stays listed after the window
    /// moves on to a new open one. That window is still in use.
    func testNotAllMergedWhileAnyPRIsOpen() {
        XCTAssertFalse(WindowPRs.allMerged([pr(394), pr(393, .merged)]))
    }

    /// Closed without merging means the work did not land.
    func testNotAllMergedForClosedOnlyOrNoPRs() {
        XCTAssertFalse(WindowPRs.allMerged([pr(395, .closed)]))
        XCTAssertFalse(WindowPRs.allMerged([]))
    }

    // MARK: back-fill into @mm_prs

    func testBackfillIsNilWhenEveryOpenPRIsAlreadyDeclared() {
        XCTAssertNil(WindowPRs.backfill(declared: [393, 411], found: [pr(411), pr(393)], readSlug: "o/r"))
    }

    func testBackfillAppendsMissingOpenPRsInFoundOrder() {
        XCTAssertEqual(
            WindowPRs.backfill(declared: [393], found: [pr(393), pr(412), pr(411)], readSlug: "o/r"),
            [393, 412, 411])
    }

    func testBackfillIgnoresUndeclaredMergedAndClosedPRs() {
        XCTAssertNil(WindowPRs.backfill(declared: [], found: [pr(393, .merged), pr(394, .closed)], readSlug: "o/r"))
        XCTAssertEqual(
            WindowPRs.backfill(declared: [], found: [pr(393, .merged), pr(411)], readSlug: "o/r"), [411])
    }

    /// Never removes: a declared PR that merged stays declared.
    func testBackfillKeepsDeclaredMergedNumbers() {
        XCTAssertEqual(
            WindowPRs.backfill(declared: [393], found: [pr(393, .merged), pr(411)], readSlug: "o/r"), [393, 411])
    }

    func testBackfillIsNilForNothingFound() {
        XCTAssertNil(WindowPRs.backfill(declared: [], found: [], readSlug: "o/r"))
        XCTAssertNil(WindowPRs.backfill(declared: [393], found: [], readSlug: "o/r"))
    }

    /// A branch PR from the cwd's repo must not be written under an `@mm_repo`
    /// naming another repo: the number would resolve to a different PR there.
    func testBackfillSkipsPRsOutsideTheRepoNumbersAreReadAgainst() {
        let elsewhere = PullRequest(
            number: 7, title: "x", url: "https://github.com/o/other/pull/7", isDraft: false)
        XCTAssertNil(WindowPRs.backfill(declared: [], found: [elsewhere], readSlug: "o/r"))
        XCTAssertEqual(
            WindowPRs.backfill(declared: [], found: [elsewhere, pr(411)], readSlug: "O/R"), [411])
    }

    func testBackfillWritesNothingWithoutARepo() {
        XCTAssertNil(WindowPRs.backfill(declared: [], found: [pr(411)], readSlug: nil))
    }

    func testBranchOnlyWindowIsUnchanged() {
        XCTAssertEqual(WindowPRs.merge(declared: [], branch: [pr(86)]).map(\.number), [86])
        XCTAssertEqual(WindowPRs.merge(declared: [], branch: []), [])
    }

    /// One spelled-out chip; the rest collapse. Measured against the 220pt
    /// sidebar — two numeric chips clipped each other and the row's name.
    func testChipLayoutCollapsesEverythingAfterTheFirst() {
        let two = WindowPRs.chipLayout([pr(1026), pr(1025)])
        XCTAssertEqual(two.visible.map(\.number), [1026])
        XCTAssertEqual(two.overflow, 1)

        let three = WindowPRs.chipLayout([pr(393), pr(394), pr(411)])
        XCTAssertEqual(three.visible.map(\.number), [393])
        XCTAssertEqual(three.overflow, 2)
    }

    func testChipLayoutPassesShortListsThrough() {
        XCTAssertEqual(WindowPRs.chipLayout([]).visible, [])
        XCTAssertEqual(WindowPRs.chipLayout([]).overflow, 0)
        XCTAssertEqual(WindowPRs.chipLayout([pr(9)]).visible.map(\.number), [9])
        XCTAssertEqual(WindowPRs.chipLayout([pr(9)]).overflow, 0)
    }

    func testStateWords() {
        XCTAssertEqual(pr(1, .open).stateWord, "Open")
        XCTAssertEqual(pr(1, .merged).stateWord, "Merged")
        XCTAssertEqual(pr(1, .closed).stateWord, "Closed")
        XCTAssertEqual(
            PullRequest(number: 1, title: "", url: "u", isDraft: true, state: .open).stateWord,
            "Draft")
        XCTAssertEqual(pr(393, .merged).chipTooltip, "Merged PR #393 · t393")
    }
}

// MARK: - Identity cache

final class PRIdentityCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pr(_ n: Int, _ state: PRState) -> PullRequest {
        PullRequest(number: n, title: "t", url: "u", isDraft: false, state: state)
    }

    func testUnknownNumberNeedsFetch() {
        XCTAssertTrue(PRIdentityCache().needsFetch(slug: "o/r", number: 1, now: t0))
    }

    /// A number that isn't a PR never becomes one — the miss is permanent.
    func testMissIsNeverRefetched() {
        let c = PRIdentityCache()
        c.store(slug: "o/r", number: 9999, pr: nil, now: t0)
        XCTAssertNil(c.pr(slug: "o/r", number: 9999))
        XCTAssertFalse(c.needsFetch(slug: "o/r", number: 9999,
                                    now: t0.addingTimeInterval(86_400)))
    }

    func testMergedAndClosedAreTerminal() {
        let c = PRIdentityCache()
        c.store(slug: "o/r", number: 393, pr: pr(393, .merged), now: t0)
        c.store(slug: "o/r", number: 394, pr: pr(394, .closed), now: t0)
        let later = t0.addingTimeInterval(86_400)
        XCTAssertFalse(c.needsFetch(slug: "o/r", number: 393, now: later))
        XCTAssertFalse(c.needsFetch(slug: "o/r", number: 394, now: later))
        XCTAssertEqual(c.pr(slug: "o/r", number: 393)?.state, .merged)
    }

    /// An open PR can merge, so it goes stale — that's how the chip repaints.
    func testOpenGoesStaleAfterTheTTL() {
        let c = PRIdentityCache()
        c.store(slug: "o/r", number: 411, pr: pr(411, .open), now: t0)
        XCTAssertFalse(c.needsFetch(slug: "o/r", number: 411,
                                    now: t0.addingTimeInterval(PRIdentityCache.openTTL - 1)))
        XCTAssertTrue(c.needsFetch(slug: "o/r", number: 411,
                                   now: t0.addingTimeInterval(PRIdentityCache.openTTL)))
    }

    func testKeyedByRepoNotJustNumber() {
        let c = PRIdentityCache()
        c.store(slug: "o/a", number: 5, pr: pr(5, .merged), now: t0)
        XCTAssertNil(c.pr(slug: "o/b", number: 5))
        XCTAssertTrue(c.needsFetch(slug: "o/b", number: 5, now: t0))
    }
}

// MARK: - gh argv + JSON

final class PullRequestByNumberTests: XCTestCase {
    func testPRViewArgv() {
        XCTAssertEqual(
            GitHubPR.prViewArgv(slug: "rebar-code/acme-app", number: 393),
            ["pr", "view", "393", "-R", "rebar-code/acme-app",
             "--json", "number,title,url,isDraft,state"])
    }

    func testParseOneReadsState() {
        let json = """
        {"isDraft":false,"number":393,"state":"MERGED",
         "title":"feat(competitors): promote LAZ stall counts",
         "url":"https://github.com/rebar-code/acme-app/pull/393"}
        """
        let pr = GitHubPR.parseOne(json: json)
        XCTAssertEqual(pr?.number, 393)
        XCTAssertEqual(pr?.state, .merged)
        XCTAssertEqual(pr?.url, "https://github.com/rebar-code/acme-app/pull/393")
    }

    func testParseOneRejectsGarbageAndIncompleteRows() {
        XCTAssertNil(GitHubPR.parseOne(json: ""))
        XCTAssertNil(GitHubPR.parseOne(json: "not json"))
        XCTAssertNil(GitHubPR.parseOne(json: "[]"))
        XCTAssertNil(GitHubPR.parseOne(json: #"{"number":1,"title":"no url"}"#))
    }

    func testUnknownStateReadsAsOpen() {
        let pr = GitHubPR.parseOne(json: #"{"number":1,"url":"u","state":"WEIRD"}"#)
        XCTAssertEqual(pr?.state, .open)
    }

    func testListParseCarriesState() {
        let json = #"[{"number":410,"url":"u","state":"OPEN","isDraft":false}]"#
        XCTAssertEqual(GitHubPR.parse(json: json).first?.state, .open)
    }
}

/// The service layer's exact git/gh-argv sequence, against a FakeRunner — the
/// pattern from GitDiffTests/WorktreesTests.
final class WindowPRServiceTests: XCTestCase {
    private func service(_ runner: FakeRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: WindowPRStaticStatusProvider(),
                    tmuxPath: "/usr/bin/tmux")
    }

    func testBranchPullRequestsResolvesSlugThenBranchThenLists() {
        let runner = FakeRunner()
        runner.responses["-C /a/repo remote get-url origin"] =
            "git@github.com:rebar-code/acme-app.git\n"
        runner.responses["-C /a/repo rev-parse --abbrev-ref HEAD"] = "feat/x\n"
        runner.responses[
            "pr list -R rebar-code/acme-app --head feat/x --state open"
            + " --json number,title,url,isDraft --limit 20"] =
            #"[{"number":411,"title":"t","url":"u","isDraft":false,"state":"OPEN"}]"#

        let out = service(runner).branchPullRequests(cwd: "/a/repo")
        XCTAssertEqual(out.slug, "rebar-code/acme-app")
        XCTAssertEqual(out.prs.map(\.number), [411])
        XCTAssertEqual(runner.argSequences, [
            ["-C", "/a/repo", "remote", "get-url", "origin"],
            ["-C", "/a/repo", "rev-parse", "--abbrev-ref", "HEAD"],
            ["pr", "list", "-R", "rebar-code/acme-app", "--head", "feat/x", "--state", "open",
             "--json", "number,title,url,isDraft", "--limit", "20"],
        ])
    }

    /// A non-repo cwd (the watcher-window case) stops after one git call and
    /// reports no slug, so the caller knows to fall back to the session's.
    func testBranchPullRequestsStopsWhenCwdIsNotAGitHubRepo() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        let out = service(runner).branchPullRequests(cwd: "/Users/me/code/github/acme-app")
        XCTAssertNil(out.slug)
        XCTAssertEqual(out.prs, [])
        XCTAssertEqual(runner.argSequences.count, 1)
    }

    /// A detached HEAD still yields the slug — the window's name-declared PRs
    /// must stay resolvable.
    func testDetachedHeadStillReportsTheSlug() {
        let runner = FakeRunner()
        runner.responses["-C /a/repo remote get-url origin"] = "https://github.com/o/r"
        runner.responses["-C /a/repo rev-parse --abbrev-ref HEAD"] = "HEAD\n"
        let out = service(runner).branchPullRequests(cwd: "/a/repo")
        XCTAssertEqual(out.slug, "o/r")
        XCTAssertEqual(out.prs, [])
        XCTAssertFalse(runner.argSequences.contains { $0.first == "pr" })
    }

    func testPullRequestByNumberRunsGhPrView() {
        let runner = FakeRunner()
        runner.responses["pr view 393 -R o/r --json number,title,url,isDraft,state"] =
            #"{"number":393,"title":"t","url":"u","isDraft":false,"state":"MERGED"}"#
        let pr = service(runner).pullRequest(slug: "o/r", number: 393)
        XCTAssertEqual(pr?.state, .merged)
        XCTAssertEqual(runner.argSequences, [
            ["pr", "view", "393", "-R", "o/r", "--json", "number,title,url,isDraft,state"],
        ])
    }

    /// gh exits non-zero for a number that isn't a PR; the runner reports nil and
    /// so do we — that is the "don't chip it" answer.
    func testPullRequestByNumberIsNilWhenGhFails() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertNil(service(runner).pullRequest(slug: "o/r", number: 9999))
    }

    func testPullRequestByNumberRejectsEmptySlugWithoutSpawning() {
        let runner = FakeRunner()
        XCTAssertNil(service(runner).pullRequest(slug: "", number: 1))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRepoSlugFromCwd() {
        let runner = FakeRunner()
        runner.responses["-C /a/repo remote get-url origin"] = "git@github.com:o/r.git\n"
        XCTAssertEqual(service(runner).repoSlug(cwd: "/a/repo"), "o/r")
        XCTAssertNil(service(runner).repoSlug(cwd: ""))
    }
}

// MARK: - PRs screen index

final class WindowPRIndexTests: XCTestCase {
    private func pr(_ n: Int, _ repo: String, _ state: PRState = .open) -> PullRequest {
        PullRequest(number: n, title: "t\(n)", url: "https://github.com/\(repo)/pull/\(n)",
                    isDraft: false, state: state)
    }

    func testIndexInvertsWindowsByPR() {
        let idx = WindowPRs.index([
            (window: "w1", prs: [pr(5, "o/r"), pr(9, "o/r", .merged)]),
            (window: "w2", prs: [pr(9, "o/r", .merged)]),
            (window: "w3", prs: []),
        ])
        XCTAssertEqual(idx.map { $0.pr.number }, [5, 9])
        XCTAssertEqual(idx.map { $0.windows }, [["w1"], ["w1", "w2"]])
        XCTAssertEqual(idx.map { $0.slug }, ["o/r", "o/r"])
    }

    func testIndexKeysByURLSoSameNumberInTwoReposStaysApart() {
        let idx = WindowPRs.index([
            (window: "a", prs: [pr(5, "o/s")]),
            (window: "b", prs: [pr(5, "o/r")]),
        ])
        XCTAssertEqual(idx.map { $0.slug }, ["o/r", "o/s"])
        XCTAssertEqual(idx.map { $0.windows }, [["b"], ["a"]])
    }

    func testIndexOrdersOpenFirstThenNewestWithinRepo() {
        let idx = WindowPRs.index([
            (window: "w", prs: [pr(3, "o/r"), pr(12, "o/r", .closed), pr(7, "o/r"), pr(20, "o/r", .merged)]),
        ])
        XCTAssertEqual(idx.map { $0.pr.number }, [7, 3, 20, 12])
    }

    func testIndexKeepsMergedAndClosed() {
        let idx = WindowPRs.index([(window: "w", prs: [pr(1, "o/r", .merged), pr(2, "o/r", .closed)])])
        XCTAssertEqual(idx.count, 2)
    }
}
