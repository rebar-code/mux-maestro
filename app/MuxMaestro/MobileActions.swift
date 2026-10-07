import Foundation

// The session-action half of the phone API: what the phone may do to the tmux
// tree, and find in one pane's scrollback. Pure, like MobileAPI.swift: every
// tmux call goes through a `MobileTmux`, so the tests assert the exact argv.
//
// The rules, in one place:
// - An action is a case of `MobileAction`. Nothing else reaches tmux.
// - A target is looked up in the live tree. The phone names a thread, or a
//   host and a session; what goes to tmux is the tree's own pane id (`%12`)
//   or session id (`$3`), never a string the phone sent. tmux gives neither
//   to another pane or session, so a request that is sent twice cannot reach
//   a newer session of the same name. A session is not targeted by a pane:
//   the sessions of one group share their panes.
// - tmux reads an argument that ends in `;` as the end of one command and the
//   start of the next. No argument built here can end in one.
// - A name passes `MobileActions.name`. It is one argv item of its own.
// - A new session starts in a directory from `MobileActions.dirs`, in one of
//   the host's home tree (`MobileActions.inHome`), or at home.
// - A directory list is of the home tree only. On a remote host it is one
//   fixed script; the path is an argument of it, never a part of it.
// - An agent is one of two fixed words. Its first prompt is one quoted word
//   after it (`MobileActions.shellWord`): data to the pane's shell.
// - A kill needs `"confirm": true`, and names its session by a thread.
// - An archive is not a tmux call of this file: the Mac archives the window
//   the way its own sidebar does, so the archive can be undone there.
// - The manager's own session takes no action.

/// One tmux call on a host: whether it exited 0, and what it printed (its
/// errors too). nil when the host has no tmux to call.
typealias MobileTmux = (_ args: [String]) -> (ok: Bool, output: String)?

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
    case archiveWindow = "archive-window"

    /// Whether the action needs the `kill` switch on top of `sessionActions`.
    /// An archive does not: the Mac can undo it (Edit > Undo Archive Window),
    /// and a kill it cannot.
    var isKill: Bool {
        switch self {
        case .killSession, .killWindow, .killPane: return true
        case .newSession, .newWindow, .renameSession, .renameWindow, .zoomPane, .archiveWindow:
            return false
        }
    }
}

enum MobileActions {
    static let maxNameLength = 64
    /// The same cap in bytes: one character can be many bytes long.
    static let maxNameBytes = 128
    static let failed = "tmux did not run the action"
    /// The home directory on a remote host: its shell expands it.
    static let remoteHome = "~"
    /// The most directories a host offers for a new session.
    static let maxDirs = 50
    /// The most sub-directories one list carries.
    static let maxListedDirs = 200
    /// The most bytes of a first prompt, counted as the quoted word that is
    /// typed. A new pane's terminal holds 1024 bytes until its shell reads
    /// them and drops what comes after: the whole line stays well under that.
    static let maxPromptBytes = 900
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
        /// The agent to start in the window the command makes.
        var agent: AgentHandoff.Agent?
        /// The agent's first prompt, checked by `prompt`.
        var prompt: String?
        /// The thread whose window the Mac archives. No tmux command then.
        var archive: MobileThread?
    }

    /// Archive the window that holds a thread, the way the Mac's sidebar
    /// does. False when the window was not archived. May block.
    typealias Archive = (MobileThread) -> Bool

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
        guard !name.isEmpty, name.count <= maxNameLength, name.utf8.count <= maxNameBytes,
              !name.hasPrefix("-") else { return nil }
        for scalar in name.unicodeScalars {
            if scalar.isASCII {
                guard CharacterSet.alphanumerics.contains(scalar) || asciiPunctuation.contains(scalar)
                else { return nil }
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned,
                 .spaceSeparator:
                // The only space in a name is the ASCII one.
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

    /// Whether the last byte is `;`. tmux reads bytes: a `;` that a combining
    /// mark follows on screen is still not last, and one that is last counts
    /// whatever character Swift makes of it.
    static func endsInSemicolon(_ text: String) -> Bool {
        text.utf8.last == UInt8(ascii: ";")
    }

    /// A path from the live tree that can be a tmux `-c` argument. tmux
    /// expands `#{…}` in that argument, so a path with a `#` is left out, and
    /// so is one that ends in `;`.
    static func path(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\n"), !raw.contains("#"), !endsInSemicolon(raw),
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

    // MARK: The home tree

    /// What the directory list asks of a remote host.
    struct HostShell {
        /// The host's home directory. nil when the host does not say. May block.
        let home: () -> String?
        /// Run one command there, each argument its own word: what it
        /// printed, or nil when it failed. Blocks.
        let run: (_ argv: [String]) -> String?
    }

    /// `raw` as a directory of the tree under `home`, or nil: not absolute,
    /// outside the tree, with a `.` or `..` step or a dot-directory in it, or
    /// not a `path`. The tree is told by its bytes: two names that only
    /// compare equal are two directories.
    static func inHome(_ raw: String, home: String) -> String? {
        let steps = { (path: String) in path.split(separator: "/", omittingEmptySubsequences: true) }
        guard raw.hasPrefix("/"), home.hasPrefix("/") else { return nil }
        let top = steps(home), asked = steps(raw)
        guard !top.isEmpty, asked.count >= top.count,
              zip(top, asked).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }),
              !asked[top.count...].contains(where: { $0.hasPrefix(".") })
        else { return nil }
        return path("/" + asked.joined(separator: "/"))
    }

    /// Lists a directory of a remote host: its home as the disk has it, the
    /// directory as the disk has it, then the entries, a `/` after each
    /// directory. The directory is `$1`.
    static let listScript = #"(cd && pwd -P) && cd -- "$1" && pwd -P && ls -1p"#

    static func listArgv(_ dir: String) -> [String] { ["sh", "-c", listScript, "--", dir] }

    /// The sub-directories of `dir` in what `listScript` printed. nil when
    /// the directory is not in the home tree on the disk (a link led out of
    /// it), or the output is not the script's.
    static func parseListing(_ output: String, dir: String) -> [String]? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, inTree(lines[1], top: lines[0]) else { return nil }
        let names = lines.dropFirst(2).filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
        return listed(names, in: dir)
    }

    private static func inTree(_ path: String, top: String) -> Bool {
        guard top.hasPrefix("/"), top.utf8.count > 1 else { return false }
        return path.utf8.elementsEqual(top.utf8) || path.utf8.starts(with: (top + "/").utf8)
    }

    private static func listed(_ names: [String], in dir: String) -> [String] {
        let paths = names.filter { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") }
            .compactMap { path(dir + "/" + $0) }
        return Array(paths.sorted().prefix(maxListedDirs))
    }

    /// The sub-directories of `dir` on this Mac. A link is not one: it may
    /// lead out of the home tree. nil when `dir` is not a directory, or is
    /// not in the home tree on the disk.
    static func localListing(_ dir: String, home: String, files: FileManager = .default) -> [String]? {
        let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        guard inTree(real(dir), top: real(home)),
              let names = try? files.contentsOfDirectory(atPath: dir) else { return nil }
        return listed(names.filter {
            (try? files.attributesOfItem(atPath: dir + "/" + $0))?[.type] as? FileAttributeType == .typeDirectory
        }, in: dir)
    }

    /// The answer to `GET /api/hosts/<host>/dirs`. With no `path`: where the
    /// host's threads work, and its home, the place to start from. With one:
    /// its sub-directories, and where it is in the home tree. `home` is this
    /// Mac's home directory. Blocks on a remote host.
    static func browse(
        host name: String, path raw: String?, snapshot: MobileSnapshot, home: String = NSHomeDirectory(),
        shell: (Host) -> HostShell?, files: FileManager = .default
    ) -> MobileResponse {
        guard let host = snapshot.hosts.first(where: { $0.host.name == name })?.host,
              let offered = dirs(host: name, snapshot: snapshot) else { return .error(404, "not_found") }
        let remote = host.isLocal ? nil : shell(host)
        let top = (host.isLocal ? home : remote?.home()).flatMap { inHome($0, home: $0) }
        guard let raw else {
            var body: [String: Any] = ["dirs": offered]
            if let top { body["home"] = top }
            return .json(body)
        }
        guard let top else { return .error(503, "unavailable", message: unreachable) }
        guard let dir = inHome(raw, home: top) else { return .error(400, "bad_dir") }
        let found: [String]
        if host.isLocal {
            // In the tree by its name and not on the disk: a link led out.
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .error(404, "not_found")
            }
            guard let listed = localListing(dir, home: top, files: files) else { return .error(400, "bad_dir") }
            found = listed
        } else {
            guard let printed = remote?.run(listArgv(dir)),
                  printed.split(separator: "\n", omittingEmptySubsequences: false).count > 2
            else { return .error(404, "not_found") }
            guard let listed = parseListing(printed, dir: dir) else { return .error(400, "bad_dir") }
            found = listed
        }
        var body: [String: Any] = ["dirs": found, "path": dir, "home": top]
        if dir != top { body["parent"] = (dir as NSString).deletingLastPathComponent }
        return .json(body)
    }

    // MARK: The first prompt

    /// `text` as one word of a shell command: in single quotes, where a shell
    /// reads nothing. A `'` and a `\` are written outside the quotes, each
    /// after a `\`: fish reads a `\` inside them, and sh, bash and zsh do not.
    static func shellWord(_ text: String) -> String {
        var word = "'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "'": word += #"'\''"#
            case "\\": word += #"'\\'"#
            default: word.unicodeScalars.append(scalar)
            }
        }
        return word + "'"
    }

    /// The agent `fields` asks for, or nil for a bare shell. One of two
    /// fixed words: nothing of the phone's is the command.
    private static func agent(_ fields: [String: Any]) throws -> AgentHandoff.Agent? {
        guard let raw = fields["agent"], !(raw is NSNull) else { return nil }
        guard let asked = raw as? String,
              let known = [AgentHandoff.Agent.claude, .codex].first(where: { $0.launchCommand == asked })
        else { throw Refusal(400, "bad_agent") }
        return known
    }

    /// The first prompt `fields` gives `agent`, or nil for none. Text only:
    /// a control character is a key to the pane. A tab is a key to its shell
    /// too (it completes a word), so it is typed as a space. It does not
    /// start with `-`: the agent would read an option.
    private static func prompt(_ fields: [String: Any], agent: AgentHandoff.Agent?) throws -> String? {
        guard let raw = fields["prompt"], !(raw is NSNull) else { return nil }
        guard let asked = raw as? String else { throw Refusal(400, "bad_prompt") }
        let text = asked.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard agent != nil, !text.hasPrefix("-"), text.unicodeScalars.allSatisfy(MobileManager.isText)
        else { throw Refusal(400, "bad_prompt") }
        guard shellWord(text).utf8.count <= maxPromptBytes else { throw Refusal(413, "too_large") }
        return text
    }

    /// What is typed into the new pane to start `agent`.
    static func launch(_ agent: AgentHandoff.Agent, prompt: String?) -> String {
        prompt.map { agent.launchCommand + " " + shellWord($0) } ?? agent.launchCommand
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

    /// The session `fields` names, as one of its threads or as a host and a
    /// session name: a thread of it from the live tree. Every value read from
    /// the result is the tree's own. The phone's name only finds the row: two
    /// strings that compare equal can still differ in their bytes.
    private static func session(
        _ fields: [String: Any], snapshot: MobileSnapshot, byThreadOnly: Bool = false
    ) throws -> MobileThread {
        let found: MobileThread
        if fields["thread"] != nil || byThreadOnly {
            found = try thread(fields, snapshot: snapshot)
        } else {
            let host = try host(fields, snapshot: snapshot)
            guard let name = fields["session"] as? String else { throw Refusal(400, "bad_request") }
            guard !isManager(host, name) else { throw Refusal(403, "protected") }
            guard let first = snapshot.threads.first(where: { $0.host == host && $0.session == name })
            else { throw Refusal(404, "not_found") }
            found = try thread(["thread": first.id], snapshot: snapshot)
        }
        // A name that ends in `;` would end the tmux command where it stands.
        guard !endsInSemicolon(found.session) else { throw Refusal(404, "not_found") }
        // The id is the tree's: `$` and digits. Without one the session
        // cannot be told from another of its group.
        guard found.sessionId.hasPrefix("$"), found.sessionId.count > 1,
              found.sessionId.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
        else { throw Refusal(409, "failed") }
        return found
    }

    private static func confirmed(_ fields: [String: Any]) throws {
        // A JSON `true`, and nothing that only reads as one.
        guard let flag = fields["confirm"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue
        else { throw Refusal(400, "confirm_required") }
    }

    // MARK: Actions

    /// Check `action` against the live tree and build its tmux command.
    /// `home` is this Mac's home directory, and `hostHome` gives a remote
    /// host's. It is asked only for a directory no thread works in.
    static func plan(
        _ action: MobileAction, fields: [String: Any], snapshot: MobileSnapshot,
        home: String = NSHomeDirectory(), hostHome: (Host) -> String? = { _ in nil }
    ) throws -> Call {
        switch action {
        case .newSession:
            let host = try host(fields, snapshot: snapshot)
            var dir: String?
            if let raw = fields["dir"], !(raw is NSNull) {
                // A directory this server offered, in the server's own
                // bytes: two strings that compare equal can differ in theirs.
                // Or one of the host's home tree.
                guard let asked = raw as? String else { throw Refusal(400, "bad_dir") }
                if let offered = dirs(host: host.name, snapshot: snapshot)?.first(where: { $0 == asked }) {
                    dir = offered
                } else if let top = host.isLocal ? home : hostHome(host), let inside = inHome(asked, home: top) {
                    dir = inside
                } else {
                    throw Refusal(400, "bad_dir")
                }
            }
            let agent = try agent(fields)
            let prompt = try prompt(fields, agent: agent)
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
            // No directory is the home directory. Without `-c`, tmux starts
            // the session where its server was started.
            let start = dir ?? (host.isLocal ? path(home) : remoteHome)
            // The pane is asked for only when something is typed into it.
            return Call(
                host: host, argv: TmuxCommands.newSession(name: unique, dir: start, printTarget: agent != nil),
                made: .session(unique), agent: agent, prompt: prompt)
        case .newWindow:
            let target = try session(fields, snapshot: snapshot)
            let agent = try agent(fields)
            let prompt = try prompt(fields, agent: agent)
            return Call(
                host: target.host,
                argv: TmuxCommands.newWindow(
                    session: target.sessionId, cwd: path(target.cwd), printTarget: true),
                made: .window, agent: agent, prompt: prompt)
        case .renameSession:
            let target = try session(fields, snapshot: snapshot)
            guard let new = name(fields["name"]) else { throw Refusal(400, "bad_name") }
            guard new == target.session
                || !sessionNames(on: target.host, snapshot: snapshot).contains(new)
            else { throw Refusal(409, "exists") }
            return Call(
                host: target.host, argv: TmuxCommands.renameSession(from: target.sessionId, to: new))
        case .renameWindow:
            let thread = try thread(fields, snapshot: snapshot)
            guard let new = name(fields["name"]) else { throw Refusal(400, "bad_name") }
            // The pane id names its window: it does not move when tmux
            // renumbers windows, as an index does.
            return Call(host: thread.host, argv: TmuxCommands.renameWindow(target: thread.pane, to: new))
        case .killSession:
            // By a thread only: a name could be a newer session's by the time
            // a request that was sent twice arrives.
            let target = try session(fields, snapshot: snapshot, byThreadOnly: true)
            try confirmed(fields)
            return Call(host: target.host, argv: TmuxCommands.killSession(id: target.sessionId))
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
        case .archiveWindow:
            // No `confirm`: the Mac keeps the archive in its undo history.
            let thread = try thread(fields, snapshot: snapshot)
            return Call(host: thread.host, argv: [], archive: thread)
        }
    }

    /// Run one action. `tmux` gives the runner for a host, nil where there is
    /// none; `archive` is nil where no Mac archives a window. Blocks on the
    /// tmux call.
    static func perform(
        _ action: MobileAction, body: Data, snapshot: MobileSnapshot, home: String = NSHomeDirectory(),
        tmux: (Host) -> MobileTmux?, archive: Archive? = nil, hostHome: (Host) -> String? = { _ in nil }
    ) -> MobileResponse {
        guard let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .error(400, "bad_request")
        }
        let call: Call
        do {
            call = try plan(action, fields: fields, snapshot: snapshot, home: home, hostHome: hostHome)
        } catch let refusal as Refusal {
            return refusal.response
        } catch {
            return .error(400, "bad_request")
        }
        if let thread = call.archive {
            guard let archive else { return .error(503, "unavailable", message: unreachable) }
            return archive(thread) ? .json(["ok": true]) : .error(409, "failed", message: failed)
        }
        guard let run = tmux(call.host), let ran = run(call.argv) else {
            return .error(503, "unavailable", message: unreachable)
        }
        var result: [String: Any] = ["ok": true]
        guard ran.ok else {
            // The target went between the tree and the call. For a kill that
            // is the goal, reached; for anything else there is nothing to act on.
            guard TmuxCommands.killReachedGoalDespiteError(ran.output) else {
                return .error(409, "failed", message: failed)
            }
            guard action.isKill else { return .error(404, "not_found") }
            result["gone"] = true
            return .json(result)
        }
        switch call.made {
        case .nothing:
            return .json(result)
        case .window:
            break
        case .session(let name):
            result["session"] = name
            // A session with no agent prints nothing: the phone finds it by its name.
            guard call.agent != nil else { return .json(result) }
        }
        if let created = TmuxCommands.parseCreatedPane(ran.output) {
            result["thread"] = MobileSnapshot.threadID(host: call.host, pane: created.pane)
            // The window is made either way; without `agent` in the
            // answer the phone opens it as the shell it is. The prompt is
            // typed with the command, as one word of it: nothing is pasted
            // later into an agent that may not be up yet.
            if let agent = call.agent,
               run(TmuxCommands.startAgent(
                   target: created.pane, command: launch(agent, prompt: call.prompt)))?.ok == true {
                result["agent"] = agent.launchCommand
                // A remote Codex has no transcript on this Mac: it opens as
                // the terminal it is, and never as a chat that stays empty.
                result["chat"] = call.host.isLocal || agent == .claude
            }
        }
        return .json(result)
    }

    /// The thread an answer of `perform` says an agent with a chat was started in.
    static func startedThread(_ response: MobileResponse) -> String? {
        guard response.status == 200,
              let result = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              result["agent"] is String, result["chat"] as? Bool != false
        else { return nil }
        return result["thread"] as? String
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
    static let busy = "Another find is running"

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
        guard let ran = tmux?(PaneSearch.captureArgv(panes: [thread.pane])) else {
            return .error(503, "unavailable", message: MobileActions.unreachable)
        }
        guard ran.ok else {
            // The pane went between the tree and the capture.
            return TmuxCommands.killReachedGoalDespiteError(ran.output)
                ? .error(404, "not_found")
                : .error(503, "unavailable", message: MobileActions.unreachable)
        }
        return .json(result(query: query, capture: ran.output, thread: thread))
    }
}
