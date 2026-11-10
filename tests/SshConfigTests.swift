import XCTest

// SshConfig.swift (Foundation-only) is compiled into this test target, so the
// pure ssh-config parsing + ssh command construction can be asserted without
// touching the real ~/.ssh/config or spawning ssh.

final class SshConfigTests: XCTestCase {
    // MARK: Host parsing

    func testParsesSingleAliasHosts() {
        let config = """
        Host nas
            HostName nas.example.com
            User dev
        """
        XCTAssertEqual(SshConfig.parseHosts(config).map(\.name), ["nas"])
    }

    func testParsesMultiAliasLineAsSeparateHosts() {
        // `Host host3 host3-server` → two hosts, both ssh-reachable by their alias.
        let config = "Host host3 host3-server\n    HostName 100.64.0.2\n"
        let hosts = SshConfig.parseHosts(config)
        XCTAssertEqual(hosts.map(\.name), ["host3", "host3-server"])
        XCTAssertEqual(hosts.map(\.sshAlias), ["host3", "host3-server"])
    }

    func testSkipsWildcardPatterns() {
        // `Host *` and `Host *.example ?` patterns are skipped (matching the awk
        // `$i!~/[*?]/` filter), but real aliases on other lines survive.
        let config = """
        Host *
            ForwardAgent yes
        Host buildbox buildbox1
            HostName 100.64.0.1
        Host web?
            HostName x
        """
        XCTAssertEqual(SshConfig.parseHosts(config).map(\.name), ["buildbox", "buildbox1"])
    }

    func testDeduplicatesRepeatedAliasPreservingOrder() {
        // The real config lists `sftp.example.com` several times; collapse to first.
        let config = """
        Host sftp.example.com
        Host alpha
        Host sftp.example.com
        """
        XCTAssertEqual(SshConfig.parseHosts(config).map(\.name), ["sftp.example.com", "alpha"])
    }

    func testIgnoresCommentsAndBlankLines() {
        let config = """
        # a comment
        Host beta  # trailing comment

        HostName example.com
        """
        XCTAssertEqual(SshConfig.parseHosts(config).map(\.name), ["beta"])
    }

    func testCaseInsensitiveHostKeyword() {
        XCTAssertEqual(SshConfig.parseHosts("HOST gamma\n").map(\.name), ["gamma"])
        XCTAssertEqual(SshConfig.parseHosts("host delta\n").map(\.name), ["delta"])
    }

    func testNonHostLinesNeverProduceHosts() {
        // A `HostName` line must not be mistaken for a `Host` line.
        let config = "HostName not-a-host\nHost real\n"
        XCTAssertEqual(SshConfig.parseHosts(config).map(\.name), ["real"])
    }

    func testEmptyConfigYieldsNoRemoteHosts() {
        XCTAssertTrue(SshConfig.parseHosts("").isEmpty)
    }

    // MARK: Ssh option construction (ControlMaster reuse + timeouts)

    func testSshOptsContainControlMasterReuseAndTimeouts() {
        let opts = Ssh.opts(host: "buildbox")
        // ControlMaster=auto + per-host ControlPath + ControlPersist multiplex
        // all commands to a host over one connection.
        XCTAssertTrue(opts.contains("ControlMaster=auto"))
        XCTAssertTrue(opts.contains("ControlPersist=60s"))
        XCTAssertTrue(opts.contains("ConnectTimeout=4"))
        // Keepalives so a connected-but-wedged host is torn down in ~5s instead of
        // hanging each command near its ceiling and stalling the whole poll cycle.
        XCTAssertTrue(opts.contains("ServerAliveInterval=5"))
        XCTAssertTrue(opts.contains("ServerAliveCountMax=1"))
        XCTAssertTrue(opts.contains("BatchMode=yes"))
        // The control path is per remote-user@host:port via ssh's own tokens.
        XCTAssertTrue(opts.contains { $0.hasPrefix("ControlPath=") && $0.contains("ssh-%r@%h:%p") })
        // The host alias is the final token.
        XCTAssertEqual(opts.last, "buildbox")
    }

    // MARK: Remote command construction (ssh prefixing of tmux argv)

    func testRemoteTransportPrefixesSshAndQuotesTmuxArgv() {
        let transport = SshTmuxTransport(host: "buildbox")
        // A `-F #{…}` format string is the critical case: ssh re-parses the
        // remote command through a shell, so `#` must be quoted or it starts a
        // remote-shell comment and eats the rest of the line.
        let cmd = transport.command(forTmux: ["list-sessions", "-F", "#{session_name}"])
        XCTAssertEqual(cmd?.path, "/usr/bin/ssh")
        let args = cmd?.args ?? []
        // Each tmux token is single-quoted so the remote shell gets it verbatim.
        XCTAssertEqual(Array(args.suffix(4)),
            ["'tmux'", "'list-sessions'", "'-F'", "'#{session_name}'"])
        XCTAssertTrue(args.contains("'tmux'"))
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        // The host appears immediately before the (quoted) remote tmux call.
        let tmuxIdx = args.firstIndex(of: "'tmux'")!
        XCTAssertEqual(args[tmuxIdx - 1], "buildbox")
    }

    func testLocalTransportRunsTmuxDirectly() {
        let transport = LocalTmuxTransport(tmuxPath: "/usr/bin/tmux")
        let cmd = transport.command(forTmux: ["list-sessions"])
        XCTAssertEqual(cmd?.path, "/usr/bin/tmux")
        XCTAssertEqual(cmd?.args, ["list-sessions"])
    }

    func testLocalTransportNilWhenNoTmux() {
        XCTAssertNil(LocalTmuxTransport(tmuxPath: nil).command(forTmux: ["list-sessions"]))
    }

    // MARK: Attach-command construction (the libghostty surface command line)

    func testRemoteAttachCommandUsesPtyAndAttachOrCreate() {
        let cmd = SshTmuxTransport(host: "buildbox").attachCommand(session: "api")
        // -t forces a PTY; new-session -A is attach-or-create.
        XCTAssertNotNil(cmd)
        XCTAssertTrue(cmd!.hasPrefix("/usr/bin/ssh -t "))
        XCTAssertTrue(cmd!.contains("ControlMaster=auto"))
        XCTAssertTrue(cmd!.contains(" buildbox "))
        // The remote command (TERM + attach-or-create) is wrapped as ONE
        // local-shell arg so it survives both shell parses intact.
        let remote = "env TERM=xterm-256color tmux new-session -A -s 'api'"
        XCTAssertTrue(cmd!.hasSuffix(Ssh.shellQuote(remote)))
        // The host must appear exactly once (Ssh.opts already ends with it);
        // a duplicate made ssh run `<host>` as the remote command.
        XCTAssertFalse(cmd!.contains("buildbox buildbox"))
    }

    func testRemoteAttachSurvivesSpaceInSessionName() {
        // A session name with a space must reach the remote tmux as a SINGLE
        // token after both shell parses — else `-s buildbox serv` split and tmux
        // ran `serv` as a command (the bug this guards).
        let cmd = SshTmuxTransport(host: "buildbox").attachCommand(session: "buildbox serv")!
        let remote = "env TERM=xterm-256color tmux new-session -A -s 'buildbox serv'"
        XCTAssertTrue(cmd.hasSuffix(Ssh.shellQuote(remote)))
    }

    func testLocalAttachCommandUsesTmuxAttach() {
        let cmd = LocalTmuxTransport(tmuxPath: "/usr/bin/tmux").attachCommand(session: "web")
        XCTAssertEqual(cmd, "/usr/bin/tmux attach -t 'web'")
    }

    func testAttachCommandQuotesSessionName() {
        // A session name with a quote is single-quote-escaped at BOTH levels so
        // neither the local nor the remote shell can be broken out of.
        let cmd = SshTmuxTransport(host: "h").attachCommand(session: "a'b")!
        let remote = "env TERM=xterm-256color tmux new-session -A -s " + Ssh.shellQuote("a'b")
        XCTAssertTrue(cmd.hasSuffix(Ssh.shellQuote(remote)))
    }

    // MARK: Mosh attach-command construction (Phase 2 — roaming attach)

    private let mosh = "/opt/homebrew/bin/mosh"

    func testMoshAttachCommandShape() {
        let t = SshTmuxTransport(host: "buildbox", moshPath: mosh)
        let cmd = t.moshAttachCommand(session: "api")!
        // mosh client first, then --ssh=<flags> (single-quoted for local bash),
        // the host as a positional arg, then -- and the remote command.
        XCTAssertTrue(cmd.hasPrefix("/opt/homebrew/bin/mosh --ssh="))
        // --ssh carries the ControlMaster flags but NOT the host (mosh appends it).
        let sshCmd = "/usr/bin/ssh " + Ssh.controlFlags.joined(separator: " ")
        XCTAssertTrue(cmd.contains("--ssh=" + Ssh.shellQuote(sshCmd)))
        XCTAssertTrue(cmd.contains(" buildbox -- "))
        // The remote command after `--`: env TERM + attach-or-create, session quoted.
        XCTAssertTrue(cmd.hasSuffix(
            "-- env TERM=xterm-256color tmux new-session -A -s 'api'"))
    }

    func testMoshAttachDoesNotDuplicateHostInSshFlags() {
        // The host must appear exactly once — as mosh's positional arg, never
        // inside the --ssh flags (Ssh.controlFlags has no host).
        let cmd = SshTmuxTransport(host: "buildbox", moshPath: mosh).moshAttachCommand(session: "api")!
        XCTAssertFalse(cmd.contains("buildbox buildbox"))
        // Count host occurrences: exactly one ` buildbox ` token.
        XCTAssertEqual(cmd.components(separatedBy: " buildbox ").count - 1, 1)
    }

    func testMoshAttachSurvivesSpaceInSessionName() {
        let cmd = SshTmuxTransport(host: "h", moshPath: mosh).moshAttachCommand(session: "out serv")!
        // Local bash keeps the name one token via the single quote; mosh execs
        // the post-`--` argv directly (no remote shell), so one quote suffices.
        XCTAssertTrue(cmd.hasSuffix("-A -s 'out serv'"))
    }

    func testMoshAttachNilWhenMoshNotInstalledLocally() {
        let cmd = SshTmuxTransport(host: "h", moshPath: nil).moshAttachCommand(session: "api")
        XCTAssertNil(cmd)
    }

    func testOptsIsControlFlagsPlusHost() {
        // The refactor must not change the existing opts shape.
        XCTAssertEqual(Ssh.opts(host: "buildbox"), Ssh.controlFlags + ["buildbox"])
        XCTAssertFalse(Ssh.controlFlags.contains("buildbox"))
    }

    // MARK: Tilde-preserving quoting (PR#9 carry-over fix)

    func testShellQuoteAllowingTildeBareTildeUnquoted() {
        // Bare `~` reaches the remote shell unquoted so it expands to $HOME.
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~"), "~")
    }

    func testShellQuoteAllowingTildeKeepsTildePrefixQuotesRest() {
        // `~/foo` → `~/'foo'` — tilde expands, the rest stays verbatim-quoted.
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~/code"), "~/'code'")
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~/My Code/api"), "~/'My Code/api'")
    }

    func testShellQuoteAllowingTildeUserHome() {
        // `~deploy` and `~deploy/app` keep the tilde-user segment literal.
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~deploy"), "~deploy")
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~deploy/app"), "~deploy/'app'")
    }

    func testShellQuoteAllowingTildeNonTildePathFullyQuoted() {
        // A path without a leading tilde is quoted exactly like shellQuote — the
        // fix must not weaken quoting for any other token.
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("/abs/path"), "'/abs/path'")
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("a~b"),
            Ssh.shellQuote("a~b"))  // tilde not leading → fully quoted
    }

    // MARK: Tilde-preserving quoting — shell-injection defense (BLOCKER fix)

    /// Every adversarial payload the free-text remote new-session dir could carry.
    /// All must come back FULLY single-quoted (no bare-tilde leak), so the remote
    /// login shell sees inert text — never live metacharacters.
    private static let injectionPayloads: [String] = [
        "~; rm -rf ~/data",
        "~`id`",
        "~&&id",
        "~|id",
        "~ ; ls",
        "~$(touch /x)",
        "~user; id",
        "~; ls",            // no-slash with metachar
        "~$(id)/code",      // slash form with command substitution before the slash
        "~`id`/x",          // slash form with backticks before the slash
        "~ /code",          // space in the tilde segment (slash form)
    ]

    func testShellQuoteAllowingTildeFallsBackToFullQuotingOnInjection() {
        for payload in Self.injectionPayloads {
            let out = Ssh.shellQuoteAllowingTilde(payload)
            // Dangerous inputs fall back to exactly shellQuote — fully quoted.
            XCTAssertEqual(out, Ssh.shellQuote(payload),
                "payload should be fully quoted: \(payload) → \(out)")
        }
    }

    func testShellQuoteAllowingTildeNeverEmitsUnquotedMetacharacters() {
        // For every payload, no shell metacharacter may appear OUTSIDE a single-
        // quoted span. Single quotes are literal in sh, so scan only the regions
        // between quotes and assert they're free of `;` ` $ & | and space.
        let dangerous: Set<Character> = [";", "`", "$", "&", "|", " "]
        for payload in Self.injectionPayloads {
            let out = Ssh.shellQuoteAllowingTilde(payload)
            var insideQuote = false
            for ch in out {
                if ch == "'" { insideQuote.toggle(); continue }
                if !insideQuote {
                    XCTAssertFalse(dangerous.contains(ch),
                        "unquoted metachar '\(ch)' in output for payload \(payload): \(out)")
                }
            }
        }
    }

    func testShellQuoteAllowingTildeKeepsLegitCasesBare() {
        // The legit tilde cases must still go bare so they tilde-expand remotely.
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~"), "~")
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~/code/x"), "~/'code/x'")
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("~deploy/app"), "~deploy/'app'")
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("/abs/path"), "'/abs/path'")
        XCTAssertEqual(Ssh.shellQuoteAllowingTilde("a~b"), Ssh.shellQuote("a~b"))
    }

    // MARK: CRLF config parsing (SHOULD-FIX)

    func testParsesHostsFromCRLFConfig() {
        // A CRLF config must parse identically to an LF one — `\r` must not cling
        // to the alias token.
        let config = "Host nas\r\n    HostName nas.example.com\r\nHost api\r\n"
        XCTAssertEqual(SshConfig.parseHosts(config).map(\.name), ["nas", "api"])
    }

    // MARK: loadHosts always includes local first

    func testLoadHostsMissingConfigYieldsLocalOnly() {
        let hosts = SshConfig.loadHosts(path: "/nonexistent/ssh/config")
        XCTAssertEqual(hosts, [.local])
        XCTAssertTrue(hosts.first!.isLocal)
    }
}

// MARK: - SshHostGate

// The per-host guard in front of every background ssh. A host that accepts the
// login and then hangs in session setup must not get a fresh login every poll.

final class SshHostGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A gate that has seen one answer, so it admits concurrent commands.
    private func healthyGate() -> SshHostGate {
        let gate = SshHostGate()
        gate.end(gate.begin(now: t0)!, outcome: .answered, now: t0)
        return gate
    }

    // MARK: Backoff

    func testFailureSkipsHostUntilBackoffPasses() {
        let gate = healthyGate()
        gate.end(gate.begin(now: t0)!, outcome: .noSession, now: t0)
        XCTAssertNil(gate.begin(now: t0.addingTimeInterval(29)))
        XCTAssertTrue(gate.isBackingOff(now: t0.addingTimeInterval(29)))
        XCTAssertNotNil(gate.begin(now: t0.addingTimeInterval(30)))
    }

    func testConsecutiveFailuresGrowToCap() {
        let gate = SshHostGate()
        var now = t0
        for expected in [30.0, 60.0, 120.0, 240.0, 300.0, 300.0] {
            gate.end(gate.begin(now: now)!, outcome: .noSession, now: now)
            XCTAssertNil(gate.begin(now: now.addingTimeInterval(expected - 1)), "\(expected)")
            now = now.addingTimeInterval(expected)
        }
    }

    func testSuccessResetsBackoff() {
        let gate = SshHostGate()
        var now = t0
        for _ in 0..<3 {
            gate.end(gate.begin(now: now)!, outcome: .noSession, now: now)
            now = now.addingTimeInterval(300)
        }
        gate.end(gate.begin(now: now)!, outcome: .answered, now: now)
        XCTAssertFalse(gate.isBackingOff(now: now))
        // The next failure starts the ladder again at 30s, not 4 minutes.
        gate.end(gate.begin(now: now)!, outcome: .noSession, now: now)
        XCTAssertNotNil(gate.begin(now: now.addingTimeInterval(30)))
    }

    func testStragglerFailureDoesNotClimbTheLadder() {
        // Three polls started on a healthy host all hit the same outage: one
        // step of backoff, not three.
        let gate = healthyGate()
        let tickets = (0..<3).map { _ in gate.begin(now: t0)! }
        for ticket in tickets { gate.end(ticket, outcome: .noSession, now: t0.addingTimeInterval(8)) }
        XCTAssertNotNil(gate.begin(now: t0.addingTimeInterval(38)))
    }

    func testResetClearsBackoff() {
        let gate = SshHostGate()
        gate.end(gate.begin(now: t0)!, outcome: .noSession, now: t0)
        gate.reset()
        XCTAssertNotNil(gate.begin(now: t0.addingTimeInterval(1)))
    }

    // MARK: Single attempt in flight

    func testUnknownHostAdmitsOneAttemptAtATime() {
        let gate = SshHostGate()
        let first = gate.begin(now: t0)
        XCTAssertNotNil(first)
        XCTAssertNil(gate.begin(now: t0), "a second login while the first is still running")
        gate.end(first!, outcome: .answered, now: t0)
        XCTAssertNotNil(gate.begin(now: t0))
    }

    func testFailedHostAdmitsOneAttemptAfterBackoff() {
        let gate = SshHostGate()
        gate.end(gate.begin(now: t0)!, outcome: .noSession, now: t0)
        let later = t0.addingTimeInterval(30)
        XCTAssertNotNil(gate.begin(now: later))
        XCTAssertNil(gate.begin(now: later))
    }

    func testHealthyHostRunsCommandsConcurrently() {
        // Healthy hosts are unchanged: commands ride the ControlMaster together.
        let gate = healthyGate()
        XCTAssertNotNil(gate.begin(now: t0))
        XCTAssertNotNil(gate.begin(now: t0))
    }

    func testNeutralEndFreesTheSlot() {
        let gate = SshHostGate()
        gate.end(gate.begin(now: t0)!, outcome: nil, now: t0)
        XCTAssertNotNil(gate.begin(now: t0))
    }
}

// MARK: - SshGatedRunner

private final class EndScriptedRunner: EndReportingRunner {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var end: RunEnd = .exited(0)
    var output: Data? = Data("ok\n".utf8)
    /// When set, every run waits on it: a login that hangs.
    var hold: DispatchSemaphore?
    let started = DispatchSemaphore(value: 0)

    func runDataReportingEnd(_ path: String, _ args: [String], stdin: Data?)
        -> (data: Data?, end: RunEnd)
    {
        lock.lock(); _calls += 1; lock.unlock()
        started.signal()
        hold?.wait()
        return (end == .exited(0) ? output : nil, end)
    }

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        runDataReportingEnd(path, args, stdin: stdin).data
            .flatMap { String(data: $0, encoding: .utf8) }
    }
}

final class SshGatedRunnerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func remoteService(_ runner: CommandRunner) -> TmuxService {
        TmuxService(
            host: Host(name: "devbox", sshAlias: "devbox"),
            transport: SshTmuxTransport(host: "devbox"),
            runner: runner,
            statusProvider: nil)
    }

    func testHungLoginBacksOffInsteadOfReconnectingEveryPoll() {
        let inner = EndScriptedRunner()
        inner.end = .timedOut
        var clock = t0
        let runner = SshGatedRunner(inner: inner, gate: SshHostGate(), now: { clock })
        let service = remoteService(runner)

        XCTAssertEqual(service.probeReachability(), .unreachable)
        XCTAssertEqual(inner.calls, 1)
        // The next polls inside the backoff spawn no ssh and read as unreachable.
        for step in [4.5, 9.0, 29.0] {
            clock = t0.addingTimeInterval(step)
            XCTAssertEqual(service.probeReachability(), .unreachable)
        }
        XCTAssertEqual(inner.calls, 1)
        // Once it passes, one retry; the host answers and polling resumes.
        clock = t0.addingTimeInterval(31)
        inner.end = .exited(0)
        XCTAssertEqual(service.probeReachability(), .reachable)
        XCTAssertEqual(inner.calls, 2)
        XCTAssertEqual(service.probeReachability(), .reachable)
        XCTAssertEqual(inner.calls, 3)
    }

    func testKeepaliveTeardownCountsAsNoSession() {
        let inner = EndScriptedRunner()
        inner.end = .exited(255)
        let gate = SshHostGate()
        let runner = SshGatedRunner(inner: inner, gate: gate, now: { self.t0 })
        XCTAssertNil(runner.run("/usr/bin/ssh", ["devbox", "true"]))
        XCTAssertTrue(gate.isBackingOff(now: t0))
    }

    func testRemoteCommandFailureIsNotABackoff() {
        // `tmux list-sessions` with no server exits 1: the host answered.
        let inner = EndScriptedRunner()
        inner.end = .exited(1)
        let gate = SshHostGate()
        let runner = SshGatedRunner(inner: inner, gate: gate, now: { self.t0 })
        XCTAssertNil(runner.run("/usr/bin/ssh", ["devbox", "tmux", "ls"]))
        XCTAssertFalse(gate.isBackingOff(now: t0))
    }

    func testSlowRunnerTimeoutIsNotABackoff() {
        let inner = EndScriptedRunner()
        inner.end = .timedOut
        let gate = SshHostGate()
        let runner = SshGatedRunner(
            inner: inner, gate: gate, timeoutMeansNoSession: false, now: { self.t0 })
        XCTAssertNil(runner.run("/usr/bin/ssh", ["devbox", "docker", "ps"]))
        XCTAssertFalse(gate.isBackingOff(now: t0))
    }

    func testNoSecondSshWhileTheFirstLoginHangs() {
        let inner = EndScriptedRunner()
        let hold = DispatchSemaphore(value: 0)
        inner.hold = hold
        let runner = SshGatedRunner(inner: inner, gate: SshHostGate(), now: { self.t0 })

        let firstDone = expectation(description: "first ssh returns")
        DispatchQueue.global().async {
            _ = runner.run("/usr/bin/ssh", ["devbox", "echo", "ok"])
            firstDone.fulfill()
        }
        XCTAssertEqual(inner.started.wait(timeout: .now() + 5), .success)
        // The first login is still hanging: more polls must not spawn ssh.
        for _ in 0..<5 { XCTAssertNil(runner.run("/usr/bin/ssh", ["devbox", "echo", "ok"])) }
        XCTAssertEqual(inner.calls, 1)
        hold.signal()
        wait(for: [firstDone], timeout: 5)
    }
}
