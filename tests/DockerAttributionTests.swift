import XCTest

// DockerAttribution.swift is Foundation-only and compiled into this target, so the
// `docker ps` parser, the published-port rule, the truncated-label join and the
// degrade-to-unknown behaviour are all asserted with no daemon anywhere near.
//
// Every fixture below is real `docker ps` output from this Mac on 2026-08-21,
// where 35 containers across four Supabase stacks were running.

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

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        lock.lock()
        _calls.append((path, args, stdin != nil))
        lock.unlock()
        if let scripted = responses[args.joined(separator: " ")] { return scripted }
        return defaultResponse
    }

    var argSequences: [[String]] { calls.map(\.args) }
}

final class DockerParsePSTests: XCTestCase {
    /// Verbatim from this Mac: two stacks, a published DB port, a container with
    /// only unpublished ports, and a compose project keyed by working dir.
    private let sample = [
        "supabase_db_acme-app-portal\tacme-app-portal\t\t0.0.0.0:54472->5432/tcp",
        "supabase_rest_acme-app-portal\tacme-app-portal\t\t3000/tcp",
        "supabase_inbucket_acme-app-portal\tacme-app-portal\t\t"
            + "1025/tcp, 1110/tcp, 0.0.0.0:54474->8025/tcp",
        "web-1\t\t/Users/me/code/github/my-site\t0.0.0.0:5173->5173/tcp",
    ].joined(separator: "\n")

    func testParsesNameLabelsAndPorts() {
        let containers = Docker.parsePS(sample)
        XCTAssertEqual(containers.count, 4)
        XCTAssertEqual(containers[0].name, "supabase_db_acme-app-portal")
        XCTAssertEqual(containers[0].supabaseProject, "acme-app-portal")
        XCTAssertEqual(containers[0].composeWorkingDir, "")
        XCTAssertEqual(containers[0].ports, [54472])
        XCTAssertEqual(containers[3].composeWorkingDir,
                       "/Users/me/code/github/my-site")
        XCTAssertEqual(containers[3].supabaseProject, "")
    }

    /// A container exposing only internal ports publishes nothing this Mac can hit.
    func testUnpublishedPortsAreDropped() {
        XCTAssertEqual(Docker.parsePS(sample)[1].ports, [])
    }

    func testBlankAndMalformedLinesAreSkippedNotGuessedAt() {
        let out = "\n\nsupabase_db_x\tx\t\t0.0.0.0:1->2/tcp\ngarbage-with-no-tabs\n"
        XCTAssertEqual(Docker.parsePS(out).map(\.name), ["supabase_db_x"])
    }

    /// Empty output is a real answer from a live daemon with nothing running, and
    /// must stay distinguishable from the daemon being down (which is `.unavailable`).
    func testEmptyOutputIsAnEmptyContainerList() {
        XCTAssertEqual(Docker.parsePS(""), [])
    }
}

final class DockerPortsTests: XCTestCase {
    func testHostPortIsTakenFromTheLeftOfTheArrow() {
        XCTAssertEqual(Docker.parsePorts("0.0.0.0:54473->3000/tcp"), [54473])
    }

    /// IPv4 and IPv6 publish the same host port; the row must not say ":54401 :54401".
    func testIPv4AndIPv6PublishDedupeToOnePort() {
        XCTAssertEqual(
            Docker.parsePorts("0.0.0.0:54401->8000/tcp, [::]:54401->8000/tcp"), [54401])
    }

    func testMixedInternalAndPublishedPorts() {
        XCTAssertEqual(
            Docker.parsePorts("1025/tcp, 1110/tcp, 0.0.0.0:54474->8025/tcp"), [54474])
    }

    func testBracketedIPv6HostIsParsed() {
        XCTAssertEqual(Docker.parsePorts("[::1]:5173->5173/tcp"), [5173])
    }

    func testResultIsAscending() {
        XCTAssertEqual(
            Docker.parsePorts("0.0.0.0:54473->3000/tcp, 0.0.0.0:54401->8000/tcp"),
            [54401, 54473])
    }

    func testEmptyColumn() { XCTAssertEqual(Docker.parsePorts(""), []) }
}

final class DockerSupabaseJoinTests: XCTestCase {
    /// The plain case: label and config.toml id are identical.
    func testExactIDMatches() {
        XCTAssertTrue(Docker.supabaseStackMatches(
            label: "acme-app-portal", projectID: "acme-app-portal"))
    }

    /// The Supabase CLI truncates `com.supabase.cli.project` to 40 characters, so a
    /// spin-created stack never equals its own config.toml id. Real pair from this
    /// Mac: a 40-char label against a 51-char project_id.
    func testTruncatedFortyCharLabelMatchesTheLongerID() {
        let label = "acme-app-portal-spin-feat-rate-auditor-f"
        let projectID = "acme-app-portal-spin-feat-rate-auditor-field-capture"
        XCTAssertEqual(label.count, Docker.supabaseLabelLimit)
        XCTAssertGreaterThan(projectID.count, label.count)
        XCTAssertTrue(Docker.supabaseStackMatches(label: label, projectID: projectID))
    }

    /// The bug this rule exists to prevent, and which shipped once: a plain prefix
    /// match lets the main repo's own short-named stack claim every spin worktree,
    /// making all of them look busy. Only a label at the exact truncation limit lost
    /// information, so only that one gets the prefix rule.
    func testShortLabelNeverPrefixMatchesALongerID() {
        XCTAssertFalse(Docker.supabaseStackMatches(
            label: "acme-app-portal",
            projectID: "acme-app-portal-spin-feat-rate-auditor-field-capture"))
    }

    /// A 40-char label must still not claim an unrelated id.
    func testFortyCharLabelDoesNotMatchADifferentProject() {
        XCTAssertFalse(Docker.supabaseStackMatches(
            label: "acme-app-portal-spin-feat-rate-auditor-f",
            projectID: "widget-shop-po-pipeline"))
    }

    func testEmptySidesNeverMatch() {
        XCTAssertFalse(Docker.supabaseStackMatches(label: "", projectID: "x"))
        XCTAssertFalse(Docker.supabaseStackMatches(label: "x", projectID: ""))
    }
}

final class DockerAttributeTests: XCTestCase {
    private let snapshot = DockerSnapshot.containers([
        DockerContainer(name: "supabase_db_mine", supabaseProject: "mine-spin-feat-a-very-long-b",
                        composeWorkingDir: "", ports: [54322]),
        DockerContainer(name: "supabase_kong_mine", supabaseProject: "mine-spin-feat-a-very-long-b",
                        composeWorkingDir: "", ports: [54321]),
        DockerContainer(name: "supabase_db_other", supabaseProject: "other",
                        composeWorkingDir: "", ports: [54332]),
        DockerContainer(name: "web-1", supabaseProject: "",
                        composeWorkingDir: "/wt/a/apps/web", ports: [5173]),
        DockerContainer(name: "elsewhere-1", supabaseProject: "",
                        composeWorkingDir: "/wt/ab", ports: [3000]),
    ])

    func testSupabaseAndComposeContainersBothCount() {
        let a = Docker.attribute(
            snapshot: snapshot, path: "/wt/a", supabaseProjectID: "mine-spin-feat-a-very-long-b")
        XCTAssertTrue(a.known)
        XCTAssertEqual(a.containers, 3)
        XCTAssertEqual(a.ports, [5173, 54321, 54322])
    }

    /// `/wt/ab` is not inside `/wt/a`; the path join must respect boundaries.
    func testSiblingDirectoryIsNotClaimed() {
        let a = Docker.attribute(snapshot: snapshot, path: "/wt/a", supabaseProjectID: nil)
        XCTAssertEqual(a.containers, 1)
        XCTAssertEqual(a.ports, [5173])
    }

    /// The whole reason `unavailable` is a case: a down daemon must not report a
    /// confident "no containers", which is what makes a stale tree look idle.
    func testUnavailableSnapshotIsUnknownNotZero() {
        let a = Docker.attribute(
            snapshot: .unavailable, path: "/wt/a", supabaseProjectID: "mine")
        XCTAssertEqual(a, .unknown)
        XCTAssertFalse(a.known)
    }

    func testLiveDaemonWithNothingRunningIsAConfidentZero() {
        let a = Docker.attribute(
            snapshot: .containers([]), path: "/wt/a", supabaseProjectID: "mine")
        XCTAssertTrue(a.known)
        XCTAssertEqual(a.containers, 0)
    }
}

final class DockerConfigTomlTests: XCTestCase {
    func testReadsProjectID() {
        let toml = """
        # A string used to distinguish different Supabase projects.
        project_id = "widget-shop-po-pipeline"

        [api]
        port = 54401
        """
        XCTAssertEqual(Docker.supabaseProjectID(configToml: toml),
                       "widget-shop-po-pipeline")
    }

    /// `worktree-supabase.sh` rewrites this file per worktree and leaves the
    /// original id behind as a comment. Reading the comment would attribute the
    /// WRONG stack.
    func testCommentedOutIDIsIgnored() {
        let toml = """
        # project_id = "widget-shop"
        project_id = "widget-shop-spin-feat-x"
        """
        XCTAssertEqual(Docker.supabaseProjectID(configToml: toml),
                       "widget-shop-spin-feat-x")
    }

    func testSingleQuotesAndLooseSpacingSurvive() {
        XCTAssertEqual(Docker.supabaseProjectID(configToml: "  project_id   =  'abc' "), "abc")
    }

    func testMissingProjectIDIsNil() {
        XCTAssertNil(Docker.supabaseProjectID(configToml: "[api]\nport = 1\n"))
        XCTAssertNil(Docker.supabaseProjectID(configToml: ""))
    }

    func testConfigPath() {
        XCTAssertEqual(Docker.configTomlPath(root: "/wt/a/"), "/wt/a/supabase/config.toml")
    }
}

final class DockerServiceArgvTests: XCTestCase {
    private func makeService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(
            host: .local, transport: LocalTmuxTransport(tmuxPath: "/opt/homebrew/bin/tmux"),
            runner: runner, statusProvider: nil)
    }

    /// Running containers only (no `-a`), and the tab-separated template that the
    /// parser depends on.
    func testDockerSnapshotArgv() {
        let runner = FakeRunner()
        runner.defaultResponse = "supabase_db_x\tx\t\t0.0.0.0:1->2/tcp"
        let snapshot = makeService(runner).dockerSnapshot()
        XCTAssertEqual(runner.argSequences.first?.first, "ps")
        XCTAssertTrue(runner.argSequences.first?.contains("--format") ?? false)
        XCTAssertFalse(runner.argSequences.first?.contains("-a") ?? true)
        XCTAssertEqual(snapshot, .containers([
            DockerContainer(name: "supabase_db_x", supabaseProject: "x",
                            composeWorkingDir: "", ports: [1]),
        ]))
    }

    /// A nil from the runner is a missing binary, a dead daemon, or the timeout
    /// firing. All three are "unknown".
    func testDockerFailureDegradesToUnavailable() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertEqual(makeService(runner).dockerSnapshot(), .unavailable)
    }

    func testSupabaseProjectIDReadsTheWorktreesOwnConfig() {
        let runner = FakeRunner()
        runner.responses["/wt/a/supabase/config.toml"] = "project_id = \"spun-id\"\n"
        XCTAssertEqual(makeService(runner).supabaseProjectID(root: "/wt/a"), "spun-id")
        XCTAssertEqual(runner.argSequences, [["/wt/a/supabase/config.toml"]])
    }

    func testSupabaseProjectIDIsNilWhenTheFileIsMissing() {
        let runner = FakeRunner()
        runner.defaultResponse = nil
        XCTAssertNil(makeService(runner).supabaseProjectID(root: "/wt/a"))
    }
}
