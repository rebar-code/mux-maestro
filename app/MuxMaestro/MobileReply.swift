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
// - The human can ask for a busy pane to take the text all the same
//   (`Delivery.queue`): the agent holds it until its turn ends. Only the
//   status check is dropped. The screen is still read both times, so a prompt
//   that is in front, or comes up, still refuses the text.
// - `Delivery.interrupt` presses Escape in a busy pane with its input box in
//   front, to end the turn so the queued text is taken up. It pastes nothing.
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

    /// The status is not first-hand: missing (no hooks) or another host's.
    var unverified: Bool { status == .unknown || remote }
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
    /// The row of the pane's screen the terminal cursor is on, from 0. An
    /// agent keeps it in its input box; a shell or a question under a dead
    /// agent's last frame has it. nil when it cannot be read.
    var cursorRow: () -> Int? = { nil }
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
    /// The choice the cursor is on: what Enter takes.
    var selected = 1
    /// The menu is scrolled: it has rows above or below the ones on screen,
    /// which the card cannot show.
    var moreAbove = false
    var moreBelow = false
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

    /// Names this prompt as the phone shows it. An answer or a key carries it
    /// back, so a tap meant for a prompt that is no longer on the pane does
    /// nothing. The counter is in it: the same question asked twice is two
    /// prompts. So is the selected row: Enter takes that row, so an Enter
    /// sent for a card that marks another row is refused.
    var id: String {
        MobileReply.hash([key, since.map(String.init) ?? "", String(sequence), String(selected)])
    }

    var json: [String: Any] {
        [
            "id": id, "kind": kind.rawValue, "title": title, "detail": detail,
            "question": question, "truncated": truncated, "selected": selected,
            "moreAbove": moreAbove, "moreBelow": moreBelow,
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
    /// The pane shows an agent's input box as the last thing on screen, the
    /// terminal cursor is in it, and there is no prompt: it is verified as
    /// idle and ready for text.
    let inputBox: Bool
    /// The rows of that box, cursor mark and all. Empty with no box.
    let boxRows: [String]
    /// Where that box is, to hold a later reading of the pane against.
    let anchor: Anchor?

    /// The rows of an input box's two rules.
    struct Anchor: Equatable {
        let top: Int
        let bottom: Int
    }
    /// The last lines with text, for naming a prompt that has no choices.
    let tail: [String]

    /// How far above the choices the tool and its command are looked for.
    static let headerLines = 60
    /// Lines between two choices that are not a choice: a question's option
    /// may carry a description.
    static let maxGap = 4
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

    /// A rule or a box edge: nothing but box-drawing characters, or the block
    /// characters Claude Code draws a dialog's top edge with.
    private static func isRule(_ line: String) -> Bool {
        !line.isEmpty && line.unicodeScalars.allSatisfy {
            (0x2500...0x257F).contains($0.value) || (0x2580...0x259F).contains($0.value)
        }
    }

    /// `… +2 models`: a menu's count of the rows that do not fit.
    private static func countsMore(_ line: String) -> Bool {
        let rest: Substring
        if line.hasPrefix("…") {
            rest = line.dropFirst()
        } else if line.hasPrefix("...") {
            rest = line.dropFirst(3)
        } else {
            return false
        }
        let count = rest.drop(while: \.isWhitespace)
        return count.first == "+" && count.dropFirst().first?.isNumber == true
    }

    /// The line starts with the cursor an input box or a list shows.
    private static func hasCursor(_ line: String) -> Bool {
        guard let first = line.first, cursors.contains(first) else { return false }
        // Claude Code puts a no-break space after its mark.
        return line.count == 1 || line.dropFirst().first?.isWhitespace == true
    }

    private struct Row {
        let n: Int
        let label: String
        var selected = false
        /// The menu's own marks for rows off screen: `↑` on its first row,
        /// `↓` on its last.
        var above = false
        var below = false
        /// Something was drawn beside it: the choices are laid out in columns.
        var boxed = false
    }

    /// `❯ 1. Yes` → row 1 "Yes", selected. `↓ 9. More` → row 9, more below.
    private static func option(_ line: String) -> Row? {
        var rest = Substring(line)
        var row = Row(n: 0, label: "")
        // The cursor mark and a scroll mark, in either order.
        for _ in 0..<2 {
            guard let first = rest.first else { return nil }
            if cursors.contains(first) {
                row.selected = true
            } else if first == "↑" {
                row.above = true
            } else if first == "↓" {
                row.below = true
            } else {
                break
            }
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count), let n = Int(digits), n >= 1,
              rest.dropFirst(digits.count).hasPrefix(". ")
        else { return nil }
        var label = rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        // A box drawn beside the choices (a preview) is not part of the label.
        var boxed = false
        if let edge = label.unicodeScalars.firstIndex(where: { (0x2500...0x259F).contains($0.value) }) {
            label = String(label.unicodeScalars[..<edge]).trimmingCharacters(in: .whitespaces)
            boxed = true
        }
        if label.hasSuffix("(esc)") { label = String(label.dropLast(5)).trimmingCharacters(in: .whitespaces) }
        guard !label.isEmpty else { return nil }
        return Row(
            n: n, label: label, selected: row.selected, above: row.above, below: row.below, boxed: boxed)
    }

    /// `cursorRow` is the row the terminal cursor is on. `pasted` is text of
    /// ours that may sit in the pane's input box: a numbered list the human
    /// sent looks like a prompt there. `after` is where the box was before
    /// that text went in.
    init(_ text: String, cursorRow: Int?, pasted: String = "", after: Anchor? = nil) {
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = raw.map(Self.content)
        tail = Array(lines.filter { !$0.isEmpty }.suffix(12))
        // A box is live only with the cursor in it. An agent keeps the cursor
        // in its input box; whatever else may be in front (a shell, a
        // question, a menu) has the cursor on its own line or parks it.
        var box = Self.inputBox(lines, raw: raw)
        if let found = box, cursorRow.map({ (found.top + 1..<found.bottom).contains($0) }) != true {
            box = nil
        }
        var found = Self.list(lines)
        if let list = found, let box {
            if list.rows.upperBound < box.top {
                // Above the live input box: an old prompt in the scrollback.
                // A prompt that waits takes the box's place, so the two are
                // never on screen together.
                found = nil
            } else if let after, after.top == box.top || after.bottom == box.bottom,
                      Self.isEcho(Array(lines[(box.top + 1)..<box.bottom]), of: pasted) {
                // Our own text, in the box that was there before the paste.
                found = nil
            }
        }
        prompt = found?.prompt
        inputBox = box != nil && found == nil
        anchor = inputBox ? box : nil
        boxRows = anchor.map { Array(lines[($0.top + 1)..<$0.bottom]) } ?? []
    }

    /// Whether the input box holds `text` and nothing else, however the box
    /// wraps it: the two are compared without their white space.
    func holds(_ text: String) -> Bool {
        guard inputBox, let first = boxRows.first, Self.hasCursor(first) else { return false }
        let squash = { (s: String) in String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }) }
        let box = squash(String(first.trimmingCharacters(in: .whitespaces).dropFirst()) + boxRows.dropFirst().joined())
        return !box.isEmpty && box == squash(text)
    }

    /// An agent's input box by its shape, with under it nothing but a
    /// footer. Anything else below it means a dead agent's last frame: a
    /// shell or a pager is in front now.
    ///
    /// Claude Code draws the box between two rules, the cursor mark on the
    /// first row between them. Codex draws no rules: its mark `›`, then a
    /// blank row, then the footer, down to the end of the screen.
    private static func inputBox(_ lines: [String], raw: [Substring]) -> Anchor? {
        ruledBox(lines, raw: raw) ?? bareBox(lines, raw: raw)
    }

    private static func ruledBox(_ lines: [String], raw: [Substring]) -> Anchor? {
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2 else { return nil }
        let (top, bottom) = (rules[rules.count - 2], rules[rules.count - 1])
        guard bottom - top >= 2, bottom - top <= maxBoxLines + 1, hasCursor(lines[top + 1])
        else { return nil }
        let below = raw[(bottom + 1)...].filter { !$0.allSatisfy(\.isWhitespace) }
        guard below.count <= maxFooterLines, below.allSatisfy(isFooter) else { return nil }
        return Anchor(top: top, bottom: bottom)
    }

    private static func bareBox(_ lines: [String], raw: [Substring]) -> Anchor? {
        let blank = { (index: Int) in lines[index].isEmpty }
        // The footer: the last rows with text, up to a blank row.
        guard let last = lines.indices.last(where: { !blank($0) }) else { return nil }
        var footer = last
        while footer > 0, !blank(footer - 1) { footer -= 1 }
        guard last - footer < maxFooterLines, raw[footer...last].allSatisfy(isFooter),
              footer >= 2, blank(footer - 1), !blank(footer - 2)
        else { return nil }
        // The composer: the rows above that blank row, up to the next one.
        let bottom = footer - 2
        var top = bottom
        while top > 0, !blank(top - 1) { top -= 1 }
        guard bottom - top < maxBoxLines, lines[top].first == "›", hasCursor(lines[top])
        else { return nil }
        return Anchor(top: top - 1, bottom: bottom + 1)
    }

    /// Marks a menu puts in front of a choice.
    private static let choiceMarks: Set<Character> = [
        "●", "○", "◉", "◯", "◆", "◇", "▶", "▸", "►", "▷", "☐", "☑", "☒", "✔", "✓",
    ]
    /// Words of a line that asks for a key or offers a choice.
    private static let asks = [
        "y/n", "y or n", "(y)es", "(n)o", "yes/no", "[y", "password", "passphrase", "--more--",
        "-- more --", "(end)", "any key",
        "enter continue", "enter to ", "to continue", "to confirm", "to select", "esc back",
    ]

    /// Whether a line under the box can be the agent's footer: hints, a mode
    /// line, a status line of the human's own. It is indented with plain
    /// spaces. A line that asks a question or offers a choice is refused; the
    /// rest is accepted, since a status line can say anything. The cursor in
    /// the box is the main check; this one is the second.
    private static func isFooter(_ line: Substring) -> Bool {
        guard line.hasPrefix("  ") else { return false }
        let text = line.drop { $0 == " " }
        guard let first = text.first, !first.isWhitespace, !cursors.contains(first),
              !choiceMarks.contains(first)
        else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        // A status line may end in a colon or a percentage; a question, a
        // shell prompt or a redirect does not belong under the box.
        guard let last = trimmed.last, !"?$#>".contains(last) else { return false }
        if ["[x]", "[ ]", "(x)", "( )", "(*)", "(•)"].contains(where: trimmed.hasPrefix) { return false }
        if trimmed.hasPrefix("press ") || trimmed.contains(" press ") { return false }
        return !asks.contains { trimmed.contains($0) }
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

    /// The last numbered list with the cursor on one of its lines, and the
    /// rows it covers. It starts at 1, or at a later number when the menu is
    /// scrolled and says so with its `↑` mark.
    private static func list(_ lines: [String]) -> (prompt: MobilePrompt, rows: ClosedRange<Int>)? {
        guard let at = lines.lastIndex(where: { option($0)?.selected == true }),
              let picked = option(lines[at]) else { return nil }

        var found: [(index: Int, row: Row)] = [(at, picked)]
        // Up to the first choice on screen.
        var want = picked.n - 1
        var index = at - 1
        var gap = 0
        while want >= 1, index >= 0, gap <= maxGap, !isRule(lines[index]) {
            if let other = option(lines[index]), other.n == want {
                found.insert((index, other), at: 0)
                want -= 1
                gap = 0
            } else {
                gap += 1
            }
            index -= 1
        }
        // Rows off screen above: the menu's `↑` mark, or a count over the list.
        let countAbove = (max(found[0].index - maxGap - 1, 0)..<found[0].index)
            .contains { countsMore(lines[$0]) }
        guard found[0].row.n == 1 || found[0].row.above || countAbove else { return nil }
        // Down to the last choice on screen.
        want = picked.n + 1
        index = at + 1
        gap = 0
        while index < lines.count, gap <= maxGap, !isRule(lines[index]) {
            if let other = option(lines[index]), other.n == want {
                found.append((index, other))
                want += 1
                gap = 0
            } else {
                gap += 1
            }
            index += 1
        }
        guard found.count >= 2 else { return nil }
        // Rows off screen below: the `↓` mark, or a count under the list.
        let lastRow = found[found.count - 1].index
        let countBelow = ((lastRow + 1)..<min(lastRow + maxGap + 2, lines.count))
            .contains { countsMore(lines[$0]) }

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
        // Choices beside a preview box wrap over rows the card does not join:
        // the card may hold only the start of each.
        if found.contains(where: \.row.boxed) { truncated = true }
        let permission = question.lowercased().hasPrefix("do you want")
            || question.lowercased().contains("allow")
        let prompt = MobilePrompt(
            kind: permission ? .permission : .question, title: title, detail: detail,
            question: question, options: found.map { .init(n: $0.row.n, label: $0.row.label) },
            selected: picked.n, moreAbove: found[0].row.above || countAbove,
            moreBelow: found[found.count - 1].row.below || countBelow, truncated: truncated)
        return (prompt, found[0].index...found[found.count - 1].index)
    }
}

enum MobileReply {
    static let busyMessage = "Thread is busy"
    static let waitingMessage = "Thread is waiting on a prompt"
    static let noInputMessage = "Thread shows no input box"
    static let unseenMessage = "Open the terminal to answer"
    static let noOptionMessage = "Not a choice on the card"
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
    static func key(in body: Data) -> (key: String, prompt: String?, terminal: Bool)? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let key = object["key"] as? String, keys.contains(key) else { return nil }
        // `terminal`: the phone shows the pane's own screen, not a card.
        return (key, object["prompt"] as? String, object["terminal"] as? Bool == true)
    }

    static func keyArgv(target: String, key: String) -> [String] {
        ["send-keys", "-t", target, key]
    }

    /// What a key does to whatever is in front of the pane. The guards are
    /// written against this, not against key names: Ctrl-M is Enter too.
    enum KeyEffect: Equatable {
        /// Sends what is typed, or takes the choice under the cursor.
        case submit
        /// Picks a numbered choice, or types a digit.
        case digit(Int)
        /// Moves the cursor or the selection.
        case navigate
        /// Backs out.
        case cancel
        /// Edits, or anything else.
        case other
    }

    static func effect(of key: String) -> KeyEffect {
        if key.count == 1, let digit = key.first?.wholeNumberValue { return .digit(digit) }
        switch key {
        // Ctrl-M is a carriage return and Ctrl-J a line feed: both are Enter
        // to a terminal. Ctrl-D ends the input and Ctrl-O runs the line in a
        // shell. Shift+Tab takes "allow all" in an agent's permission menu.
        case "Enter", "C-m", "C-j", "C-d", "C-o", "BTab": return .submit
        // Ctrl-I is Tab.
        case "Up", "Down", "Left", "Right", "Tab", "C-i", "C-n", "C-p", "C-f", "C-b", "C-a", "C-e":
            return .navigate
        case "Escape", "C-c", "C-g": return .cancel
        default: return .other
        }
    }

    /// Whether `key` can answer a prompt.
    static func answers(_ key: String) -> Bool {
        switch effect(of: key) {
        case .submit, .digit: return true
        case .navigate, .cancel, .other: return false
        }
    }

    /// Press one whitelisted key.
    ///
    /// A pane on a prompt takes it, as a terminal would, but only for the
    /// prompt the phone was showing: `prompt` must name the one on the pane
    /// now. A key that can answer (a submit key or a digit) also needs a
    /// prompt the phone can show as a card, and a digit needs to be a choice
    /// on that card. A prompt the human has not seen is answered by no key.
    ///
    /// With no prompt to name, every key goes only into a verified input box,
    /// on every pane and whatever its status says: a status can be old, and
    /// a shell or a question may be in front. Keys that move or cancel stay
    /// allowed for a prompt the phone names, and for the box.
    ///
    /// `terminal` says the phone shows the pane's own screen. There the human
    /// reads a prompt that could not be made into a card, so a key that can
    /// answer is allowed for it. The id is still checked: it names what the
    /// screen showed when the phone last read it.
    static func press(
        _ key: String, prompt sent: String?, terminal: Bool = false, target: String, io: MobilePaneIO,
        state: MobilePaneState?
    ) -> MobileResponse {
        guard keys.contains(key) else { return .error(400, "bad_key") }
        guard let state else { return .error(404, "not_found") }
        guard let text = io.screen() else { return .error(503, "unavailable", message: unreachable) }
        let seen = MobileScreen(text, cursorRow: io.cursorRow())
        let card = prompt(state: state, seen: seen, io: io)
        let effect = effect(of: key)
        if let current = card?.id ?? waitingID(state: state, seen: seen, io: io) {
            guard current == sent else { return .error(409, "stale") }
            if answers(key) {
                if let card {
                    if case .digit(let n) = effect, !card.options.contains(where: { $0.n == n }) {
                        return .error(409, "no_option", message: noOptionMessage)
                    }
                } else if !terminal {
                    return .error(409, "unseen", message: unseenMessage)
                }
            }
        } else if !seen.inputBox {
            // No card, and the status does not say waiting. That is not proof
            // of an input box: "press any key" takes any key at all.
            return .error(409, "no_input", message: noInputMessage)
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
    /// agent's idle input box with the cursor in it.
    static func refusal(state: MobilePaneState?, io: MobilePaneIO) -> MobileResponse? {
        verify(state: state, io: io).refusal
    }

    /// The same check, and where the input box is when it passes. `pasted` is
    /// text of ours already in that box, and `after` where the box was before
    /// it went in. With `queue` a busy status is no refusal: the human asked
    /// for the agent to hold the text until its turn ends.
    static func verify(
        state: MobilePaneState?, io: MobilePaneIO, pasted: String = "", after: MobileScreen.Anchor? = nil,
        queue: Bool = false
    ) -> (refusal: MobileResponse?, anchor: MobileScreen.Anchor?) {
        guard let state else { return (.error(404, "not_found"), nil) }
        if state.status == .busy, !queue { return (.error(409, "busy", message: busyMessage), nil) }
        if state.status == .waiting { return (.error(409, "waiting", message: waitingMessage), nil) }
        guard let text = io.screen() else {
            return (.error(503, "unavailable", message: unreachable), nil)
        }
        let seen = MobileScreen(text, cursorRow: io.cursorRow(), pasted: pasted, after: after)
        if seen.prompt != nil { return (.error(409, "waiting", message: waitingMessage), nil) }
        if !seen.inputBox { return (.error(409, "no_input", message: noInputMessage), nil) }
        return (nil, seen.anchor)
    }

    // MARK: Text

    /// How a reply reaches an agent that may be in the middle of a turn.
    enum Delivery: String {
        /// Into an idle pane only: a busy one refuses the text.
        case idle
        /// Into a busy pane too. The agent holds the text and takes it up
        /// when its turn ends; the turn is not cut short.
        case queue
        /// Escape first: the turn ends now, and what was queued is taken up.
        case interrupt
    }

    /// The `mode` of a text request: `idle` when it names none, nil when it
    /// names one that is not a `Delivery`.
    static func delivery(in body: Data) -> Delivery? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let mode = object["mode"]
        else { return .idle }
        return (mode as? String).flatMap(Delivery.init(rawValue:))
    }

    /// The pause between the Escape and the look at what it left in the box.
    static let interruptDelay: TimeInterval = 0.5

    /// Paste `text` into the pane and submit it. `state` is the pane's state
    /// now, nil once its thread has gone; it and the screen are read before
    /// the paste and again immediately before the Enter. `text` must have
    /// passed `MobileManager.text`. With `queue` a busy pane takes it too.
    static func send(
        _ text: String, queue: Bool = false, target: String, io: MobilePaneIO,
        state: () -> MobilePaneState?,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> MobileResponse {
        let before = verify(state: state(), io: io, queue: queue)
        if let refusal = before.refusal { return refusal }
        if let failure = paste(text, target: target, io: io) { return failure }
        pause(enterDelay)
        // A prompt that came up since the paste would take the Enter as its
        // answer.
        if let refusal = verify(
            state: state(), io: io, pasted: text, after: before.anchor, queue: queue
        ).refusal {
            return notSent(refusal, text: text, target: target, io: io, after: before.anchor)
        }
        guard io.tmux(TmuxCommands.submitPastedText(target: target), nil) != nil else {
            return .error(503, "unavailable", message: unreachable)
        }
        return .json(["ok": true])
    }

    /// End the agent's turn so it takes up `queued`, text that a `queue`
    /// delivery put in the pane before. Escape is the whole interrupt: it is
    /// one key press of its own, and nothing is pasted, so the text cannot go
    /// in twice.
    ///
    /// Escape goes only to a busy pane with its input box in front. A turn
    /// that has ended needs none, and the answer says so (`interrupted`
    /// false). A prompt would take the Escape as its own cancel, so a pane on
    /// one refuses.
    ///
    /// An agent may hand what it held back to its input box when its turn is
    /// cut short, in place of running it. The box is read again after the
    /// Escape: if it holds exactly `queued` and nothing came up in front, one
    /// Enter sends it.
    static func interrupt(
        queued: String, target: String, io: MobilePaneIO, state: () -> MobilePaneState?,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> MobileResponse {
        guard let now = state() else { return .error(404, "not_found") }
        if now.status == .waiting { return .error(409, "waiting", message: waitingMessage) }
        guard now.status == .busy else { return .json(["ok": true, "interrupted": false]) }
        guard let text = io.screen() else { return .error(503, "unavailable", message: unreachable) }
        let seen = MobileScreen(text, cursorRow: io.cursorRow())
        if seen.prompt != nil { return .error(409, "waiting", message: waitingMessage) }
        if !seen.inputBox { return .error(409, "no_input", message: noInputMessage) }
        guard io.tmux(keyArgv(target: target, key: "Escape"), nil) != nil else {
            return .error(503, "unavailable", message: unreachable)
        }
        pause(interruptDelay)
        let after = io.screen().map { MobileScreen($0, cursorRow: io.cursorRow(), pasted: queued, after: seen.anchor) }
        if let after, after.holds(queued), state()?.status != .waiting {
            guard io.tmux(TmuxCommands.submitPastedText(target: target), nil) != nil else {
                return .error(503, "unavailable", message: unreachable)
            }
        }
        return .json(["ok": true, "interrupted": true])
    }

    /// The answer for text that was pasted and then refused. The text is
    /// taken out of the input box, or the next Enter in the pane would send
    /// it; but only when the box is what is in front. With a prompt in front,
    /// or anything that is not the box, the keys that clear would go to that
    /// instead, so none are sent. `cleared` tells the phone what the pane
    /// holds now: false means the text may still be in the box.
    private static func notSent(
        _ refusal: MobileResponse, text: String, target: String, io: MobilePaneIO,
        after: MobileScreen.Anchor?
    ) -> MobileResponse {
        // A thread that has gone has no pane to clear.
        guard refusal.status != 404 else { return refusal }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let body = (try? JSONSerialization.jsonObject(with: refusal.body)) as? [String: Any]
        let waiting = body?["error"] as? String == "waiting"
        let boxInFront = !waiting
            && (io.screen().map {
                MobileScreen($0, cursorRow: io.cursorRow(), pasted: text, after: after).inputBox
            } ?? false)
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
    static func prompt(state: MobilePaneState?, seen: MobileScreen?, io: MobilePaneIO) -> MobilePrompt? {
        guard let state, var prompt = seen?.prompt else { return nil }
        prompt.since = state.since
        prompt.sequence = io.sequence(prompt.key)
        return prompt
    }

    /// The pane's screen and cursor, read now.
    static func look(_ io: MobilePaneIO) -> MobileScreen? {
        io.screen().map { MobileScreen($0, cursorRow: io.cursorRow()) }
    }

    /// What names the thing a waiting pane waits on when its choices cannot
    /// be read: a name made from what the screen shows. nil for a pane that
    /// is not waiting.
    static func waitingID(state: MobilePaneState, seen: MobileScreen, io: MobilePaneIO) -> String? {
        guard state.status == .waiting else {
            // Nothing is waiting: the next prompt is a new one.
            _ = io.sequence(nil)
            return nil
        }
        let key = hash(seen.tail)
        return "w" + hash([key, state.since.map(String.init) ?? "", String(io.sequence(key))])
    }

    /// The `GET …/prompt` body: the card, and the id a key must carry.
    static func promptBody(state: MobilePaneState?, io: MobilePaneIO) -> [String: Any] {
        let seen = look(io)
        let prompt = prompt(state: state, seen: seen, io: io)
        var id = prompt?.id
        if id == nil, let state, let seen { id = waitingID(state: state, seen: seen, io: io) }
        return ["prompt": prompt.map { $0.json as Any } ?? NSNull(), "id": id ?? NSNull()]
    }

    /// `{"prompt": "<id>", "option": <n>}`.
    /// Or `{"prompt": "<id>", "cancel": true}` to back out: `option` is nil.
    static func answer(in body: Data) -> (prompt: String, option: Int?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let prompt = object["prompt"] as? String, !prompt.isEmpty
        else { return nil }
        if object["option"] == nil, object["cancel"] as? Bool == true,
           let cancel = object["cancel"] as? NSNumber, CFGetTypeID(cancel) == CFBooleanGetTypeID() {
            return (prompt, nil)
        }
        guard object["cancel"] == nil,
              let number = object["option"] as? NSNumber,
              // A JSON `true` is an NSNumber too.
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue)
        else { return nil }
        return (prompt, number.intValue)
    }

    /// Pick `option` of the prompt the phone showed. The pane's screen is read
    /// again first: when it shows another prompt, or none, nothing is sent.
    /// With no `option` it backs out instead: Escape, for the prompt the
    /// phone showed, card or not.
    static func answer(
        prompt id: String, option: Int?, target: String, io: MobilePaneIO, state: MobilePaneState?
    ) -> MobileResponse {
        guard let state else { return .error(404, "not_found") }
        guard let option else {
            return press("Escape", prompt: id, target: target, io: io, state: state)
        }
        guard let prompt = prompt(state: state, seen: look(io), io: io), prompt.id == id else {
            return .error(409, "stale")
        }
        // A choice on the card, and one a digit key can pick.
        guard (1...9).contains(option), prompt.options.contains(where: { $0.n == option }) else {
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
    ///
    /// Without `paste` the file is saved and nothing is typed: the phone
    /// puts the path into its own reply box, and it reaches the pane later
    /// as part of a reply, under every rule a reply is held to. So the pane's
    /// state does not matter here; `text` is the path as it should be typed.
    static func upload(
        _ data: Data, name raw: String, thread: MobileThread, io: MobilePaneIO, limit: Int,
        paste typed: Bool = true, state: () -> MobilePaneState?
    ) -> MobileResponse {
        upload(
            data, name: raw, cwd: thread.cwd, target: thread.pane, io: io, limit: limit, paste: typed,
            state: state)
    }

    /// The same for any pane: `cwd` is its working directory and `target`
    /// its tmux target. The manager's pane is not a thread of the tree, and
    /// its files are saved this way, never pasted.
    static func upload(
        _ data: Data, name raw: String, cwd: String, target: String, io: MobilePaneIO, limit: Int,
        paste typed: Bool = true, state: () -> MobilePaneState?
    ) -> MobileResponse {
        guard data.count <= min(limit, maxUploadBytes) else { return .error(413, "too_large") }
        guard !data.isEmpty, let name = fileName(raw) else { return .error(400, "bad_request") }
        // The directory comes from the Mac, never from the phone.
        guard cwd.hasPrefix("/"), cwd.unicodeScalars.allSatisfy(MobileManager.isText),
              !cwd.contains("\n")
        else { return .error(503, "unavailable", message: unreachable) }
        if typed {
            if let refusal = refusal(state: state(), io: io) { return refusal }
        } else if state() == nil {
            return .error(404, "not_found")
        }

        // The create is exclusive, so a name that is taken (a file, or a link
        // to anywhere) is never written through: the next name is tried.
        var path = FileTransfer.dropDestination(cwd: cwd, fileName: name)
        var n = 2
        save: while true {
            switch io.save(data, path) {
            case .saved: break save
            case .failed: return .error(503, "unavailable", message: unreachable)
            case .exists:
                guard n <= 99 else { return .error(409, "exists") }
                path = FileTransfer.dropDestination(cwd: cwd, fileName: numbered(name, n))
                n += 1
            }
        }
        guard typed else {
            return .json(["ok": true, "path": path, "pasted": false, "text": pasted(path: path)])
        }
        // The file is in place. Its path is pasted only into a pane that can
        // still take text.
        guard refusal(state: state(), io: io) == nil,
              paste(pasted(path: path) + " ", target: target, io: io) == nil
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
