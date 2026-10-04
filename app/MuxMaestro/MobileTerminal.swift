import Foundation

// The live terminal's bridge to one tmux pane: a tmux control-mode client
// (`tmux -C attach-session`). Foundation only, so the test target compiles it
// and runs it against a private tmux server.
//
// Control mode, and not a pty with `tmux attach` in it: a control client has
// no size of its own, so tmux never resizes the window the human looks at on
// the Mac, and it names the pane each line of output came from, so one pane
// is told from the rest of its session.
//
// What the phone types never becomes part of a tmux command. The only lines
// written to the client are the three built here: each is fixed text, a pane
// id that came from the tree and was checked to be `%` and digits, and, for
// input, the bytes as hex pairs.

enum MobileTerminal {
    /// What Settings asks before the switch goes on. The one place the
    /// switch is explained: it is the strongest one the phone has.
    static let confirmTitle = "Turn on Live terminal?"
    static let confirmText = "The phone gets full keyboard control of each session it opens, "
        + "including answering permission prompts. What it types goes straight to the session: "
        + "the checks that Replies and the Key bar make do not apply."

    /// Scrollback lines the phone gets when it connects.
    static let historyLines = 2000
    /// Bytes of input in one `send-keys` line.
    static let inputChunk = 256
    /// The longest line of control output that is kept. A longer one ends the
    /// bridge: tmux sends output in far smaller pieces.
    static let maxLineBytes = 1_048_576
    /// The most the first capture may hold.
    static let maxSnapshotBytes = 8_388_608

    /// The pane a socket is bound to, and the session to attach to see it.
    struct Target: Equatable {
        /// `%` and digits.
        let pane: String
        /// `$` and digits.
        let session: String
    }

    /// The target of `thread`, from the tree alone. nil when the tree's ids
    /// are not the plain ids tmux gives: such a thread has no live terminal.
    static func target(_ thread: MobileThread) -> Target? {
        // The manager's own session is never in the tree the server is given.
        // Said again here, so a tree that held it would still open nothing.
        guard !(thread.host.isLocal && thread.session == ManagerHome.sessionName) else { return nil }
        guard isID(thread.pane, sigil: "%"), isID(thread.sessionId, sigil: "$") else { return nil }
        return Target(pane: thread.pane, session: thread.sessionId)
    }

    private static func isID(_ text: String, sigil: Character) -> Bool {
        let digits = text.dropFirst()
        return text.first == sigil && !digits.isEmpty && digits.count <= 9
            && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The tmux argv of the bridge. `ignore-size` says again what a control
    /// client already is: its size never counts towards a window's.
    static func attachArgv(_ target: Target) -> [String] {
        ["-C", "attach-session", "-f", "ignore-size", "-t", target.session]
    }

    static let stateFormat = "#{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{alternate_on} "
        + "#{cursor_flag} #{keypad_cursor_flag} #{scroll_region_upper} #{scroll_region_lower}"

    static func stateCommand(_ target: Target) -> String {
        "display-message -p -t \(target.pane) '\(stateFormat)'"
    }

    static func captureCommand(_ target: Target) -> String {
        "capture-pane -p -e -S -\(historyLines) -t \(target.pane)"
    }

    /// `data` as key presses: `send-keys -H` takes each byte as two hex
    /// digits and hands it to the pane as it is. A line holds hex digits and
    /// spaces after its fixed start, so no byte can end the command, start
    /// another, or be read as a key name.
    static func keyCommands(_ data: Data, target: Target) -> [String] {
        stride(from: 0, to: data.count, by: inputChunk).map { start in
            let bytes = data.dropFirst(start).prefix(inputChunk)
            return "send-keys -t \(target.pane) -H "
                + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    /// The bytes of a `%output` line: tmux writes a byte below space, and a
    /// backslash, as a backslash and three octal digits.
    static func unescape(_ text: Data) -> Data {
        var out = Data(capacity: text.count)
        let bytes = [UInt8](text)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), index + 3 < bytes.count,
               let value = octal(bytes[index + 1], bytes[index + 2], bytes[index + 3]) {
                out.append(value)
                index += 4
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }

    private static func octal(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8? {
        let digits = [a, b, c].map { Int($0) - 48 }
        guard digits.allSatisfy({ (0...7).contains($0) }), digits[0] <= 3 else { return nil }
        return UInt8(digits[0] << 6 | digits[1] << 3 | digits[2])
    }

    /// What a pane shows when the phone connects.
    struct State: Equatable {
        var cols: Int
        var rows: Int
        var cursorX = 0
        var cursorY = 0
        var alternate = false
        var cursorVisible = true
        var applicationCursor = false
        var regionTop = 0
        var regionBottom = 0

        /// The reply to `stateCommand`.
        init?(_ line: String) {
            let fields = line.split(separator: " ").map { Int($0) }
            guard fields.count == 9, let cols = fields[0], let rows = fields[1],
                  (1...1000).contains(cols), (1...1000).contains(rows)
            else { return nil }
            self.cols = cols
            self.rows = rows
            cursorX = min(max(fields[2] ?? 0, 0), cols - 1)
            cursorY = min(max(fields[3] ?? 0, 0), rows - 1)
            alternate = fields[4] == 1
            cursorVisible = fields[5] != 0
            applicationCursor = fields[6] == 1
            regionTop = min(max(fields[7] ?? 0, 0), rows - 1)
            regionBottom = min(max(fields[8] ?? rows - 1, regionTop), rows - 1)
        }

        init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
            regionBottom = rows - 1
        }
    }

    /// The bytes that draw a captured pane in a new terminal of the pane's
    /// size: its scrollback and screen, then the modes and the cursor the
    /// pane's program expects to find.
    static func snapshot(state: State, capture: [Data]) -> Data {
        var out = Data()
        let escape = { (text: String) in out.append(Data("\u{1B}[\(text)".utf8)) }
        if state.alternate { escape("?1049h") }
        for (index, line) in capture.enumerated() {
            if index > 0 { out.append(Data("\r\n".utf8)) }
            out.append(line)
        }
        escape("0m")
        if state.regionTop > 0 || state.regionBottom < state.rows - 1 {
            escape("\(state.regionTop + 1);\(state.regionBottom + 1)r")
        }
        if state.applicationCursor { escape("?1h") }
        escape("\(state.cursorY + 1);\(state.cursorX + 1)H")
        if !state.cursorVisible { escape("?25l") }
        return out
    }
}

/// The control-mode conversation of one bridge, without the process: lines
/// in, events out. It keeps the replies to its own commands apart from the
/// output of the pane.
struct MobileControlSession {
    enum Event: Equatable {
        /// Write this line to the control client.
        case send(String)
        /// The pane as it is now. Sent once, before any `output`.
        case ready(MobileTerminal.State, snapshot: Data)
        /// Bytes the pane wrote since.
        case output(Data)
        case size(cols: Int, rows: Int)
        /// The bridge is over: the pane, its session or the client went away.
        case exit
    }

    private enum Reply { case state, capture, size, keys }

    let target: MobileTerminal.Target
    /// The replies still to come, in the order their commands were written.
    private var awaited: [Reply] = [.state, .capture]
    /// The block being read: its `%begin` arguments, and whose it is.
    private var block: (tag: Data, reply: Reply?, lines: [Data], bytes: Int)?
    private var state: MobileTerminal.State?
    private var ready = false
    private var over = false

    init(target: MobileTerminal.Target) { self.target = target }

    /// The lines to write when the client starts.
    var opening: [String] {
        [MobileTerminal.stateCommand(target), MobileTerminal.captureCommand(target)]
    }

    /// Bytes from the phone, as lines to write.
    mutating func keys(_ data: Data) -> [String] {
        guard !over, !data.isEmpty else { return [] }
        let lines = MobileTerminal.keyCommands(data, target: target)
        awaited += lines.map { _ in .keys }
        return lines
    }

    /// One line of the client's output, without its newline.
    mutating func line(_ line: Data) -> [Event] {
        guard !over else { return [] }
        if block != nil { return inBlock(line) }
        let words = line.split(separator: UInt8(ascii: " "), maxSplits: 2, omittingEmptySubsequences: false)
        guard let first = words.first, first.first == UInt8(ascii: "%") else { return [] }
        switch String(decoding: first, as: UTF8.self) {
        case "%begin":
            // The last field is 1 for a reply to a command this client wrote.
            let fields = line.split(separator: UInt8(ascii: " "))
            let mine = fields.count == 4 && fields[3] == Data("1".utf8)
            let reply: Reply? = mine && !awaited.isEmpty ? awaited.removeFirst() : nil
            block = (Data(line.dropFirst("%begin".count)), reply, [], 0)
            return []
        case "%output":
            guard ready, words.count == 3, words[1] == Data(target.pane.utf8) else { return [] }
            return [.output(MobileTerminal.unescape(Data(words[2])))]
        case "%extended-output":
            // `%extended-output %1 <age> ... : <data>`.
            guard ready, words.count == 3, words[1] == Data(target.pane.utf8),
                  let colon = words[2].range(of: Data(" : ".utf8))
            else { return [] }
            return [.output(MobileTerminal.unescape(Data(words[2][colon.upperBound...])))]
        case "%layout-change":
            // The pane may have a new size. One question at a time.
            guard ready, !awaited.contains(.size) else { return [] }
            awaited.append(.size)
            return [.send(MobileTerminal.stateCommand(target))]
        case "%session-changed":
            // tmux moved the client to another session: this one is gone.
            guard words.count >= 2, words[1] != Data(target.session.utf8) else { return [] }
            return end()
        case "%exit":
            return end()
        default:
            return []
        }
    }

    private mutating func end() -> [Event] {
        over = true
        block = nil
        return [.exit]
    }

    private mutating func inBlock(_ line: Data) -> [Event] {
        guard var current = block else { return [] }
        // A block ends only with its own `%begin` arguments said again.
        let failed = line == Data("%error".utf8) + current.tag
        guard failed || line == Data("%end".utf8) + current.tag else {
            guard current.reply == .state || current.reply == .capture || current.reply == .size
            else { return [] }
            current.bytes += line.count + 1
            guard current.bytes <= MobileTerminal.maxSnapshotBytes else { return end() }
            current.lines.append(line)
            block = current
            return []
        }
        block = nil
        switch current.reply {
        case nil:
            return []
        case .keys:
            // The pane no longer takes keys: it has gone.
            return failed ? end() : []
        case .state:
            guard !failed, let line = current.lines.first,
                  let state = MobileTerminal.State(String(decoding: line, as: UTF8.self))
            else { return end() }
            self.state = state
            return []
        case .capture:
            guard !failed, let state else { return end() }
            ready = true
            return [.ready(state, snapshot: MobileTerminal.snapshot(state: state, capture: current.lines))]
        case .size:
            guard !failed, let line = current.lines.first,
                  let now = MobileTerminal.State(String(decoding: line, as: UTF8.self))
            else { return end() }
            guard now.cols != state?.cols || now.rows != state?.rows else { return [] }
            state = now
            return [.size(cols: now.cols, rows: now.rows)]
        }
    }
}

/// One running control client. It reads the client's output on a queue of its
/// own and reports what `MobileControlSession` makes of it.
///
/// Back-pressure: after it reports output it reads no more until `resume()`
/// is called. A phone that reads slowly so stops the reading, and what the
/// pane writes meanwhile waits in tmux, which drops a client that falls too
/// far behind. This process holds one read of output at a time.
///
/// The client never outlives the bridge. `stop()` ends it, letting go of the
/// bridge without `stop()` ends it, and so does the death of this process,
/// however it dies: see `supervised`.
final class MobileTerminalBridge {
    /// The command that runs the control client, here or over ssh.
    struct Launch: Equatable {
        var path: String
        var args: [String]
    }

    enum Event: Equatable {
        case ready(cols: Int, rows: Int, snapshot: Data)
        /// Call `resume()` when there is room for more.
        case output(Data)
        case size(cols: Int, rows: Int)
        case exit
    }

    /// `launch` under a small shell that ends the client when this process
    /// goes away. The shell's standard error is the read end of a pipe whose
    /// only write end this process holds: when that closes, by `stop()` or
    /// because the app quit, crashed or was killed, the shell signals the
    /// client. A signal is needed: a tmux control client with output still to
    /// write stays attached when its pipes merely close, and tmux then keeps
    /// what the pane writes for it.
    static func supervised(_ launch: Launch) -> Launch {
        Launch(path: "/bin/sh", args: ["-c", supervisor, "sh", launch.path] + launch.args)
    }

    private static let supervisor = """
        exec 3<&0
        "$@" <&3 3<&- 2>/dev/null &
        c=$!
        ( exec 0<&- 1>&- 3<&-; read _ <&2; kill "$c" 2>/dev/null; sleep 2; kill -9 "$c" 2>/dev/null ) &
        w=$!
        exec 0<&- 1>&- 3<&-
        wait "$c"
        kill "$w" 2>/dev/null
        """

    /// The running half. The queue's blocks hold it, never the bridge, so the
    /// bridge is free to go while a read is under way.
    private final class Engine {
        let launch: Launch
        let onEvent: (Event) -> Void
        let io = DispatchQueue(label: "is.rebar.muxmaestro.mobile.terminal")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        /// Its write end is held open for as long as the client may run.
        let lifeline = Pipe()

        // Confined to `io`.
        var session: MobileControlSession
        var source: DispatchSourceRead?
        var reading = false
        var pending = Data()
        var stopped = false

        init(launch: Launch, target: MobileTerminal.Target, onEvent: @escaping (Event) -> Void) {
            self.launch = MobileTerminalBridge.supervised(launch)
            self.onEvent = onEvent
            session = MobileControlSession(target: target)
        }

        func start() -> Bool {
            process.executableURL = URL(fileURLWithPath: launch.path)
            process.arguments = launch.args
            var environment = ProcessCommandRunner.childEnvironment
            if environment["TERM"] == nil { environment["TERM"] = "xterm-256color" }
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = lifeline.fileHandleForReading
            do { try process.run() } catch {
                io.async { self.finish(report: false) }
                return false
            }
            // This process keeps the write end alone.
            try? lifeline.fileHandleForReading.close()
            // A write to a client that has gone is an error, not a signal.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            io.async { [self] in
                guard !stopped else { return }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
                source.setEventHandler { [self] in read(fd) }
                self.source = source
                reading = true
                source.resume()
                write(session.opening)
            }
            return true
        }

        func write(_ lines: [String]) {
            guard !stopped, !lines.isEmpty else { return }
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            let fd = input.fileHandleForWriting.fileDescriptor
            let failed = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let wrote = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if wrote < 0 && errno == EINTR { continue }
                    guard wrote > 0 else { return true }
                    offset += wrote
                }
                return false
            }
            if failed { finish(report: true) }
        }

        func resume() {
            guard !stopped, !reading, let source else { return }
            reading = true
            source.resume()
        }

        func read(_ fd: Int32) {
            guard !stopped else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            guard count > 0 else { return finish(report: true) }
            pending.append(contentsOf: chunk[0..<count])

            var out = Data()
            var events: [Event] = []
            func flush() {
                if !out.isEmpty { events.append(.output(out)) }
                out = Data()
            }
            var ended = false
            while !ended, let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[pending.startIndex..<newline])
                pending = Data(pending[pending.index(after: newline)...])
                for event in session.line(line) {
                    switch event {
                    case .send(let text): write([text])
                    case .output(let data): out.append(data)
                    case .ready(let state, let snapshot):
                        flush()
                        events.append(.ready(cols: state.cols, rows: state.rows, snapshot: snapshot))
                    case .size(let cols, let rows):
                        flush()
                        events.append(.size(cols: cols, rows: rows))
                    case .exit:
                        ended = true
                    }
                }
            }
            flush()
            guard !stopped else { return }
            // Wait for room after anything that takes room at the other end.
            let heavy = events.contains {
                if case .output = $0 { return true }
                if case .ready = $0 { return true }
                return false
            }
            if heavy, reading {
                reading = false
                source?.suspend()
            }
            events.forEach(onEvent)
            if ended || pending.count > MobileTerminal.maxLineBytes { finish(report: true) }
        }

        func finish(report: Bool) {
            guard !stopped else { return }
            stopped = true
            // Both ends of the client's pipes are closed, and the lifeline:
            // the shell around the client then signals it. A client with
            // output still to write would wait for a reader for ever.
            let reader = output.fileHandleForReading
            if let source {
                source.setCancelHandler { try? reader.close() }
                // A suspended source must run again before it can be let go.
                if !reading { source.resume() }
                source.cancel()
            } else {
                try? reader.close()
            }
            source = nil
            try? input.fileHandleForWriting.close()
            try? lifeline.fileHandleForWriting.close()
            // By its own process id, and only if the shell did not end.
            io.asyncAfter(deadline: .now() + 5) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if report { onEvent(.exit) }
        }
    }

    private let engine: Engine

    /// `onEvent` is called on the bridge's own queue.
    init(launch: Launch, target: MobileTerminal.Target, onEvent: @escaping (Event) -> Void) {
        engine = Engine(launch: launch, target: target, onEvent: onEvent)
    }

    deinit { stop() }

    /// Start the client. False when it could not be run.
    func start() -> Bool { engine.start() }

    /// Bytes from the phone, for the pane.
    func input(_ data: Data) {
        engine.io.async { [engine] in engine.write(engine.session.keys(data)) }
    }

    /// There is room for more output.
    func resume() {
        engine.io.async { [engine] in engine.resume() }
    }

    /// End the client. Safe to call more than once and from any queue.
    func stop() {
        engine.io.async { [engine] in engine.finish(report: false) }
    }
}
