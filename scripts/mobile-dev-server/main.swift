import Foundation

// A stand-in for the app, for working on the phone server without touching the
// real one: it serves the phone API from a throwaway tmux server (`tmux -L`).
// Built and run by scripts/mobile-dev-server.sh; never shipped in the app.

/// tmux on a named socket, so the real tmux server is never read or changed.
struct SocketTransport: TmuxTransport {
    let tmuxPath: String
    let socket: String
    var timeout: TimeInterval = 4.0

    func command(forTmux args: [String]) -> (path: String, args: [String])? {
        (tmuxPath, ["-L", socket] + args)
    }

    func attachCommand(session: String) -> String? { nil }
}

/// No agent scan: the demo panes are plain shells.
struct NoStatus: AttentionStatusProvider {
    func statuses() -> [String: AttentionStatus] { [:] }
}

func value(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

guard let socket = value("--socket"), let port = value("--port").flatMap(Int.init),
      let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
          .first(where: FileManager.default.isExecutableFile(atPath:))
else {
    print("usage: mobile-dev-server --socket <tmux -L name> --port <n> [--remote-socket <name>]"
        + " [--static <dir>] [--chat <pane>=<transcript.jsonl>] [--login <login>] [--host <name>]"
        + " [--token <pairing token>] [--live] [--replies] [--manager-db <manager.db>]"
        + " [--log-dir <dir>]")
    exit(2)
}
let identity = MobileIdentity(
    login: value("--login") ?? "me@example.com", dnsName: value("--host") ?? "devmac.example.ts.net")
// `--chat %0=file.jsonl` gives one demo pane a transcript, as a local agent has.
let chat = (value("--chat") ?? "").split(separator: "=", maxSplits: 1).map(String.init)

// Both services are built as remote hosts with a local transport: a service
// for `Host.local` would write the real session-recovery snapshot.
func service(_ name: String, socket: String) -> TmuxService {
    TmuxService(
        host: Host(name: name, sshAlias: name),
        transport: SocketTransport(tmuxPath: tmuxPath, socket: socket),
        runner: ProcessCommandRunner(), statusProvider: NoStatus())
}
let devbox = Host(name: "devbox", sshAlias: "devbox")
let local = service("demo", socket: socket)
let remote = value("--remote-socket").map { service("devbox", socket: $0) }

// `--manager-db <path>` stands in for the Maestro: its review list is read from
// a DB that `mux` writes (run `mux` with MUX_MANAGER_DB set to the same path),
// and the session snapshot `mux point` checks is published to it. There is no
// Maestro pane, so a turn is refused.
let store = value("--manager-db").flatMap { try? ManagerStore(dbPath: $0) }
let manager = store.map { store in
    MobileServer.Manager(
        pane: { (.idle, nil) },
        send: { _, _, completion in completion(.refused("The dev server has no Maestro pane")) },
        dismiss: { key in try? store.dismiss(key: key) },
        answered: { key, label, at in try? store.recordAnswer(key: key, label: label, at: at) },
        screen: { _ in nil })
}

/// The review list as the phone's board: what `ManagerSnapshot.mobileBoard` gives the app.
func board(_ store: ManagerStore) -> MobileManagerBoard {
    MobileManagerBoard(items: ((try? store.reviewItems()) ?? []).map { review in
        MobileManagerItem(
            kind: .review, key: review.key, title: review.session, detail: review.text,
            severity: review.severity, at: review.updatedAt,
            link: review.session.isEmpty ? nil : .open(
                session: review.session, window: review.window, pane: nil, host: review.host),
            pointer: review.isPointer, card: MobileCard(review))
    })
}

let server = MobileServer(
    staticRoot: value("--static").map { URL(fileURLWithPath: $0, isDirectory: true) },
    sources: MobileServer.Sources(
        screen: { thread, lines in
            (thread.host.isLocal ? local : remote)?.captureScrollback(target: thread.pane, lines: lines)
        },
        transcript: { thread in
            chat.count == 2 && thread.pane == chat[0] ? (chat[1], false) : nil
        },
        // The demo panes have no hooks: a pane's state is the tree's, so a
        // reply goes only into a pane that shows an agent's input box.
        pane: { thread in
            (thread.host.isLocal ? local : remote)?.phonePane(target: thread.pane) {
                MobilePaneState(status: $0.status, since: $0.since)
            }
        },
        terminal: { thread, target in
            (thread.host.isLocal ? local : remote)?.phoneTerminal(target)
        }),
    manager: manager,
    // `--log-dir` keeps the phone's own log there, as the app does.
    logDirectory: value("--log-dir").map { URL(fileURLWithPath: $0, isDirectory: true) })

func snapshot(stats: HostStats?) -> MobileSnapshot {
    var sessions = local.loadTree() ?? []
    if chat.count == 2 {
        for s in sessions.indices {
            for w in sessions[s].windows.indices {
                for p in sessions[s].windows[w].panes.indices
                where sessions[s].windows[w].panes[p].id == chat[0] {
                    sessions[s].windows[w].panes[p].claudeSessionId = "demo"
                    sessions[s].windows[w].panes[p].attention = .busy
                }
            }
        }
    }
    var inputs = [MobileHostInput(
        host: .local, colorHex: "#3291ff", reachability: .reachable, stats: stats, sessions: sessions)]
    if let remote {
        inputs.append(MobileHostInput(
            host: devbox, colorHex: "#f5a623", reachability: .reachable, stats: nil,
            sessions: remote.loadTree() ?? []))
    }
    return MobileSnapshot.build(inputs)
}

// `--live` and `--replies` turn those features on, as their switches in
// Settings do. The Maestro's routes are on when there is a DB to read.
var capabilities = Set<MobileCapability>()
if CommandLine.arguments.contains("--live") { capabilities.insert(.liveTerminal) }
if CommandLine.arguments.contains("--replies") { capabilities.insert(.replies) }
if store != nil { capabilities.insert(.manager) }
server.configure(MobileConfig(capabilities: capabilities))
let token = value("--token") ?? "demo-token"
server.start(port: port, identity: identity, token: token) { result in
    switch result {
    case .success(let bound):
        print("listening on http://127.0.0.1:\(bound) as \(identity.login) @ \(identity.dnsName)"
            + ", token \(token)")
        fflush(stdout)
    case .failure(let error):
        print("could not listen: \(error)")
        exit(1)
    }
}
// The app pushes its sidebar poll into the server; here a timer stands in.
// Host stats run no tmux command, so a local-host service is safe for them.
let stats = TmuxService(
    host: .local, transport: SocketTransport(tmuxPath: tmuxPath, socket: socket),
    runner: ProcessCommandRunner(), statusProvider: NoStatus()).hostStats()
let timer = DispatchSource.makeTimerSource(queue: .global())
timer.schedule(deadline: .now(), repeating: 1.5)
timer.setEventHandler {
    server.update(snapshot(stats: stats))
    guard let store else { return }
    try? store.replaceSessions((local.loadTree() ?? []).map { session in
        ManagerSessionRow(
            name: session.name, host: Host.local.name, attached: session.attached,
            state: ManagerSessionRow.State(.unknown), windows: session.windows.count,
            panes: session.windows.reduce(0) { $0 + $1.panes.count },
            cwd: session.windows.first?.cwd ?? "", windowIndexes: session.windows.map(\.index))
    })
    server.updateManager(board(store))
}
timer.resume()
dispatchMain()
