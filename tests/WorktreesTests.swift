import XCTest

// Worktrees.swift + TmuxService.swift are Foundation-only and compiled into this
// test target, so the classifier, the two rules the 2026-08-19 sweep taught us
// (ignore supabase/config.toml; decide unique commits by patch content), the
// orphan matcher, and the service's git-argv sequence are all asserted with no
// real git spawned.

/// Records every command and replies from a scripted table — same shape as the
/// FakeRunner in GitDiffTests/TmuxServiceTests (each is file-private, so this
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

final class WorktreesClassifyTests: XCTestCase {
    private let home = "/Users/me"

    /// The main checkout: `--git-dir` and `--git-common-dir` are the same path.
    /// Verified by hand on this machine against `mux-maestro`.
    func testMainCheckoutWhenGitDirEqualsCommonDir() {
        let dir = "/Users/me/code/github/mux-maestro/.git"
        XCTAssertEqual(
            Worktrees.classify(
                gitDir: dir, commonDir: dir,
                path: "/Users/me/code/github/mux-maestro", home: home),
            .main)
    }

    /// git prints a trailing newline; equality must survive it.
    func testTrailingNewlineDoesNotMakeAMainCheckoutLookLinked() {
        XCTAssertEqual(
            Worktrees.classify(
                gitDir: "/a/repo/.git\n", commonDir: "/a/repo/.git",
                path: "/a/repo", home: home),
            .main)
    }

    /// A leased pool tree: linked, and under `~/.treehouse/`.
    func testTreehouseLeaseIsPool() {
        XCTAssertEqual(
            Worktrees.classify(
                gitDir: "/a/repo/.git/worktrees/5",
                commonDir: "/a/repo/.git",
                path: "/Users/me/.treehouse/acme-app/5/acme-app", home: home),
            .pool)
    }

    /// Decision 1: "unmanaged" is ANY linked worktree outside the pool, not only
    /// trees under a `.worktrees/` directory.
    func testWorktreesDirectoryTreeIsUnmanaged() {
        XCTAssertEqual(
            Worktrees.classify(
                gitDir: "/a/acme-app/.git/worktrees/job-runner-hardening",
                commonDir: "/a/acme-app/.git",
                path: "/Users/me/code/github/acme-app/.worktrees/job-runner-hardening",
                home: home),
            .unmanaged)
    }

    /// The case the issue's narrower rule missed: this repo has 10+ linked
    /// worktrees that are plain siblings of the checkout. They must badge.
    func testPlainSiblingWorktreeIsUnmanaged() {
        XCTAssertEqual(
            Worktrees.classify(
                gitDir: "/a/mux-maestro/.git/worktrees/hdr",
                commonDir: "/a/mux-maestro/.git",
                path: "/Users/me/code/github/mux-maestro-hdr", home: home),
            .unmanaged)
    }

    /// Not a repo at all: git failed, both probes came back empty.
    func testNonRepoPathClassifiesAsNil() {
        XCTAssertNil(
            Worktrees.classify(gitDir: "", commonDir: "", path: "/tmp/scratch", home: home))
        XCTAssertNil(
            Worktrees.classify(
                gitDir: "/a/repo/.git", commonDir: "", path: "/tmp/scratch", home: home))
    }

    /// Path-boundary awareness at the pool root: `~/.treehouse-old` is not the pool.
    func testAdjacentDirectoryIsNotThePool() {
        XCTAssertEqual(
            Worktrees.linkedKind(path: "/Users/me/.treehouse-old/x", home: home), .unmanaged)
        XCTAssertEqual(
            Worktrees.linkedKind(path: "/Users/me/.treehouse/x", home: home), .pool)
    }
}

final class WorktreesParseTests: XCTestCase {
    private let home = "/Users/me"

    private let porcelain = """
    worktree /Users/me/code/github/mux-maestro
    HEAD 0fe9e87aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    branch refs/heads/main

    worktree /Users/me/code/github/mux-maestro-hdr
    HEAD c17b19daaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    branch refs/heads/feat/hdr

    worktree /Users/me/.treehouse/mux-maestro/5/mux-maestro
    HEAD f9a2a32aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    detached

    """

    func testFirstRecordIsTheMainCheckout() {
        let list = Worktrees.parseList(porcelain: porcelain, home: home)
        XCTAssertEqual(list.count, 3)
        XCTAssertTrue(list[0].isMain)
        XCTAssertEqual(list[0].kind, .main)
        XCTAssertEqual(list[0].branch, "main")
        XCTAssertFalse(list[1].isMain)
    }

    func testBranchRefIsShortened() {
        let list = Worktrees.parseList(porcelain: porcelain, home: home)
        XCTAssertEqual(list[1].branch, "feat/hdr")
    }

    func testDetachedWorktreeHasEmptyBranch() {
        let list = Worktrees.parseList(porcelain: porcelain, home: home)
        XCTAssertEqual(list[2].branch, "")
    }

    func testLinkedEntriesCarryTheirKind() {
        let list = Worktrees.parseList(porcelain: porcelain, home: home)
        XCTAssertEqual(list[1].kind, .unmanaged)
        XCTAssertEqual(list[2].kind, .pool)
    }

    /// Porcelain (not the columnar default) is used precisely so a path with a
    /// space survives — the columnar form is ambiguous.
    func testPathWithSpacesSurvives() {
        let out = """
        worktree /Users/me/My Code/repo
        HEAD aaaa

        """
        let list = Worktrees.parseList(porcelain: out, home: home)
        XCTAssertEqual(list.map(\.path), ["/Users/me/My Code/repo"])
    }

    func testNameIsTheDirectoryName() {
        let list = Worktrees.parseList(porcelain: porcelain, home: home)
        XCTAssertEqual(list[1].name, "mux-maestro-hdr")
    }

    /// A registration whose directory is gone. It is bookkeeping, not a tree on
    /// disk, and counting it inflates the pile with entries `git worktree prune`
    /// would clear.
    func testPrunableEntryIsMarked() {
        let out = """
        worktree /a/repo
        branch refs/heads/main

        worktree /a/repo-gone
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        """
        let list = Worktrees.parseList(porcelain: out, home: "/Users/me")
        XCTAssertFalse(list[0].isPrunable)
        XCTAssertTrue(list[1].isPrunable)
    }

    func testPrunableEntriesAreNotOrphans() {
        let out = """
        worktree /a/repo
        branch refs/heads/main

        worktree /a/repo-gone
        prunable gitdir file points to non-existent location

        """
        let list = Worktrees.parseList(porcelain: out, home: "/Users/me")
        XCTAssertTrue(Worktrees.orphans(worktrees: list, sessionCwds: []).isEmpty)
    }

    func testEmptyOutputYieldsNoEntries() {
        XCTAssertTrue(Worktrees.parseList(porcelain: "", home: home).isEmpty)
    }
}

final class WorktreesDirtyTests: XCTestCase {
    /// Records are NUL-separated ("XY <path>"), matching `GitCommit.statusArgv`.
    private func z(_ records: [String]) -> String {
        records.map { $0 + "\u{0}" }.joined()
    }

    /// THE rule from the incident: `worktree-supabase.sh` rewrites
    /// `supabase/config.toml` in every worktree by design. Counting it is the gate
    /// that made `treehouse-tidy` exit 0 for 11 nights and release nothing.
    func testConfigTomlAloneIsNotDirty() {
        XCTAssertFalse(Worktrees.isDirty(porcelain: z([" M supabase/config.toml"])))
    }

    func testConfigTomlPlusRealWorkIsDirty() {
        XCTAssertTrue(Worktrees.isDirty(
            porcelain: z([" M supabase/config.toml", " M src/app.ts"])))
    }

    func testCleanTreeIsNotDirty() {
        XCTAssertFalse(Worktrees.isDirty(porcelain: ""))
    }

    /// The 93 uncommitted lines the sweep found were in tracked files; untracked
    /// files count too (`--untracked-files=all` is in the argv).
    func testUntrackedFileIsDirty() {
        XCTAssertTrue(Worktrees.isDirty(porcelain: z(["?? notes.md"])))
    }

    /// A path that merely ends in the ignored name is still real work.
    func testSimilarlyNamedPathIsStillDirty() {
        XCTAssertTrue(Worktrees.isDirty(porcelain: z([" M apps/web/supabase/config.toml"])))
    }
}

final class WorktreesCherryTests: XCTestCase {
    /// `+` = no equivalent patch upstream. This is the "don't delete this" signal.
    func testPlusLineMeansUniqueCommits() {
        XCTAssertTrue(Worktrees.hasUniqueCommits(cherryOutput: "+ abc123 add adapter\n"))
    }

    /// `-` = already applied upstream under a different sha (squash/rebase). Six
    /// branches with a MERGED PR still held `+` commits on 2026-08-19, and 27
    /// already-merged commits looked unpushed — patch content is the only signal
    /// that told the truth in both directions.
    func testOnlyMinusLinesMeanNoUniqueCommits() {
        XCTAssertFalse(Worktrees.hasUniqueCommits(
            cherryOutput: "- abc123 merged one\n- def456 merged two\n"))
    }

    func testMixedOutputMeansUniqueCommits() {
        XCTAssertTrue(Worktrees.hasUniqueCommits(cherryOutput: "- abc123 old\n+ def456 new\n"))
    }

    func testEmptyOutputMeansNoUniqueCommits() {
        XCTAssertFalse(Worktrees.hasUniqueCommits(cherryOutput: ""))
    }

    /// THE bug this cross-check exists for. `git cherry` emits one line per
    /// NON-MERGE commit and is silent on merges, so a branch ahead only by a merge
    /// produces empty output — which read as "nothing unique, safe to delete".
    /// Reproduced on a scratch repo: `feature` merges `main`, is 1 commit ahead,
    /// and `git cherry main HEAD` prints nothing at all.
    ///
    /// This project integrates with merge and never rebases, so that is the normal
    /// shape of a long-lived branch, not a corner case.
    func testMergeOnlyAheadIsUnaccountedForByCherry() {
        XCTAssertEqual(Worktrees.unaccountedCommits(aheadCount: 1, cherryOutput: ""), 1)
        XCTAssertFalse(Worktrees.hasUniqueCommits(cherryOutput: ""))
    }

    /// A consistent tree: every commit ahead is a non-merge commit cherry listed.
    /// Nothing unaccounted for, so cherry's verdict stands.
    func testCherryAccountingForAllNonMergeCommits() {
        let out = "- abc123 already upstream\n- def456 already upstream\n"
        XCTAssertEqual(Worktrees.unaccountedCommits(aheadCount: 2, cherryOutput: out), 0)
    }

    /// `-` lines explain commits ahead just as well as `+` lines do — they are
    /// commits already applied upstream under a different sha. A shortfall must
    /// mean merges, not merely "more ahead than `+` lines".
    func testMinusLinesCountTowardTheAccounting() {
        let out = "+ aaa new work\n- bbb already upstream\n- ccc already upstream\n"
        XCTAssertEqual(Worktrees.cherryLineCount(cherryOutput: out), 3)
        XCTAssertEqual(Worktrees.unaccountedCommits(aheadCount: 3, cherryOutput: out), 0)
        XCTAssertEqual(Worktrees.unaccountedCommits(aheadCount: 5, cherryOutput: out), 2)
    }

    func testAheadCountNeverGoesNegative() {
        XCTAssertEqual(Worktrees.unaccountedCommits(aheadCount: 0, cherryOutput: "+ a\n"), 0)
    }

    /// Unparseable output must reach the caller as nil so it degrades to
    /// `.unknown`. Reading it as 0 would silently mean "nothing ahead".
    func testParseAheadCountRejectsGarbage() {
        XCTAssertEqual(Worktrees.parseAheadCount("3\n"), 3)
        XCTAssertEqual(Worktrees.parseAheadCount("0"), 0)
        XCTAssertNil(Worktrees.parseAheadCount(""))
        XCTAssertNil(Worktrees.parseAheadCount("fatal: bad revision"))
    }

    /// Deleted branches leave their remote-tracking refs behind, and the tree then
    /// reads as ahead of work that already shipped — `.worktrees/ai-chat` looked 17
    /// commits ahead when all 17 patches were in prod.
    func testFetchPrunesDeletedRemoteBranches() {
        XCTAssertEqual(Worktrees.fetchArgv(cwd: "/a/wt"),
                       ["-C", "/a/wt", "fetch", "--quiet", "--prune", "origin"])
    }

    func testAheadCountArgv() {
        XCTAssertEqual(Worktrees.aheadCountArgv(cwd: "/a/wt", base: "origin/main"),
                       ["-C", "/a/wt", "rev-list", "--count", "origin/main..HEAD"])
    }

    func testDefaultBranchParsesAndRejectsEmpty() {
        XCTAssertEqual(Worktrees.parseDefaultBranch("origin/main\n"), "origin/main")
        XCTAssertNil(Worktrees.parseDefaultBranch("\n"))
    }
}

final class WorktreesOrphanTests: XCTestCase {
    private func entry(_ path: String, isMain: Bool = false) -> WorktreeEntry {
        WorktreeEntry(path: path, branch: "b", isMain: isMain,
                      kind: isMain ? .main : .unmanaged)
    }

    /// The whole point: a worktree outlives the window that made it.
    func testWorktreeWithNoSessionIsAnOrphan() {
        let out = Worktrees.orphans(
            worktrees: [entry("/a/repo", isMain: true), entry("/a/repo-hdr")],
            sessionCwds: ["/a/repo"])
        XCTAssertEqual(out.map(\.path), ["/a/repo-hdr"])
    }

    func testSessionInsideAWorktreeClearsIt() {
        let out = Worktrees.orphans(
            worktrees: [entry("/a/repo-hdr")], sessionCwds: ["/a/repo-hdr"])
        XCTAssertTrue(out.isEmpty)
    }

    /// A session deep inside the tree still counts as watching it.
    func testSessionInASubdirectoryClearsTheWorktree() {
        let out = Worktrees.orphans(
            worktrees: [entry("/a/repo-hdr")], sessionCwds: ["/a/repo-hdr/src/app"])
        XCTAssertTrue(out.isEmpty)
    }

    /// Path-boundary matching: `/a/foobar` must not absorb a worktree at `/a/foo`.
    func testAdjacentPathDoesNotAbsorbTheWorktree() {
        let out = Worktrees.orphans(worktrees: [entry("/a/foo")], sessionCwds: ["/a/foobar"])
        XCTAssertEqual(out.map(\.path), ["/a/foo"])
    }

    /// A repo you aren't working in right now is not a leak.
    func testMainCheckoutIsNeverAnOrphan() {
        let out = Worktrees.orphans(worktrees: [entry("/a/repo", isMain: true)], sessionCwds: [])
        XCTAssertTrue(out.isEmpty)
    }

    func testEmptyCwdMatchesNothing() {
        XCTAssertFalse(Worktrees.isInside(path: "", root: "/a/foo"))
        XCTAssertFalse(Worktrees.isInside(path: "/a/foo", root: ""))
    }
}

final class WorktreeBadgeTests: XCTestCase {
    /// A main checkout is the overwhelmingly common case; it gets no chip at all.
    func testMainCheckoutHasNoBadge() {
        XCTAssertNil(WorktreeBadge(kind: .main, work: .unique))
    }

    func testLabelsNameTheKind() {
        XCTAssertEqual(WorktreeBadge(kind: .pool, work: .none)?.label, "pool")
        XCTAssertEqual(WorktreeBadge(kind: .unmanaged, work: .none)?.label, "worktree")
    }

    /// The `·work` suffix is the state that matters — it is what made 46 deletions
    /// safe and 5 not.
    func testUniqueWorkIsMarkedAndAlerts() {
        let badge = WorktreeBadge(kind: .unmanaged, work: .unique)
        XCTAssertEqual(badge?.label, "worktree ·work")
        XCTAssertEqual(badge?.isAlert, true)
    }

    /// The row chip is compact — the sidebar is ~220pt wide — so the kind word
    /// lives in the tooltip and only the alarm reaches the chip.
    func testChipTextIsCompact() {
        XCTAssertEqual(WorktreeBadge(kind: .unmanaged, work: WorktreeWork.none)?.chipText, "⑂")
        XCTAssertEqual(WorktreeBadge(kind: .pool, work: .unique)?.chipText, "⑂ work")
    }

    /// Degrades to "not computed yet", never to a wrong claim of "safe to delete".
    func testUnknownWorkNeitherMarksNorAlerts() {
        let badge = WorktreeBadge(kind: .pool, work: .unknown)
        XCTAssertEqual(badge?.label, "pool")
        XCTAssertEqual(badge?.isAlert, false)
        XCTAssertTrue(badge?.tooltip.contains("not checked yet") ?? false)
    }
}

/// The sweep's cadence, asserted against an injected clock — no timers, no I/O.
/// It reuses `RemoteScanScheduler` (a keyed "when is this due again" clock with
/// geometric backoff — nothing about it is remote-specific) with the worktree
/// policy, rather than carrying a second copy of the same logic.
final class WorktreeSectionCountTests: XCTestCase {
    private func row(_ path: String, work: WorktreeWork) -> (WorktreeEntry, WorktreeWork) {
        (WorktreeEntry(path: path, branch: "b", isMain: false, kind: .unmanaged), work)
    }

    /// The collapsed header has to carry the number that decides whether opening
    /// the section is worth it: how many orphans can't simply be deleted.
    /// `.unknown` is not counted — it means "not computed", not "holds work".
    func testWorkCountCountsOnlyUniqueRows() {
        let rows = [
            row("/a/1", work: .unique),
            row("/a/2", work: WorktreeWork.none),
            row("/a/3", work: .unknown),
            row("/a/4", work: .unique),
        ]
        XCTAssertEqual(rows.filter { $0.1 == .unique }.count, 2)
    }
}

final class WorktreeScanCadenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func scheduler() -> RemoteScanScheduler {
        RemoteScanScheduler(policy: .init(
            baseInterval: Worktrees.scanBaseInterval, maxInterval: Worktrees.scanMaxInterval))
    }

    func testNeverSweptRepoIsDueImmediately() {
        XCTAssertTrue(scheduler().isDue("/a/repo/.git", now: t0))
    }

    /// 10 minutes between sweeps of a repo — this path runs `git fetch`, so it is
    /// real network I/O and must not ride the 1.5s poll.
    func testSuccessDefersByTenMinutes() {
        let s = scheduler()
        s.recordSuccess("/a/repo/.git", now: t0)
        XCTAssertFalse(s.isDue("/a/repo/.git", now: t0.addingTimeInterval(599)))
        XCTAssertTrue(s.isDue("/a/repo/.git", now: t0.addingTimeInterval(600)))
    }

    func testInFlightRepoIsNotSweptTwice() {
        let s = scheduler()
        s.begin("/a/repo/.git")
        XCTAssertFalse(s.isDue("/a/repo/.git", now: t0))
    }

    func testRepeatedGitFailuresBackOffToTheCeiling() {
        let s = scheduler()
        var now = t0
        for expected in [600.0, 1200.0, 2400.0, 3600.0, 3600.0] {
            s.recordFailure("/a/broken/.git", now: now)
            XCTAssertEqual(s.nextDue("/a/broken/.git"), now.addingTimeInterval(expected))
            now = now.addingTimeInterval(expected)
        }
    }

    func testRetainDropsReposWithNoSessionsLeft() {
        let s = scheduler()
        s.recordSuccess("/a/repo/.git", now: t0)
        s.recordSuccess("/a/gone/.git", now: t0)
        s.retain(["/a/repo/.git"])
        XCTAssertNil(s.nextDue("/a/gone/.git"))
    }
}

/// The service layer's exact git-argv sequence, against a FakeRunner — the
/// pattern from GitDiffTests.
final class WorktreeServiceTests: XCTestCase {
    private func service(_ runner: FakeRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: WorktreeStaticStatusProvider(),
                    tmuxPath: "/usr/bin/tmux")
    }

    func testWorktreeInfoRunsBothRevParseProbes() {
        let runner = FakeRunner()
        runner.responses["-C /a/repo rev-parse --path-format=absolute --git-dir"] = "/a/repo/.git\n"
        runner.responses["-C /a/repo rev-parse --path-format=absolute --git-common-dir"] =
            "/a/repo/.git\n"
        let info = service(runner).worktreeInfo(cwd: "/a/repo")
        XCTAssertEqual(info?.kind, .main)
        XCTAssertEqual(info?.commonDir, "/a/repo/.git")
        XCTAssertEqual(runner.argSequences, [
            ["-C", "/a/repo", "rev-parse", "--path-format=absolute", "--git-dir"],
            ["-C", "/a/repo", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        ])
    }

    func testWorktreeInfoReportsNilWhenGitFails() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertNil(service(runner).worktreeInfo(cwd: "/tmp/scratch"))
    }

    /// A dirty tree short-circuits: no fetch base lookup, no cherry.
    func testDirtyTreeReportsUniqueWithoutRunningCherry() {
        let runner = FakeRunner()
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] =
            " M src/app.ts\u{0}"
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), .unique)
        XCTAssertFalse(runner.argSequences.contains { $0.contains("cherry") })
    }

    /// `supabase/config.toml` alone must not trip the dirty gate — the run falls
    /// through to the cherry check, which is clean here.
    func testConfigTomlOnlyFallsThroughToCherry() {
        let runner = FakeRunner()
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] =
            " M supabase/config.toml\u{0}"
        runner.responses["-C /a/wt symbolic-ref --quiet --short refs/remotes/origin/HEAD"] =
            "origin/main\n"
        runner.responses["-C /a/wt cherry origin/main"] = ""
        runner.responses["-C /a/wt rev-list --count origin/main..HEAD"] = "0\n"
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), WorktreeWork.none)
        XCTAssertTrue(runner.argSequences.contains(["-C", "/a/wt", "cherry", "origin/main"]))
    }

    func testUnpushedCommitsReportUnique() {
        let runner = FakeRunner()
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] = ""
        runner.responses["-C /a/wt symbolic-ref --quiet --short refs/remotes/origin/HEAD"] =
            "origin/main\n"
        runner.responses["-C /a/wt cherry origin/main"] = "+ abc123 unfinished adapter\n"
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), .unique)
    }

    /// origin/HEAD unset → probe the fallbacks in order, and use the first that
    /// resolves.
    /// End to end through the service: cherry silent, but the tree is 1 commit
    /// ahead. That commit is a merge, and a merge can carry work found nowhere
    /// else, so this must NOT report `.none`.
    func testMergeOnlyAheadReportsUniqueNotNone() {
        let runner = FakeRunner()
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] = ""
        runner.responses["-C /a/wt symbolic-ref --quiet --short refs/remotes/origin/HEAD"] =
            "origin/main\n"
        runner.responses["-C /a/wt cherry origin/main"] = ""
        runner.responses["-C /a/wt rev-list --count origin/main..HEAD"] = "1\n"
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), .unique)
    }

    /// The genuinely clean case still reports `.none`, or the section cries wolf
    /// on every tree and gets ignored.
    func testTrulyCleanTreeStillReportsNone() {
        let runner = FakeRunner()
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] = ""
        runner.responses["-C /a/wt symbolic-ref --quiet --short refs/remotes/origin/HEAD"] =
            "origin/main\n"
        runner.responses["-C /a/wt cherry origin/main"] = ""
        runner.responses["-C /a/wt rev-list --count origin/main..HEAD"] = "0\n"
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), WorktreeWork.none)
    }

    /// A failed count must degrade to `.unknown`, never to `.none`.
    func testFailedAheadCountReportsUnknown() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] = ""
        runner.responses["-C /a/wt symbolic-ref --quiet --short refs/remotes/origin/HEAD"] =
            "origin/main\n"
        runner.responses["-C /a/wt cherry origin/main"] = ""
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), .unknown)
    }

    func testFallsBackToOriginMainWhenOriginHeadIsUnset() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] = ""
        runner.responses["-C /a/wt rev-parse --verify -q origin/main^{commit}"] = "abc123\n"
        runner.responses["-C /a/wt cherry origin/main"] = "+ abc123 work\n"
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), .unique)
    }

    /// No resolvable base → `.unknown`, never `.none`. A missing signal must never
    /// read as "safe to delete".
    func testUnresolvableBaseReportsUnknown() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        runner.responses["-C /a/wt status --porcelain=v1 -z --untracked-files=all"] = ""
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), .unknown)
    }

    func testStatusFailureReportsUnknown() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertEqual(service(runner).worktreeWork(cwd: "/a/wt"), .unknown)
    }

    func testWorktreesUsesPorcelainListing() {
        let runner = FakeRunner()
        runner.responses["-C /a/repo worktree list --porcelain"] = """
        worktree /a/repo
        branch refs/heads/main

        """
        let list = service(runner).worktrees(cwd: "/a/repo")
        XCTAssertEqual(list.map(\.path), ["/a/repo"])
        XCTAssertEqual(runner.argSequences,
                       [["-C", "/a/repo", "worktree", "list", "--porcelain"]])
    }

    func testFetchOriginArgv() {
        let runner = FakeRunner()
        XCTAssertTrue(service(runner).fetchOrigin(cwd: "/a/repo"))
        XCTAssertEqual(runner.argSequences,
                       [["-C", "/a/repo", "fetch", "--quiet", "--prune", "origin"]])
    }
}

/// The close dialog's "Also clean up worktree" checkbox: when it is offered, the
/// spindown command it runs, and how spindown's `--json` report becomes a toast.
final class WorktreesCleanupTests: XCTestCase {
    private let wt = "/Users/me/.treehouse/mux-maestro-7d8fda/4/mux-maestro"
    private let main = "/Users/me/code/github/mux-maestro"

    /// A fake filesystem: directory → what its `.git` is.
    private func fs(_ entries: [String: Worktrees.DotGit]) -> (String) -> Worktrees.DotGit? {
        { entries[$0] }
    }

    private var tree: (String) -> Worktrees.DotGit? {
        fs([
            wt: .file("gitdir: /Users/me/code/github/mux-maestro/.git/worktrees/mux-maestro4\n"),
            main: .directory,
            main + "/vendor/sub": .file("gitdir: ../../.git/modules/sub\n"),
        ])
    }

    func testLinkedWorktreeRootFoundFromNestedCwd() {
        XCTAssertEqual(Worktrees.linkedWorktreeRoot(of: wt + "/app/MuxMaestro", dotGit: tree), wt)
        XCTAssertEqual(Worktrees.linkedWorktreeRoot(of: wt + "/", dotGit: tree), wt)
    }

    func testMainCheckoutIsNeverOffered() {
        XCTAssertNil(Worktrees.linkedWorktreeRoot(of: main + "/app", dotGit: tree))
    }

    /// A submodule's `.git` file points into `modules/`, not `worktrees/`, and the
    /// walk stops there rather than climbing past it to the main checkout.
    func testSubmoduleIsNotALinkedWorktree() {
        XCTAssertNil(Worktrees.linkedWorktreeRoot(of: main + "/vendor/sub/src", dotGit: tree))
    }

    func testOutsideAnyRepoOrEmptyCwdIsNil() {
        XCTAssertNil(Worktrees.linkedWorktreeRoot(of: "/tmp/scratch", dotGit: tree))
        XCTAssertNil(Worktrees.linkedWorktreeRoot(of: "", dotGit: tree))
    }

    /// git 2.48's `worktree.useRelativePaths` writes a relative gitdir.
    func testRelativeGitdirStillCountsAsLinked() {
        XCTAssertTrue(Worktrees.isLinkedGitdirFile("gitdir: ../repo/.git/worktrees/x\n"))
        XCTAssertFalse(Worktrees.isLinkedGitdirFile("gitdir: /r/.git/worktrees\n"))
        XCTAssertFalse(Worktrees.isLinkedGitdirFile(""))
    }

    func testOfferedWhenNoSurvivingPaneSitsInTheWorktree() {
        XCTAssertEqual(
            Worktrees.cleanupOffer(
                cwd: wt + "/app", survivorCwds: [main, "/Users/me"], dotGit: tree),
            wt)
    }

    func testNotOfferedWhileAnotherPaneSitsInTheWorktree() {
        XCTAssertNil(Worktrees.cleanupOffer(
            cwd: wt, survivorCwds: [main, wt + "/tests"], dotGit: tree))
    }

    /// `/…/mux-maestro-2` is not inside `/…/mux-maestro`.
    func testSiblingWithSharedPrefixDoesNotBlockTheOffer() {
        XCTAssertEqual(
            Worktrees.cleanupOffer(cwd: wt, survivorCwds: [wt + "-2"], dotGit: tree), wt)
    }

    /// `--force` deletes uncommitted files on a plain worktree; `--keep-tmux` keeps
    /// spindown from killing windows the dialog never named.
    func testSpindownArgvNeverForcesAndKeepsTmux() {
        let argv = Worktrees.spindownArgv(python: "/py", script: "/s.py", worktree: wt)
        XCTAssertEqual(argv, ["/py", "/s.py", "--worktree", wt, "--yes", "--json", "--keep-tmux"])
        XCTAssertFalse(argv.contains("--force"))
    }

    func testParseCleaned() {
        let json = #"{"targets": [{"worktree": "/w", "branch": "feat/x", "cleaned": true, "#
            + #""skipped": [], "actions": ["git: removed worktree ~/w"]}], "applied": true}"#
        XCTAssertEqual(Worktrees.parseSpindown(json: json), .cleaned(branch: "feat/x"))
    }

    func testParseKeptCarriesTheGateReason() {
        let json = #"{"targets": [{"worktree": "/w", "branch": "feat/x", "cleaned": false, "#
            + #""skipped": ["HAS WORK — uncommitted: wip.txt"], "actions": []}], "applied": true}"#
        XCTAssertEqual(
            Worktrees.parseSpindown(json: json),
            .kept(branch: "feat/x", reason: "HAS WORK — uncommitted: wip.txt"))
    }

    func testParseFailedStepNamesIt() {
        let json = #"{"targets": [{"worktree": "/w", "branch": null, "cleaned": false, "#
            + #""skipped": [], "actions": ["supabase: x is not running", "#
            + #""git: worktree remove failed — locked"]}], "applied": true}"#
        XCTAssertEqual(
            Worktrees.parseSpindown(json: json),
            .failed(branch: nil, detail: "git: worktree remove failed — locked"))
    }

    /// spindown exits 1 with empty stdout on errors such as a bad path; the runner
    /// hands back nil for a non-zero exit.
    func testNoReportParsesToNil() {
        XCTAssertNil(Worktrees.parseSpindown(json: nil))
        XCTAssertNil(Worktrees.parseSpindown(json: ""))
        XCTAssertNil(Worktrees.parseSpindown(json: #"{"targets": [], "applied": true}"#))
    }

    func testToastCopy() {
        XCTAssertEqual(
            Worktrees.cleanupToast(.cleaned(branch: "feat/x"), worktree: "/w/wt").body,
            "Worktree cleaned up")
        let kept = Worktrees.cleanupToast(
            .kept(branch: "feat/x", reason: "HAS WORK — uncommitted: wip.txt"), worktree: "/w/wt")
        XCTAssertEqual(kept.title, "feat/x")
        XCTAssertEqual(kept.body, "Kept worktree: uncommitted: wip.txt")
        let none = Worktrees.cleanupToast(nil, worktree: "/w/wt")
        XCTAssertEqual(none.title, "wt")
        XCTAssertEqual(none.body, "Worktree cleanup failed")
    }
}

private struct WorktreeStaticStatusProvider: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}

/// Right-click → Remove on a WORKTREES row: what the menu offers, and what the
/// confirm sheet says. spindown still owns the real gate; this only decides
/// whether to ask at all.
final class WorktreesRemoveGuardTests: XCTestCase {
    private func entry(
        _ path: String = "/r/repo-hdr", isMain: Bool = false, prunable: Bool = false
    ) -> WorktreeEntry {
        WorktreeEntry(path: path, branch: "feat/x", isMain: isMain,
                      kind: isMain ? .main : .unmanaged, isPrunable: prunable)
    }

    func testCleanTreeIsOffered() {
        XCTAssertEqual(Worktrees.removeOffer(entry: entry(), work: .none), .confirm)
    }

    /// Unknown is its own state: offered, but the sheet must say it was not checked.
    func testUncheckedTreeIsOfferedWithAWarning() {
        XCTAssertEqual(Worktrees.removeOffer(entry: entry(), work: .unknown), .confirmUnchecked)
    }

    func testTreeHoldingWorkIsRefused() {
        XCTAssertEqual(
            Worktrees.removeOffer(entry: entry(), work: .unique), .refuse("holds work"))
    }

    /// Never the main checkout — not even when the classifier calls it clean.
    func testMainCheckoutIsRefusedWhateverItsWork() {
        for work in [WorktreeWork.none, .unknown, .unique] {
            XCTAssertEqual(
                Worktrees.removeOffer(entry: entry("/r/repo", isMain: true), work: work),
                .refuse("main checkout"))
        }
        let mainKind = WorktreeEntry(path: "/r/repo", branch: "main", isMain: false, kind: .main)
        XCTAssertEqual(Worktrees.removeOffer(entry: mainKind, work: .none), .refuse("main checkout"))
    }

    func testPrunableEntryIsRefused() {
        XCTAssertEqual(
            Worktrees.removeOffer(entry: entry(prunable: true), work: .none),
            .refuse("already gone"))
    }

    func testMenuTitles() {
        XCTAssertEqual(Worktrees.removeMenuTitle(.confirm), "Remove Worktree…")
        XCTAssertEqual(Worktrees.removeMenuTitle(.confirmUnchecked), "Remove Worktree…")
        XCTAssertEqual(
            Worktrees.removeMenuTitle(.refuse("holds work")), "Remove Worktree — holds work")
    }

    func testConfirmSheetNamesTheTreeAndBranch() {
        let sheet = Worktrees.removeConfirm(entry: entry(), offer: .confirm)
        XCTAssertEqual(sheet.title, "Remove worktree “repo-hdr”?")
        XCTAssertTrue(sheet.info.contains("feat/x"))
        XCTAssertFalse(sheet.info.contains("not checked"))
    }

    func testUncheckedSheetSaysSo() {
        let sheet = Worktrees.removeConfirm(entry: entry(), offer: .confirmUnchecked)
        XCTAssertTrue(sheet.info.contains("not checked"))
    }
}

/// The breadcrumb chip for a selection whose pane sits in a linked worktree.
final class WorktreesCrumbTests: XCTestCase {
    private let wt = "/Users/me/.treehouse/mux-maestro-7d8fda/4/mux-maestro"
    private let main = "/Users/me/code/github/mux-maestro"

    private var tree: (String) -> Worktrees.DotGit? {
        let entries: [String: Worktrees.DotGit] = [
            wt: .file("gitdir: /Users/me/code/github/mux-maestro/.git/worktrees/mux-maestro4\n"),
            main: .directory,
            main + "/vendor/sub": .file("gitdir: ../../.git/modules/sub\n"),
        ]
        return { entries[$0] }
    }

    func testPaneInsideALinkedWorktreeGetsTheChip() {
        let crumb = Worktrees.worktreeCrumb(
            cwd: wt + "/app", isLocal: true, home: "/Users/me", dotGit: tree)
        XCTAssertEqual(crumb?.text, "⑂ worktree")
        XCTAssertEqual(crumb?.root, wt)
        XCTAssertEqual(crumb?.tooltip, "~/.treehouse/mux-maestro-7d8fda/4/mux-maestro")
    }

    func testMainCheckoutSubmoduleAndNoRepoGetNoChip() {
        for cwd in [main, main + "/app", main + "/vendor/sub/src", "/tmp", ""] {
            XCTAssertNil(Worktrees.worktreeCrumb(
                cwd: cwd, isLocal: true, home: "/Users/me", dotGit: tree), cwd)
        }
    }

    /// A remote pane's path means nothing on this Mac's filesystem.
    func testRemoteHostGetsNoChip() {
        XCTAssertNil(Worktrees.worktreeCrumb(
            cwd: wt, isLocal: false, home: "/Users/me", dotGit: tree))
    }
}
