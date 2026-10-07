import Foundation

// The live terminal's bridge to one tmux pane: a tmux control-mode client
// (`tmux -C attach-session`). Foundation only, so the test target compiles it
// and runs it against a private tmux server.
//
// Control mode, and not a pty with `tmux attach` in it: a control client has
// no size until it is given one, so tmux resizes the window the human looks
// at on the Mac only while a phone has the terminal open and has said its
// size, and it names the pane each line of output came from, so one pane is
// told from the rest of its session.
//
// What the phone types never becomes part of a tmux command. The only lines
// written to the client are the four kinds built here: each is fixed text, an
// id that came from the tree and was checked to be a sigil and digits, and,
// for input, the bytes as hex pairs, or, for a size, two checked integers.

enum MobileTerminal {
    /// What Settings asks before the switch goes on. The one place the
    /// switch is explained: it is the strongest one the phone has.
    static let confirmTitle = "Turn on Live terminal?"
    static let confirmText = "The phone gets full keyboard control of each session it opens, "
        + "including answering permission prompts. What it types goes straight to the session: "
        + "the checks that Replies and the Key bar make do not apply."

    /// Scrollback lines the phone gets when it connects.
    static let historyLines = 5000
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

    /// The tmux argv of the bridge: a control client, which has no size of
    /// its own. `flowCommand` then says so again.
    static func attachArgv(_ target: Target) -> [String] {
        ["-C", "attach-session", "-t", target.session]
    }

    /// A pipe whose two ends are close-on-exec from the moment they exist.
    /// `pipe()` and a flag set afterwards leave a moment in which a process
    /// started by another thread inherits the ends; this system has no call
    /// that makes a pipe with the flag. Opening a named pipe does take the
    /// flag, so the pipe is made with a name, opened twice, and its name
    /// removed. nil when it could not be made.
    static func pipe() -> (read: Int32, write: Int32, path: String)? {
        let path = NSTemporaryDirectory() + "mm-pipe-" + UUID().uuidString
        guard mkfifo(path, 0o600) == 0 else { return nil }
        defer { unlink(path) }
        // The reading end first, without waiting for a writer.
        let read = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard read >= 0 else { return nil }
        let write = open(path, O_WRONLY | O_CLOEXEC)
        guard write >= 0 else {
            close(read)
            return nil
        }
        // Blocking again: the reader is the client, which expects that.
        _ = fcntl(read, F_SETFL, fcntl(read, F_GETFL) & ~O_NONBLOCK)
        return (read, write, path)
    }

    /// The mouse flags come last: a tmux that does not know one of them
    /// leaves it out, and the nine before them still stand.
    static let stateFormat = "#{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{alternate_on} "
        + "#{cursor_flag} #{keypad_cursor_flag} #{scroll_region_upper} #{scroll_region_lower} "
        + "#{mouse_standard_flag} #{mouse_button_flag} #{mouse_all_flag} #{mouse_sgr_flag}"

    static func stateCommand(_ target: Target) -> String {
        "display-message -p -t \(target.pane) '\(stateFormat)'"
    }

    static func captureCommand(_ target: Target) -> String {
        "capture-pane -p -e -S -\(historyLines) -t \(target.pane)"
    }

    /// Asks tmux to hold a pane's output for this client once the client is
    /// a second behind, and not to keep it. Without it tmux keeps every byte
    /// a slow client has not taken, and its memory grows with the pane. The
    /// same command says the client's size does not count towards a window's:
    /// that holds until the phone says a size, see `sizeCommands`.
    /// A tmux older than 3.2 refuses it, and the bridge then ends: see
    /// `MobileControlSession.Event.unsupported`.
    static let flowCommand = "refresh-client -f ignore-size,pause-after=1"
    /// The client's size counts from here on.
    static let sizedFlowCommand = "refresh-client -f !ignore-size"

    static let sizeCols = 20...300
    static let sizeRows = 5...200

    /// The size a phone asked for, brought inside the limits.
    static func clamp(cols: Int, rows: Int) -> (cols: Int, rows: Int) {
        (min(max(cols, sizeCols.lowerBound), sizeCols.upperBound),
         min(max(rows, sizeRows.lowerBound), sizeRows.upperBound))
    }

    /// The phone's size frame: `{"type":"size","cols":n,"rows":n}` with two
    /// whole numbers, and nothing else. The numbers come back clamped.
    static func sizeFrame(_ data: Data) -> (cols: Int, rows: Int)? {
        guard data.count <= 128,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 3, object["type"] as? String == "size",
              let cols = whole(object["cols"]), let rows = whole(object["rows"])
        else { return nil }
        return clamp(cols: cols, rows: rows)
    }

    private static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let exact = Int(exactly: number.doubleValue)
        else { return nil }
        return exact
    }

    /// The client's size: two integers inside the limits and fixed text.
    static func sizeCommand(cols: Int, rows: Int) -> String {
        let size = clamp(cols: cols, rows: rows)
        return "refresh-client -C \(size.cols)x\(size.rows)"
    }

    /// Give the window the phone's size. With tmux's `window-size latest`
    /// (its default) the window has the size of the client used last. A
    /// control client counts as used when it is put on its session, so that
    /// comes first; the size then takes effect. The Mac's own client takes
    /// the window back at its next key press, and when this client ends.
    static func sizeCommands(cols: Int, rows: Int, target: Target) -> [String] {
        ["switch-client -t \(target.session)", sizeCommand(cols: cols, rows: rows)]
    }
    /// Output older than this, in milliseconds, means the client is falling
    /// behind the pane: the bridge pauses the pane itself, well before tmux
    /// would.
    static let maxAgeMilliseconds = 250

    /// Stop the pane's output to this client. tmux drops what it held for it.
    static func pauseCommand(_ target: Target) -> String {
        "refresh-client -A '\(target.pane):pause'"
    }

    static func continueCommand(_ target: Target) -> String {
        "refresh-client -A '\(target.pane):continue'"
    }

    /// The control client under a small shell that ends it when its input
    /// closes: when the bridge stops, and when this app goes away for any
    /// reason, a kill included. The shell reads the input and hands it to
    /// the client through a named pipe; at the end of input it closes the
    /// pipe, waits a second, and signals the client. The signal is needed: a
    /// control client with output still to write stays attached when its
    /// pipes merely close.
    ///
    /// One line, with no quote, backslash or newline in it, so it can also
    /// be one word of a command for a remote login shell of any kind.
    static let supervisor = "f=$(mktemp -u) && mkfifo -m 600 \"$f\" || exit 1; "
        + "\"$@\" <\"$f\" 2>/dev/null & c=$! ; exec 3>\"$f\"; rm -f \"$f\"; cat >&3; exec 3>&-; "
        + "sleep 1; kill \"$c\" 2>/dev/null; sleep 2; kill -9 \"$c\" 2>/dev/null; wait"

    /// `command` (a program and its arguments) under the supervisor.
    static func supervised(_ command: [String]) -> [String] {
        ["sh", "-c", supervisor, "sh"] + command
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
        /// Mouse reports the pane's program asked for: clicks, drags, every
        /// move, and the SGR form of them.
        var mouseStandard = false
        var mouseButton = false
        var mouseAll = false
        var mouseSGR = false

        /// The reply to `stateCommand`.
        init?(_ line: String) {
            let fields = line.split(separator: " ").map { Int($0) }
            guard (9...13).contains(fields.count), let cols = fields[0], let rows = fields[1],
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
            let flag = { (index: Int) in index < fields.count && fields[index] == 1 }
            mouseStandard = flag(9)
            mouseButton = flag(10)
            mouseAll = flag(11)
            mouseSGR = flag(12)
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
        // The mouse modes the program set before the phone came: the phone's
        // terminal must know them to scroll the program with wheel reports.
        if state.mouseStandard { escape("?1000h") }
        if state.mouseButton { escape("?1002h") }
        if state.mouseAll { escape("?1003h") }
        if state.mouseSGR { escape("?1006h") }
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
        /// The pane's output to this client has stopped, and what was on its
        /// way is lost. `resync()` starts it again with a new `ready`.
        case paused
        case size(cols: Int, rows: Int)
        /// tmux refused flow control: it is too old for a live terminal. The
        /// bridge is over.
        case unsupported
        /// The bridge is over: the pane, its session or the client went away.
        case exit
    }

    private enum Reply { case flow, state, capture, size, keys, other }

    let target: MobileTerminal.Target
    /// The replies still to come, in the order their commands were written.
    private var awaited: [Reply] = [.flow, .state, .capture]
    /// The block being read: its `%begin` arguments, and whose it is.
    private var block: (tag: Data, reply: Reply?, lines: [Data], bytes: Int)?
    private var state: MobileTerminal.State?
    private var ready = false
    private var paused = false
    private var over = false
    /// The phone has said a size: the client's size counts.
    private var sized = false

    init(target: MobileTerminal.Target) { self.target = target }

    /// The lines to write when the client starts.
    var opening: [String] {
        [
            MobileTerminal.flowCommand, MobileTerminal.stateCommand(target),
            MobileTerminal.captureCommand(target),
        ]
    }

    /// Stop the pane's output: the phone cannot take it as fast as it comes.
    mutating func pause() -> [String] {
        guard !over, !paused else { return [] }
        paused = true
        ready = false
        awaited.append(.other)
        return [MobileTerminal.pauseCommand(target)]
    }

    /// Start a paused pane again, from a new capture of its screen.
    mutating func resync() -> [String] {
        guard !over, paused else { return [] }
        paused = false
        awaited += [.other, .state, .capture]
        return [
            MobileTerminal.continueCommand(target), MobileTerminal.stateCommand(target),
            MobileTerminal.captureCommand(target),
        ]
    }

    /// Bytes from the phone, as lines to write.
    mutating func keys(_ data: Data) -> [String] {
        guard !over, !data.isEmpty else { return [] }
        let lines = MobileTerminal.keyCommands(data, target: target)
        awaited += lines.map { _ in .keys }
        return lines
    }

    /// The size the phone's terminal has room for, as lines to write.
    mutating func size(cols: Int, rows: Int) -> [String] {
        guard !over else { return [] }
        var lines = MobileTerminal.sizeCommands(cols: cols, rows: rows, target: target)
        if !sized { lines.insert(MobileTerminal.sizedFlowCommand, at: 0) }
        sized = true
        awaited += lines.map { _ in .other }
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
            // `%extended-output %1 <age in ms> ... : <data>`.
            guard ready, words.count == 3, words[1] == Data(target.pane.utf8),
                  let colon = words[2].range(of: Data(" : ".utf8))
            else { return [] }
            let age = words[2].split(separator: UInt8(ascii: " ")).first
                .flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            // Old output: the pane writes faster than this client reads.
            if age > MobileTerminal.maxAgeMilliseconds {
                return pause().map(Event.send) + [.paused]
            }
            return [.output(MobileTerminal.unescape(Data(words[2][colon.upperBound...])))]
        case "%pause":
            // tmux stopped the pane for this client by itself.
            guard words.count >= 2, words[1] == Data(target.pane.utf8), !paused else { return [] }
            paused = true
            ready = false
            return [.paused]
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
        case nil, .other:
            return []
        case .flow:
            guard failed else { return [] }
            over = true
            return [.unsupported]
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
/// Back-pressure: one lot of output is with the server at a time, until it
/// calls `resume()`. The client's output is read all the while, so tmux never
/// keeps it for a slow reader. What the phone cannot take is held up to a
/// limit; past that the pane is paused in tmux, which keeps nothing for a
/// paused client, and a new capture of the screen follows when there is room.
///
/// The client never outlives the bridge. `stop()` ends it, letting go of the
/// bridge without `stop()` ends it, and so does the death of this process,
/// however it dies: see `MobileTerminal.supervisor`.
final class MobileTerminalBridge {
    /// The command that runs the control client, here or over ssh.
    struct Launch: Equatable {
        var path: String
        var args: [String]

        /// `launch` under `MobileTerminal.supervisor`, run by this Mac's shell.
        static func supervised(_ launch: Launch) -> Launch {
            let command = MobileTerminal.supervised([launch.path] + launch.args)
            return Launch(path: "/bin/sh", args: Array(command.dropFirst()))
        }

        /// The same for a host reached over ssh: the supervisor runs there, next
        /// to the client. Each word is quoted for the remote shell.
        static func remote(
                sshPath: String, options: [String], tmux: String, target: MobileTerminal.Target
            ) -> Launch {
            let command = MobileTerminal.supervised([tmux] + MobileTerminal.attachArgv(target))
            return Launch(path: sshPath, args: options + command.map(Ssh.shellQuote))
        }
    }

    enum Event: Equatable {
        case ready(cols: Int, rows: Int, snapshot: Data)
        /// Call `resume()` when there is room for more.
        case output(Data)
        case size(cols: Int, rows: Int)
        /// The host's tmux is too old for a live terminal. The bridge is over.
        case unsupported
        case exit
    }

    /// Output held for the phone while it has not taken the last lot. More
    /// than this and the pane is paused.
    static let heldLimit = 262_144
    /// The least time between a pause and the capture that follows it.
    static let resyncGap: TimeInterval = 0.5

    /// The running half. The queue's blocks hold it, never the bridge, so the
    /// bridge is free to go while a read is under way.
    private final class Engine {
        let launch: Launch
        let onEvent: (Event) -> Void
        let io = DispatchQueue(label: "is.rebar.muxmaestro.mobile.terminal")
        let process = Process()
        /// The client's input and output. Each end is close-on-exec from
        /// the start, so no other process this app starts ever holds one: a
        /// copy of the input's writing end would keep the client alive.
        let input: (reading: FileHandle, writing: FileHandle)?
        let output: (reading: FileHandle, writing: FileHandle)?

        // Confined to `io`.
        var session: MobileControlSession
        var source: DispatchSourceRead?
        var pending = Data()
        var stopped = false
        /// The server has a lot of output it has not said there is room after.
        var awaiting = false
        var held = Data()
        var paused = false
        var pausedAt = Date.distantPast
        var resyncDue = false

        init(launch: Launch, target: MobileTerminal.Target, onEvent: @escaping (Event) -> Void) {
            self.launch = launch
            self.onEvent = onEvent
            session = MobileControlSession(target: target)
            let handles = { (pipe: (read: Int32, write: Int32, path: String)?) in
                pipe.map {
                    (FileHandle(fileDescriptor: $0.read, closeOnDealloc: true),
                     FileHandle(fileDescriptor: $0.write, closeOnDealloc: true))
                }
            }
            input = handles(MobileTerminal.pipe())
            output = handles(MobileTerminal.pipe())
        }

        /// The descriptors this process keeps while the client runs.
        var descriptors: [Int32] {
            [input?.writing.fileDescriptor, output?.reading.fileDescriptor].compactMap { $0 }
        }

        func start() -> Bool {
            guard let input, let output else { return false }
            process.executableURL = URL(fileURLWithPath: launch.path)
            process.arguments = launch.args
            var environment = ProcessCommandRunner.childEnvironment
            if environment["TERM"] == nil { environment["TERM"] = "xterm-256color" }
            process.environment = environment
            process.standardInput = input.reading
            process.standardOutput = output.writing
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                io.async { self.finish(report: false) }
                return false
            }
            // The client's own ends are the client's alone.
            try? input.reading.close()
            try? output.writing.close()
            // A write to a client that has gone is an error, not a signal.
            _ = fcntl(input.writing.fileDescriptor, F_SETNOSIGPIPE, 1)
            let fd = output.reading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            io.async { [self] in
                guard !stopped else { return }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
                source.setEventHandler { [self] in read(fd) }
                self.source = source
                source.resume()
                write(session.opening)
            }
            return true
        }

        func write(_ lines: [String]) {
            guard !stopped, !lines.isEmpty, let input else { return }
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            let fd = input.writing.fileDescriptor
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

        /// The server took the last lot and has room.
        func resume() {
            guard !stopped else { return }
            awaiting = false
            if !held.isEmpty {
                let next = held
                held = Data()
                deliver(.output(next))
            } else if paused {
                resyncSoon()
            }
        }

        /// Hand the server a lot of output, or a screen, and wait for room.
        func deliver(_ event: Event) {
            awaiting = true
            onEvent(event)
        }

        /// Output from the pane. One lot is with the server at a time; what
        /// comes meanwhile is held, up to a limit. Past it the pane is
        /// paused in tmux, which then keeps nothing for this client, and
        /// what was held is dropped: a new capture follows.
        func offer(_ data: Data) {
            guard !data.isEmpty, !paused else { return }
            guard awaiting else { return deliver(.output(data)) }
            held.append(data)
            guard held.count > MobileTerminalBridge.heldLimit else { return }
            write(session.pause())
            didPause()
        }

        func didPause() {
            held = Data()
            paused = true
            pausedAt = Date()
        }

        /// Start the pane again once the server has room, and not at once:
        /// a pane that floods would otherwise be captured without a rest.
        func resyncSoon() {
            guard !resyncDue else { return }
            resyncDue = true
            let wait = max(0, MobileTerminalBridge.resyncGap - Date().timeIntervalSince(pausedAt))
            io.asyncAfter(deadline: .now() + wait) { [self] in
                resyncDue = false
                guard !stopped, paused, !awaiting else { return }
                paused = false
                write(session.resync())
            }
        }

        /// The pane is always read, whatever the phone does: tmux never has
        /// to keep output because this process is slow to take it.
        func read(_ fd: Int32) {
            guard !stopped else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            guard count > 0 else { return finish(report: true) }
            pending.append(contentsOf: chunk[0..<count])

            var out = Data()
            var ended = false
            while !ended, !stopped, let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[pending.startIndex..<newline])
                pending = Data(pending[pending.index(after: newline)...])
                for event in session.line(line) {
                    switch event {
                    case .send(let text): write([text])
                    case .output(let data): out.append(data)
                    case .ready(let state, let snapshot):
                        // A screen replaces whatever was on its way.
                        out = Data()
                        held = Data()
                        deliver(.ready(cols: state.cols, rows: state.rows, snapshot: snapshot))
                    case .size(let cols, let rows):
                        offer(out)
                        out = Data()
                        onEvent(.size(cols: cols, rows: rows))
                    case .paused:
                        out = Data()
                        didPause()
                    case .unsupported:
                        out = Data()
                        onEvent(.unsupported)
                        return finish(report: false)
                    case .exit:
                        ended = true
                    }
                }
            }
            guard !stopped else { return }
            offer(out)
            if paused, !awaiting { resyncSoon() }
            if ended || pending.count > MobileTerminal.maxLineBytes { finish(report: true) }
        }

        func finish(report: Bool) {
            guard !stopped else { return }
            stopped = true
            // Both of this process's pipe ends are closed. The end of input
            // is what the shell around the client waits for.
            let reader = output?.reading
            if let source {
                source.setCancelHandler { try? reader?.close() }
                source.cancel()
            } else {
                try? reader?.close()
            }
            source = nil
            try? input?.writing.close()
            // By its own process id, and only if the shell did not end.
            io.asyncAfter(deadline: .now() + 6) { [process] in
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

    /// The descriptors this process holds for the client. For tests.
    var descriptors: [Int32] { engine.descriptors }

    /// Bytes from the phone, for the pane.
    func input(_ data: Data) {
        engine.io.async { [engine] in engine.write(engine.session.keys(data)) }
    }

    /// The size the phone has room for. The pane's new size comes back as
    /// a `size` event once tmux has given it.
    func size(cols: Int, rows: Int) {
        engine.io.async { [engine] in engine.write(engine.session.size(cols: cols, rows: rows)) }
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
