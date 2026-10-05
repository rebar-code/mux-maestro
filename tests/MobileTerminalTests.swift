import Network
import XCTest

// The live terminal: the control-mode conversation as a pure state machine,
// then the whole path over a real loopback socket to a private tmux server
// (`tmux -L <name>`, never the default one).
final class MobileTerminalTests: XCTestCase {
    private let target = MobileTerminal.Target(pane: "%12", session: "$3")

    private func thread(pane: String = "%12", session: String = "$3") -> MobileThread {
        MobileThread(
            id: "devbox:12", host: .local, hostColor: "#3291ff", session: "acme-app", window: 1,
            name: "checkout-fix", pane: pane, sessionId: session, command: "claude",
            cwd: "/Users/me/acme-app", status: .busy, since: nil, idleStage: .awake, lastPrompt: nil,
            lastActivityAt: nil, sessionActivity: 0, claudeSessionId: nil, codexSessionId: nil)
    }

    func testTheConfirmationSaysWhatThePhoneGets() {
        XCTAssertTrue(MobileTerminal.confirmText.contains("full keyboard control"))
        XCTAssertTrue(MobileTerminal.confirmText.contains("answering permission prompts"))
    }

    // MARK: target

    func testTheTargetComesFromTheTreeAndIsPlainIDs() {
        XCTAssertEqual(MobileTerminal.target(thread()), target)
        for pane in ["12", "%", "%1;kill-server", "%1 -t %2", "%١٢", "@1", "", "%1\n", "%1234567890"] {
            XCTAssertNil(MobileTerminal.target(thread(pane: pane)), pane)
        }
        for session in ["", "acme-app", "$", "$1;x", "=acme", "$1 $2"] {
            XCTAssertNil(MobileTerminal.target(thread(session: session)), session)
        }
    }

    func testTheAttachCommandIsAControlClientThatIgnoresSize() {
        XCTAssertEqual(
            MobileTerminal.attachArgv(target), ["-C", "attach-session", "-t", "$3"])
        // Asked for after the attach, with flow control, in one command: a
        // tmux that knows neither refuses it, and the bridge ends.
        XCTAssertEqual(MobileTerminal.flowCommand, "refresh-client -f ignore-size,pause-after=1")
    }

    func testOverSshTheSupervisorRunsOnTheFarHostAndEveryWordIsQuoted() {
        let launch = MobileTerminalBridge.Launch.remote(
            sshPath: "/usr/bin/ssh", options: Ssh.opts(host: "devbox"), tmux: "tmux", target: target)
        XCTAssertEqual(launch.path, "/usr/bin/ssh")
        XCTAssertEqual(
            Array(launch.args.suffix(10)),
            [
                "devbox", "'sh'", "'-c'", "'\(MobileTerminal.supervisor)'", "'sh'", "'tmux'", "'-C'",
                "'attach-session'", "'-t'", "'$3'",
            ])
        // Nothing keeps ssh's input open or gives it a terminal: the end of
        // input must reach the far host.
        for flag in ["-t", "-tt", "-n", "-f", "-N"] { XCTAssertFalse(launch.args.contains(flag), flag) }
    }

    func testTheSupervisorIsOneWordForAnyShell() {
        // A quote, a backslash or a newline would need quoting that differs
        // between sh, csh and fish; `!` and a character after it is history in csh.
        for bad in ["'", "\\", "\n", "`"] { XCTAssertFalse(MobileTerminal.supervisor.contains(bad), bad) }
        XCTAssertNil(MobileTerminal.supervisor.range(of: #"![^ ]"#, options: .regularExpression))
        XCTAssertEqual(
            MobileTerminalBridge.Launch.supervised(.init(path: "/opt/homebrew/bin/tmux", args: ["-C"])),
            .init(path: "/bin/sh", args: ["-c", MobileTerminal.supervisor, "sh", "/opt/homebrew/bin/tmux", "-C"]))
    }

    // MARK: input is data

    func testEveryByteBecomesTwoHexDigitsAndNothingElse() throws {
        let all = Data((0...255).map { UInt8($0) })
        let hostile = Data("\n; kill-server\n\rnew-window 'rm -rf ~'\n%exit\n\\; run-shell x #{x} $(x) `x`".utf8)
        let line = try NSRegularExpression(pattern: #"^send-keys -t %12 -H( [0-9a-f]{2}){1,256}$"#)
        for data in [all, hostile, Data([0x0A]), Data(repeating: 0x3B, count: 1000)] {
            let commands = MobileTerminal.keyCommands(data, target: target)
            XCTAssertEqual(commands.count, (data.count + 255) / 256)
            var bytes = Data()
            for command in commands {
                XCTAssertNotNil(
                    line.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)), command)
                bytes.append(contentsOf: command.split(separator: " ").dropFirst(4).map { UInt8($0, radix: 16)! })
            }
            XCTAssertEqual(bytes, data)
        }
        XCTAssertEqual(
            MobileTerminal.keyCommands(Data("hi\r".utf8), target: target), ["send-keys -t %12 -H 68 69 0d"])
    }

    func testTheOnlyLinesEverWrittenAreTheThreeFixedCommands() {
        var session = MobileControlSession(target: target)
        var written = session.opening
        written += session.keys(Data("x\nkill-server\n".utf8))
        written += session.pause()
        written += session.resync()
        for line in ["%begin 1 1 0", "%end 1 1 0", "%layout-change @1 abcd,80x24,0,0,1 abcd,80x24,0,0,1 *"] {
            for case .send(let text) in session.line(Data(line.utf8)) { written.append(text) }
        }
        let fixed = [
            "refresh-client -f ignore-size,pause-after=1", "refresh-client -A '%12:pause'",
            "refresh-client -A '%12:continue'",
        ]
        for line in written {
            XCTAssertFalse(line.contains("\n"))
            XCTAssertTrue(
                fixed.contains(line) || line.hasPrefix("display-message -p -t %12 '")
                    || line.hasPrefix("capture-pane -p -e -S -") || line.hasPrefix("send-keys -t %12 -H "), line)
        }
        XCTAssertEqual(written.count, 8)
    }

    // MARK: control mode

    func testOctalEscapesAreUndone() {
        XCTAssertEqual(
            MobileTerminal.unescape(Data(#"a\033[1mb\015\012\134n"#.utf8)), Data("a\u{1B}[1mb\r\n\\n".utf8))
        // Not an escape: kept as it came.
        XCTAssertEqual(MobileTerminal.unescape(Data(#"\9 \12 \"#.utf8)), Data(#"\9 \12 \"#.utf8))
        XCTAssertEqual(MobileTerminal.unescape(Data([0xC3, 0xA9])), Data([0xC3, 0xA9]))
    }

    /// Feed lines; collect the events.
    private func run(_ session: inout MobileControlSession, _ lines: [String]) -> [MobileControlSession.Event] {
        lines.flatMap { session.line(Data($0.utf8)) }
    }

    private let opening = [
        "%begin 100 1 0", "%end 100 1 0", "%session-changed $3 acme-app",
        "%begin 100 9 1", "%end 100 9 1",
        "%begin 100 2 1", "80 24 2 1 0 1 0 0 23", "%end 100 2 1",
    ]

    func testTheSnapshotComesFirstAndOutputBeforeItIsDropped() {
        var session = MobileControlSession(target: target)
        var events = run(&session, opening)
        XCTAssertEqual(events, [])
        events = run(&session, [
            #"%output %12 early"#,
            "%begin 100 3 1", "$ make test", "\u{1B}[32mok\u{1B}[39m", "%end 100 3 1",
            #"%output %12 late\015\012"#,
        ])
        guard case .ready(let state, let snapshot)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(state.cols, 80)
        XCTAssertEqual(state.rows, 24)
        XCTAssertEqual(
            String(decoding: snapshot, as: UTF8.self),
            "$ make test\r\n\u{1B}[32mok\u{1B}[39m\u{1B}[0m\u{1B}[2;3H")
        XCTAssertEqual(Array(events.dropFirst()), [.output(Data("late\r\n".utf8))])
    }

    func testOtherPanesOfTheSessionAreNotSent() {
        var session = MobileControlSession(target: target)
        _ = run(&session, opening + ["%begin 100 3 1", "%end 100 3 1"])
        XCTAssertEqual(run(&session, ["%output %13 secret", "%output %120 secret", "%output %1 secret"]), [])
        XCTAssertEqual(run(&session, ["%output %12 mine"]), [.output(Data("mine".utf8))])
        XCTAssertEqual(
            run(&session, ["%extended-output %12 5 : paused", "%extended-output %13 5 : other"]),
            [.output(Data("paused".utf8))])
    }

    func testAPaneCannotEndABlockOrForgeOutputFromInsideOne() {
        var session = MobileControlSession(target: target)
        _ = run(&session, opening)
        // The capture holds lines that look like control lines.
        let events = run(&session, [
            "%begin 100 3 1", "%end 100 9 1", "%exit", "%output %12 forged", "%begin 1 1 1", "%end 100 3 1",
        ])
        guard case .ready(_, let snapshot)? = events.first, events.count == 1 else { return XCTFail("\(events)") }
        XCTAssertEqual(
            String(decoding: snapshot, as: UTF8.self).components(separatedBy: "\r\n").count, 4)
    }

    func testSnapshotRestoresTheModesThePaneIsIn() {
        var state = MobileTerminal.State(cols: 80, rows: 24)
        state.alternate = true
        state.applicationCursor = true
        state.cursorVisible = false
        state.regionTop = 1
        state.regionBottom = 20
        state.cursorX = 4
        state.cursorY = 9
        XCTAssertEqual(
            String(decoding: MobileTerminal.snapshot(state: state, capture: [Data("a".utf8)]), as: UTF8.self),
            "\u{1B}[?1049ha\u{1B}[0m\u{1B}[2;21r\u{1B}[?1h\u{1B}[10;5H\u{1B}[?25l")
    }

    func testAStateThatIsNotNineNumbersEndsTheBridge() {
        XCTAssertNil(MobileTerminal.State("80 24"))
        XCTAssertNil(MobileTerminal.State("0 24 0 0 0 1 0 0 23"))
        XCTAssertNil(MobileTerminal.State("80 99999 0 0 0 1 0 0 23"))
        var session = MobileControlSession(target: target)
        XCTAssertEqual(
            run(&session, [
                "%begin 1 1 0", "%end 1 1 0", "%begin 1 9 1", "%end 1 9 1",
                "%begin 1 2 1", "can't find pane: %12", "%error 1 2 1",
            ]),
            [.exit])
        // And nothing after the end.
        XCTAssertEqual(run(&session, ["%output %12 x"]), [])
        XCTAssertEqual(session.keys(Data("x".utf8)), [])
    }

    func testALayoutChangeAsksTheSizeOnceAndReportsAChange() {
        var session = MobileControlSession(target: target)
        _ = run(&session, opening + ["%begin 100 3 1", "%end 100 3 1"])
        let change = "%layout-change @1 abcd,100x30,0,0,1 abcd,100x30,0,0,1 *"
        XCTAssertEqual(run(&session, [change]), [.send(MobileTerminal.stateCommand(target))])
        XCTAssertEqual(run(&session, [change]), [])
        XCTAssertEqual(
            run(&session, ["%begin 100 4 1", "100 30 0 0 0 1 0 0 29", "%end 100 4 1"]),
            [.size(cols: 100, rows: 30)])
        // The same size again is no event.
        _ = run(&session, [change])
        XCTAssertEqual(run(&session, ["%begin 100 5 1", "100 30 0 0 0 1 0 0 29", "%end 100 5 1"]), [])
    }

    /// A session that has its first screen.
    private func screened() -> MobileControlSession {
        var session = MobileControlSession(target: target)
        _ = run(&session, opening + ["%begin 100 3 1", "%end 100 3 1"])
        return session
    }

    func testTheClientAsksTmuxToHoldOutputForASlowReader() {
        XCTAssertEqual(
            MobileControlSession(target: target).opening.first,
            "refresh-client -f ignore-size,pause-after=1")
    }

    func testATmuxThatRefusesFlowControlEndsTheBridge() {
        // A tmux older than 3.2 does not know the flag. Without it tmux
        // would keep a slow client's output, so there is no live terminal.
        var session = MobileControlSession(target: target)
        let events = run(&session, [
            "%begin 1 1 0", "%end 1 1 0", "%begin 1 2 1", "unknown flag -- f", "%error 1 2 1",
            "%begin 1 3 1", "80 24 0 0 0 1 0 0 23", "%end 1 3 1", "%begin 1 4 1", "$", "%end 1 4 1",
            "%output %12 x",
        ])
        XCTAssertEqual(events, [.unsupported])
        XCTAssertEqual(session.keys(Data("x".utf8)), [])
    }

    func testOutputThatIsOldPausesThePane() {
        var session = screened()
        XCTAssertEqual(
            run(&session, ["%extended-output %12 40 : fresh"]), [.output(Data("fresh".utf8))])
        XCTAssertEqual(
            run(&session, ["%extended-output %12 900 : stale"]),
            [.send("refresh-client -A '%12:pause'"), .paused])
        // Paused: nothing more is passed on, and nothing is asked twice.
        XCTAssertEqual(run(&session, ["%extended-output %12 950 : more", "%output %12 x"]), [])
        XCTAssertEqual(session.pause(), [])
    }

    func testAPauseFromTmuxItselfIsSeen() {
        var session = screened()
        XCTAssertEqual(run(&session, ["%pause %13"]), [])
        XCTAssertEqual(run(&session, ["%pause %12"]), [.paused])
        XCTAssertEqual(run(&session, ["%output %12 x"]), [])
    }

    func testAPausedPaneStartsAgainFromANewCapture() {
        var session = screened()
        XCTAssertEqual(session.resync(), [])
        XCTAssertEqual(session.pause(), ["refresh-client -A '%12:pause'"])
        XCTAssertEqual(run(&session, ["%begin 100 4 1", "%end 100 4 1", "%pause %12"]), [])
        XCTAssertEqual(session.resync(), [
            "refresh-client -A '%12:continue'", MobileTerminal.stateCommand(target),
            MobileTerminal.captureCommand(target),
        ])
        // What the pane writes before the capture ends is in the capture.
        let events = run(&session, [
            "%begin 100 5 1", "%end 100 5 1", "%continue %12", "%extended-output %12 0 : early",
            "%begin 100 6 1", "100 30 1 2 0 1 0 0 29", "%end 100 6 1",
            "%begin 100 7 1", "new screen", "%end 100 7 1", "%extended-output %12 0 : late",
        ])
        guard case .ready(let state, let snapshot)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(state.cols, 100)
        XCTAssertTrue(String(decoding: snapshot, as: UTF8.self).hasPrefix("new screen"))
        XCTAssertEqual(Array(events.dropFirst()), [.output(Data("late".utf8))])
    }

    func testAPipeIsBornCloseOnExec() throws {
        let pipe = try XCTUnwrap(MobileTerminal.pipe())
        defer {
            close(pipe.read)
            close(pipe.write)
        }
        for fd in [pipe.read, pipe.write] {
            XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
        }
        // A pipe like any other: blocking, in order, with an end.
        XCTAssertEqual(fcntl(pipe.read, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertEqual(write(pipe.write, "hi", 2), 2)
        var bytes = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(read(pipe.read, &bytes, 8), 2)
        XCTAssertEqual(Array(bytes.prefix(2)), Array("hi".utf8))
        // Its name is gone: nothing else can open it.
        var info = stat()
        XCTAssertNotEqual(stat(pipe.path, &info), 0)
    }

    func testTheBridgeEndsWhenTheClientExitsOrChangesSession() {
        var gone = MobileControlSession(target: target)
        XCTAssertEqual(run(&gone, opening + ["%exit"]), [.exit])
        var moved = MobileControlSession(target: target)
        XCTAssertEqual(run(&moved, opening + ["%session-changed $4 other"]), [.exit])
    }

    func testKeysToAPaneThatHasGoneEndTheBridge() {
        var session = MobileControlSession(target: target)
        _ = run(&session, opening + ["%begin 100 3 1", "%end 100 3 1"])
        XCTAssertEqual(session.keys(Data("a".utf8)).count, 1)
        XCTAssertEqual(run(&session, ["%begin 100 4 1", "can't find pane: %12", "%error 100 4 1"]), [.exit])
    }

    func testAnEndlessBlockEndsTheBridge() {
        var session = MobileControlSession(target: target)
        _ = run(&session, opening + ["%begin 100 3 1"])
        let line = Data(repeating: 65, count: 65_536)
        var events: [MobileControlSession.Event] = []
        for _ in 0..<(MobileTerminal.maxSnapshotBytes / line.count + 2) where events.isEmpty {
            events = session.line(line)
        }
        XCTAssertEqual(events, [.exit])
    }
}

// MARK: - Over a real socket, to a private tmux server

final class MobileTerminalSocketTests: XCTestCase {
    private let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")
    private var tmux: PrivateTmux!
    private var server: MobileServer!
    private var port = 0
    private let launches = Counter()
    private var phones: [Phone] = []

    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A tmux server of the test's own, with one session whose pane runs `cat`.
    private final class PrivateTmux {
        let path: String
        let name = "mm-live-\(UUID().uuidString.prefix(8))"
        private var clients: [(process: Process, master: Int32, drain: DispatchSourceRead)] = []

        /// `owner` is the process the server must not outlive.
        init?(owner: Int32 = ProcessInfo.processInfo.processIdentifier) {
            guard let path = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            self.path = path
            _ = run(["-f", "/dev/null", "new-session", "-d", "-s", "acme-app", "-x", "100", "-y", "30", "cat"])
            run(TmuxOrphanGuard.argv(tmux: path, socket: name, owner: owner))
        }

        @discardableResult
        func run(_ args: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-L", name] + args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var alive: Bool { !run(["list-sessions", "-F", "#{session_name}"]).isEmpty }
        var windowSize: String { run(["display-message", "-p", "-t", "acme-app", "#{window_width}x#{window_height}"]) }
        var clientCount: Int { run(["list-clients", "-F", "#{client_name}"]).split(separator: "\n").count }
        func screen(_ pane: String) -> String { run(["capture-pane", "-p", "-t", pane]) }

        /// The first pane of `window` and its session, as the tree would hold them.
        func ids(window: String = "acme-app:0") -> (pane: String, session: String) {
            let parts = run(["display-message", "-p", "-t", window, "#{pane_id} #{session_id}"]).split(separator: " ")
            return (String(parts.first ?? ""), String(parts.last ?? ""))
        }

        /// Attach a real client with a terminal of `cols` x `rows`, as the
        /// human's own window on the Mac is.
        func attach(cols: UInt16, rows: UInt16) {
            var master: Int32 = 0, slave: Int32 = 0
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { return XCTFail("openpty") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-L", name, "attach-session", "-t", "acme-app"]
            let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            process.environment = environment
            guard (try? process.run()) != nil else { return XCTFail("attach") }
            close(slave)
            // What tmux draws is read and dropped, so the client never blocks.
            let drain = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
            drain.setEventHandler {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                _ = read(master, &bytes, bytes.count)
            }
            drain.resume()
            clients.append((process, master, drain))
        }

        func stop() {
            for client in clients {
                client.drain.cancel()
                if client.process.isRunning { client.process.terminate() }
                close(client.master)
            }
            // The server leaves its socket file behind: take that away too.
            let socket = run(["display-message", "-p", "#{socket_path}"])
            run(["kill-server"])
            if socket.contains(name) { unlink(socket) }
        }
    }

    /// A phone's side of the socket: a raw connection that masks its frames.
    private final class Phone {
        struct Frame: Equatable {
            let opcode: UInt8
            let payload: Data
        }

        private let connection: NWConnection
        private let queue = DispatchQueue(label: "mobile-terminal-tests.phone")
        private let lock = NSCondition()
        private var buffer = Data()
        private var closed = false
        private var reading = false

        init(port: Int) {
            // Opened through the shared client, which waits out a machine
            // with no free local port. A port nobody listens on still gives a
            // connection, started as before, whose reads then end at once.
            if case .open(let opened) = LoopbackClient.connect(port: port, queue: queue) {
                connection = opened
            } else {
                connection = NWConnection(
                    host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
                connection.start(queue: queue)
            }
        }

        /// Read what the server sends. A phone that never calls this is one
        /// that does not read.
        func startReading() {
            lock.lock()
            let start = !reading
            reading = true
            lock.unlock()
            if start { read() }
        }

        private func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self else { return }
                self.lock.lock()
                if let data { self.buffer.append(data) }
                if complete || error != nil { self.closed = true }
                let done = self.closed
                self.lock.broadcast()
                self.lock.unlock()
                if !done { self.read() }
            }
        }

        func send(_ data: Data) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func send(_ opcode: UInt8, _ payload: Data = Data()) {
            send(MobileSocketTests.frame(opcode, [UInt8](payload)))
        }

        func hangUp() { connection.cancel() }

        /// Wait until `take` gets something out of the buffer, the server
        /// hangs up, or `timeout` passes.
        private func wait<T>(_ timeout: TimeInterval, _ take: (inout Data) -> T?) -> T? {
            startReading()
            let deadline = Date().addingTimeInterval(timeout)
            lock.lock()
            defer { lock.unlock() }
            while true {
                if let value = take(&buffer) { return value }
                if closed || !lock.wait(until: deadline) { return take(&buffer) }
            }
        }

        /// The answer to the upgrade: its status line and headers.
        func head(_ timeout: TimeInterval = 5) -> String? {
            wait(timeout) { buffer in
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                // A refusal has a body; nothing follows it.
                buffer = head.hasPrefix("HTTP/1.1 101") ? Data(buffer[end.upperBound...]) : Data()
                return head
            }
        }

        /// The next frame from the server, pings answered and skipped.
        func frame(_ timeout: TimeInterval = 5, answerPings: Bool = true) -> Frame? {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let next: Frame? = wait(max(0, deadline.timeIntervalSinceNow)) { buffer in
                    let bytes = [UInt8](buffer.prefix(10))
                    guard bytes.count >= 2 else { return nil }
                    var length = Int(bytes[1] & 0x7F), header = 2
                    if length == 126 {
                        guard bytes.count >= 4 else { return nil }
                        (length, header) = (Int(bytes[2]) << 8 | Int(bytes[3]), 4)
                    } else if length == 127 {
                        guard bytes.count >= 10 else { return nil }
                        (length, header) = (bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }, 10)
                    }
                    guard buffer.count >= header + length else { return nil }
                    let payload = Data(buffer.dropFirst(header).prefix(length))
                    buffer = Data(buffer.dropFirst(header + length))
                    return Frame(opcode: bytes[0] & 0x0F, payload: payload)
                }
                guard let next else { return nil }
                guard next.opcode == 9, answerPings else { return next }
                send(10, next.payload)
            }
        }

        /// The close code the server sends, skipping what comes before it.
        func closeCode(_ timeout: TimeInterval = 5) -> UInt16? {
            let deadline = Date().addingTimeInterval(timeout)
            while let frame = frame(max(0, deadline.timeIntervalSinceNow)) {
                guard frame.opcode == 8, frame.payload.count >= 2 else { continue }
                return UInt16(frame.payload[frame.payload.startIndex]) << 8
                    | UInt16(frame.payload[frame.payload.startIndex + 1])
            }
            return nil
        }

        /// Whether the server hung up, with or without a close frame.
        func isClosed(within timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while frame(max(0, deadline.timeIntervalSinceNow)) != nil {}
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        /// Binary frames until their bytes hold `text`.
        func output(until text: String, _ timeout: TimeInterval = 5) -> String {
            var bytes = Data()
            let deadline = Date().addingTimeInterval(timeout)
            while let frame = frame(max(0, deadline.timeIntervalSinceNow)) {
                if frame.opcode == 2 { bytes.append(frame.payload) }
                if frame.opcode == 8 { break }
                if String(decoding: bytes, as: UTF8.self).contains(text) { break }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    override func setUpWithError() throws {
        guard let tmux = PrivateTmux(), tmux.alive else { throw XCTSkip("no tmux on this machine") }
        self.tmux = tmux
        startServer()
    }

    override func tearDown() {
        phones.forEach { $0.hangUp() }
        server?.stop()
        tmux?.stop()
    }

    private func startServer(
        limits: MobileServer.Limits = MobileServer.Limits(), capabilities: Set<MobileCapability> = [.liveTerminal],
        launch: MobileTerminalBridge.Launch? = nil
    ) {
        server?.stop()
        let (path, name) = (tmux.path, tmux.name)
        server = MobileServer(
            staticRoot: nil,
            sources: MobileServer.Sources(
                screen: { _, _ in nil }, transcript: { _ in nil },
                terminal: { [launches] _, target in
                    launches.add()
                    if let launch { return launch }
                    return .supervised(MobileTerminalBridge.Launch(
                        path: path, args: ["-L", name] + MobileTerminal.attachArgv(target)))
                }),
            limits: limits)
        let started = expectation(description: "listening")
        server.start(port: 0, identity: identity, token: "demo-token") { result in
            if case .success(let bound) = result { self.port = bound }
            started.fulfill()
        }
        wait(for: [started], timeout: 5)
        server.configure(MobileConfig(capabilities: capabilities))
        server.update(snapshot())
    }

    /// The tree as the app builds it: the manager's session is not in it.
    private func snapshot(windows: [String] = ["acme-app:0"]) -> MobileSnapshot {
        let panes = windows.map { tmux.ids(window: $0) }
        return MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: "acme-app", attached: true, id: panes[0].session, windows:
                panes.enumerated().map { index, ids in
                    TmuxWindow(index: index, name: "w\(index)", active: index == 0, panes: [
                        TmuxPane(id: ids.pane, index: 0, command: "cat", title: "", active: true),
                    ])
                })])])
    }

    private func threadID(_ window: String = "acme-app:0") -> String {
        MobileSnapshot.threadID(host: .local, pane: tmux.ids(window: window).pane)
    }

    /// Open the socket for `thread`. Returns the phone and the upgrade's answer.
    private func connect(
        _ thread: String? = nil, path: String? = nil, origin: String? = "https://devmac.example.ts.net:7433",
        login: String? = "me@example.com", device: String = "100.64.0.7", token: String? = nil
    ) -> (Phone, String) {
        let phone = Phone(port: port)
        phones.append(phone)
        let id = (thread ?? threadID()).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var raw = "GET \(path ?? "/api/terminal/\(id)") HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nX-Forwarded-For: \(device)\r\n"
        if let origin { raw += "Origin: \(origin)\r\n" }
        if let login { raw += "Tailscale-User-Login: \(login)\r\n" }
        if let token { raw += "X-MuxMaestro-Token: \(token)\r\n" }
        phone.send(Data((raw + "\r\n").utf8))
        return (phone, phone.head() ?? "")
    }

    /// A paired socket that has its first screen.
    private func live(_ thread: String? = nil, device: String = "100.64.0.7") -> Phone {
        let (phone, head) = connect(thread, device: device)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        phone.send(1, Data("demo-token".utf8))
        let ready = phone.frame()
        XCTAssertEqual(ready?.opcode, 1, "\(String(describing: ready))")
        return phone
    }

    private func eventually(_ timeout: TimeInterval = 5, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return check()
    }

    // MARK: the path

    func testTypingReachesThePaneOutputComesBackAndTheMacWindowKeepsItsSize() throws {
        tmux.attach(cols: 120, rows: 40)
        XCTAssertTrue(eventually { tmux.windowSize == "120x39" }, tmux.windowSize)
        let pane = tmux.ids().pane

        let (phone, head) = connect()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        XCTAssertTrue(head.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        phone.send(1, Data("demo-token".utf8))

        // The first message says the pane's size: the phone draws that many
        // cells and scrolls sideways. It asks for no size of its own.
        let ready = try XCTUnwrap(phone.frame())
        XCTAssertEqual(ready.opcode, 1)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: ready.payload) as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "ready")
        XCTAssertEqual(message["cols"] as? Int, 120)
        XCTAssertEqual(message["rows"] as? Int, 39)

        // Typed on the socket: shown in the pane, and echoed back as output.
        phone.send(2, Data("hello \u{e9}\r".utf8))
        XCTAssertTrue(phone.output(until: "hello \u{e9}").contains("hello \u{e9}"))
        XCTAssertTrue(eventually { tmux.screen(pane).contains("hello \u{e9}") })

        // Written in the pane from the Mac: it reaches the phone.
        tmux.run(["send-keys", "-t", pane, "-l", "from the mac"])
        tmux.run(["send-keys", "-t", pane, "Enter"])
        XCTAssertTrue(phone.output(until: "from the mac").contains("from the mac"))

        XCTAssertEqual(tmux.windowSize, "120x39")
        XCTAssertEqual(tmux.clientCount, 2)

        // Hanging up ends the control client; the human's client stays.
        phone.hangUp()
        XCTAssertTrue(eventually { tmux.clientCount == 1 })
        XCTAssertEqual(tmux.windowSize, "120x39")
        XCTAssertEqual(launches.value, 1)
    }

    func testTheFirstScreenHoldsWhatThePaneAlreadyShowed() {
        let pane = tmux.ids().pane
        tmux.run(["send-keys", "-t", pane, "-l", "before the phone"])
        tmux.run(["send-keys", "-t", pane, "Enter"])
        XCTAssertTrue(eventually { tmux.screen(pane).contains("before the phone\nbefore the phone") })
        let phone = live()
        XCTAssertTrue(phone.output(until: "before the phone").contains("before the phone"))
    }

    func testWhatIsTypedIsNeverATmuxCommand() {
        let pane = tmux.ids().pane
        let phone = live()
        // In a shell or in a tmux command line each of these would do harm.
        // On the socket they are bytes for the pane.
        let hostile = "x\r; kill-server\rkill-session -a\r\u{02}:kill-server\r$(tmux kill-server)\r"
        phone.send(2, Data(hostile.utf8))
        XCTAssertTrue(eventually { tmux.screen(pane).contains("; kill-server") })
        XCTAssertTrue(tmux.alive)
        XCTAssertEqual(tmux.run(["list-sessions", "-F", "#{session_name}"]), "acme-app")
        XCTAssertEqual(tmux.run(["list-windows", "-a", "-F", "#{window_index}"]), "0")
    }

    func testOneSocketIsBoundToOnePane() {
        tmux.run(["new-window", "-d", "-t", "acme-app", "cat"])
        server.update(snapshot(windows: ["acme-app:0", "acme-app:1"]))
        let other = tmux.ids(window: "acme-app:1").pane
        let phone = live(threadID("acme-app:0"))
        // The other pane of the session writes; none of it reaches this socket.
        tmux.run(["send-keys", "-t", other, "-l", "other pane secret"])
        tmux.run(["send-keys", "-t", other, "Enter"])
        phone.send(2, Data("mine\r".utf8))
        let got = phone.output(until: "mine\r\nmine")
        XCTAssertTrue(got.contains("mine"))
        XCTAssertFalse(got.contains("secret"), got)
        XCTAssertFalse(tmux.screen(other).contains("mine"))
    }

    // MARK: the token

    func testNothingIsSentAndNoPaneIsTouchedBeforeTheToken() {
        var limits = MobileServer.Limits()
        limits.socketAuthTimeout = 0.4
        startServer(limits: limits)
        let (phone, head) = connect()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        // No token: the only frame that ever comes is the close.
        let frame = phone.frame(3)
        XCTAssertEqual(frame?.opcode, 8)
        XCTAssertEqual(frame?.payload, Data([0x11, 0x31]))
        XCTAssertEqual(launches.value, 0)
        XCTAssertEqual(tmux.clientCount, 0)
    }

    func testAWrongTokenClosesTheSocket() {
        for token in ["wrong", "demo-toke", "demo-token ", ""] {
            let (phone, _) = connect()
            phone.send(1, Data(token.utf8))
            XCTAssertEqual(phone.closeCode(), 4401, token)
        }
        // A token in a binary frame, or keys before the token, are not a token.
        let (binary, _) = connect()
        binary.send(2, Data("demo-token".utf8))
        XCTAssertEqual(binary.closeCode(), 4401)
        XCTAssertEqual(launches.value, 0)
    }

    func testATokenInTheURLOrAHeaderOpensNothing() {
        let (_, query) = connect(path: "/api/terminal/\(threadID())?token=demo-token")
        XCTAssertTrue(query.hasPrefix("HTTP/1.1 400"), query)
        // The header a fetch carries is no pass for a bad origin.
        let (_, header) = connect(origin: "https://evil.example.com", token: "demo-token")
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 403"), header)
        // With the header and a good origin the first message is still needed.
        let (phone, ok) = connect(token: "demo-token")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 101"), ok)
        phone.send(2, Data("x".utf8))
        XCTAssertEqual(phone.closeCode(), 4401)
        XCTAssertEqual(launches.value, 0)
    }

    func testTheUpgradeIsRefusedOverTheWire() {
        XCTAssertTrue(connect(origin: "https://evil.example.com").1.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(connect(origin: "https://devmac.example.ts.net:8443").1.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(connect(origin: nil).1.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(connect(login: nil).1.hasPrefix("HTTP/1.1 403"))
        startServer(capabilities: [.replies, .keyBar])
        XCTAssertTrue(connect().1.hasPrefix("HTTP/1.1 403"))
        XCTAssertEqual(launches.value, 0)
    }

    func testANewTokenSignsTheSocketOut() {
        let phone = live()
        server.setToken("another-token")
        XCTAssertTrue(phone.isClosed(within: 5))
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
    }

    // MARK: the target

    func testAThreadThatIsNotInTheTreeIsRefused() {
        // The manager's own pane and a hidden session are never in the tree
        // the server is given, so their ids are unknown here.
        tmux.run(["new-session", "-d", "-s", "manager", "cat"])
        let manager = tmux.run(["display-message", "-p", "-t", "manager", "#{pane_id}"])
        for id in [
            MobileSnapshot.threadID(host: .local, pane: manager), "local:999", "devbox:0", "%0",
            "acme-app:0.0", "=acme-app", "local:0;kill-server",
        ] {
            let (phone, head) = connect(id)
            XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), id)
            phone.send(1, Data("demo-token".utf8))
            XCTAssertEqual(phone.closeCode(), 4404, id)
        }
        XCTAssertEqual(launches.value, 0)
        XCTAssertTrue(tmux.alive)
    }

    func testAPaneThatLeavesTheTreeClosesItsSocket() {
        let phone = live()
        server.update(MobileSnapshot())
        XCTAssertEqual(phone.closeCode(), 4404)
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
    }

    func testAKilledPaneEndsTheSocket() {
        tmux.run(["new-window", "-d", "-t", "acme-app", "cat"])
        server.update(snapshot(windows: ["acme-app:0", "acme-app:1"]))
        let phone = live(threadID("acme-app:1"))
        tmux.run(["kill-window", "-t", "acme-app:1"])
        // The tree has not said so yet: typing finds the pane gone.
        phone.send(2, Data("x".utf8))
        XCTAssertEqual(phone.closeCode(), 4410)
    }

    func testTurningTheSwitchOffClosesEverySocket() {
        let phone = live()
        server.configure(MobileConfig())
        XCTAssertEqual(phone.closeCode(), 4403)
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
        XCTAssertTrue(connect().1.hasPrefix("HTTP/1.1 403"))
    }

    // MARK: limits

    func testAMessagePastTheSizeLimitClosesTheSocket() {
        let phone = live()
        phone.send(2, Data(repeating: 65, count: MobileSocket.maxMessageBytes + 1))
        XCTAssertEqual(phone.closeCode(), 1009)
        XCTAssertFalse(tmux.screen(tmux.ids().pane).contains("AAAA"))
    }

    func testATextMessageAfterPairingClosesTheSocket() {
        let phone = live()
        phone.send(1, Data("resize 10 10".utf8))
        XCTAssertEqual(phone.closeCode(), 1003)
    }

    func testAnUnmaskedFrameClosesTheSocket() {
        let phone = live()
        phone.send(MobileSocketTests.frame(2, [65], masked: false))
        XCTAssertEqual(phone.closeCode(), 1002)
    }

    func testTheMessageRateIsCapped() {
        var limits = MobileServer.Limits()
        limits.socketRate = 1
        limits.socketBurst = 5
        startServer(limits: limits)
        let phone = live()
        var flood = Data()
        for _ in 0..<50 { flood.append(MobileSocketTests.frame(2, [65])) }
        phone.send(flood)
        XCTAssertEqual(phone.closeCode(), 1008)
    }

    func testSocketsAreCappedOverall() {
        var limits = MobileServer.Limits()
        limits.maxSockets = 2
        startServer(limits: limits)
        // Not paired yet, and counted all the same.
        XCTAssertTrue(connect(device: "100.64.0.1").1.hasPrefix("HTTP/1.1 101"))
        XCTAssertTrue(connect(device: "100.64.0.2").1.hasPrefix("HTTP/1.1 101"))
        XCTAssertTrue(connect(device: "100.64.0.3").1.hasPrefix("HTTP/1.1 503"))
    }

    func testOnePhoneHoldsFewSocketsAndItsOldestGivesWay() {
        var limits = MobileServer.Limits()
        limits.maxSocketsPerClient = 2
        startServer(limits: limits)
        let first = live()
        let second = live()
        let third = live()
        XCTAssertEqual(first.closeCode(), 4409)
        // The two newest still work.
        second.send(2, Data("second\r".utf8))
        XCTAssertTrue(second.output(until: "second").contains("second"))
        third.send(2, Data("third\r".utf8))
        XCTAssertTrue(third.output(until: "third").contains("third"))
        XCTAssertTrue(eventually { tmux.clientCount == 2 })
    }

    func testASocketNobodyTypesOnIsClosed() {
        var limits = MobileServer.Limits()
        limits.socketPing = 0.1
        limits.socketIdle = 0.5
        startServer(limits: limits)
        let phone = live()
        XCTAssertEqual(phone.closeCode(), 4408)
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
    }

    func testAPhoneThatAnswersNoPingIsDropped() {
        var limits = MobileServer.Limits()
        limits.socketPing = 0.1
        limits.socketDead = 0.5
        startServer(limits: limits)
        let phone = live()
        // Pings come; this phone never answers one.
        var pings = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, let frame = phone.frame(1, answerPings: false) {
            if frame.opcode == 9 { pings += 1 }
        }
        XCTAssertGreaterThan(pings, 0)
        XCTAssertTrue(phone.isClosed(within: 3))
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
    }

    func testAPhoneThatDoesNotReadIsDroppedAndThePaneIsReadNoMore() {
        var limits = MobileServer.Limits()
        limits.socketPing = 0.1
        limits.socketBacklog = 4096
        limits.socketStall = 0.5
        // Pongs are not what this test is about.
        limits.socketDead = 60
        startServer(limits: limits)
        tmux.run(["new-window", "-d", "-t", "acme-app",
                  "while :; do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done"])
        server.update(snapshot(windows: ["acme-app:0", "acme-app:1"]))
        // A plain socket that is written to and never read: its buffers are
        // the kernel's alone, so they fill.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let id = threadID("acme-app:1").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var hello = Data((
            "GET /api/terminal/\(id) HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
                + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: https://devmac.example.ts.net:7433\r\n"
                + "Tailscale-User-Login: me@example.com\r\n\r\n").utf8)
        // The token goes out with the request; nothing is ever read back.
        hello.append(MobileSocketTests.frame(1, Array("demo-token".utf8)))
        XCTAssertEqual(hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, hello.count)
        XCTAssertTrue(eventually { tmux.clientCount == 1 })
        // The socket fills, the server stops reading the pane, then lets go.
        XCTAssertTrue(eventually(20) { tmux.clientCount == 0 })
    }

    // MARK: stopping

    func testStoppingTheServerEndsEveryBridge() {
        let phone = live()
        XCTAssertTrue(eventually { tmux.clientCount == 1 })
        server.stop()
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
        XCTAssertTrue(phone.isClosed(within: 5))
    }

    func testStoppingTheServerWhileAPhoneDoesNotReadEndsTheBridge() {
        var limits = MobileServer.Limits()
        limits.socketBacklog = 4096
        limits.socketStall = 60
        startServer(limits: limits)
        tmux.run(["new-window", "-d", "-t", "acme-app", Self.flood])
        server.update(snapshot(windows: ["acme-app:0", "acme-app:1"]))
        let fd = unreadSocket(threadID("acme-app:1"))
        defer { close(fd) }
        XCTAssertTrue(eventually { tmux.clientCount == 1 })
        // Long enough for the socket to fill and the bridge to stop reading.
        Thread.sleep(forTimeInterval: 1.5)
        server.stop()
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
        XCTAssertTrue(tmux.alive)
    }

    func testABridgeLetGoWithoutStopEndsItsClient() {
        tmux.run(["new-window", "-d", "-t", "acme-app", Self.flood])
        let ids = tmux.ids(window: "acme-app:1")
        let target = MobileTerminal.Target(pane: ids.pane, session: ids.session)
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        var bridge: MobileTerminalBridge? = MobileTerminalBridge(
            launch: localLaunch(target), target: target
        ) { event in
            if case .ready = event { ready.fulfill() }
        }
        XCTAssertEqual(bridge?.start(), true)
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(tmux.clientCount, 1)
        // Nobody said there is room, and the pane floods. Let go of it.
        bridge = nil
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
    }

    func testTheClientDiesWhenItsParentIsKilled() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("no python3") }
        tmux.run(["new-window", "-d", "-t", "acme-app", Self.flood])
        let ids = tmux.ids(window: "acme-app:1")
        let target = MobileTerminal.Target(pane: ids.pane, session: ids.session)
        try killedParent(of: localLaunch(target), python: python)
    }

    func testTheFarClientDiesWhenTheParentOfSshIsKilled() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("no python3") }
        tmux.run(["new-window", "-d", "-t", "acme-app", Self.flood])
        let ids = tmux.ids(window: "acme-app:1")
        let (launch, dir) = try sshLaunch(MobileTerminal.Target(pane: ids.pane, session: ids.session))
        defer { try? FileManager.default.removeItem(at: dir) }
        try killedParent(of: launch, python: python)
    }

    /// A parent that starts the client as the bridge does, never reads its
    /// output, and is killed. The pane floods a client nobody reads: the
    /// worst case to let go of.
    private func killedParent(of launch: MobileTerminalBridge.Launch, python: String) throws {
        let script = """
            import subprocess, sys, time
            p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL)
            time.sleep(600)
            """
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: python)
        parent.arguments = ["-c", script, launch.path] + launch.args
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        XCTAssertTrue(eventually { tmux.clientCount == 1 })
        Thread.sleep(forTimeInterval: 1)
        kill(parent.processIdentifier, SIGKILL)
        parent.waitUntilExit()
        XCTAssertTrue(eventually(8) { tmux.clientCount == 0 })
        XCTAssertTrue(tmux.alive)
    }

    private func localLaunch(_ target: MobileTerminal.Target) -> MobileTerminalBridge.Launch {
        .supervised(.init(path: tmux.path, args: ["-L", tmux.name] + MobileTerminal.attachArgv(target)))
    }

    /// The bridge's command for a host over ssh, with a stand-in for ssh: it
    /// drops its options and the host, then hands the rest to a shell as one
    /// string, as sshd does on the far side. `tmux` there is the private server.
    private func sshLaunch(_ target: MobileTerminal.Target) throws -> (MobileTerminalBridge.Launch, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("tmux")
        try "#!/bin/sh\nexec \(tmux.path) -L \(tmux.name) \"$@\"\n".write(to: shim, atomically: true, encoding: .utf8)
        let ssh = dir.appendingPathComponent("ssh")
        try """
            #!/bin/sh
            while [ "$1" = "-o" ]; do shift 2; done
            echo "$1" > "\(dir.path)/host"
            shift
            PATH="\(dir.path):$PATH" exec /bin/sh -c "$*"

            """.write(to: ssh, atomically: true, encoding: .utf8)
        for file in [shim, ssh] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (.remote(sshPath: ssh.path, options: Ssh.opts(host: "devbox"), tmux: "tmux", target: target), dir)
    }

    func testStoppingABridgeOverSshEndsTheFarClientOfAFloodingPane() throws {
        tmux.run(["new-window", "-d", "-t", "acme-app", "yes"])
        let ids = tmux.ids(window: "acme-app:1")
        let target = MobileTerminal.Target(pane: ids.pane, session: ids.session)
        let (launch, dir) = try sshLaunch(target)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let bridge = MobileTerminalBridge(launch: launch, target: target) { event in
            if case .ready = event { ready.fulfill() }
        }
        XCTAssertTrue(bridge.start())
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(tmux.clientCount, 1)
        // Never told there is room: the pane floods a bridge that passes nothing on.
        Thread.sleep(forTimeInterval: 1)
        bridge.stop()
        XCTAssertTrue(eventually(8) { tmux.clientCount == 0 })
        XCTAssertTrue(tmux.alive)
    }

    // MARK: an old tmux

    func testATmuxTooOldForFlowControlClosesTheSocketWithItsOwnCode() throws {
        // A stand-in for an old tmux's control client: it attaches, then
        // refuses the first command, as tmux before 3.2 refuses the flag.
        let script = "printf '%%begin 1 1 0\\n%%end 1 1 0\\n'; read line; "
            + "printf '%%begin 1 2 1\\nunknown flag -- f\\n%%error 1 2 1\\n'; cat >/dev/null"
        startServer(launch: .init(path: "/bin/sh", args: ["-c", script]))
        let (phone, head) = connect()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        phone.send(1, Data("demo-token".utf8))
        // No screen is ever sent: the first frame is the close.
        let frame = try XCTUnwrap(phone.frame())
        XCTAssertEqual(frame.opcode, 8)
        XCTAssertEqual(frame.payload, Data([0x11, 0x4A]))
    }

    // MARK: descriptors

    func testNoOtherProcessInheritsTheBridgesPipes() {
        let ids = tmux.ids()
        let target = MobileTerminal.Target(pane: ids.pane, session: ids.session)
        let bridge = MobileTerminalBridge(launch: localLaunch(target), target: target) { _ in }
        XCTAssertTrue(bridge.start())
        XCTAssertEqual(bridge.descriptors.count, 2)
        for fd in bridge.descriptors {
            XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC, "fd \(fd)")
        }
        bridge.stop()
    }

    func testAProcessStartedMeanwhileDoesNotKeepTheClientAttached() throws {
        tmux.run(["new-window", "-d", "-t", "acme-app", Self.flood])
        let ids = tmux.ids(window: "acme-app:1")
        let target = MobileTerminal.Target(pane: ids.pane, session: ids.session)
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let bridge = MobileTerminalBridge(launch: localLaunch(target), target: target) { event in
            if case .ready = event { ready.fulfill() }
        }
        XCTAssertTrue(bridge.start())
        wait(for: [ready], timeout: 5)
        // A process started the plain way, as the embedded terminal starts a
        // shell: it gets every descriptor that is not marked close-on-exec.
        var pid: pid_t = 0
        let args: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { args.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, nil, args, nil), 0)
        defer {
            kill(pid, SIGKILL)
            waitpid(pid, nil, 0)
        }
        bridge.stop()
        XCTAssertTrue(eventually(6) { tmux.clientCount == 0 })
    }

    // MARK: over ssh

    func testTheBridgeRunsOverSshAndClosesCleanly() throws {
        let ids = tmux.ids()
        let target = MobileTerminal.Target(pane: ids.pane, session: ids.session)
        let (launch, dir) = try sshLaunch(target)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = expectation(description: "ready")
        let echoed = expectation(description: "echoed")
        echoed.assertForOverFulfill = false
        var seen = Data()
        var bridge: MobileTerminalBridge?
        bridge = MobileTerminalBridge(launch: launch, target: target) { event in
            switch event {
            case .ready: ready.fulfill()
            case .output(let bytes):
                seen.append(bytes)
                if String(decoding: seen, as: UTF8.self).contains("over ssh") { echoed.fulfill() }
            default: break
            }
        }
        XCTAssertEqual(bridge?.start(), true)
        wait(for: [ready], timeout: 5)
        bridge?.resume()
        bridge?.input(Data("over ssh\r".utf8))
        wait(for: [echoed], timeout: 5)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("host")), "devbox\n")
        XCTAssertTrue(eventually { tmux.screen(ids.pane).contains("over ssh") })
        XCTAssertEqual(tmux.clientCount, 1)
        bridge?.stop()
        XCTAssertTrue(eventually { tmux.clientCount == 0 })
    }

    // MARK: the manager

    func testTheManagersOwnSessionHasNoLiveTerminalEvenIfATreeHoldsIt() {
        tmux.run(["new-session", "-d", "-s", ManagerHome.sessionName, "cat"])
        let parts = tmux.run(["display-message", "-p", "-t", ManagerHome.sessionName, "#{pane_id} #{session_id}"])
            .split(separator: " ").map(String.init)
        // A tree that should never be given to the server: it holds the manager.
        let pane = TmuxPane(id: parts[0], index: 0, command: "claude", title: "", active: true)
        server.update(MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: ManagerHome.sessionName, attached: false, id: parts[1], windows: [
                TmuxWindow(index: 0, name: "manager", active: true, panes: [pane]),
            ])])]))
        let (phone, head) = connect(MobileSnapshot.threadID(host: .local, pane: parts[0]))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        phone.send(1, Data("demo-token".utf8))
        XCTAssertEqual(phone.closeCode(), 4404)
        XCTAssertEqual(launches.value, 0)
    }

    // MARK: no lost start

    func testEverySocketGetsOutputAfterItsFirstScreen() {
        for round in 0..<25 {
            let phone = live(device: "100.64.0.\(round)")
            phone.send(2, Data("r\(round)\r".utf8))
            XCTAssertTrue(phone.output(until: "r\(round)\r\nr\(round)", 3).contains("r\(round)"), "round \(round)")
            phone.hangUp()
        }
    }

    // MARK: one phone

    func testTheCapPerPhoneDoesNotTrustAForwardedAddress() {
        var limits = MobileServer.Limits()
        limits.maxSocketsPerClient = 1
        startServer(limits: limits)
        // The same token from "another address" is the same holder.
        let first = live(device: "100.64.0.7")
        _ = live(device: "100.64.0.99")
        XCTAssertEqual(first.closeCode(), 4409)
    }

    func testEmptyFragmentsCountTowardsTheRate() {
        var limits = MobileServer.Limits()
        limits.socketRate = 1
        limits.socketBurst = 5
        startServer(limits: limits)
        let phone = live()
        var flood = MobileSocketTests.frame(2, [], fin: false)
        for _ in 0..<50 { flood.append(MobileSocketTests.frame(0, [], fin: false)) }
        phone.send(flood)
        XCTAssertEqual(phone.closeCode(), 1008)
    }

    func testTheLargeAllowanceEndsWithTheFirstScreen() {
        var limits = MobileServer.Limits()
        limits.socketBacklog = 4096
        limits.socketStall = 60
        startServer(limits: limits)
        tmux.run(["new-window", "-d", "-t", "acme-app", Self.flood])
        server.update(snapshot(windows: ["acme-app:0", "acme-app:1"]))
        let fd = unreadSocket(threadID("acme-app:1"))
        defer { close(fd) }
        XCTAssertTrue(eventually { tmux.clientCount == 1 })
        Thread.sleep(forTimeInterval: 1.5)
        // Far less than the megabytes a first capture may take.
        let held = server.socketPending
        XCTAssertFalse(held.isEmpty)
        for pending in held { XCTAssertLessThan(pending, 4096 + 2 * 262_144) }
        XCTAssertLessThan(server.socketAllowance.max() ?? .max, 1_048_576)
    }

    // MARK: tmux holds the output, and does not keep it

    /// The tmux server's resident memory, in megabytes.
    private func serverMegabytes() -> Int {
        let pid = tmux.run(["display-message", "-p", "#{pid}"])
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", pid]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return -1 }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return (Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1) / 1024
    }

    /// Watch the server's memory for `seconds`; the most it reached.
    private func peakMegabytes(for seconds: TimeInterval) -> Int {
        var peak = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            peak = max(peak, serverMegabytes())
            Thread.sleep(forTimeInterval: 0.25)
        }
        return peak
    }

    func testAPhoneThatDoesNotReadCostsTheTmuxServerNoMemory() {
        var limits = MobileServer.Limits()
        // The socket is kept, so the whole time is spent stalled.
        limits.socketStall = 120
        limits.socketDead = 120
        startServer(limits: limits)
        tmux.run(["new-window", "-d", "-t", "acme-app", "yes"])
        server.update(snapshot(windows: ["acme-app:0", "acme-app:1"]))
        let fd = unreadSocket(threadID("acme-app:1"))
        defer { close(fd) }
        XCTAssertTrue(eventually { tmux.clientCount == 1 })
        let peak = peakMegabytes(for: 30)
        XCTAssertLessThan(peak, 50, "tmux server reached \(peak) MB")
        XCTAssertEqual(tmux.clientCount, 1)
    }

    func testAPhoneThatReadsAFloodCostsTheTmuxServerNoMemory() {
        tmux.run(["new-window", "-d", "-t", "acme-app", "yes"])
        server.update(snapshot(windows: ["acme-app:0", "acme-app:1"]))
        let phone = live(threadID("acme-app:1"))
        var bytes = 0
        let end = Date().addingTimeInterval(15)
        var peak = 0
        while Date() < end, let frame = phone.frame(2) {
            bytes += frame.payload.count
            if bytes % 64 == 0 { peak = max(peak, serverMegabytes()) }
        }
        peak = max(peak, serverMegabytes())
        XCTAssertLessThan(peak, 50, "tmux server reached \(peak) MB")
        XCTAssertGreaterThan(bytes, 100_000)
        // The socket is still good: the pane's screen keeps coming.
        XCTAssertEqual(tmux.clientCount, 1)
    }

    // MARK: a test run that is killed

    func testTheTmuxServerEndsWhenTheProcessThatMadeItIsGone() throws {
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["60"]
        try owner.run()
        guard let orphan = PrivateTmux(owner: owner.processIdentifier), orphan.alive else {
            owner.terminate()
            return XCTFail("no server")
        }
        addTeardownBlock { orphan.stop() }
        orphan.run(["new-window", "-d", "-t", "acme-app", "yes"])
        let socket = orphan.run(["display-message", "-p", "#{socket_path}"])
        // No teardown runs: the owner is gone at once.
        owner.terminate()
        owner.waitUntilExit()
        XCTAssertTrue(eventually { !orphan.alive })
        XCTAssertTrue(eventually { !FileManager.default.fileExists(atPath: socket) })
    }

    private static let flood =
        "while :; do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done"

    /// A paired socket whose answers are never read: a plain descriptor, so
    /// its buffers are the kernel's alone and they fill.
    private func unreadSocket(_ thread: String) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let id = thread.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var hello = Data((
            "GET /api/terminal/\(id) HTTP/1.1\r\nHost: devmac.example.ts.net:7433\r\n"
                + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: https://devmac.example.ts.net:7433\r\n"
                + "Tailscale-User-Login: me@example.com\r\n\r\n").utf8)
        hello.append(MobileSocketTests.frame(1, Array("demo-token".utf8)))
        XCTAssertEqual(hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, hello.count)
        return fd
    }
}
