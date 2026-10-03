import Foundation

// The reply half of the phone API: what the phone may type into a thread's
// pane, and the checks before each write. Pure, like MobileAPI.swift: every
// tmux call goes through `MobilePaneIO`, so the tests assert the exact argv.
//
// The rules, in one place:
// - Text is `MobileManager.text`: the one filter that keeps a key press out of
//   pasted text. It goes in as one bracketed paste, never as key presses.
// - Free text goes only into a pane that is neither busy nor on a prompt. The
//   status and the pane's screen are both read before the paste and again
//   immediately before the Enter. A pane whose status is not known first-hand
//   (no hooks, or another host) must show an input box.
// - Text that was pasted and then refused is taken out of the input box.
// - A pane on a prompt takes an answer the human tapped, or a whitelisted
//   key; both name the prompt the phone showed, and a prompt that changed
//   takes neither.
// - A key is a name from `MobileReply.keys`. Nothing else reaches `send-keys`.

/// What a pane is doing now.
struct MobilePaneState: Equatable {
    var status: AttentionStatus
    /// When it entered that status. It tells two prompts with the same words
    /// apart.
    var since: Int?
    /// The status was read on another host: it comes from the last scan, not
    /// from this Mac's hooks, so it may be old.
    var remote = false
}

/// What the server may do to one thread's pane. The app builds it from the
/// host's `TmuxService`; every call may block.
struct MobilePaneIO {
    /// Run one tmux command on the pane's host. nil when it failed.
    var tmux: (_ args: [String], _ stdin: Data?) -> String?
    /// The pane's visible text.
    var screen: () -> String?
    /// The pane's state now, given its row in the latest tree: the hook state
    /// is read again, so it is newer than the tree.
    var state: (MobileThread) -> MobilePaneState
    /// Create `path` on the pane's host with `data`. It never overwrites and
    /// never follows a link.
    var save: (_ data: Data, _ path: String) -> FileTransfer.Saved
    /// The pane's prompt counter, given what the pane shows now (`key` names
    /// the prompt's words; nil for no prompt). The server raises it each time
    /// the pane starts waiting, each time the words change, and after each
    /// answer, so the same words asked twice never share an id, even on a
    /// host that gives no time for the prompt.
    var sequence: (_ key: String?) -> Int = { _ in 0 }
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
    /// The card does not hold all of what the pane shows above the choices.
    var truncated = false
    /// When the pane started waiting, and the pane's prompt counter. Both
    /// are part of the id.
    var since: Int? = nil
    var sequence = 0

    /// The prompt's words alone: what the server's counter watches.
    var key: String {
        MobileReply.hash([title, detail, question] + options.map { "\($0.n).\($0.label)" })
    }

    /// Names this prompt. An answer or a key carries it back, so a tap meant
    /// for a prompt that is no longer on the pane does nothing. The counter
    /// is in it: the same question asked twice is two prompts.
    var id: String {
        MobileReply.hash([key, since.map(String.init) ?? "", String(sequence)])
    }

    var json: [String: Any] {
        [
            "id": id, "kind": kind.rawValue, "title": title, "detail": detail,
            "question": question, "truncated": truncated,
            "options": options.map { ["n": $0.n, "label": $0.label] as [String: Any] },
        ]
    }

    /// The lines "1. Yes", "2. No": the choices as the pane shows them.
    var block: [String] { options.map { "\($0.n). \($0.label)" } }
}

/// A pane's screen, read for the two things a write depends on: a prompt that
/// is waiting for a key, and an input box that takes text.
struct MobileScreen: Equatable {
    /// The prompt the pane waits on. nil when it shows none.
    let prompt: MobilePrompt?
    /// The pane shows an agent's input box as the last thing on screen, and
    /// no prompt: it is verified as idle and ready for text.
    let inputBox: Bool
    /// The last lines with text, for naming a prompt that has no choices.
    let tail: [String]

    /// How far above the choices the tool and its command are looked for.
    static let headerLines = 60
    /// Lines between two choices that are not a choice: a question's option
    /// may carry a description.
    static let maxGap = 2
    static let maxDetailLength = 1200
    /// The tallest input box that is looked for.
    static let maxBoxLines = 40
    /// Lines an agent draws under its input box: hints and a status line.
    static let maxFooterLines = 4

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

    /// The line starts with the cursor an input box or a list shows.
    private static func hasCursor(_ line: String) -> Bool {
        guard let first = line.first, cursors.contains(first) else { return false }
        return line.count == 1 || line.dropFirst().first == " "
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

    /// `pasted` is text of ours that may sit in the pane's input box: a
    /// numbered list the human sent looks like a prompt there.
    init(_ text: String, pasted: String = "") {
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = raw.map(Self.content)
        tail = Array(lines.filter { !$0.isEmpty }.suffix(12))
        let box = Self.inputBox(lines, raw: raw)
        var found = Self.list(lines)
        if let list = found, let box {
            if list.rows.upperBound < box.lowerBound {
                // Above the live input box: an old prompt in the scrollback.
                // A prompt that waits takes the box's place, so the two are
                // never on screen together.
                found = nil
            } else if Self.isEcho(Array(lines[box]), of: pasted) {
                found = nil
            }
        }
        prompt = found?.prompt
        inputBox = box != nil && found == nil
    }

    /// The agent's live input box, as the rows inside it: two rules with the
    /// cursor on the first row between them, and under them nothing but the
    /// agent's own footer. A box with anything else below it is a dead
    /// agent's last frame: a shell or a pager is in front now.
    private static func inputBox(_ lines: [String], raw: [Substring]) -> ClosedRange<Int>? {
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2 else { return nil }
        let (top, bottom) = (rules[rules.count - 2], rules[rules.count - 1])
        guard bottom - top >= 2, bottom - top <= maxBoxLines + 1, hasCursor(lines[top + 1])
        else { return nil }
        // The footer is a few indented lines. A shell prompt, a question or a
        // pager's last line starts at the left edge.
        let below = raw[(bottom + 1)...].filter { !$0.allSatisfy(\.isWhitespace) }
        guard below.count <= maxFooterLines, below.allSatisfy({ $0.first?.isWhitespace == true })
        else { return nil }
        return (top + 1)...(bottom - 1)
    }

    /// Whether the input box holds exactly `text`: every row of the box is a
    /// line of the text, and every line of the text a row, in order. A prompt
    /// drawn like an input box matches no text that says more than its
    /// choices, and a text that holds a prompt's choices among other lines is
    /// not that prompt.
    static func isEcho(_ box: [String], of text: String) -> Bool {
        var rows = box.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = rows.first, hasCursor(first) else { return false }
        rows[0] = String(first.dropFirst()).trimmingCharacters(in: .whitespaces)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return !text.isEmpty && rows == lines
    }

    /// The last list numbered from 1 with the cursor on one of its lines, and
    /// the rows it covers.
    private static func list(_ lines: [String]) -> (prompt: MobilePrompt, rows: ClosedRange<Int>)? {
        guard let at = lines.lastIndex(where: { option($0)?.selected == true }),
              let picked = option(lines[at]) else { return nil }

        var found: [(index: Int, option: MobilePrompt.Option)] = [(at, .init(n: picked.n, label: picked.label))]
        // Up to choice 1.
        var want = picked.n - 1
        var index = at - 1
        var gap = 0
        while want >= 1, index >= 0, gap <= maxGap {
            if let other = option(lines[index]), other.n == want {
                found.insert((index, .init(n: other.n, label: other.label)), at: 0)
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
                found.append((index, .init(n: other.n, label: other.label)))
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
        // The top edge was not reached: the start of what is asked is not here.
        var truncated = index >= 0 && !isRule(lines[index])
        let question = header.popLast() ?? ""
        let title = truncated ? "" : header.first ?? ""
        var detail = (truncated ? header : Array(header.dropFirst())).joined(separator: "\n")
        if detail.count > maxDetailLength {
            // The start of a command says what it does: keep that end.
            detail = String(detail.prefix(maxDetailLength))
            truncated = true
        }
        let permission = question.lowercased().hasPrefix("do you want")
            || question.lowercased().contains("allow")
        let prompt = MobilePrompt(
            kind: permission ? .permission : .question, title: title, detail: detail,
            question: question, options: found.map(\.option), truncated: truncated)
        return (prompt, found[0].index...found[found.count - 1].index)
    }
}

enum MobileReply {
    static let busyMessage = "Thread is busy"
    static let waitingMessage = "Thread is waiting on a prompt"
    static let noInputMessage = "Thread shows no input box"
    static let unseenMessage = "Open the terminal to answer"
    static let unreachable = "Could not reach the pane"
    static let sending = "A reply is being sent"

    /// The pause between the paste and the Enter: the agent's input box takes
    /// a bracketed paste in before it reads the next key.
    static let enterDelay: TimeInterval = 0.3

    /// FNV-1a over the parts, as hex. Names a prompt; it is not a secret.
    static func hash(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Keys

    /// Every key the phone may press. Anything else is refused: a key name is
    /// an argument to `send-keys`, and tmux reads far more names than these.
    static let keys: Set<String> = {
        var keys: Set<String> = ["Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab"]
        for letter in "abcdefghijklmnopqrstuvwxyz" { keys.insert("C-\(letter)") }
        for digit in 1...9 { keys.insert(String(digit)) }
        return keys
    }()

    /// The `key` of a key request, and the prompt the phone was showing; nil
    /// when the key is not on the whitelist.
    static func key(in body: Data) -> (key: String, prompt: String?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let key = object["key"] as? String, keys.contains(key) else { return nil }
        return (key, object["prompt"] as? String)
    }

    static func keyArgv(target: String, key: String) -> [String] {
        ["send-keys", "-t", target, key]
    }

    /// The keys that answer a prompt: Enter takes the choice under the
    /// cursor, a digit picks one.
    static func answers(_ key: String) -> Bool {
        key == "Enter" || (key.count == 1 && key.first?.isNumber == true)
    }

    /// Press one whitelisted key. A pane on a prompt takes it too, as a
    /// terminal would, but only for the prompt the phone was showing: `prompt`
    /// must name the one on the pane now. Enter and the digits answer a
    /// prompt, so they also need a prompt the phone can show as a card: one
    /// whose choices were read. A prompt the human has not seen is answered
    /// by no key. Escape and the arrows answer nothing and stay allowed.
    static func press(
        _ key: String, prompt sent: String?, target: String, io: MobilePaneIO, state: MobilePaneState?
    ) -> MobileResponse {
        guard keys.contains(key) else { return .error(400, "bad_key") }
        guard let state else { return .error(404, "not_found") }
        guard let screen = io.screen() else { return .error(503, "unavailable", message: unreachable) }
        let card = prompt(state: state, screen: screen, io: io)
        if let current = card?.id ?? waitingID(state: state, screen: screen, io: io) {
            guard current == sent else { return .error(409, "stale") }
            if answers(key), card == nil { return .error(409, "unseen", message: unseenMessage) }
        }
        let response = send(key: key, target: target, io: io)
        // The prompt is answered: the same words after this are a new prompt.
        if response.status == 200, card != nil, answers(key) { _ = io.sequence(nil) }
        return response
    }

    private static func send(key: String, target: String, io: MobilePaneIO) -> MobileResponse {
        guard io.tmux(keyArgv(target: target, key: key), nil) != nil else {
            return .error(503, "unavailable", message: unreachable)
        }
        return .json(["ok": true])
    }

    // MARK: State

    /// The pane's state now. The hook row is newer than the tree, so it wins
    /// under the rule the sidebar uses (`AgentState.isFresh`); a row from
    /// another session in the same pane is not this thread's.
    static func state(thread: MobileThread, rows: [AgentStateRow], now: Int) -> MobilePaneState {
        let remote = !thread.host.isLocal
        guard !remote,
              let row = rows.first(where: {
                  $0.pane == thread.pane
                      && ($0.sessionId == thread.claudeSessionId || $0.sessionId == thread.codexSessionId)
              }),
              AgentState.isFresh(row, scanStatus: thread.status, now: now)
        else { return MobilePaneState(status: thread.status, since: thread.since, remote: remote) }
        return MobilePaneState(status: AgentState.attention(row.state), since: row.since)
    }

    /// Why free text cannot go into the pane now; nil when it can.
    ///
    /// A busy pane may reach a prompt between the paste and the Enter, and
    /// the Enter would answer it; a waiting pane is already on one. The
    /// status is not enough on its own: it may be old (another host) or
    /// missing (no hooks), so the screen is always read too. Any prompt on it
    /// refuses the text, and so does a screen that cannot be verified as an
    /// agent's idle input box. `pasted` is text of ours already in that box.
    static func refusal(
        state: MobilePaneState?, screen: () -> String?, pasted: String = ""
    ) -> MobileResponse? {
        guard let state else { return .error(404, "not_found") }
        if state.status == .busy { return .error(409, "busy", message: busyMessage) }
        if state.status == .waiting { return .error(409, "waiting", message: waitingMessage) }
        guard let text = screen() else { return .error(503, "unavailable", message: unreachable) }
        let seen = MobileScreen(text, pasted: pasted)
        if seen.prompt != nil { return .error(409, "waiting", message: waitingMessage) }
        if !seen.inputBox { return .error(409, "no_input", message: noInputMessage) }
        return nil
    }

    // MARK: Text

    /// Paste `text` into the pane and submit it. `state` is the pane's state
    /// now, nil once its thread has gone; it and the screen are read before
    /// the paste and again immediately before the Enter. `text` must have
    /// passed `MobileManager.text`.
    static func send(
        _ text: String, target: String, io: MobilePaneIO, state: () -> MobilePaneState?,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> MobileResponse {
        if let refusal = refusal(state: state(), screen: io.screen) { return refusal }
        if let failure = paste(text, target: target, io: io) { return failure }
        pause(enterDelay)
        // A prompt that came up since the paste would take the Enter as its
        // answer.
        if let refusal = refusal(state: state(), screen: io.screen, pasted: text) {
            return notSent(refusal, text: text, target: target, io: io)
        }
        guard io.tmux(TmuxCommands.submitPastedText(target: target), nil) != nil else {
            return .error(503, "unavailable", message: unreachable)
        }
        return .json(["ok": true])
    }

    /// The answer for text that was pasted and then refused. The text is
    /// taken out of the input box, or the next Enter in the pane would send
    /// it; but only when the box is what is in front. With a prompt in front,
    /// or anything that is not the box, the keys that clear would go to that
    /// instead, so none are sent. `cleared` tells the phone what the pane
    /// holds now: false means the text may still be in the box.
    private static func notSent(
        _ refusal: MobileResponse, text: String, target: String, io: MobilePaneIO
    ) -> MobileResponse {
        // A thread that has gone has no pane to clear.
        guard refusal.status != 404 else { return refusal }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let body = (try? JSONSerialization.jsonObject(with: refusal.body)) as? [String: Any]
        let waiting = body?["error"] as? String == "waiting"
        let boxInFront = !waiting
            && (io.screen().map { MobileScreen($0, pasted: text).inputBox } ?? false)
        let cleared = boxInFront
            && io.tmux(TmuxCommands.clearInput(target: target, lines: lines), nil) != nil
        return .json([
            "error": "not_sent", "reason": body?["error"] as? String ?? "unavailable",
            "message": body?["message"] as? String ?? unreachable, "cleared": cleared,
        ], status: 409)
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

    /// The prompt on the pane now, with the time the pane started waiting
    /// and the pane's prompt counter.
    static func prompt(state: MobilePaneState?, screen: String?, io: MobilePaneIO) -> MobilePrompt? {
        guard let state, let screen else { return nil }
        guard var prompt = MobileScreen(screen).prompt else { return nil }
        prompt.since = state.since
        prompt.sequence = io.sequence(prompt.key)
        return prompt
    }

    /// What names the thing a waiting pane waits on when its choices cannot
    /// be read: a name made from what the screen shows. nil for a pane that
    /// is not waiting.
    static func waitingID(state: MobilePaneState, screen: String, io: MobilePaneIO) -> String? {
        guard state.status == .waiting else {
            // Nothing is waiting: the next prompt is a new one.
            _ = io.sequence(nil)
            return nil
        }
        let key = hash(MobileScreen(screen).tail)
        return "w" + hash([key, state.since.map(String.init) ?? "", String(io.sequence(key))])
    }

    /// The `GET …/prompt` body: the card, and the id a key must carry.
    static func promptBody(state: MobilePaneState?, screen: String?, io: MobilePaneIO) -> [String: Any] {
        let prompt = prompt(state: state, screen: screen, io: io)
        var id = prompt?.id
        if id == nil, let state, let screen { id = waitingID(state: state, screen: screen, io: io) }
        return ["prompt": prompt.map { $0.json as Any } ?? NSNull(), "id": id ?? NSNull()]
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
        prompt id: String, option: Int, target: String, io: MobilePaneIO, state: MobilePaneState?
    ) -> MobileResponse {
        guard state != nil else { return .error(404, "not_found") }
        guard let prompt = prompt(state: state, screen: io.screen(), io: io), prompt.id == id else {
            return .error(409, "stale")
        }
        guard prompt.options.contains(where: { $0.n == option }) else {
            return .error(400, "bad_request")
        }
        let response = send(key: String(option), target: target, io: io)
        // The prompt is answered: the same words after this are a new prompt.
        if response.status == 200 { _ = io.sequence(nil) }
        return response
    }

    // MARK: Upload

    /// The most an upload may be, whatever Settings says: the body is held in
    /// memory.
    static let maxUploadBytes = 26_214_400
    static let uploadLimits = [5_242_880, 10_485_760, maxUploadBytes]
    static let defaultUploadLimit = 10_485_760
    /// A file name is at most 255 bytes on the disks this writes to. The rest
    /// is room for the number a taken name gets.
    static let maxFileNameBytes = 240

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
        guard name.utf8.count > maxFileNameBytes else { return name }
        // Keep the extension: it is how the agent knows what the file is.
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard !ext.isEmpty, ext.utf8.count < 16 else { return clip(name, bytes: maxFileNameBytes) }
        return clip(stem, bytes: maxFileNameBytes - ext.utf8.count - 1) + "." + ext
    }

    /// The longest prefix of `text` that fits in `bytes` of UTF-8, cut
    /// between characters.
    private static func clip(_ text: String, bytes: Int) -> String {
        var out = ""
        var used = 0
        for character in text {
            used += character.utf8.count
            guard used <= bytes else { break }
            out.append(character)
        }
        return out
    }

    /// `photo.png` → `photo-2.png`, for a name that is taken.
    static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(name)-\(n)" : "\(stem)-\(n).\(ext)"
    }

    /// A path as it is pasted into a prompt: quoted when it holds anything a
    /// shell or an agent could split on.
    static func pasted(path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        return path.unicodeScalars.allSatisfy(plain.contains) ? path : Ssh.shellQuote(path)
    }

    /// Save `data` in the thread's working directory and paste its path into
    /// the pane, as a file drop on the Mac does. Nothing is overwritten, no
    /// link is followed and nothing is submitted. The path is text like any
    /// other, so a pane that cannot take text is refused before anything is
    /// written.
    static func upload(
        _ data: Data, name raw: String, thread: MobileThread, io: MobilePaneIO, limit: Int,
        state: () -> MobilePaneState?
    ) -> MobileResponse {
        guard data.count <= min(limit, maxUploadBytes) else { return .error(413, "too_large") }
        guard !data.isEmpty, let name = fileName(raw) else { return .error(400, "bad_request") }
        // The directory comes from the live tree, never from the phone.
        guard thread.cwd.hasPrefix("/"), thread.cwd.unicodeScalars.allSatisfy(MobileManager.isText),
              !thread.cwd.contains("\n")
        else { return .error(503, "unavailable", message: unreachable) }
        if let refusal = refusal(state: state(), screen: io.screen) { return refusal }

        // The create is exclusive, so a name that is taken (a file, or a link
        // to anywhere) is never written through: the next name is tried.
        var path = FileTransfer.dropDestination(cwd: thread.cwd, fileName: name)
        var n = 2
        save: while true {
            switch io.save(data, path) {
            case .saved: break save
            case .failed: return .error(503, "unavailable", message: unreachable)
            case .exists:
                guard n <= 99 else { return .error(409, "exists") }
                path = FileTransfer.dropDestination(cwd: thread.cwd, fileName: numbered(name, n))
                n += 1
            }
        }
        // The file is in place. Its path is pasted only into a pane that can
        // still take text.
        guard refusal(state: state(), screen: io.screen) == nil,
              paste(pasted(path: path) + " ", target: thread.pane, io: io) == nil
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
