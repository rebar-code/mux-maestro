import XCTest

// WorktreeMetrics.swift is Foundation-only and compiled into this target, so the
// treehouse parser, the untracked classifier, the chips and the detail lines are
// asserted here with no real worktree, treehouse or Docker.


/// Records every command and replies from a scripted table — same shape as the
/// FakeRunner in WorktreesTests/GitDiffTests (each is file-private).
private final class FakeRunner: CommandRunner {
    private let lock = NSLock()
    private var _calls: [(path: String, args: [String], hadStdin: Bool)] = []
    var calls: [(path: String, args: [String], hadStdin: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var responses: [String: String?] = [:]
    var defaultResponse: String? = ""
    var capturingOK = true

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        _calls.append((path, args, stdin != nil))
        lock.unlock()
        if let scripted = responses[args.joined(separator: " ")] { return scripted }
        return defaultResponse
    }

    func runCapturing(_ path: String, _ args: [String]) -> (ok: Bool, text: String) {
        _ = run(path, args, stdin: nil)
        return (capturingOK, capturingOK ? "" : "refused")
    }

    var argSequences: [[String]] { calls.map(\.args) }
}

private func entry(
    path: String = "/Users/me/.treehouse/acme-app-80d837/7/acme-app",
    branch: String = "feat/rate-auditor-comp-set",
    kind: WorktreeKind = .pool
) -> WorktreeEntry {
    WorktreeEntry(path: path, branch: branch, isMain: kind == .main, kind: kind)
}

// MARK: - treehouse

final class TreehouseParseTests: XCTestCase {
    /// Verbatim `treehouse status --json` from the acme-app-monorepo pool on this
    /// Mac, 2026-08-21 — one dirty tree, one stale lease, one with live processes.
    private let sample = """
    [{"name":"1","path":"/Users/me/.treehouse/acmeApp-80d837/1/acmeApp","status":"dirty",\
    "lease_id":"","lease_holder":"","leased_at":null,"processes":[]},\
    {"name":"7","path":"/Users/me/.treehouse/acmeApp-80d837/7/acmeApp","status":"leased",\
    "lease_id":"874e7a37","lease_holder":"spin:feat/rate-auditor-field-capture",\
    "leased_at":"2026-08-19T14:10:28.97234-05:00","processes":[]},\
    {"name":"11","path":"/Users/me/.treehouse/acmeApp-80d837/11/acmeApp","status":"leased",\
    "lease_id":"a394cd29","lease_holder":"spin:feat/rate-auditor-comp-set",\
    "leased_at":"2026-08-20T13:53:50.453603-05:00",\
    "processes":[{"pid":19486,"name":"2.1.237"},{"pid":19645,"name":"mcp-server-darwin-arm64"}]},\
    {"name":"12","path":"/Users/me/.treehouse/acmeApp-80d837/12/acmeApp","status":"in-use",\
    "lease_id":"","lease_holder":"","leased_at":null,"processes":[{"pid":70452,"name":"zsh"}]}]
    """

    func testParsesEveryRow() {
        let rows = Treehouse.parseStatus(sample)
        XCTAssertEqual(rows.map(\.name), ["1", "7", "11", "12"])
        XCTAssertEqual(rows[1].status, "leased")
        XCTAssertEqual(rows[1].leaseHolder, "spin:feat/rate-auditor-field-capture")
        XCTAssertEqual(rows[2].processes, ["2.1.237 (19486)", "mcp-server-darwin-arm64 (19645)"])
    }

    /// Go's RFC3339 with fractional seconds and a numeric offset.
    func testParsesLeasedAt() {
        let rows = Treehouse.parseStatus(sample)
        XCTAssertNil(rows[0].leasedAt)
        XCTAssertEqual(
            rows[1].leasedAt,
            Treehouse.parseTimestamp("2026-08-19T14:10:28.97234-05:00"))
        XCTAssertNotNil(rows[1].leasedAt)
    }

    func testParsesTimestampWithoutFractionalSeconds() {
        XCTAssertNotNil(Treehouse.parseTimestamp("2026-08-19T14:10:28-05:00"))
    }

    /// Garbage, an error message, or treehouse not being installed all produce no
    /// rows — the row then has no lease line rather than a wrong one.
    func testUnparseableOutputYieldsNoRows() {
        XCTAssertEqual(Treehouse.parseStatus("not json"), [])
        XCTAssertEqual(Treehouse.parseStatus(""), [])
        XCTAssertEqual(Treehouse.parseStatus("[]"), [])
    }

    /// treehouse has no `-C`; it resolves the pool from the working directory, so
    /// the directory is the argument — and it must be the MAIN checkout, because
    /// from inside a pool tree the CLI answers "you're here".
    func testStatusArgvSetsTheWorkingDirectory() {
        XCTAssertEqual(
            Treehouse.statusArgv(treehouse: "/Users/me/go/bin/treehouse",
                                 repo: "/Users/me/code/github/acme-app/"),
            ["-C", "/Users/me/code/github/acme-app",
             "/Users/me/go/bin/treehouse", "status", "--json"])
    }

    func testLeaseSummaryNamesHolderAgeAndProcesses() {
        let now = Treehouse.parseTimestamp("2026-08-21T15:00:00-05:00")!
        let rows = Treehouse.parseStatus(sample)
        XCTAssertEqual(rows[1].summary(now: now),
                       "treehouse: leased by spin:feat/rate-auditor-field-capture · 2d")
        XCTAssertEqual(rows[3].summary(now: now), "treehouse: in-use · zsh (70452)")
    }
}

// MARK: - metric derivation + formatting

final class WorktreeMetricsDerivationTests: XCTestCase {
    func testNewestPicksTheLatestNonNil() {
        let a = Date(timeIntervalSince1970: 100)
        let b = Date(timeIntervalSince1970: 900)
        XCTAssertEqual(WorktreeMetrics.newest([a, nil, b]), b)
        XCTAssertNil(WorktreeMetrics.newest([nil, nil]))
        XCTAssertNil(WorktreeMetrics.newest([]))
    }

    func testParseEpoch() {
        XCTAssertEqual(WorktreeMetrics.parseEpoch("1755800000\n"),
                       Date(timeIntervalSince1970: 1_755_800_000))
        XCTAssertNil(WorktreeMetrics.parseEpoch(""))
        XCTAssertNil(WorktreeMetrics.parseEpoch("not-a-number"))
        XCTAssertNil(WorktreeMetrics.parseEpoch("0"))
    }

    func testParseDuKB() {
        XCTAssertEqual(WorktreeMetrics.parseDuKB("2216484\t/Users/me/wt/a\n"), 2_216_484)
        XCTAssertEqual(WorktreeMetrics.parseDuKB(" 44 /wt/a"), 44)
        XCTAssertNil(WorktreeMetrics.parseDuKB(""))
        XCTAssertNil(WorktreeMetrics.parseDuKB("du: /wt/a: No such file or directory"))
    }
}

final class WorktreeMetricsFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_800_000)

    func testAgeLabelIsOneCoarseUnit() {
        XCTAssertEqual(WorktreeMetrics.ageLabel(now.addingTimeInterval(-11 * 86_400), now: now), "11d")
        XCTAssertEqual(WorktreeMetrics.ageLabel(now.addingTimeInterval(-4 * 3_600), now: now), "4h")
        XCTAssertEqual(WorktreeMetrics.ageLabel(now.addingTimeInterval(-12 * 60), now: now), "12m")
        XCTAssertEqual(WorktreeMetrics.ageLabel(now.addingTimeInterval(-5), now: now), "now")
    }

    /// A clock skew must not print a negative age.
    func testFutureDateReadsAsNow() {
        XCTAssertEqual(WorktreeMetrics.ageLabel(now.addingTimeInterval(600), now: now), "now")
    }

    func testSizeLabel() {
        XCTAssertEqual(WorktreeMetrics.sizeLabel(kb: 2_100_000), "2.1 GB")
        XCTAssertEqual(WorktreeMetrics.sizeLabel(kb: 67_100_000), "67 GB")
        XCTAssertEqual(WorktreeMetrics.sizeLabel(kb: 812_000), "812 MB")
        XCTAssertEqual(WorktreeMetrics.sizeLabel(kb: 44), "44 KB")
        XCTAssertEqual(WorktreeMetrics.sizeLabel(kb: 0), "0 KB")
    }

    /// The BRANCH is the row's name. Every tree of one repo shares a directory
    /// name, so the directory carries no information in that space.
    func testBranchLabel() {
        XCTAssertEqual(
            WorktreeMetrics.branchLabel(
                entry: entry(path: "/wt/acme-app-monorepo", branch: "fix/competitor-operator")),
            "fix/competitor-operator")
        XCTAssertEqual(WorktreeMetrics.branchLabel(entry: entry(path: "/wt/a", branch: "")), "detached")
    }

    /// A path that names nothing cannot drive a decision.
    func testBasenamesReplacePathsAndCountTheRemainder() {
        XCTAssertEqual(
            WorktreeMetrics.basenames(
                ["apps/admin/src/lib/server/competitors/marketplace.ts",
                 "apps/admin/x.ts", "apps/admin/y.ts", "apps/admin/z.ts"], limit: 1),
            "marketplace.ts +3")
        XCTAssertEqual(WorktreeMetrics.basenames(["a/b.ts"], limit: 3), "b.ts")
        XCTAssertEqual(WorktreeMetrics.basenames([], limit: 3), "")
    }

    /// Only the facts a chip cannot carry, and filenames as basenames. Idle time
    /// and size are chips on the header, so repeating them here was the same fact
    /// Only the facts a chip cannot carry, and filenames as basenames. Idle time,
    /// containers and size are chips on the header.
    func testDetailLinesCarryOnlyWhatAChipCannot() {
        var m = WorktreeMetrics()
        m.lastUsed = now.addingTimeInterval(-11 * 86_400)
        m.changes = WorktreeChanges(
            trackedDirty: ["apps/web/src/pmc.ts", "a.ts", "b.ts", "c.ts", "d.ts"],
            untracked: [])
        m.docker = DockerAttribution(known: true, containers: 3, ports: [54321, 54322])
        m.lease = TreehouseWorktree(
            name: "7", path: "/wt/a", status: "leased", leaseHolder: "spin:feat/x",
            leasedAt: now.addingTimeInterval(-2 * 86_400), processes: [])
        m.diskKB = 2_100_000
        let lines = m.detailLines(entry: entry(path: "/wt/a"), work: .unique, now: now)
        XCTAssertEqual(lines, [
            "/wt/a",
            "dirty pmc.ts, a.ts, b.ts +2",
            "treehouse: leased by spin:feat/x · 2d",
        ])
    }

    func testDetailLinesNameUntrackedFiles() {
        var m = WorktreeMetrics()
        m.changes = WorktreeChanges.parse(
            porcelain: "?? shot.png\u{0}?? .lavish/x.png\u{0}", authoredExtensions: ["ts"])
        let lines = m.detailLines(entry: entry(path: "/wt/a", kind: .unmanaged), work: .unique, now: now)
        XCTAssertEqual(lines, ["/wt/a", "untracked shot.png, x.png — scratch", "unmanaged"])
    }

    func testDetailLinesDegradeToUnknownNotToReassuringZeros() {
        let lines = WorktreeMetrics().detailLines(
            entry: entry(path: "/wt/a", kind: .unmanaged), work: .unknown, now: now)
        XCTAssertEqual(lines, ["/wt/a", "not checked", "unmanaged"])
    }

    func testCleanAndUnpushedTreesSaySo() {
        let clean = WorktreeMetrics().detailLines(entry: entry(path: "/wt/a"), work: .none, now: now)
        XCTAssertEqual(clean[1], "clean")
        var m = WorktreeMetrics()
        m.changes = WorktreeChanges()
        let unpushed = m.detailLines(entry: entry(path: "/wt/a"), work: .unique, now: now)
        XCTAssertEqual(unpushed[1], "unpushed commits")
    }

    /// A pool tree with no treehouse verdict must say so rather than silently look
    /// like an unmanaged tree.
    func testPoolTreeWithoutALeaseSaysSo() {
        let lines = WorktreeMetrics().detailLines(entry: entry(), work: .none, now: now)
        XCTAssertTrue(lines.contains("treehouse: no lease"))
    }
}

// MARK: - chips

final class WorktreeChipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_800_000)

    private func chips(_ m: WorktreeMetrics, work: WorktreeWork = .none) -> [WorktreeChip] {
        m.chips(work: work, now: now)
    }

    /// `10 containers · :54471 :54472 :54473 :54474` is a wall of digits at 220pt.
    /// The count is the glance; the ports are the tooltip.
    func testContainerCountIsAChipAndPortsAreItsTooltip() {
        var m = WorktreeMetrics()
        m.docker = DockerAttribution(known: true, containers: 10, ports: [54471, 54472])
        let chip = chips(m).first { $0.text.hasPrefix("⬢") }
        XCTAssertEqual(chip?.text, "⬢10")
        XCTAssertEqual(chip?.tooltip, "10 running · :54471 :54472")
    }

    /// A confident zero is worth no pixels; an unknown is worth one glyph, because
    /// "we didn't ask Docker" must not read as "nothing is running".
    func testZeroContainersHasNoChipButUnknownDoes() {
        var known = WorktreeMetrics()
        known.docker = DockerAttribution(known: true, containers: 0, ports: [])
        XCTAssertFalse(chips(known).contains { $0.text.hasPrefix("⬢") })

        let unknown = WorktreeMetrics()  // docker defaults to .unknown
        XCTAssertEqual(chips(unknown).first { $0.text.hasPrefix("⬢") }?.text, "⬢?")
    }

    func testIdleIsAlwaysAChipEvenWhenUnknown() {
        var m = WorktreeMetrics()
        m.lastUsed = now.addingTimeInterval(-11 * 86_400)
        XCTAssertTrue(chips(m).contains { $0.text == "11d" })
        XCTAssertTrue(chips(WorktreeMetrics()).contains { $0.text == "?" })
    }

    /// Size appears only once it has been paid for — never as a permanent "—".
    func testSizeChipOnlyAppearsOnceMeasured() {
        XCTAssertFalse(chips(WorktreeMetrics()).contains { $0.text.contains("GB") })
        var pending = WorktreeMetrics(); pending.diskPending = true
        XCTAssertTrue(chips(pending).contains { $0.text == "…" })
        var done = WorktreeMetrics(); done.diskKB = 1_900_000
        XCTAssertTrue(chips(done).contains { $0.text == "1.9 GB" })
    }

    /// The one chip that is a warning, and it leads.
    func testUniqueWorkLeadsAndIsTheOnlyWarningTone() {
        let list = chips(WorktreeMetrics(), work: .unique)
        XCTAssertEqual(list.first?.text, "work")
        XCTAssertEqual(list.first?.tone, .warning)
        XCTAssertEqual(list.filter { $0.tone == .warning }.count, 1)
    }

    /// The strip only draws `WorktreeChipStrip.maxChips`, so the pure side must not
    /// produce more than a row can show.
    func testNeverMoreChipsThanTheStripCanDraw() {
        var m = WorktreeMetrics()
        m.docker = DockerAttribution(known: true, containers: 10, ports: [1])
        m.lastUsed = now
        m.diskKB = 1
        XCTAssertLessThanOrEqual(m.chips(work: .unique, now: now).count, 4)
    }
}

// MARK: - untracked classification

/// Fixtures are the exact paths from
/// `~/Downloads/worktree-rescue-20260819/untracked-classification-groundtruth.py`
/// — 32 real untracked files hand-labelled during the 2026-08-19 purge across
/// widget-shop, acme-app-monorepo and my-site. No percentage from that
/// run is encoded here: 32 files, one purge, three repos, one person's labels.
final class UntrackedClassifierTests: XCTestCase {
    /// widget-shop really tracks `.png` and `.xlsx`; acme-app-monorepo
    /// authors `.ts` and `.md` but no `.mts`.
    private let widgetShop: Set<String> = ["ts", "svelte", "sql", "html", "png", "xlsx", "md", "json"]
    private let acmeApp: Set<String> = ["ts", "mjs", "svelte", "sql", "html", "xml", "md", "json"]

    private func widgetShopClass(_ p: String) -> UntrackedClass {
        UntrackedClassifier.classify(path: p, authoredExtensions: widgetShop)
    }
    private func acmeAppClass(_ p: String) -> UntrackedClass {
        UntrackedClassifier.classify(path: p, authoredExtensions: acmeApp)
    }

    /// The repo root is where downloads, screenshots and pasted files land.
    func testRootLevelFilesAreLikelyScratch() {
        for p in ["K74038 ticket.pdf", "pasted-20260810-165020-150.png",
                  "1786458674675_8872_Summerwalk_Tr._Pick_up_8-11-26.xlsx",
                  "Builder Import Issue.png", "image001.png", "render-check.png",
                  "shotA.png", "J43286.xls", "Screenshot 2026-08-19 at 12.43.12.png"] {
            XCTAssertEqual(widgetShopClass(p), .likelyScratch, p)
        }
    }

    /// A leading-dot directory belongs to a tool, not to the project.
    func testFilesUnderADotDirectoryAreLikelyScratch() {
        for p in [".lavish/after-app.png", ".lavish/legacy-footer-rows-status.html",
                  ".lavish/prod-now.png", ".lavish/workbook-left.png",
                  ".lavish/workbook-right.png"] {
            XCTAssertEqual(widgetShopClass(p), .likelyScratch, p)
        }
    }

    /// An extension the repo authors, in a real directory, is work.
    func testAuthoredExtensionsInRealDirectoriesAreWork() {
        for p in ["tests/legacy-footer-visual.spec.ts",
                  "scripts/sql/RUNBOOK-window-screen-locations-apply.sql",
                  "scripts/sql/backfill-descriptions.sql",
                  "scripts/sql/backfill-window-screen-locations.sql",
                  "scripts/sql/runbook-window-screen-locations.html"] {
            XCTAssertEqual(widgetShopClass(p), .work, p)
        }
        for p in ["apps/admin/src/lib/server/connectors/adapters/pmc.ts",
                  "apps/admin/src/lib/server/connectors/adapters/pmc.test.ts",
                  "apps/admin/src/lib/server/connectors/adapters/__fixtures__/pmc-lot.html",
                  "apps/admin/src/lib/server/connectors/adapters/__fixtures__/pmc-sitemap.xml",
                  "apps/admin/scripts/netsuite-columns.ts",
                  "apps/admin/scripts/netsuite-period-probe.ts",
                  "apps/admin/scripts/netsuite-probe.ts",
                  "supabase/migrations/20260814180754_location_canonical_fields.sql",
                  "tasks/todo.md"] {
            XCTAssertEqual(acmeAppClass(p), .work, p)
        }
    }

    /// The reason the third state exists. Both files are real work; the repo authors
    /// `.ts` and `.mjs` but no `.mts`, so no extension rule can see them. `unknown`
    /// never counts as scratch — folding it in is what would hide them.
    func testUnfamiliarExtensionsAreUnknownNotScratch() {
        XCTAssertEqual(acmeAppClass("apps/admin/env-shim.mts"), .unknown)
        XCTAssertEqual(acmeAppClass("apps/admin/scrape-airgarage-once.mts"), .unknown)
    }

    /// **Known, accepted loss.** Both are labelled work, and both classify as
    /// scratch because they sit at the repo root. Root-level notes are genuinely
    /// ambiguous — the same person archives notes by default and would file these as
    /// scratch — and tuning the rule to catch them re-introduces false positives on
    /// the 14 root-level screenshots above. The cost here is only a quieter chip.
    func testRootLevelNotesAreAKnownAcceptedLoss() {
        XCTAssertEqual(acmeAppClass("LEARNINGS.md"), .likelyScratch)
        XCTAssertEqual(acmeAppClass("BRIEF.md"), .likelyScratch)
    }

    /// The case an extension denylist gets wrong: widget-shop tracks 17
    /// `.png`, so a `.png` sitting in a real directory alongside the project's own
    /// images is work, not junk.
    func testATrackedImageTypeInARealDirectoryIsWorkNotScratch() {
        XCTAssertEqual(widgetShopClass("static/images/hero.png"), .work)
        XCTAssertEqual(widgetShopClass("docs/screens/workbook.png"), .work)
        // ...and the same extension at the root is still scratch.
        XCTAssertEqual(widgetShopClass("hero.png"), .likelyScratch)
    }

    func testAuthoredExtensionsAreLearnedFromLsFiles() {
        let listing = "Makefile\napp/Main.swift\ndocs/a.PNG\ntests/x.swift\n"
        XCTAssertEqual(UntrackedClassifier.authoredExtensions(lsFiles: listing),
                       ["swift", "png"])
    }

    func testLsFilesArgv() {
        XCTAssertEqual(UntrackedClassifier.lsFilesArgv(cwd: "/r/"), ["-C", "/r", "ls-files"])
    }
}

final class WorktreeChangesTests: XCTestCase {
    private let exts: Set<String> = ["ts", "md"]

    private func porcelain(_ records: [(String, String)]) -> String {
        records.map { "\($0.0) \($0.1)\0" }.joined()
    }

    func testSplitsTrackedEditsFromUntrackedAndDropsConfigToml() {
        let z = porcelain([
            (".M", "supabase/config.toml"),
            (".M", "src/pmc.ts"),
            ("??", "image001.png"),
            ("??", "src/new-thing.ts"),
        ])
        let c = WorktreeChanges.parse(porcelain: z, authoredExtensions: exts)
        XCTAssertEqual(c.trackedDirty, ["src/pmc.ts"])
        XCTAssertEqual(c.untracked.map(\.path), ["image001.png", "src/new-thing.ts"])
        XCTAssertEqual(c.untracked.map(\.verdict), [.likelyScratch, .work])
        XCTAssertFalse(c.isScratchOnly)
    }

    func testScratchOnlyTreeIsRecognised() {
        let c = WorktreeChanges.parse(
            porcelain: porcelain([("??", "shotA.png"), ("??", ".lavish/x.png")]),
            authoredExtensions: exts)
        XCTAssertTrue(c.isScratchOnly)
    }

    /// A `config.toml`-only diff is not work; that mistake exited 0 for eleven
    /// nights and released nothing.
    func testConfigTomlAloneIsNotWork() {
        let c = WorktreeChanges.parse(
            porcelain: porcelain([(".M", "supabase/config.toml")]), authoredExtensions: exts)
        XCTAssertTrue(c.isScratchOnly)
    }

    /// Names, with the verdict of the most serious file in the set.
    func testUntrackedLineNamesFilesAndReportsTheWorstVerdict() {
        let c = WorktreeChanges.parse(
            porcelain: porcelain([("??", "a.png"), ("??", "b.png"), ("??", "c.png")]),
            authoredExtensions: exts)
        XCTAssertEqual(c.untrackedLine(), "untracked a.png, b.png, c.png — scratch")

        let mixed = WorktreeChanges.parse(
            porcelain: porcelain([("??", "a.png"), ("??", "src/x.mts")]),
            authoredExtensions: exts)
        XCTAssertEqual(mixed.untrackedLine(), "untracked a.png, x.mts — unrecognised")
    }

    /// `unknown` is not scratch: an unfamiliar extension keeps the tree loud.
    func testUnknownFileIsNotScratchOnly() {
        let c = WorktreeChanges.parse(
            porcelain: porcelain([("??", "shotA.png"), ("??", "src/tool.mts")]),
            authoredExtensions: exts)
        XCTAssertFalse(c.isScratchOnly)
    }

    func testUntrackedLineIsNilWhenThereAreNone() {
        XCTAssertNil(WorktreeChanges().untrackedLine())
    }
}

// MARK: - service argv

final class WorktreeMetricsServiceTests: XCTestCase {
    private func makeService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(
            host: .local, transport: LocalTmuxTransport(tmuxPath: "/opt/homebrew/bin/tmux"),
            runner: runner, statusProvider: nil)
    }

    /// Cheap and bounded: one `git log -1`, never a `--all` and never a tree walk.
    func testLastUsedAsksGitForOneCommitDate() {
        let runner = FakeRunner()
        runner.defaultResponse = "1755800000"
        _ = makeService(runner).worktreeLastUsed(path: "/wt/a")
        XCTAssertEqual(runner.argSequences.first,
                       ["-C", "/wt/a", "log", "-1", "--format=%ct"])
    }

    func testDiskUsageArgvIsASummaryInKilobytes() {
        let runner = FakeRunner()
        runner.defaultResponse = "2216484\t/wt/a"
        XCTAssertEqual(makeService(runner).diskUsageKB(path: "/wt/a"), 2_216_484)
        XCTAssertEqual(runner.argSequences, [["-sk", "/wt/a"]])
    }

    func testDiskUsageFailureIsNilNotZero() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertNil(makeService(runner).diskUsageKB(path: "/wt/a"))
    }

    /// The only `git status` the sweep runs per tree.
    func testStatusUsesPorcelainWithUntrackedFiles() {
        let runner = FakeRunner()
        runner.defaultResponse = "?? shotA.png\u{0}"
        XCTAssertEqual(makeService(runner).worktreeStatus(cwd: "/wt/a"), "?? shotA.png\u{0}")
        XCTAssertEqual(runner.argSequences,
                       [["-C", "/wt/a", "status", "--porcelain=v1", "-z", "--untracked-files=all"]])
    }

    /// One status read feeds both the work verdict and the file names; a dirty
    /// tree never pays for cherry.
    func testWorkFromAStatusAlreadyReadRunsNoSecondStatus() {
        let runner = FakeRunner()
        let status = " M src/app.ts\u{0}"
        XCTAssertEqual(makeService(runner).worktreeWork(cwd: "/wt/a", status: status), .unique)
        XCTAssertTrue(runner.argSequences.isEmpty)
    }

    func testStatusIsNilWhenGitFails() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertNil(makeService(runner).worktreeStatus(cwd: "/wt/a"))
    }

    /// The commit check ignores the working tree and reuses the merge-aware rule:
    /// cherry silent but one commit ahead is still unique.
    func testCommitWorkCountsMergeCommits() {
        let runner = FakeRunner()
        runner.responses["-C /wt/a symbolic-ref --quiet --short refs/remotes/origin/HEAD"] =
            "origin/main\n"
        runner.responses["-C /wt/a cherry origin/main"] = ""
        runner.responses["-C /wt/a rev-list --count origin/main..HEAD"] = "1\n"
        XCTAssertEqual(makeService(runner).worktreeCommitWork(cwd: "/wt/a"), .unique)
        XCTAssertFalse(runner.argSequences.contains { $0.contains("status") })
    }

    func testCommitWorkIsNoneWhenEverythingLandedUpstream() {
        let runner = FakeRunner()
        runner.responses["-C /wt/a symbolic-ref --quiet --short refs/remotes/origin/HEAD"] =
            "origin/main\n"
        runner.responses["-C /wt/a cherry origin/main"] = "- abc123\n"
        runner.responses["-C /wt/a rev-list --count origin/main..HEAD"] = "1\n"
        XCTAssertEqual(makeService(runner).worktreeCommitWork(cwd: "/wt/a"), WorktreeWork.none)
    }

    /// No resolvable base is "couldn't tell", not "nothing unpushed".
    func testCommitWorkIsUnknownWithNoBaseBranch() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertEqual(makeService(runner).worktreeCommitWork(cwd: "/wt/a"), .unknown)
    }

    func testAuthoredExtensionsComeFromLsFiles() {
        let runner = FakeRunner()
        runner.defaultResponse = "Makefile\napp/Main.swift\ndocs/a.PNG\n"
        XCTAssertEqual(makeService(runner).authoredExtensions(repo: "/r"), ["swift", "png"])
    }
}

/// The cry-wolf regression: `work` was amber on 26 of 28 visible rows, because
/// `.unique` counts any untracked file and most are screenshots. A signal that
/// fires on nearly everything is not a signal.
final class WorktreeWorkChipToneTests: XCTestCase {
    private let authored: Set<String> = [".ts", ".swift", ".sql"]
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func chipTexts(_ changes: WorktreeChanges, unpushed: Bool? = false) -> [String] {
        var m = WorktreeMetrics()
        m.changes = changes
        m.hasUnpushedCommits = unpushed
        return m.chips(work: .unique, now: t0).map(\.text)
    }

    /// Real case from this Mac: `feat/legacy-sheet-conflicts-ui`, whose entire
    /// untracked set is three root-level files named `scratch-*`.
    func testScratchOnlyTreeReadsScratchNotWork() {
        let changes = WorktreeChanges.parse(
            porcelain: ["?? scratch-conflict-header-count.png",
                        "?? scratch-conflict-shots.mjs",
                        "?? scratch-conflict-strip-after.png"].map { $0 + "\u{0}" }.joined(),
            authoredExtensions: authored)
        XCTAssertTrue(changes.isScratchOnly)
        XCTAssertTrue(chipTexts(changes).contains("scratch"))
        XCTAssertFalse(chipTexts(changes).contains("work"))
    }

    /// The other real case: mostly scratch, but one genuine `.sql` under
    /// `scripts/sql/`. One real file is enough to keep the loud chip.
    func testOneRealFileAmongScratchStillReadsWork() {
        let changes = WorktreeChanges.parse(
            porcelain: ["?? pasted-20260812-153402-712.png",
                        "?? scripts/sql/reb-1380-restore-m53471.sql"]
                .map { $0 + "\u{0}" }.joined(),
            authoredExtensions: authored)
        XCTAssertFalse(changes.isScratchOnly)
        XCTAssertTrue(chipTexts(changes).contains("work"))
    }

    /// A tracked edit is never scratch, whatever the untracked set looks like.
    func testTrackedEditKeepsTheWorkChip() {
        let changes = WorktreeChanges.parse(
            porcelain: [" M src/app.ts", "?? shot.png"].map { $0 + "\u{0}" }.joined(),
            authoredExtensions: authored)
        XCTAssertTrue(chipTexts(changes).contains("work"))
    }

    /// Unpushed commits outrank the untracked set entirely.
    func testUnpushedCommitsKeepTheWorkChip() {
        let changes = WorktreeChanges.parse(
            porcelain: "?? shot.png\u{0}", authoredExtensions: authored)
        XCTAssertTrue(changes.isScratchOnly)
        XCTAssertTrue(chipTexts(changes, unpushed: true).contains("work"))
    }

    /// Not-yet-computed must never read as scratch.
    func testUnknownCommitStateKeepsTheWorkChip() {
        let changes = WorktreeChanges.parse(
            porcelain: "?? shot.png\u{0}", authoredExtensions: authored)
        XCTAssertTrue(chipTexts(changes, unpushed: nil).contains("work"))
    }
}
