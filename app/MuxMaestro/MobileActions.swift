import Foundation

// The session-action half of the phone API: what the phone may do to the tmux
// tree, and find in one pane's scrollback. Pure, like MobileAPI.swift: every
// tmux call goes through a `MobileTmux`, so the tests assert the exact argv.
//
// The rules, in one place:
// - An action is a case of `MobileAction`. Nothing else reaches tmux.
// - A target is looked up in the live tree. The phone names a thread, or a
//   host and a session; what goes to tmux is the tree's own pane id or session
//   name, never a string the phone sent.
// - A name passes `MobileActions.name`. It is one argv item of its own.
// - A new session starts in a directory from `MobileActions.dirs`, or at home.
// - A kill needs `"confirm": true`.
// - The manager's own session takes no action.

/// One tmux call on a host. nil when it failed.
typealias MobileTmux = (_ args: [String]) -> String?

/// Every action the phone may ask for: the last segment of `/api/tmux/<action>`.
enum MobileAction: String, CaseIterable {
    case newSession = "new-session"
    case newWindow = "new-window"
    case renameSession = "rename-session"
    case renameWindow = "rename-window"
    case killSession = "kill-session"
    case killWindow = "kill-window"
    case killPane = "kill-pane"
    case zoomPane = "zoom-pane"

    var isKill: Bool {
        switch self {
        case .killSession, .killWindow, .killPane: return true
        case .newSession, .newWindow, .renameSession, .renameWindow, .zoomPane: return false
        }
    }
}

enum MobileActions {
    static let maxNameLength = 64
    /// The most directories a host offers for a new session.
    static let maxDirs = 50
    static let unreachable = "Could not reach tmux"
    /// The name of a session made in no directory, or in one whose own name
    /// is not a usable session name.
    static let fallbackName = "session"

    /// One checked action: the host to run it on and the tmux command.
    struct Call: Equatable {
        enum Made: Equatable {
            case nothing
            /// The command prints the new window's index and pane id.
            case window
            case session(String)
        }

        let host: Host
        let argv: [String]
        var made = Made.nothing
    }

    /// Why an action is not run.
    struct Refusal: Error {
        let response: MobileResponse

        init(_ status: Int, _ code: String) { response = .error(status, code) }
    }

    // MARK: Names

    private static let asciiPunctuation = CharacterSet(charactersIn: "-_/, ")

    /// A session or window name the phone may set, or nil. No control or
    /// format characters, and of ASCII only letters, digits, space and
    /// `- _ / ,`: that leaves out everything tmux reads in a target or a
    /// format (`: . = $ @ % # { } ! ^ + ~ * ? [ ]`) and every shell character.
    /// It starts with neither `-` (tmux would read a flag) nor a space.
    static func name(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= maxNameLength, !name.hasPrefix("-") else { return nil }
        for scalar in name.unicodeScalars {
            if scalar.isASCII {
                guard CharacterSet.alphanumerics.contains(scalar) || asciiPunctuation.contains(scalar)
                else { return nil }
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                return nil
            case .format:
                // The joiner inside an emoji; every other format character
                // (direction marks, invisible spaces) is refused.
                guard scalar.value == 0x200D else { return nil }
            default:
                continue
            }
        }
        return name
    }

    // MARK: Targets

    /// A path from the live tree that can be a tmux `-c` argument.
    private static func path(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\n"),
              raw.unicodeScalars.allSatisfy(MobileManager.isText) else { return nil }
        return raw
    }

    /// The directories `host` offers for a new session: where its threads
    /// work now. nil when the tree has no such host.
    static func dirs(host: String, snapshot: MobileSnapshot) -> [String]? {
        guard snapshot.hosts.contains(where: { $0.host.name == host }) else { return nil }
        let paths = snapshot.threads.filter { $0.host.name == host && !isManager($0.host, $0.session) }
            .compactMap { path($0.cwd) }
        return Array(Set(paths).sorted().prefix(maxDirs))
    }

    private static func isManager(_ host: Host, _ session: String) -> Bool {
        host.isLocal && session == ManagerHome.sessionName
    }

    private static func sessionNames(on host: Host, snapshot: MobileSnapshot) -> Set<String> {
        var names = Set(snapshot.threads.filter { $0.host == host }.map(\.session))
        // Hidden from the tree, and still a name that is taken.
        if host.isLocal { names.insert(ManagerHome.sessionName) }
        return names
    }

    private static func host(_ fields: [String: Any], snapshot: MobileSnapshot) throws -> Host {
        guard let name = fields["host"] as? String else { throw Refusal(400, "bad_request") }
        guard let found = snapshot.hosts.first(where: { $0.host.name == name }) else {
            throw Refusal(404, "not_found")
        }
        return found.host
    }

    /// The thread `fields` names, from the live tree. Its pane id is the
    /// tree's own, so it is `%` and digits.
    private static func thread(_ fields: [String: Any], snapshot: MobileSnapshot) throws -> MobileThread {
        guard let id = fields["thread"] as? String else { throw Refusal(400, "bad_request") }
        guard let thread = snapshot.thread(id: id), thread.pane.hasPrefix("%"),
              thread.pane.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }), thread.pane.count > 1
        else { throw Refusal(404, "not_found") }
        guard !isManager(thread.host, thread.session) else { throw Refusal(403, "protected") }
        return thread
    }

    /// The session `fields` names, as a thread or as a host and a session
    /// name, with a directory of its own.
    private static func session(
        _ fields: [String: Any], snapshot: MobileSnapshot
    ) throws -> (host: Host, name: String, cwd: String?) {
        if fields["thread"] != nil {
            let thread = try thread(fields, snapshot: snapshot)
            return (thread.host, thread.session, path(thread.cwd))
        }
        let host = try host(fields, snapshot: snapshot)
        guard let name = fields["session"] as? String else { throw Refusal(400, "bad_request") }
        guard !isManager(host, name) else { throw Refusal(403, "protected") }
        guard let first = snapshot.threads.first(where: { $0.host == host && $0.session == name })
        else { throw Refusal(404, "not_found") }
        return (host, name, path(first.cwd))
    }

    private static func confirmed(_ fields: [String: Any]) throws {
        // A JSON `true`, and nothing that only reads as one.
        guard let flag = fields["confirm"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue
        else { throw Refusal(400, "confirm_required") }
    }

    // MARK: Actions

    /// Check `action` against the live tree and build its tmux command.
    static func plan(
        _ action: MobileAction, fields: [String: Any], snapshot: MobileSnapshot
    ) throws -> Call {
        switch action {
        case .newSession:
            let host = try host(fields, snapshot: snapshot)
            var dir: String?
            if let raw = fields["dir"], !(raw is NSNull) {
                // Only a directory this server offered.
                guard let asked = raw as? String,
                      dirs(host: host.name, snapshot: snapshot)?.contains(asked) == true
                else { throw Refusal(400, "bad_dir") }
                dir = asked
            }
            let wanted: String
            if let raw = fields["name"], !(raw is NSNull) {
                guard let asked = name(raw) else { throw Refusal(400, "bad_name") }
                wanted = asked
            } else {
                let folder = dir.map { ($0 as NSString).lastPathComponent } ?? ""
                wanted = name(TmuxCommands.sanitizedSessionName(folder)) ?? fallbackName
            }
            let unique = TmuxCommands.uniqueSessionName(
                wanted, existing: sessionNames(on: host, snapshot: snapshot))
            return Call(
                host: host, argv: TmuxCommands.newSession(name: unique, dir: dir), made: .session(unique))
        case .newWindow:
            let target = try session(fields, snapshot: snapshot)
            // `=` pins the session to an exact name.
            return Call(
                host: target.host,
                argv: TmuxCommands.newWindow(session: "=\(target.name)", cwd: target.cwd, printTarget: true),
                made: .window)
        case .renameSession:
            let target = try session(fields, snapshot: snapshot)
            guard let new = name(fields["name"]) else { throw Refusal(400, "bad_name") }
            guard new == target.name
                || !sessionNames(on: target.host, snapshot: snapshot).contains(new)
            else { throw Refusal(409, "exists") }
            return Call(
                host: target.host, argv: TmuxCommands.renameSession(from: "=\(target.name)", to: new))
        case .renameWindow:
            let thread = try thread(fields, snapshot: snapshot)
            guard let new = name(fields["name"]) else { throw Refusal(400, "bad_name") }
            // The pane id names its window: it does not move when tmux
            // renumbers windows, as an index does.
            return Call(host: thread.host, argv: TmuxCommands.renameWindow(target: thread.pane, to: new))
        case .killSession:
            let target = try session(fields, snapshot: snapshot)
            try confirmed(fields)
            return Call(host: target.host, argv: TmuxCommands.killSession(name: target.name))
        case .killWindow:
            let thread = try thread(fields, snapshot: snapshot)
            try confirmed(fields)
            return Call(host: thread.host, argv: TmuxCommands.killWindow(target: thread.pane))
        case .killPane:
            let thread = try thread(fields, snapshot: snapshot)
            try confirmed(fields)
            return Call(host: thread.host, argv: TmuxCommands.killPane(target: thread.pane))
        case .zoomPane:
            let thread = try thread(fields, snapshot: snapshot)
            return Call(host: thread.host, argv: TmuxCommands.toggleZoom(target: thread.pane))
        }
    }

    /// Run one action. `tmux` gives the runner for a host, nil where there is
    /// none. Blocks on the tmux call.
    static func perform(
        _ action: MobileAction, body: Data, snapshot: MobileSnapshot, tmux: (Host) -> MobileTmux?
    ) -> MobileResponse {
        guard let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .error(400, "bad_request")
        }
        let call: Call
        do {
            call = try plan(action, fields: fields, snapshot: snapshot)
        } catch let refusal as Refusal {
            return refusal.response
        } catch {
            return .error(400, "bad_request")
        }
        guard let run = tmux(call.host), let output = run(call.argv) else {
            return .error(503, "unavailable", message: unreachable)
        }
        var result: [String: Any] = ["ok": true]
        switch call.made {
        case .nothing:
            break
        case .window:
            if let created = TmuxCommands.parseCreatedPane(output) {
                result["thread"] = MobileSnapshot.threadID(host: call.host, pane: created.pane)
            }
        case .session(let name):
            result["session"] = name
        }
        return .json(result)
    }
}

// MARK: - Find

/// Find in one thread's scrollback: `PaneSearch` over that pane alone.
enum MobileFind {
    static let maxQueryLength = 200
    /// The most matching lines one answer carries.
    static let maxMatches = 200
    /// The most scrollback text one answer carries; older lines are left out.
    static let maxTextBytes = 524_288

    /// The text to look for, or nil: empty, too long, or not plain text. It
    /// is matched as it is, never as a pattern.
    static func query(_ raw: String) -> String? {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, query.count <= maxQueryLength,
              query.unicodeScalars.allSatisfy({ MobileManager.isText($0) && $0 != "\n" && $0 != "\t" })
        else { return nil }
        return query
    }

    /// The scrollback the phone shows and where `query` is in it. `capture`
    /// is the output of `PaneSearch.captureArgv` for the thread's pane.
    /// A match is a line (0-based, into `text`) and its ranges, in UTF-16
    /// units as a browser counts them.
    static func result(query: String, capture: String, thread: MobileThread) -> [String: Any] {
        var lines = PaneSearch.parseCaptures(capture)[thread.pane] ?? []
        // A pane is mostly empty rows below its prompt.
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        lines = lines.map { PaneSearch.clamp(line: $0, highlights: []).0 }
        var first = lines.count
        var bytes = 0
        while first > 0, bytes + lines[first - 1].utf8.count + 1 <= maxTextBytes {
            first -= 1
            bytes += lines[first].utf8.count + 1
        }
        lines = Array(lines[first...])

        let pane = PaneSearchTarget(
            paneId: thread.pane, session: thread.session, window: thread.window,
            windowName: thread.name, command: thread.command, host: thread.host)
        let found = PaneSearch.match(
            query: query, captures: [thread.pane: lines], panes: [pane],
            perPaneCap: maxMatches, maxMatches: maxMatches)
        let matches: [[String: Any]] = found.matches.map { match in
            let utf8 = match.lineText.utf8
            let units = { (offset: Int) in
                String(decoding: utf8.prefix(offset), as: UTF8.self).utf16.count
            }
            return [
                "line": match.lineNumber - 1,
                "ranges": match.highlights.map { [units($0.lowerBound), units($0.upperBound)] },
            ]
        }
        return ["text": lines.joined(separator: "\n"), "matches": matches, "truncated": found.truncated]
    }

    /// Search the thread's pane. Blocks on the tmux call.
    static func search(thread: MobileThread, query: String, tmux: MobileTmux?) -> MobileResponse {
        guard let tmux, let capture = tmux(PaneSearch.captureArgv(panes: [thread.pane])) else {
            return .error(503, "unavailable", message: MobileActions.unreachable)
        }
        return .json(result(query: query, capture: capture, thread: thread))
    }
}
