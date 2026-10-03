import Foundation

// The reply half of the phone API: what the phone may type into a thread's
// pane, and the checks before each write. Pure, like MobileAPI.swift: every
// tmux call goes through `MobilePaneIO`, so the tests assert the exact argv.
//
// The rules, in one place:
// - Text is `MobileManager.text`: the one filter that keeps a key press out of
//   pasted text. It goes in as one bracketed paste, never as key presses.
// - Free text goes only into a pane that is neither busy nor on a prompt, and
//   the state is read again immediately before the Enter.
// - A pane on a prompt takes an answer the human tapped, or a whitelisted key.
// - A key is a name from `MobileReply.keys`. Nothing else reaches `send-keys`.

/// What the server may do to one thread's pane. The app builds it from the
/// host's `TmuxService`; every call may block.
struct MobilePaneIO {
    /// Run one tmux command on the pane's host. nil when it failed.
    var tmux: (_ args: [String], _ stdin: Data?) -> String?
    /// The pane's visible text.
    var screen: () -> String?
    /// The pane's status now, given its row in the latest tree: the hook state
    /// is read again, so it is newer than the tree.
    var status: (MobileThread) -> AttentionStatus
    /// Copy a file on this Mac to `path` on the pane's host.
    var copy: (_ localPath: String, _ path: String) -> Bool
    /// Whether `path` exists on the pane's host.
    var exists: (_ path: String) -> Bool
}

/// A prompt a pane waits on, read from its screen: the choices the phone shows
/// as buttons.
struct MobilePrompt: Equatable {
    enum Kind: String { case permission, question }

    struct Option: Equatable {
        /// The digit that picks it.
        let n: Int
        let label: String
    }

    let kind: Kind
    let title: String
    let detail: String
    let question: String
    let options: [Option]

    /// Names this prompt. An answer carries it back, so a tap on a card that
    /// is no longer on the pane answers nothing.
    var id: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let text = ([title, detail, question] + options.map { "\($0.n).\($0.label)" })
            .joined(separator: "\u{1F}")
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    var json: [String: Any] {
        [
            "id": id, "kind": kind.rawValue, "title": title, "detail": detail,
            "question": question,
            "options": options.map { ["n": $0.n, "label": $0.label] as [String: Any] },
        ]
    }

    /// How far above the choices the tool and its command are looked for.
    static let headerLines = 14
    /// Lines between two choices that are not a choice: a question's option
    /// may carry a description.
    static let maxGap = 2
    static let maxDetailLength = 600

    private static let frame = CharacterSet(charactersIn: "│┃|").union(.whitespaces)
    private static let cursors: Set<Character> = ["❯", "›", ">"]

    /// A line without its box edges.
    private static func content(_ line: Substring) -> String {
        String(line).trimmingCharacters(in: frame)
    }

    /// A rule or a box edge: nothing but box-drawing characters.
    private static func isRule(_ line: String) -> Bool {
        !line.isEmpty && line.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    /// `❯ 1. Yes` → (1, "Yes", selected).
    private static func option(_ line: String) -> (n: Int, label: String, selected: Bool)? {
        var rest = Substring(line)
        var selected = false
        if let first = rest.first, cursors.contains(first) {
            selected = true
            rest = rest.dropFirst().drop { $0 == " " }
        }
        guard let digit = rest.first, let n = digit.wholeNumberValue, (1...9).contains(n),
              digit.isASCII, rest.dropFirst().hasPrefix(". ")
        else { return nil }
        var label = rest.dropFirst(3).trimmingCharacters(in: .whitespaces)
        if label.hasSuffix("(esc)") { label = String(label.dropLast(5)).trimmingCharacters(in: .whitespaces) }
        return label.isEmpty ? nil : (n, label, selected)
    }

    /// The prompt on `screen`, or nil when it shows none. A prompt is a list
    /// numbered from 1 with the cursor on one of its lines; the last such list
    /// on the screen is the live one.
    static func parse(screen: String) -> MobilePrompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(content)
        guard let at = lines.lastIndex(where: { option($0)?.selected == true }),
              let picked = option(lines[at]) else { return nil }

        var found: [(index: Int, option: Option)] = [(at, Option(n: picked.n, label: picked.label))]
        // Up to choice 1.
        var want = picked.n - 1
        var index = at - 1
        var gap = 0
        while want >= 1, index >= 0, gap <= maxGap {
            if let other = option(lines[index]), other.n == want {
                found.insert((index, Option(n: other.n, label: other.label)), at: 0)
                want -= 1
                gap = 0
            } else {
                gap += 1
            }
            index -= 1
        }
        guard want == 0 else { return nil }
        // Down to the last choice.
        want = picked.n + 1
        index = at + 1
        gap = 0
        while want <= 9, index < lines.count, gap <= maxGap, !isRule(lines[index]) {
            if let other = option(lines[index]), other.n == want {
                found.append((index, Option(n: other.n, label: other.label)))
                want += 1
                gap = 0
            } else {
                gap += 1
            }
            index += 1
        }
        guard found.count >= 2 else { return nil }

        // What is asked: the block above choice 1, back to the box's top edge.
        var header: [String] = []
        index = found[0].index - 1
        while index >= 0, header.count < headerLines, !isRule(lines[index]) {
            if !lines[index].isEmpty { header.insert(lines[index], at: 0) }
            index -= 1
        }
        let question = header.popLast() ?? ""
        let title = header.first ?? ""
        let detail = String(header.dropFirst().joined(separator: "\n").prefix(maxDetailLength))
        let permission = question.lowercased().hasPrefix("do you want")
            || question.lowercased().contains("allow")
        return MobilePrompt(
            kind: permission ? .permission : .question, title: title, detail: detail,
            question: question, options: found.map(\.option))
    }

    /// Whether this "prompt" is only `text` sitting in the pane's input box: a
    /// numbered list the human sent looks like one.
    func isEcho(of text: String) -> Bool {
        options.allSatisfy { text.contains($0.label) }
    }
}

enum MobileReply {
    static let busyMessage = "Thread is busy"
    static let waitingMessage = "Thread is waiting on a prompt"
    static let unreachable = "Could not reach the pane"
    static let sending = "A reply is being sent"

    /// The pause between the paste and the Enter: the agent's input box takes
    /// a bracketed paste in before it reads the next key.
    static let enterDelay: TimeInterval = 0.3

    // MARK: Keys

    /// Every key the phone may press. Anything else is refused: a key name is
    /// an argument to `send-keys`, and tmux reads far more names than these.
    static let keys: Set<String> = {
        var keys: Set<String> = ["Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab"]
        for letter in "abcdefghijklmnopqrstuvwxyz" { keys.insert("C-\(letter)") }
        for digit in 1...9 { keys.insert(String(digit)) }
        return keys
    }()

    /// The `key` of a key request; nil when it is not on the whitelist.
    static func key(in body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let key = object["key"] as? String, keys.contains(key) else { return nil }
        return key
    }

    static func keyArgv(target: String, key: String) -> [String] {
        ["send-keys", "-t", target, key]
    }

    /// Press one whitelisted key. A pane on a prompt takes it too: Escape is
    /// how the human backs out of one.
    static func press(_ key: String, target: String, io: MobilePaneIO) -> MobileResponse {
        guard keys.contains(key) else { return .error(400, "bad_key") }
        guard io.tmux(keyArgv(target: target, key: key), nil) != nil else {
            return .error(503, "unavailable", message: unreachable)
        }
        return .json(["ok": true])
    }

    // MARK: State

    /// The pane's status now. The hook row is newer than the tree, so it wins
    /// under the rule the sidebar uses (`AgentState.isFresh`); a row from
    /// another session in the same pane is not this thread's.
    static func status(thread: MobileThread, rows: [AgentStateRow], now: Int) -> AttentionStatus {
        guard thread.host.isLocal,
              let row = rows.first(where: {
                  $0.pane == thread.pane
                      && ($0.sessionId == thread.claudeSessionId || $0.sessionId == thread.codexSessionId)
              }),
              AgentState.isFresh(row, scanStatus: thread.status, now: now)
        else { return thread.status }
        return AgentState.attention(row.state)
    }

    /// Why free text cannot go into the pane now; nil when it can. A busy pane
    /// may reach a prompt between the paste and the Enter, and the Enter would
    /// answer it; a waiting pane is already on one. Where no status is known
    /// (a pane without hooks), the screen is read for a prompt instead.
    /// `pasted` is text of ours already in the input box.
    static func refusal(
        status: AttentionStatus?, screen: () -> String?, pasted: String = ""
    ) -> MobileResponse? {
        switch status {
        case nil: return .error(404, "not_found")
        case .busy: return .error(409, "busy", message: busyMessage)
        case .waiting: return .error(409, "waiting", message: waitingMessage)
        case .idle: return nil
        case .unknown:
            guard let prompt = screen().flatMap(MobilePrompt.parse), !prompt.isEcho(of: pasted)
            else { return nil }
            return .error(409, "waiting", message: waitingMessage)
        }
    }

    // MARK: Text

    /// Paste `text` into the pane and submit it. `status` is the pane's status
    /// now, nil once its thread has gone; it is asked before the paste and
    /// again immediately before the Enter. `text` must have passed
    /// `MobileManager.text`.
    static func send(
        _ text: String, target: String, io: MobilePaneIO, status: () -> AttentionStatus?,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> MobileResponse {
        if let refusal = refusal(status: status(), screen: io.screen) { return refusal }
        if let failure = paste(text, target: target, io: io) { return failure }
        pause(enterDelay)
        // A prompt that came up since the paste would take the Enter as its
        // answer. The text stays in the input box, unsent.
        if let refusal = refusal(status: status(), screen: io.screen, pasted: text) { return refusal }
        guard io.tmux(TmuxCommands.submitPastedText(target: target), nil) != nil else {
            return .error(503, "unavailable", message: unreachable)
        }
        return .json(["ok": true])
    }

    /// One bracketed paste, through a buffer of its own. nil when it worked.
    private static func paste(_ text: String, target: String, io: MobilePaneIO) -> MobileResponse? {
        // A pane in copy mode (the human scrolled it) reads keys as copy-mode
        // keys, and the paste would not reach the input box.
        _ = io.tmux(["copy-mode", "-q", "-t", target], nil)
        let commands = TmuxCommands.pastePrompt(
            session: target, buffer: "\(TmuxCommands.sendBuffer)-phone-\(UUID().uuidString)")
        guard io.tmux(commands.load, Data(text.utf8)) != nil, io.tmux(commands.paste, nil) != nil
        else { return .error(503, "unavailable", message: unreachable) }
        return nil
    }

    // MARK: Prompts

    /// The prompt the phone may show for a pane in `status`: a pane that is
    /// idle or working shows none, whatever its screen looks like.
    static func prompt(status: AttentionStatus?, io: MobilePaneIO) -> MobilePrompt? {
        guard status == .waiting || status == .unknown else { return nil }
        return io.screen().flatMap(MobilePrompt.parse)
    }

    /// `{"prompt": "<id>", "option": <n>}`.
    static func answer(in body: Data) -> (prompt: String, option: Int)? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let prompt = object["prompt"] as? String, !prompt.isEmpty,
              let number = object["option"] as? NSNumber,
              // A JSON `true` is an NSNumber too.
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue)
        else { return nil }
        return (prompt, number.intValue)
    }

    /// Pick `option` of the prompt the phone showed. The pane's screen is read
    /// again first: when it shows another prompt, or none, nothing is sent.
    static func answer(
        prompt id: String, option: Int, target: String, io: MobilePaneIO, status: AttentionStatus?
    ) -> MobileResponse {
        guard status != nil else { return .error(404, "not_found") }
        guard let prompt = prompt(status: status, io: io), prompt.id == id else {
            return .error(409, "stale")
        }
        guard prompt.options.contains(where: { $0.n == option }) else {
            return .error(400, "bad_request")
        }
        return press(String(option), target: target, io: io)
    }

    // MARK: Upload

    /// The most an upload may be, whatever Settings says: the body is held in
    /// memory.
    static let maxUploadBytes = 26_214_400
    static let uploadLimits = [5_242_880, 10_485_760, maxUploadBytes]
    static let defaultUploadLimit = 10_485_760
    static let maxFileNameLength = 100

    /// A file name safe to join to a directory and to paste into a prompt:
    /// the last path component, letters, digits, `.`, `-` and `_` only, and
    /// never a dot file. nil when nothing is left.
    static func fileName(_ raw: String) -> String? {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = ""
        for scalar in last.precomposedStringWithCanonicalMapping.unicodeScalars {
            let keep = CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_"
            if keep {
                name.unicodeScalars.append(scalar)
            } else if !name.hasSuffix("-") {
                name.append("-")
            }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !name.isEmpty else { return nil }
        guard name.count > maxFileNameLength else { return name }
        // Keep the extension: it is how the agent knows what the file is.
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard !ext.isEmpty, ext.count < 12 else { return String(name.prefix(maxFileNameLength)) }
        return String(stem.prefix(maxFileNameLength - ext.count - 1)) + "." + ext
    }

    /// `photo.png` → `photo-2.png`, for a name that is taken.
    static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(name)-\(n)" : "\(stem)-\(n).\(ext)"
    }

    /// Save `data` in the thread's working directory and paste its path into
    /// the pane, as a file drop on the Mac does. Nothing is overwritten and
    /// nothing is submitted. The path is text like any other, so a pane that
    /// is busy or on a prompt is refused before anything is written.
    static func upload(
        _ data: Data, name raw: String, thread: MobileThread, io: MobilePaneIO, limit: Int,
        status: () -> AttentionStatus?, scratch: URL = FileManager.default.temporaryDirectory
    ) -> MobileResponse {
        guard data.count <= min(limit, maxUploadBytes) else { return .error(413, "too_large") }
        guard !data.isEmpty, let name = fileName(raw) else { return .error(400, "bad_request") }
        // The directory comes from the live tree, never from the phone.
        guard thread.cwd.hasPrefix("/"), thread.cwd.unicodeScalars.allSatisfy(MobileManager.isText),
              !thread.cwd.contains("\n")
        else { return .error(503, "unavailable", message: unreachable) }
        if let refusal = refusal(status: status(), screen: io.screen) { return refusal }

        var path = FileTransfer.dropDestination(cwd: thread.cwd, fileName: name)
        var n = 2
        while io.exists(path) {
            guard n <= 99 else { return .error(409, "exists") }
            path = FileTransfer.dropDestination(cwd: thread.cwd, fileName: numbered(name, n))
            n += 1
        }

        let folder = scratch.appendingPathComponent("muxmaestro-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: local)
        } catch {
            return .error(500, "failed")
        }
        guard io.copy(local.path, path) else {
            return .error(503, "unavailable", message: unreachable)
        }
        // The file is in place. Its path is pasted only into a pane that can
        // still take text.
        guard refusal(status: status(), screen: io.screen) == nil,
              paste(path + " ", target: thread.pane, io: io) == nil
        else { return .json(["ok": true, "path": path, "pasted": false]) }
        return .json(["ok": true, "path": path, "pasted": true])
    }
}

// MARK: - Slash commands

/// The skills and commands a thread's agent knows, for the composer's `/` list.
enum MobileCommands {
    struct Command: Equatable {
        enum Source: String { case skill, command, builtin }
        let name: String
        let description: String
        let source: Source

        var json: [String: Any] {
            ["name": name, "description": description, "source": source.rawValue]
        }
    }

    static let maxCommands = 300
    static let maxDescriptionLength = 120
    /// How much of a file is read for its front matter.
    static let headBytes = 4096
    /// How far up from the working directory a project's `.claude` is looked for.
    static let maxParents = 8

    static let claudeBuiltins: [(String, String)] = [
        ("clear", "Clear the conversation"), ("compact", "Compact the conversation"),
        ("context", "Show context usage"), ("cost", "Show session cost"),
        ("help", "Show help"), ("init", "Write a CLAUDE.md"), ("model", "Pick the model"),
        ("review", "Review a pull request"), ("resume", "Resume a conversation"),
        ("rewind", "Go back to an earlier point"), ("status", "Show status"),
        ("memory", "Edit memory files"), ("agents", "Manage agents"), ("mcp", "Manage MCP servers"),
        ("permissions", "Manage permissions"), ("usage", "Show plan usage"),
    ]
    static let codexBuiltins: [(String, String)] = [
        ("new", "Start a new chat"), ("compact", "Compact the conversation"),
        ("diff", "Show the git diff"), ("model", "Pick the model"),
        ("approvals", "Pick what needs approval"), ("status", "Show status"),
        ("review", "Review the changes"), ("init", "Write an AGENTS.md"),
        ("mention", "Mention a file"),
    ]

    /// The list for one thread: the project's own, then the user's, then the
    /// agent's built-ins. Only this Mac's disk is read, so a remote thread
    /// gets the built-ins alone.
    static func list(
        for thread: MobileThread, home: String = NSHomeDirectory(), files: FileManager = .default
    ) -> [Command] {
        let codex = thread.codexSessionId != nil && thread.claudeSessionId == nil
        var out: [Command] = []
        if thread.host.isLocal {
            if codex {
                out += prompts(in: home + "/.codex/prompts", files: files)
            } else {
                for root in projectRoots(cwd: thread.cwd, home: home, files: files) + [home] {
                    out += skills(in: root + "/.claude/skills", files: files)
                    out += commands(in: root + "/.claude/commands", files: files)
                }
            }
        }
        out += (codex ? codexBuiltins : claudeBuiltins).map {
            Command(name: $0.0, description: $0.1, source: .builtin)
        }
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0.name).inserted }.prefix(maxCommands))
    }

    /// The working directory and its parents that hold a `.claude` folder, up
    /// to the repository root. The home folder is the user's own and is listed
    /// apart.
    static func projectRoots(cwd: String, home: String, files: FileManager) -> [String] {
        guard cwd.hasPrefix("/") else { return [] }
        var roots: [String] = []
        var dir = (cwd as NSString).standardizingPath
        for _ in 0...maxParents {
            guard dir != "/", dir != home else { break }
            if files.fileExists(atPath: dir + "/.claude") { roots.append(dir) }
            if files.fileExists(atPath: dir + "/.git") { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return roots
    }

    private static func skills(in dir: String, files: FileManager) -> [Command] {
        let names = (try? files.contentsOfDirectory(atPath: dir)) ?? []
        return names.sorted().compactMap { entry in
            guard let name = commandName(entry),
                  let head = head(of: "\(dir)/\(entry)/SKILL.md") else { return nil }
            return Command(name: name, description: description(in: head), source: .skill)
        }
    }

    /// `commands/git/tidy.md` is `/git:tidy`.
    private static func commands(in dir: String, files: FileManager) -> [Command] {
        let paths = (try? files.subpathsOfDirectory(atPath: dir)) ?? []
        return paths.sorted().compactMap { path in
            guard path.hasSuffix(".md"),
                  let name = commandName(String(path.dropLast(3)).replacingOccurrences(of: "/", with: ":")),
                  let head = head(of: "\(dir)/\(path)") else { return nil }
            return Command(name: name, description: description(in: head), source: .command)
        }
    }

    private static func prompts(in dir: String, files: FileManager) -> [Command] {
        let names = (try? files.contentsOfDirectory(atPath: dir)) ?? []
        return names.sorted().compactMap { entry in
            guard entry.hasSuffix(".md"), let name = commandName("prompts:" + String(entry.dropLast(3))),
                  let head = head(of: "\(dir)/\(entry)") else { return nil }
            return Command(name: name, description: description(in: head), source: .command)
        }
    }

    /// A name the phone inserts into a prompt: no spaces, nothing a terminal
    /// reads as a key.
    static func commandName(_ raw: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:."))
        guard !raw.isEmpty, !raw.hasPrefix("."), raw.count <= 80,
              raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    private static func head(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: headBytes)) ?? Data(), as: UTF8.self)
    }

    /// The `description:` of a file's front matter, as one short line.
    static func description(in head: String) -> String {
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return "" }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard trimmed.hasPrefix("description:") else { continue }
            let value = trimmed.dropFirst("description:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                .unicodeScalars.filter(MobileManager.isText)
            return String(String(String.UnicodeScalarView(value)).prefix(maxDescriptionLength))
        }
        return ""
    }
}

// MARK: - A thread's turn, for voice

/// Follows one turn in a thread after its text went in, for a voice take that
/// reads the reply back: the assistant's new rows are the reply, and the turn
/// ends when the pane stops working.
final class MobileThreadTurn {
    struct Timing {
        var interval: TimeInterval = 1
        /// How long an idle pane is given to start the turn.
        var startGrace: TimeInterval = 6
        var timeout: TimeInterval = 300
    }

    private let read: (_ after: UInt64?) -> MobileChatPage?
    private let status: () -> AttentionStatus?
    private let timing: Timing
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.mobile.thread-turn")
    private var cursor: UInt64?
    private var reply = ""
    private var sawBusy = false
    private var elapsed: TimeInterval = 0

    /// `read` is the thread's transcript from a cursor; `status` the pane's
    /// status now, nil once the thread has gone.
    init(
        read: @escaping (_ after: UInt64?) -> MobileChatPage?,
        status: @escaping () -> AttentionStatus?, timing: Timing = Timing()
    ) {
        self.read = read
        self.status = status
        self.timing = timing
    }

    /// Note where the transcript ends now. Call before the text is sent.
    func mark() {
        queue.sync { cursor = read(nil)?.next }
    }

    /// Follow the turn. `onDelta` gets each new piece of the reply;
    /// `completion` comes exactly once.
    func follow(
        onDelta: @escaping (String) -> Void, completion: @escaping (ManagerTurnOutcome) -> Void
    ) {
        queue.asyncAfter(deadline: .now() + timing.interval) { [self] in
            elapsed += timing.interval
            let now = status()
            if now == .busy { sawBusy = true }
            if let page = cursor.flatMap({ read($0) }) {
                // A transcript that was rewritten starts over: what it holds
                // now is not this turn's reply.
                if !page.reset {
                    for message in page.messages where message.role == .assistant {
                        reply += (reply.isEmpty ? "" : "\n\n") + message.text
                        onDelta(message.text + "\n\n")
                    }
                }
                cursor = page.next
            }
            switch now {
            case nil:
                completion(.unreachable(MobileReply.unreachable))
            case .waiting:
                completion(.permission(reply: reply))
            case .busy, .idle, .unknown:
                // An idle pane has ended the turn once it was seen working, or
                // never started one.
                if now != .busy, sawBusy || elapsed >= timing.startGrace {
                    return completion(.done(reply: reply))
                }
                if elapsed >= timing.timeout { return completion(.timeout(reply: reply)) }
                follow(onDelta: onDelta, completion: completion)
            }
        }
    }
}
