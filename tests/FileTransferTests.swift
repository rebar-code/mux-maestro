import XCTest

// FileTransfer.swift + TmuxService.swift + TmuxCommands.swift +
// SshConfig.swift are compiled into this test target, so the M11 command
// construction and the drop sequence can be asserted against a fake
// CommandRunner with no real scp / ssh / tmux spawned.

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

final class FileTransferTests: XCTestCase {
    private let tmux = "/usr/bin/tmux"
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

    // MARK: copyArgv — local cp vs remote scp+ControlMaster

    func testCopyArgvLocalDropIsCpLocalToRemoteOrder() {
        // Local host ⇒ cp <local> <dest>.
        let (path, args) = FileTransfer.copyArgv(
            host: .local, localPath: "/tmp/drop.png",
            remotePath: "/Users/x/proj/drop.png")
        XCTAssertEqual(path, "/bin/cp")
        XCTAssertEqual(args, ["/tmp/drop.png", "/Users/x/proj/drop.png"])
    }

    func testCopyArgvRemoteDropPutsHostOperandLast() {
        let (path, args) = FileTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/drop.svg",
            remotePath: "/home/me/proj/drop.svg")
        XCTAssertEqual(path, "/usr/bin/scp")
        // ControlMaster opts present (connection reuse with the tree loads).
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        // local source first (raw argv), remote dest operand last (path
        // shell-quoted — scp expands it through the remote login shell).
        XCTAssertEqual(Array(args.suffix(2)),
            ["/tmp/drop.svg", "buildbox:'/home/me/proj/drop.svg'"])
    }

    func testCopyArgvLocalCpOperandsAreRawArgvRemoteIsShellQuoted() {
        // LOCAL cp: operands are argv elements to /bin/cp (no shell) — a space
        // in the path needs no quoting and must reach cp verbatim.
        let (_, localArgs) = FileTransfer.copyArgv(
            host: .local, localPath: "/tmp/my out.html",
            remotePath: "/Users/x/My Proj/my out.html")
        XCTAssertEqual(localArgs, ["/tmp/my out.html", "/Users/x/My Proj/my out.html"])

        // REMOTE scp: the remote path is expanded by the remote LOGIN SHELL, so
        // the path portion of the `alias:` operand must be shell-quoted. The
        // local operand stays raw argv.
        let (_, remoteArgs) = FileTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/my out.html",
            remotePath: "/home/me/My Proj/my out.html")
        XCTAssertEqual(remoteArgs[remoteArgs.count - 2], "/tmp/my out.html")
        XCTAssertEqual(remoteArgs.last, "buildbox:'/home/me/My Proj/my out.html'")
    }

    // MARK: copyArgv — scp remote-operand shell-injection defense

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

    func testCopyArgvRemoteOperandQuotesInjectionPayloads() {
        let payloads = [
            "/tmp/a;rm -rf b.png",
            "/x/$(id).png",
            "/x/`id`.png",
            "~/r;m.html",          // leading-tilde with metachar → fully quoted
        ]
        for payload in payloads {
            // The remote operand is last.
            let (_, drop) = FileTransfer.copyArgv(
                host: buildbox, localPath: "/tmp/out", remotePath: payload)
            assertRemotePathSafelyQuoted(drop.last!)
        }
    }

    func testCopyArgvBenignTildePathKeepsTildeBareRestQuoted() {
        // A safe `~/report.html` still tilde-expands on the remote: the `~/`
        // stays bare, the rest is single-quoted (matches the app's other quoting).
        let (_, args) = FileTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/out", remotePath: "~/report.html")
        XCTAssertEqual(args.last, "buildbox:~/'report.html'")
    }

    func testCopyArgvMaliciousLeadingTildeFallsBackToFullQuoting() {
        // `~/r;m.html` — the metachar is past the tilde segment, so the tilde
        // stays bare but the `;` is safely inside the single-quoted remainder.
        let (_, args) = FileTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/out", remotePath: "~/r;m.html")
        XCTAssertEqual(args.last, "buildbox:~/'r;m.html'")

        // `~;rm.html` — the metachar is INSIDE the tilde segment (no slash), so
        // the helper fails its tilde-segment validation and fully quotes the
        // whole token; the `~` is NOT left bare.
        let (_, args2) = FileTransfer.copyArgv(
            host: buildbox, localPath: "/tmp/out", remotePath: "~;rm.html")
        XCTAssertEqual(args2.last, "buildbox:'~;rm.html'")
    }

    // MARK: captureScrollbackArgv

    func testCaptureScrollbackArgvAsksForHistoryAndColourAndKeepsWrapping() {
        XCTAssertEqual(
            FileTransfer.captureScrollbackArgv(target: "%12", lines: 2000),
            ["capture-pane", "-p", "-e", "-S", "-2000", "-t", "%12"])
        // No -J: lines keep the pane's own wrapping.
        XCTAssertFalse(FileTransfer.captureScrollbackArgv(target: "%12", lines: 5).contains("-J"))
        // A negative count can never turn into a positive start line.
        XCTAssertEqual(FileTransfer.captureScrollbackArgv(target: "%1", lines: -5)[4], "-0")
        // The plain capture its other callers use is unchanged.
        XCTAssertEqual(FileTransfer.capturePaneArgv(target: "%12"), ["capture-pane", "-p", "-t", "%12"])
    }

    // MARK: capturePaneArgv

    func testCapturePaneArgv() {
        XCTAssertEqual(
            FileTransfer.capturePaneArgv(target: "web:1.%12"),
            ["capture-pane", "-p", "-t", "web:1.%12"])
    }

    // MARK: destination helper

    func testDropDestinationJoinsCwdAndFileNameNormalizingSlash() {
        XCTAssertEqual(
            FileTransfer.dropDestination(cwd: "/home/me/proj", fileName: "a.png"),
            "/home/me/proj/a.png")
        XCTAssertEqual(
            FileTransfer.dropDestination(cwd: "/home/me/proj/", fileName: "a.png"),
            "/home/me/proj/a.png")
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
