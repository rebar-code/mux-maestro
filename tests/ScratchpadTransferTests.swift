import XCTest

// ScratchpadTransfer.swift + TmuxService.swift + TmuxCommands.swift +
// SshConfig.swift are compiled into this test target, so the M11 command
// construction and the grab/drop sequences can be asserted against a fake
// CommandRunner with no real scp / ssh / scratchpad / tmux spawned.

/// Records every command and replies from a scripted table so the exact argv
/// sequence + stdin presence can be asserted. (Local to this file; the M5
/// FakeRunner is private to TmuxServiceTests.)
private final class FakeRunner: CommandRunner {
    private(set) var calls: [(path: String, args: [String], hadStdin: Bool)] = []
    var responses: [String: String?] = [:]
    var defaultResponse: String? = ""

    func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
        calls.append((path, args, stdin != nil))
        let key = args.joined(separator: " ")
        if let scripted = responses[key] { return scripted }
        return defaultResponse
    }

    var argSequences: [[String]] { calls.map(\.args) }
}

private struct StaticStatus: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}

final class ScratchpadTransferTests: XCTestCase {
    private let tmux = "/usr/bin/tmux"
    private let py = "/usr/bin/python3"
    private let script = "/Users/x/.claude/skills/local-scratchpad/scratchpad.py"
    private let buildbox = Host(name: "buildbox", sshAlias: "buildbox")

    private func localService(_ runner: FakeRunner) -> TmuxService {
        TmuxService(runner: runner, statusProvider: StaticStatus(), tmuxPath: tmux)
    }
    private func remoteService(_ runner: FakeRunner, host: String = "buildbox") -> TmuxService {
        TmuxService(
            host: Host(name: host, sshAlias: host),
            transport: SshTmuxTransport(host: host),
            runner: runner, statusProvider: StaticStatus())
    }

    // MARK: copyArgv — local cp vs remote scp+ControlMaster, src/dst ordering

    func testCopyArgvLocalGrabIsCpRemoteToLocalOrder() {
        // GRAB on local: remote is the source ⇒ cp <src> <dst>.
        let (path, args) = ScratchpadTransfer.copyArgv(
            host: .local, localPath: "/tmp/out.html",
            remotePath: "/Users/x/report.html", remoteIsSource: true)
        XCTAssertEqual(path, "/bin/cp")
        XCTAssertEqual(args, ["/Users/x/report.html", "/tmp/out.html"])
    }

    func testCopyArgvLocalDropIsCpLocalToRemoteOrder() {
        // DROP on local: remote is the destination ⇒ cp <local> <dest>.
        let (path, args) = ScratchpadTransfer.copyArgv(
            host: .local, localPath: "/tmp/drop.png",
            remotePath: "/Users/x/proj/drop.png", remoteIsSource: false)
        XCTAssertEqual(path, "/bin/cp")
        XCTAssertEqual(args, ["/tmp/drop.png", "/Users/x/proj/drop.png"])
    }

    func testCopyArgvRemoteGrabIsScpWithControlMaster() {
        let (path, args) = ScratchpadTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/out.html",
            remotePath: "/home/me/report.html", remoteIsSource: true)
        XCTAssertEqual(path, "/usr/bin/scp")
        // ControlMaster opts present (connection reuse with the tree loads).
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        // remote source operand first (path shell-quoted — scp expands it
        // through the remote login shell), then the local dest (raw argv).
        XCTAssertEqual(Array(args.suffix(2)),
            ["buildbox:'/home/me/report.html'", "/tmp/out.html"])
    }

    func testCopyArgvRemoteDropPutsHostOperandLast() {
        let (path, args) = ScratchpadTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/drop.svg",
            remotePath: "/home/me/proj/drop.svg", remoteIsSource: false)
        XCTAssertEqual(path, "/usr/bin/scp")
        // local source first (raw argv), remote dest operand last (path
        // shell-quoted — scp expands it through the remote login shell).
        XCTAssertEqual(Array(args.suffix(2)),
            ["/tmp/drop.svg", "buildbox:'/home/me/proj/drop.svg'"])
    }

    func testCopyArgvLocalCpOperandsAreRawArgvRemoteIsShellQuoted() {
        // LOCAL cp: operands are argv elements to /bin/cp (no shell) — a space
        // in the path needs no quoting and must reach cp verbatim.
        let (_, localArgs) = ScratchpadTransfer.copyArgv(
            host: .local, localPath: "/tmp/my out.html",
            remotePath: "/Users/x/My Proj/my out.html", remoteIsSource: false)
        XCTAssertEqual(localArgs, ["/tmp/my out.html", "/Users/x/My Proj/my out.html"])

        // REMOTE scp: the remote path is expanded by the remote LOGIN SHELL, so
        // the path portion of the `alias:` operand must be shell-quoted. The
        // local operand stays raw argv.
        let (_, remoteArgs) = ScratchpadTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/my out.html",
            remotePath: "/home/me/My Proj/my out.html", remoteIsSource: true)
        XCTAssertEqual(remoteArgs.last, "/tmp/my out.html")
        XCTAssertEqual(remoteArgs[remoteArgs.count - 2],
            "buildbox:'/home/me/My Proj/my out.html'")
    }

    // MARK: copyArgv — scp remote-operand shell-injection defense (grab + drop)

    /// The remote-shell metacharacters that must never appear UNQUOTED in the
    /// remote operand's path portion (the bit after `alias:`).
    private func assertRemotePathSafelyQuoted(
        _ operand: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let colon = operand.firstIndex(of: ":") else {
            return XCTFail("operand \(operand) missing alias: prefix", file: file, line: line)
        }
        let path = String(operand[operand.index(after: colon)...])
        // A safe quoting either single-quotes the whole token, or (the tilde
        // case) keeps only a leading `~…/` bare and single-quotes the rest. In
        // both cases no metacharacter sits outside a single-quoted region.
        XCTAssertTrue(
            isShellSafeQuoted(path),
            "remote path portion not safely quoted: \(path)", file: file, line: line)
    }

    /// True iff every shell metacharacter in `s` lives inside a single-quoted
    /// span — i.e. the string can't inject into the remote login shell.
    private func isShellSafeQuoted(_ s: String) -> Bool {
        let danger: Set<Character> = [";", "$", "`", "&", "|", " ", "(", ")", "<", ">", "\n"]
        var inQuote = false
        for ch in s {
            if ch == "'" { inQuote.toggle(); continue }
            if !inQuote && danger.contains(ch) { return false }
        }
        return true
    }

    func testCopyArgvRemoteOperandQuotesInjectionPayloadsGrabAndDrop() {
        let payloads = [
            "/tmp/a;rm -rf b.png",
            "/x/$(id).png",
            "/x/`id`.png",
            "~/r;m.html",          // leading-tilde with metachar → fully quoted
        ]
        for payload in payloads {
            // GRAB (remoteIsSource: true) — remote operand is first.
            let (_, grab) = ScratchpadTransfer.copyArgv(
                host: buildbox, localPath: "/tmp/out", remotePath: payload, remoteIsSource: true)
            assertRemotePathSafelyQuoted(grab[grab.count - 2])
            // DROP (remoteIsSource: false) — remote operand is last.
            let (_, drop) = ScratchpadTransfer.copyArgv(
                host: buildbox, localPath: "/tmp/out", remotePath: payload, remoteIsSource: false)
            assertRemotePathSafelyQuoted(drop.last!)
        }
    }

    func testCopyArgvBenignTildePathKeepsTildeBareRestQuoted() {
        // A safe `~/report.html` still tilde-expands on the remote: the `~/`
        // stays bare, the rest is single-quoted (matches the app's other quoting).
        let (_, args) = ScratchpadTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/out", remotePath: "~/report.html",
            remoteIsSource: true)
        XCTAssertEqual(args[args.count - 2], "buildbox:~/'report.html'")
    }

    func testCopyArgvMaliciousLeadingTildeFallsBackToFullQuoting() {
        // `~/r;m.html` — the metachar is past the tilde segment, so the tilde
        // stays bare but the `;` is safely inside the single-quoted remainder.
        let (_, args) = ScratchpadTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/out", remotePath: "~/r;m.html",
            remoteIsSource: true)
        XCTAssertEqual(args[args.count - 2], "buildbox:~/'r;m.html'")

        // `~;rm.html` — the metachar is INSIDE the tilde segment (no slash), so
        // the helper fails its tilde-segment validation and fully quotes the
        // whole token; the `~` is NOT left bare.
        let (_, args2) = ScratchpadTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/out", remotePath: "~;rm.html",
            remoteIsSource: true)
        XCTAssertEqual(args2[args2.count - 2], "buildbox:'~;rm.html'")
    }

    // MARK: capturePaneArgv

    func testCapturePaneArgv() {
        XCTAssertEqual(
            ScratchpadTransfer.capturePaneArgv(target: "web:1.%12"),
            ["capture-pane", "-p", "-t", "web:1.%12"])
    }

    // MARK: scratchpad invocations (add vs push --kind, title)

    func testAddInvocation() {
        let (path, args) = ScratchpadTransfer.addInvocation(
            python: py, scriptPath: script, file: "/tmp/out.html", title: "report.html @ buildbox")
        XCTAssertEqual(path, py)
        XCTAssertEqual(args, [script, "add", "/tmp/out.html", "--title", "report.html @ buildbox"])
    }

    func testPushInvocationCarriesKindAndTitle() {
        let (path, args) = ScratchpadTransfer.pushInvocation(
            python: py, scriptPath: script, kind: "text", title: "web:1 @ buildbox")
        XCTAssertEqual(path, py)
        XCTAssertEqual(args, [script, "push", "--kind", "text", "--title", "web:1 @ buildbox"])
    }

    // MARK: title + destination helpers

    func testFileTitleIsBasenameAtHost() {
        XCTAssertEqual(
            ScratchpadTransfer.fileTitle(path: "/home/me/sub/report.html", host: buildbox),
            "report.html @ buildbox")
        XCTAssertEqual(
            ScratchpadTransfer.fileTitle(path: "/tmp/x.png", host: .local),
            "x.png @ localhost")
    }

    func testPaneTitle() {
        XCTAssertEqual(
            ScratchpadTransfer.paneTitle(session: "web", window: 2, host: buildbox),
            "web:2 @ buildbox")
    }

    func testDropDestinationJoinsCwdAndFileNameNormalizingSlash() {
        XCTAssertEqual(
            ScratchpadTransfer.dropDestination(cwd: "/home/me/proj", fileName: "a.png"),
            "/home/me/proj/a.png")
        XCTAssertEqual(
            ScratchpadTransfer.dropDestination(cwd: "/home/me/proj/", fileName: "a.png"),
            "/home/me/proj/a.png")
    }

    // MARK: grabFileToScratchpad — local adds the file directly

    func testGrabFileLocalAddsFileWithoutCopy() {
        let runner = FakeRunner()
        let ok = localService(runner).grabFileToScratchpad(
            remotePath: "/Users/x/report.html", localStaging: "/tmp/staged.html",
            python: py, scratchpadScript: script)
        XCTAssertTrue(ok)
        // Local: no cp/scp — the file is added directly to the scratchpad.
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].path, py)
        XCTAssertEqual(runner.calls[0].args,
            [script, "add", "/Users/x/report.html", "--title", "report.html @ localhost"])
    }

    // MARK: grabFileToScratchpad — remote scps down, then adds the staged copy

    func testGrabFileRemoteScpsThenAddsStagedCopy() {
        let runner = FakeRunner()
        let ok = remoteService(runner).grabFileToScratchpad(
            remotePath: "/home/me/report.html", localStaging: "/tmp/staged.html",
            python: py, scratchpadScript: script)
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls.count, 2)
        // 1) scp remote:path → staging
        XCTAssertEqual(runner.calls[0].path, "/usr/bin/scp")
        XCTAssertEqual(Array(runner.calls[0].args.suffix(2)),
            ["buildbox:'/home/me/report.html'", "/tmp/staged.html"])
        // 2) scratchpad add the STAGED local copy (not the remote path)
        XCTAssertEqual(runner.calls[1].args,
            [script, "add", "/tmp/staged.html", "--title", "report.html @ buildbox"])
    }

    func testGrabFileRemoteAbortsWhenScpFails() {
        let runner = FakeRunner()
        runner.defaultResponse = String?.none  // scp fails
        let ok = remoteService(runner).grabFileToScratchpad(
            remotePath: "/home/me/x.html", localStaging: "/tmp/s.html",
            python: py, scratchpadScript: script)
        XCTAssertFalse(ok)
        XCTAssertEqual(runner.calls.count, 1)  // never reaches the scratchpad add
    }

    // MARK: grabPaneOutputToScratchpad — capture-pane → push --kind text (stdin)

    func testGrabPaneOutputCapturesThenPushesTextOverStdin() {
        let runner = FakeRunner()
        runner.responses["capture-pane -p -t %12"] = "line one\nline two\n"
        let ok = localService(runner).grabPaneOutputToScratchpad(
            session: "web", window: 1, paneTarget: "%12",
            python: py, scratchpadScript: script)
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].args, ["capture-pane", "-p", "-t", "%12"])
        // push --kind text --title "web:1 @ localhost", bytes on stdin.
        XCTAssertEqual(runner.calls[1].args,
            [script, "push", "--kind", "text", "--title", "web:1 @ localhost"])
        XCTAssertTrue(runner.calls[1].hadStdin)
    }

    func testGrabPaneOutputRemoteCaptureIsSshWrapped() {
        let runner = FakeRunner()
        runner.responses["'tmux' 'capture-pane' '-p' '-t' '%9'"] = "remote text"
        // Remote capture-pane is ssh-wrapped + quoted by the transport. The
        // FakeRunner keys on the FULL args, so script the ssh-wrapped form:
        let svc = remoteService(runner)
        // Find the wrapped key dynamically — build the expected args via opts.
        runner.responses.removeAll()
        runner.defaultResponse = "remote text"
        let ok = svc.grabPaneOutputToScratchpad(
            session: "api", window: 0, paneTarget: "%9",
            python: py, scratchpadScript: script)
        XCTAssertTrue(ok)
        // First call is the ssh-wrapped capture-pane; last is the local push.
        XCTAssertEqual(runner.calls[0].path, "/usr/bin/ssh")
        XCTAssertEqual(Array(runner.calls[0].args.suffix(5)),
            ["'tmux'", "'capture-pane'", "'-p'", "'-t'", "'%9'"])
        XCTAssertEqual(runner.calls.last!.args,
            [script, "push", "--kind", "text", "--title", "api:0 @ buildbox"])
    }

    // MARK: dropFileToSession — resolve cwd → scp/cp → PASTE the path (no Enter)

    func testDropFileLocalResolvesCwdCopiesThenPastesPathNoEnter() {
        let runner = FakeRunner()
        // sessionCwd reads the active pane's path.
        runner.responses["display-message -p -t web #{pane_current_path}"] = "/Users/x/proj\n"
        let dest = localService(runner).dropFileToSession(
            session: "web", localFile: "/tmp/chart.png")
        XCTAssertEqual(dest, "/Users/x/proj/chart.png")

        let seq = runner.argSequences
        // 1) cwd resolve, 2) cp into cwd, 3) load-buffer (path on stdin), 4) paste
        XCTAssertEqual(seq[0], ["display-message", "-p", "-t", "web", "#{pane_current_path}"])
        XCTAssertEqual(runner.calls[1].path, "/bin/cp")
        XCTAssertEqual(runner.calls[1].args, ["/tmp/chart.png", "/Users/x/proj/chart.png"])
        XCTAssertEqual(seq[2], ["load-buffer", "-b", "sidekick", "-"])
        XCTAssertTrue(runner.calls[2].hadStdin)  // the path is streamed in
        XCTAssertEqual(seq[3], ["paste-buffer", "-d", "-b", "sidekick", "-t", "web"])
        // CRITICAL (M11 decision): no send-keys Enter — the path is pasted, not run.
        XCTAssertFalse(seq.contains(["send-keys", "-t", "web", "Enter"]))
    }

    func testDropFilePastesTheRemotePathText() {
        // Assert the pasted TEXT is exactly the destination path (over stdin).
        var capturedStdin: Data?
        final class StdinCapture: CommandRunner {
            var onStdin: (Data?) -> Void = { _ in }
            var responses: [String: String?] = [:]
            func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
                if args.first == "load-buffer" { onStdin(stdin) }
                if args == ["display-message", "-p", "-t", "web", "#{pane_current_path}"] {
                    return "/home/me/proj"
                }
                return ""
            }
        }
        let runner = StdinCapture()
        runner.onStdin = { capturedStdin = $0 }
        let svc = TmuxService(runner: runner, statusProvider: StaticStatus(), tmuxPath: tmux)
        let dest = svc.dropFileToSession(session: "web", localFile: "/tmp/a.svg")
        XCTAssertEqual(dest, "/home/me/proj/a.svg")
        XCTAssertEqual(capturedStdin.flatMap { String(data: $0, encoding: .utf8) },
            "/home/me/proj/a.svg")
    }

    func testDropFileTrailingSpacePastesPathWithSpaceButReturnsBarePath() {
        // The terminal-pane drop asks for a trailing space (old type-the-path UX):
        // the pasted TEXT is `<path> ` but the returned dest stays the bare path.
        var capturedStdin: Data?
        final class StdinCapture: CommandRunner {
            var onStdin: (Data?) -> Void = { _ in }
            func run(_ path: String, _ args: [String], stdin: Data?) -> String? {
                if args.first == "load-buffer" { onStdin(stdin) }
                if args == ["display-message", "-p", "-t", "web", "#{pane_current_path}"] {
                    return "/home/me/proj"
                }
                return ""
            }
        }
        let runner = StdinCapture()
        runner.onStdin = { capturedStdin = $0 }
        let svc = TmuxService(runner: runner, statusProvider: StaticStatus(), tmuxPath: tmux)
        let dest = svc.dropFileToSession(
            session: "web", localFile: "/tmp/a.svg", trailingSpace: true)
        XCTAssertEqual(dest, "/home/me/proj/a.svg")
        XCTAssertEqual(capturedStdin.flatMap { String(data: $0, encoding: .utf8) },
            "/home/me/proj/a.svg ")
    }

    func testDropFileRemoteScpsToCwdThenPastes() {
        let runner = FakeRunner()
        // Every remote call is ssh-wrapped + quoted; the cwd probe returns the
        // path (non-cwd calls returning the same string is harmless — they only
        // need a non-nil success). defaultResponse covers the full ssh argv key.
        runner.defaultResponse = "/home/me/proj\n"
        let dest = remoteService(runner).dropFileToSession(
            session: "web", localFile: "/tmp/a.png")
        XCTAssertEqual(dest, "/home/me/proj/a.png")
        // The copy step is scp local → buildbox:dest.
        let scp = runner.calls.first { $0.path == "/usr/bin/scp" }
        XCTAssertNotNil(scp)
        XCTAssertEqual(Array(scp!.args.suffix(2)),
            ["/tmp/a.png", "buildbox:'/home/me/proj/a.png'"])
        // The paste is ssh-wrapped paste-buffer; never a send-keys Enter.
        XCTAssertFalse(runner.argSequences.contains { $0.contains("'Enter'") })
    }

    func testDropFileAbortsWhenCwdUnavailable() {
        let runner = FakeRunner()
        runner.responses["display-message -p -t web #{pane_current_path}"] = String?.none
        let dest = localService(runner).dropFileToSession(
            session: "web", localFile: "/tmp/a.png")
        XCTAssertNil(dest)
        // Only the cwd probe ran; no copy/paste attempted.
        XCTAssertEqual(runner.calls.count, 1)
    }
}
