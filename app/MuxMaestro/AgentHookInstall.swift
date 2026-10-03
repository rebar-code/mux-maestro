import Foundation

/// Installs (and removes) MuxMaestro's hooks in both agents' config files. Two
/// independent hook sets:
///
/// - `.recovery` — a `SessionStart` hook that records an agent session id against
///   its tmux pane, so a reboot can restore it.
/// - `.events` — a hook on every event that moves an agent's state, running
///   `mux event`, so the sidebar dots and toasts come from the agents themselves.
///
/// Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) use
/// the identical shape — `hooks` → `<Event>` → `[{matcher, hooks:[{type,
/// command}]}]` — so one installer serves both. Entries are keyed by a trailing
/// marker comment in the command string (`# muxmaestro-recovery`,
/// `# muxmaestro-events`), the convention the user's other hooks already follow,
/// so install is idempotent and uninstall touches nothing else — including the
/// other hook set.
///
/// Codex's `config.toml` records a `trusted_hash` per hook **keyed by its index**
/// in the array (`hooks.json:session_start:<matcher>:<hook>`), so a new entry is
/// always **appended** and a stale one is replaced where it stands: inserting
/// would shift every later hook's key onto the wrong command and silently untrust
/// the lot.
///
/// Files are edited through `JSON`, which keeps key order and the layout both
/// agents write, so the only lines that change are ours.
enum AgentHookInstall {
    /// The recovery hook's marker.
    static let marker = Hook.recovery.marker

    enum Hook {
        case recovery
        case events

        var marker: String {
            switch self {
            case .recovery: return "# muxmaestro-recovery"
            case .events: return "# muxmaestro-events"
            }
        }

        /// The events this hook set is installed on. `.events` is every event
        /// that moves a session's state in `mux event`; Codex has fewer of them.
        func events(for target: Target) -> [String] {
            switch (self, target) {
            case (.recovery, _):
                return ["SessionStart"]
            case (.events, .claude):
                return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                        "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
            case (.events, .codex):
                return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                        "PermissionRequest", "Stop"]
            }
        }

        /// Seconds the agent waits before giving up on the hook; nil keeps the
        /// agent's default. `mux event` takes ~10ms — the bound only matters if
        /// SQLite wedges, and the default is 60s (Claude) or 600s (Codex).
        var timeout: Int? {
            switch self {
            case .recovery: return nil
            case .events: return 5
            }
        }
    }

    /// The two config files, and which agent name the script is passed for each.
    enum Target: CaseIterable {
        case claude
        case codex

        var configURL: URL {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            switch self {
            case .claude: return home.appendingPathComponent(".claude/settings.json")
            case .codex: return home.appendingPathComponent(".codex/hooks.json")
            }
        }

        /// The config path as the user writes it, for the confirm alert.
        var displayPath: String {
            switch self {
            case .claude: return "~/.claude/settings.json"
            case .codex: return "~/.codex/hooks.json"
            }
        }

        var agentName: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            }
        }

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }
    }

    // MARK: Pure core (unit-tested)

    /// The recovery command for `target`, pointing at the installed script. Single
    /// quotes so a path with spaces survives the shell — the install path is
    /// under "Application Support", which has one.
    static func command(scriptPath: String, target: Target) -> String {
        "'\(scriptPath)' \(target.agentName) \(Hook.recovery.marker)"
    }

    /// The `.events` command. A hook that exits 2 blocks the agent's prompt or
    /// tool call, and `mux` exits 2 on usage — so a missing `mux`, or one older
    /// than `event`, must still exit 0: stderr is dropped and the status forced.
    static func eventsCommand(muxPath: String, target: Target) -> String {
        "'\(muxPath)' event \(target.agentName) 2>/dev/null || true \(Hook.events.marker)"
    }

    static func command(for hook: Hook, path: String, target: Target) -> String {
        switch hook {
        case .recovery: return command(scriptPath: path, target: target)
        case .events: return eventsCommand(muxPath: path, target: target)
        }
    }

    /// Whether a hook entry (one element of an event's array) carries `marker`.
    private static func isOurs(_ entry: JSON, marker: String) -> Bool {
        guard let hooks = entry["hooks"]?.arrayValue else { return false }
        return hooks.contains { $0["command"]?.stringValue?.contains(marker) == true }
    }

    private static func entry(command: String, timeout: Int?) -> JSON {
        var hook: [JSON.Member] = [.init("type", .string("command")), .init("command", .string(command))]
        if let timeout { hook.append(.init("timeout", .number(String(timeout)))) }
        return .object([.init("matcher", .string("")), .init("hooks", .array([.object(hook)]))])
    }

    /// Rewrite a config so each of `hook`'s events holds exactly one of our
    /// entries (install) or none (uninstall), leaving every other hook and every
    /// unrelated key untouched. An entry of ours on an event the set no longer
    /// uses is removed. Returns nil when nothing needs to change, so an
    /// already-correct file is never rewritten.
    static func apply(
        _ root: JSON, hook: Hook, target: Target, install: Bool, command: String
    ) throws -> JSON? {
        guard case .object = root else { throw InstallError.notAnObject }
        var root = root
        var hooks = root["hooks"] ?? .object([])
        guard case .object(let existing) = hooks else { throw InstallError.notAnObject }

        let wanted = install ? hook.events(for: target) : []
        let names = existing.map(\.key) + wanted.filter { name in
            !existing.contains { $0.key == name }
        }
        let ours = entry(command: command, timeout: hook.timeout)
        var changed = false
        for name in names {
            let current = hooks[name]
            // Not an array: malformed, and not ours to repair.
            guard current == nil || current?.arrayValue != nil else { continue }
            let entries = current?.arrayValue ?? []
            let wants = wanted.contains(name)
            var updated: [JSON] = []
            var placed = false
            for entry in entries {
                guard isOurs(entry, marker: hook.marker) else {
                    updated.append(entry)
                    continue
                }
                // Replaced where it stands (see the Codex note above); extras dropped.
                if wants && !placed {
                    updated.append(ours)
                    placed = true
                }
            }
            if wants && !placed { updated.append(ours) }
            if updated == entries { continue }
            hooks[name] = updated.isEmpty ? nil : .array(updated)
            changed = true
        }
        guard changed else { return nil }
        root["hooks"] = hooks == .object([]) ? nil : hooks
        return root
    }

    /// `apply` over raw bytes, for a file that may not exist yet (nil `data`
    /// starts from an empty object). Returns nil when no change is needed. Keeps
    /// the file's trailing newline, or its absence.
    static func apply(
        data: Data?, hook: Hook = .recovery, target: Target = .claude,
        install: Bool, command: String
    ) throws -> Data? {
        let root: JSON
        var trailingNewline = true
        if let data, !data.isEmpty {
            root = try JSON.parse(data)
            trailingNewline = data.last == UInt8(ascii: "\n")
        } else {
            // Uninstalling a config that doesn't exist is a no-op, not a file to
            // create.
            guard install else { return nil }
            root = .object([])
        }
        guard let updated = try apply(
            root, hook: hook, target: target, install: install, command: command)
        else { return nil }
        return Data((updated.rendered() + (trailingNewline ? "\n" : "")).utf8)
    }

    /// The events whose arrays `apply` would change — the confirm alert's diff.
    static func changedEvents(
        data: Data?, hook: Hook, target: Target, install: Bool, command: String
    ) -> [String] {
        let before = data.flatMap { $0.isEmpty ? nil : try? JSON.parse($0) } ?? .object([])
        guard let after = try? apply(
            before, hook: hook, target: target, install: install, command: command),
            case .object(let beforeEvents) = before["hooks"] ?? .object([]),
            case .object(let afterEvents) = after["hooks"] ?? .object([])
        else { return [] }
        let names = beforeEvents.map(\.key)
            + afterEvents.map(\.key).filter { name in !beforeEvents.contains { $0.key == name } }
        return names.filter { before["hooks"]?[$0] != after["hooks"]?[$0] }
    }

    /// Whether `data` carries one of our entries on every event of `hook`.
    static func isInstalled(data: Data?, hook: Hook = .recovery, target: Target = .claude) -> Bool {
        guard let data, !data.isEmpty, let root = try? JSON.parse(data) else { return false }
        return hook.events(for: target).allSatisfy { name in
            root["hooks"]?[name]?.arrayValue?.contains { isOurs($0, marker: hook.marker) } == true
        }
    }

    // MARK: Filesystem

    enum InstallError: LocalizedError {
        case notAnObject
        case invalidJSON
        case noSupportDirectory
        case missingResource

        var errorDescription: String? {
            switch self {
            case .notAnObject: return "the config file isn’t a JSON object"
            case .invalidJSON: return "the config file isn’t valid JSON"
            case .noSupportDirectory: return "couldn’t reach Application Support"
            case .missingResource: return "the recovery script is missing from the app bundle"
            }
        }
    }

    /// Copy the bundled hook script to its stable path under Application Support
    /// and return it. Re-copied on every install so an app update refreshes it —
    /// the config files point at this path, not into the bundle, because
    /// `make install` replaces the bundle wholesale.
    @discardableResult
    static func installScript() throws -> URL {
        guard let dest = SessionRecord.hookScriptURL() else {
            throw InstallError.noSupportDirectory
        }
        guard let source = Bundle.main.url(
            forResource: "record-agent-session", withExtension: "sh", subdirectory: "recovery")
        else { throw InstallError.missingResource }
        let fm = FileManager.default
        try fm.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }

    /// The script `hook`'s entries run, seeded under Application Support: the
    /// recovery script, or the manager home's `bin/mux` (which `ManagerHome`
    /// refreshes from the bundle).
    static func installedScriptPath(for hook: Hook) throws -> String {
        switch hook {
        case .recovery: return try installScript().path
        case .events: return try ManagerHome.ensure().appendingPathComponent("bin/mux").path
        }
    }

    /// Where `installedScriptPath` will put the script, without seeding it.
    static func scriptPath(for hook: Hook) -> String {
        switch hook {
        case .recovery: return SessionRecord.hookScriptURL()?.path ?? ""
        case .events: return ManagerHome.defaultHome()?.appendingPathComponent("bin/mux").path ?? ""
        }
    }

    /// True when `hook` is present in both config files.
    static func isInstalled(_ hook: Hook = .recovery) -> Bool {
        Target.allCases.allSatisfy {
            isInstalled(data: try? Data(contentsOf: $0.configURL), hook: hook, target: $0)
        }
    }

    /// What `run` would change in each config file, for the confirm alert. Reads
    /// only. Files with no change are left out.
    static func preview(_ hook: Hook, install: Bool) -> [(target: Target, events: [String])] {
        let path = scriptPath(for: hook)
        return Target.allCases.compactMap { target in
            let events = changedEvents(
                data: try? Data(contentsOf: target.configURL), hook: hook, target: target,
                install: install, command: command(for: hook, path: path, target: target))
            return events.isEmpty ? nil : (target, events)
        }
    }

    /// The result of one install/uninstall pass, for the message shown to the user.
    struct Outcome {
        /// Config files actually rewritten.
        var changed: [Target] = []
        /// Config files that were already in the requested state.
        var unchanged: [Target] = []
        /// Config files that couldn't be written, with why.
        var failed: [(target: Target, reason: String)] = []
    }

    /// Install or remove `hook` in both config files. Blocking (small file IO);
    /// call off the main thread. Each file is written via a temp file and an
    /// atomic replace, so a failure part-way can't leave a half-written config.
    /// `configURL` is injectable so the pass can run against copies.
    static func run(
        _ hook: Hook = .recovery, install: Bool,
        configURL: (Target) -> URL = { $0.configURL }
    ) -> Outcome {
        var outcome = Outcome()
        // Uninstall matches on the marker (inside `apply`), not the command, so
        // it needs no script.
        var path = ""
        if install {
            do { path = try installedScriptPath(for: hook) }
            catch {
                for target in Target.allCases {
                    outcome.failed.append((target, error.localizedDescription))
                }
                return outcome
            }
        }

        for target in Target.allCases {
            let url = configURL(target)
            let data = try? Data(contentsOf: url)
            let cmd = command(for: hook, path: path, target: target)
            do {
                guard let updated = try apply(
                    data: data, hook: hook, target: target, install: install, command: cmd)
                else {
                    outcome.unchanged.append(target)
                    continue
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try updated.write(to: url, options: .atomic)
                outcome.changed.append(target)
            } catch {
                outcome.failed.append((target, error.localizedDescription))
            }
        }
        return outcome
    }
}

// MARK: - JSON that keeps its layout

extension AgentHookInstall {
    /// A JSON value that keeps object key order and number spelling, so a config
    /// file can be edited without reformatting it. `JSONSerialization` loses key
    /// order, which rewrites every line of a hand-ordered `settings.json`.
    ///
    /// Renders the way both agents write their files — `JSON.stringify(value,
    /// null, 2)`: two-space indent, `"key": value`, `[]` and `{}` when empty.
    enum JSON: Equatable {
        struct Member: Equatable {
            let key: String
            var value: JSON

            init(_ key: String, _ value: JSON) {
                self.key = key
                self.value = value
            }
        }

        case object([Member])
        case array([JSON])
        case string(String)
        /// The literal as written, so `1.50` stays `1.50`.
        case number(String)
        case bool(Bool)
        case null

        /// An object's value for `key` (the first, if the key repeats). Setting
        /// replaces the value in place, appends a new key, or removes it for nil.
        subscript(key: String) -> JSON? {
            get {
                guard case .object(let members) = self else { return nil }
                return members.first { $0.key == key }?.value
            }
            set {
                guard case .object(var members) = self else { return }
                if let index = members.firstIndex(where: { $0.key == key }) {
                    if let newValue {
                        members[index].value = newValue
                    } else {
                        members.remove(at: index)
                    }
                } else if let newValue {
                    members.append(Member(key, newValue))
                }
                self = .object(members)
            }
        }

        var arrayValue: [JSON]? {
            if case .array(let items) = self { return items }
            return nil
        }

        var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        static func parse(_ data: Data) throws -> JSON {
            var parser = Parser(bytes: Array(data))
            return try parser.document()
        }

        func rendered() -> String {
            var out = ""
            render(into: &out, indent: "")
            return out
        }

        private func render(into out: inout String, indent: String) {
            let inner = indent + "  "
            switch self {
            case .null: out += "null"
            case .bool(let value): out += value ? "true" : "false"
            case .number(let literal): out += literal
            case .string(let value): Self.quote(value, into: &out)
            case .array(let items):
                guard !items.isEmpty else { out += "[]"; return }
                out += "[\n"
                for (index, item) in items.enumerated() {
                    if index > 0 { out += ",\n" }
                    out += inner
                    item.render(into: &out, indent: inner)
                }
                out += "\n" + indent + "]"
            case .object(let members):
                guard !members.isEmpty else { out += "{}"; return }
                out += "{\n"
                for (index, member) in members.enumerated() {
                    if index > 0 { out += ",\n" }
                    out += inner
                    Self.quote(member.key, into: &out)
                    out += ": "
                    member.value.render(into: &out, indent: inner)
                }
                out += "\n" + indent + "}"
            }
        }

        private static func quote(_ value: String, into out: inout String) {
            out += "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            out += "\""
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func document() throws -> JSON {
            let value = try parseValue()
            skipSpace()
            guard index == bytes.count else { throw InstallError.invalidJSON }
            return value
        }

        private mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        private func peek(_ ascii: Unicode.Scalar) -> Bool {
            index < bytes.count && bytes[index] == UInt8(ascii: ascii)
        }

        private mutating func expect(_ ascii: Unicode.Scalar) throws {
            skipSpace()
            guard peek(ascii) else { throw InstallError.invalidJSON }
            index += 1
        }

        private mutating func literal(_ word: String, _ value: JSON) throws -> JSON {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count,
                  Array(bytes[index..<index + utf8.count]) == utf8
            else { throw InstallError.invalidJSON }
            index += utf8.count
            return value
        }

        private mutating func parseValue() throws -> JSON {
            skipSpace()
            guard index < bytes.count else { throw InstallError.invalidJSON }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [JSON.Member] = []
                skipSpace()
                if peek("}") {
                    index += 1
                    return .object(members)
                }
                while true {
                    skipSpace()
                    guard peek("\"") else { throw InstallError.invalidJSON }
                    let key = try parseString()
                    try expect(":")
                    members.append(JSON.Member(key, try parseValue()))
                    skipSpace()
                    if peek(",") {
                        index += 1
                        continue
                    }
                    try expect("}")
                    return .object(members)
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [JSON] = []
                skipSpace()
                if peek("]") {
                    index += 1
                    return .array(items)
                }
                while true {
                    items.append(try parseValue())
                    skipSpace()
                    if peek(",") {
                        index += 1
                        continue
                    }
                    try expect("]")
                    return .array(items)
                }
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                return try literal("true", .bool(true))
            case UInt8(ascii: "f"):
                return try literal("false", .bool(false))
            case UInt8(ascii: "n"):
                return try literal("null", .null)
            default:
                let start = index
                let numberBytes = Array("-+.eE0123456789".utf8)
                while index < bytes.count, numberBytes.contains(bytes[index]) { index += 1 }
                let literal = String(decoding: bytes[start..<index], as: UTF8.self)
                guard !literal.isEmpty, Double(literal) != nil else { throw InstallError.invalidJSON }
                return .number(literal)
            }
        }

        private mutating func parseString() throws -> String {
            index += 1  // the opening quote
            var utf8: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") { return String(decoding: utf8, as: UTF8.self) }
                guard byte == UInt8(ascii: "\\") else {
                    utf8.append(byte)
                    continue
                }
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    // A UTF-16 surrogate pair spells one scalar across two escapes.
                    if (0xD800...0xDBFF).contains(code), index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let resume = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = resume
                        }
                    }
                    utf8.append(contentsOf: String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8)
                default:
                    throw InstallError.invalidJSON
                }
            }
            throw InstallError.invalidJSON
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw InstallError.invalidJSON }
            index += 4
            return code
        }
    }
}
