import Foundation

// The model half of the phone API: the phone picks a model and an effort level
// for the agent in a thread's pane. Pure, like MobileReply.swift: every tmux
// call goes through `MobilePaneIO`.
//
// Both agents change the model through a menu of their own, opened by `/model`,
// and both take `s` there for "this session only". Enter in that menu saves the
// pick as the default for every new session, and so does `/model <name>` in
// Claude Code; Codex has no `/model <name>` at all and sends it as a prompt.
// So the menu is driven, and Enter is never pressed where it would save.
//
// The rules:
// - `/model` goes in as a reply does (`MobileReply.send`): into an idle input
//   box only.
// - The models and levels the phone shows are read from the menu on the pane.
//   Nothing is listed here, so nothing goes out of date.
// - Every move is read back from the screen before the next key. A menu that
//   is not what the phone showed is closed with Escape and nothing is applied.
// - A menu that does not offer `s` is closed: the pick is never saved as a
//   default.

/// An agent's `/model` menu, read from the pane's screen.
struct MobileModelMenu: Equatable {
    enum Agent: String { case claude, codex }
    /// Codex asks in two lists: the model, then its reasoning level. Claude
    /// Code has one list, with the effort on a line under it.
    enum Step: String { case model, effort }

    struct Row: Equatable {
        let n: Int
        let label: String
        let description: String
        /// What the session runs now.
        var current = false
        /// The menu's cursor is on it.
        var selected = false
        /// `More reasoning…`: it opens another menu, and is not offered.
        var opens = false

        var json: [String: Any] {
            ["n": n, "label": label, "description": description, "current": current]
        }
    }

    /// Claude Code's line under the list: `● High effort ←/→ to adjust`.
    enum Effort: Equatable {
        case level(String)
        /// `Effort not supported for Haiku 4.5`.
        case unsupported
    }

    let agent: Agent
    let step: Step
    let rows: [Row]
    /// The list is scrolled: it has rows that are not on screen.
    let moreAbove: Bool
    let moreBelow: Bool
    let effort: Effort?
    /// The model a Codex list of levels is for.
    let subject: String?
    /// The menu takes `s` for "this session only".
    let sessionKey: Bool
    /// Enter opens the next list and saves nothing.
    let advances: Bool

    var selected: Row? { rows.first(where: \.selected) }

    private static let cursors: Set<Character> = ["❯", "›", ">"]

    private static func header(_ line: String) -> (agent: Agent, step: Step, subject: String?)? {
        if line == "Select model" { return (.claude, .model, nil) }
        if line == "Select Model and Effort" { return (.codex, .model, nil) }
        let levels = "Select Reasoning Level for "
        if line.hasPrefix(levels) { return (.codex, .effort, String(line.dropFirst(levels.count))) }
        return nil
    }

    /// `❯ 2.  Opus 5.5 ✔   For complex work` → row 2 "Opus 5.5", current,
    /// selected. `↓ 10. Opus 4.8` → row 10, with rows below it.
    private static func row(_ line: String) -> (row: Row, above: Bool, below: Bool)? {
        var rest = Substring(line)
        var selected = false, above = false, below = false
        for _ in 0..<2 {
            guard let first = rest.first else { return nil }
            if cursors.contains(first) {
                selected = true
            } else if first == "↑" {
                above = true
            } else if first == "↓" {
                below = true
            } else {
                break
            }
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count), let n = Int(digits), n >= 1,
              rest.dropFirst(digits.count).hasPrefix(". ")
        else { return nil }
        let text = rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        // The label and what is said of it are in two columns.
        var label = text
        var description = ""
        if let gap = text.range(of: "  ") {
            label = String(text[..<gap.lowerBound])
            description = text[gap.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        let current = label.contains("✔") || label.contains("(current)")
        for mark in ["✔", "(current)", "(default)"] {
            label = label.replacingOccurrences(of: mark, with: "")
        }
        label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        let row = Row(
            n: n, label: label, description: description, current: current, selected: selected,
            opens: label.hasSuffix("…") || label.hasSuffix("..."))
        return (row, above, below)
    }

    /// `… +3 models`: the count of the rows that do not fit.
    private static func countsMore(_ line: String) -> Bool {
        guard line.hasPrefix("…") else { return false }
        return line.dropFirst().drop(while: \.isWhitespace).first == "+"
    }

    private static func effort(_ line: String) -> Effort? {
        // The line starts with a mark for the level.
        var words = line.split(separator: " ").map(String.init)
        if let mark = words.first, mark.count == 1, mark.first?.isLetter != true { words.removeFirst() }
        if words.starts(with: ["Effort", "not", "supported"]) { return .unsupported }
        guard words.count >= 2, words[1] == "effort" else { return nil }
        return .level(words[0])
    }

    /// nil when the screen's last thing is not a model menu: the menu's line
    /// of keys must be the last line with text.
    init?(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.lastIndex(where: { !$0.isEmpty }) else { return nil }
        let keys = lines[last].lowercased()
        guard keys.contains("enter"), keys.contains("esc"),
              let top = lines[..<last].lastIndex(where: { Self.header($0) != nil }),
              let kind = Self.header(lines[top])
        else { return nil }

        var rows: [Row] = []
        var above = false, below = false
        var effort: Effort?
        for line in lines[(top + 1)..<last] {
            if let found = Self.row(line) {
                // Numbers that do not follow on are not this list.
                if let before = rows.last, found.row.n != before.n + 1 { return nil }
                rows.append(found.row)
                above = above || found.above
                below = below || found.below
            } else if Self.countsMore(line) {
                if rows.isEmpty { above = true } else { below = true }
            } else if !rows.isEmpty, effort == nil {
                effort = Self.effort(line)
            }
        }
        guard !rows.isEmpty, rows.filter(\.selected).count == 1 else { return nil }
        agent = kind.agent
        step = kind.step
        subject = kind.subject
        self.rows = rows
        moreAbove = above || rows[0].n > 1
        moreBelow = below
        self.effort = kind.agent == .claude ? effort : nil
        let parts = keys.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        sessionKey = parts.contains { $0.hasPrefix("s ") && $0.contains("session") }
        advances = parts.contains("enter select")
    }
}

enum MobileModel {
    static let command = "/model"
    static let noMenuMessage = "The agent did not open its model menu"
    static let changedMessage = "The model menu changed"
    static let noSessionMessage = "This agent cannot change the model for one session"
    static let noEffortMessage = "The model does not have this effort level"
    static let notAppliedMessage = "The model was not changed"

    /// The pause between a key and the look at what it did, and how often the
    /// screen is looked at before a key counts as lost.
    static let keyDelay: TimeInterval = 0.15
    static let tries = 14
    /// The same for one step of the effort line. Its last step changes
    /// nothing, and that is how the end of the line is found.
    static let levelTries = 4
    /// More effort levels than any model has.
    static let maxLevels = 8
    /// More rows than a model list has.
    static let maxRows = 60

    /// What the phone asks for.
    enum Request: Equatable {
        /// Open the menu and list its models.
        case open
        /// Put the cursor on a model, and list its effort levels.
        case model(n: Int, label: String)
        /// Take the model with this level, for this session only. No `effort`:
        /// the model has none to pick.
        case apply(model: String, effort: String?)
        /// Close the menu.
        case cancel
    }

    /// `{"step": "open"}`, `{"step": "model", "n": 2, "label": "Opus 5.5"}`,
    /// `{"step": "apply", "model": "Opus 5.5", "effort": "High"}`,
    /// `{"step": "cancel"}`.
    static func request(in body: Data) -> Request? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let step = object["step"] as? String else { return nil }
        let label = { (key: String) -> String? in
            guard let value = object[key] as? String, !value.isEmpty, value.count <= 80 else { return nil }
            return value
        }
        switch step {
        case "open": return .open
        case "cancel": return .cancel
        case "model":
            guard let number = object["n"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue), (1...99).contains(number.intValue),
                  let label = label("label") else { return nil }
            return .model(n: number.intValue, label: label)
        case "apply":
            guard let model = label("model") else { return nil }
            if object["effort"] == nil || object["effort"] is NSNull { return .apply(model: model, effort: nil) }
            guard let effort = label("effort") else { return nil }
            return .apply(model: model, effort: effort)
        default: return nil
        }
    }

    static func run(
        _ request: Request, target: String, io: MobilePaneIO, state: () -> MobilePaneState?,
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> MobileResponse {
        guard state() != nil else { return .error(404, "not_found") }
        let pane = Pane(target: target, io: io, pause: pause)
        switch request {
        case .open: return open(pane, state: state)
        case .model(let n, let label): return pick(n: n, label: label, pane)
        case .apply(let model, let effort): return apply(model: model, effort: effort, pane)
        case .cancel:
            pane.close()
            return .json(["ok": true])
        }
    }

    /// The pane, and the few things done to it.
    private struct Pane {
        let target: String
        let io: MobilePaneIO
        let pause: (TimeInterval) -> Void

        var menu: MobileModelMenu? { io.screen().flatMap(MobileModelMenu.init) }

        func press(_ key: String, times: Int = 1) -> Bool {
            guard times > 0 else { return true }
            return io.tmux(["send-keys", "-t", target] + Array(repeating: key, count: times), nil) != nil
        }

        /// The menu once it is as `wanted`; nil when it never is.
        func menu(tries: Int = MobileModel.tries, where wanted: (MobileModelMenu) -> Bool) -> MobileModelMenu? {
            for _ in 0..<tries {
                pause(MobileModel.keyDelay)
                if let menu, wanted(menu) { return menu }
            }
            return nil
        }

        /// Whether the menu went away.
        func closed() -> Bool {
            for _ in 0..<MobileModel.tries {
                pause(MobileModel.keyDelay)
                if io.screen() != nil, menu == nil { return true }
            }
            return false
        }

        /// Escape until no menu is in front. Codex goes back one list for each.
        func close() {
            for _ in 0..<3 {
                guard menu != nil, press("Escape") else { return }
                pause(MobileModel.keyDelay * 2)
            }
        }

        /// Close the menu and say why nothing was applied.
        func refuse(_ error: String, _ message: String) -> MobileResponse {
            close()
            return .error(409, error, message: message)
        }

        /// Move the list's cursor to row `n`.
        func move(from at: Int, to n: Int) -> MobileModelMenu? {
            guard press(n > at ? "Down" : "Up", times: abs(n - at)) else { return nil }
            return menu { $0.selected?.n == n }
        }
    }

    // MARK: Open

    private static func open(_ pane: Pane, state: () -> MobilePaneState?) -> MobileResponse {
        var seen = pane.menu
        if seen == nil {
            let sent = MobileReply.send(command, target: pane.target, io: pane.io, state: state, pause: pane.pause)
            guard sent.status == 200 else { return sent }
            seen = pane.menu { _ in true }
        }
        // A Codex pane left on its list of levels: back to the models.
        if seen?.step == .effort {
            guard pane.press("Escape") else { return .error(503, "unavailable", message: MobileReply.unreachable) }
            seen = pane.menu { $0.step == .model }
        }
        guard let menu = seen, menu.step == .model else {
            return pane.refuse("no_menu", noMenuMessage)
        }
        guard let rows = allRows(of: menu, pane) else { return pane.refuse("no_menu", noMenuMessage) }
        return .json([
            "agent": menu.agent.rawValue,
            "models": rows.filter { !$0.opens }.map(\.json),
        ])
    }

    /// Every row of a list, also the ones a scrolled list does not show. The
    /// list's cursor wraps: one Up from the first row shows the list's end.
    private static func allRows(of first: MobileModelMenu, _ pane: Pane) -> [MobileModelMenu.Row]? {
        guard first.moreAbove || first.moreBelow else { return first.rows }
        var found: [Int: MobileModelMenu.Row] = [:]
        let keep = { (menu: MobileModelMenu) in
            for row in menu.rows { found[row.n] = row }
        }
        keep(first)
        guard let at = first.selected, let top = at.n == 1 ? first : pane.move(from: at.n, to: 1),
              pane.press("Up"), var menu = pane.menu(where: { ($0.selected?.n ?? 1) > 1 }),
              let last = menu.selected?.n
        else { return nil }
        keep(top)
        keep(menu)
        // A list more than two screens long: up one row at a time.
        var row = last
        while found.count < last {
            guard row > 1, last - row < maxRows, let next = pane.move(from: row, to: row - 1) else { return nil }
            menu = next
            keep(menu)
            row -= 1
        }
        return found.values.sorted { $0.n < $1.n }
    }

    // MARK: Model

    private static func pick(n: Int, label: String, _ pane: Pane) -> MobileResponse {
        guard var menu = pane.menu else { return .error(409, "no_menu", message: noMenuMessage) }
        if menu.step == .effort {
            guard pane.press("Escape"), let back = pane.menu(where: { $0.step == .model })
            else { return pane.refuse("no_menu", noMenuMessage) }
            menu = back
        }
        guard let at = menu.selected, let there = at.n == n ? menu : pane.move(from: at.n, to: n),
              there.selected?.label == label
        else { return pane.refuse("changed", changedMessage) }

        switch there.agent {
        case .codex:
            // Enter here opens the list of levels. It saves nothing.
            guard there.advances, pane.press("Enter"),
                  let levels = pane.menu(where: { $0.step == .effort })
            else { return pane.refuse("changed", changedMessage) }
            let marked = levels.rows.contains(where: \.current)
            return .json([
                "efforts": levels.rows.filter { !$0.opens }.map { row -> [String: Any] in
                    ["label": row.label, "description": row.description,
                     "current": marked ? row.current : row.selected]
                },
            ])
        case .claude:
            guard case .level(let now) = there.effort else { return .json(["efforts": [Any]()]) }
            guard let levels = levels(pane) else { return pane.refuse("changed", changedMessage) }
            // Leave the line as it was found.
            if let index = levels.firstIndex(of: now) {
                _ = pane.press("Left", times: levels.count - 1 - index)
            }
            return .json([
                "efforts": levels.map { ["label": $0, "description": "", "current": $0 == now] as [String: Any] },
            ])
        }
    }

    /// The effort levels of the model under the cursor, lowest first. The
    /// line does not wrap: Left goes to its start, and Right stops at its end.
    private static func levels(_ pane: Pane) -> [String]? {
        guard pane.press("Left", times: maxLevels) else { return nil }
        pane.pause(keyDelay * 2)
        guard case .level(let lowest) = pane.menu?.effort else { return nil }
        var levels = [lowest]
        while levels.count < maxLevels {
            guard pane.press("Right") else { return nil }
            let last = levels[levels.count - 1]
            guard let next = pane.menu(tries: levelTries, where: { $0.effort != .level(last) }),
                  case .level(let level) = next.effort
            else { break }
            levels.append(level)
        }
        return levels
    }

    // MARK: Apply

    private static func apply(model: String, effort: String?, _ pane: Pane) -> MobileResponse {
        guard let menu = pane.menu else { return .error(409, "no_menu", message: noMenuMessage) }
        // Without `s` the only way to take the pick is Enter, which saves it.
        guard menu.sessionKey else { return pane.refuse("no_session", noSessionMessage) }

        switch (menu.agent, menu.step) {
        case (.claude, .model):
            guard menu.selected?.label == model else { return pane.refuse("changed", changedMessage) }
            if let effort {
                guard let levels = levels(pane), let index = levels.firstIndex(of: effort) else {
                    return pane.refuse("no_effort", noEffortMessage)
                }
                // `levels` left the line on its last level.
                guard pane.press("Left", times: levels.count - 1 - index),
                      let set = pane.menu(where: { $0.effort == .level(effort) }),
                      set.selected?.label == model
                else { return pane.refuse("no_effort", noEffortMessage) }
            }
        case (.codex, .effort):
            guard menu.subject == model, let at = menu.selected else {
                return pane.refuse("changed", changedMessage)
            }
            if let effort {
                guard let want = menu.rows.first(where: { $0.label == effort && !$0.opens }),
                      let there = at.n == want.n ? menu : pane.move(from: at.n, to: want.n),
                      there.selected?.label == effort, there.subject == model
                else { return pane.refuse("no_effort", noEffortMessage) }
            }
        default:
            return pane.refuse("changed", changedMessage)
        }

        guard pane.press("s") else { return .error(503, "unavailable", message: MobileReply.unreachable) }
        guard pane.closed() else { return pane.refuse("not_applied", notAppliedMessage) }
        return .json(["ok": true])
    }
}
