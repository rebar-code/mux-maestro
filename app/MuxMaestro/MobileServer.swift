import Foundation
import Network

/// The phone's HTTP server: a loopback-only listener that serves the static
/// bundle and the API. `tailscale serve` is the only way in from another
/// device; `MobileAPI.authorize` checks every request it forwards.
///
/// The server never polls. `update(_:)` hands it the tree the sidebar already
/// loads, and it pushes a Server-Sent Event when the bytes it would serve change.
final class MobileServer {
    /// The two reads that go past the snapshot. Both are called off the server
    /// queue and may block.
    struct Sources {
        /// The pane's last `lines` lines of scrollback and its screen, with
        /// colour escapes.
        var screen: (MobileThread, _ lines: Int) -> String?
        /// The thread's transcript file, and whether it is a Codex rollout.
        var transcript: (MobileThread) -> (path: String, codex: Bool)?
        /// The thread's pane, to type into. nil where nothing can be typed
        /// (the dev server): the reply routes then answer 503.
        var pane: (MobileThread) -> MobilePaneIO? = { _ in nil }
        /// tmux on a host, for session actions and find. nil where there is
        /// none (the dev server): those routes then answer 503. May block.
        var tmux: (Host) -> MobileTmux? = { _ in nil }
        /// A session action changed the tree: load it again now.
        var changed: () -> Void = {}
        /// The home folder whose skills and commands the `/` list reads.
        var home = NSHomeDirectory()
        /// What the thread's transcript says its agent made. nil where no
        /// transcript is read (the dev server): the artifact routes then
        /// answer 503. May block.
        var artifacts: ((MobileThread) -> MobileArtifactSource?)? = nil
        /// What the thread's pane has running, or nil once the pane has gone.
        /// nil where nothing is scanned (the dev server): 503. May block.
        var running: ((MobileThread) -> RunningSet?)? = nil
    }

    /// The local ports published on the tailnet, as `PhoneLink` keeps them.
    /// nil where there is no tailnet (the dev server): the server routes then
    /// answer 503. Every call may block.
    struct Serving {
        var open: (_ port: Int, _ https: Bool, _ thread: String, _ label: String) -> MobileServing.Opened
        /// False when this app has no mapping on the port.
        var close: (_ port: Int) -> Bool
        var list: () -> [MobilePortMapping]
    }

    /// The manager pane, as the app reaches it. nil where there is no manager
    /// (the dev server): the manager routes then answer 503.
    struct Manager {
        /// The pane's status and its transcript file. Called off the server
        /// queue and may block.
        var pane: () -> (status: MobileManagerStatus, transcript: String?)
        /// Run one turn, the way the Mac rail does. Both callbacks may come on
        /// any queue; `completion` comes exactly once.
        var send: (
            _ text: String, _ onDelta: @escaping (String) -> Void,
            _ completion: @escaping (ManagerTurnOutcome) -> Void
        ) -> Void
        var dismiss: (_ key: String) -> Void
        /// The pane's last `lines` lines and its screen, with colour escapes.
        /// Called off the server queue and may block.
        var screen: (_ lines: Int) -> String?
        /// The manager's pane, to answer a prompt it waits on: its tmux
        /// target and what may be done to it. nil where there is none.
        var io: () -> (target: String, io: MobilePaneIO)? = { nil }
    }

    /// Speech for the phone: the Mac's own engine. nil where there is none
    /// (the dev server): the voice routes then answer 503.
    struct Voice {
        var speech: VoiceSpeech
        /// Load the models a take will need, ahead of its audio. `speaker` off
        /// leaves the read-back model alone.
        var warm: (_ speaker: Bool) -> Void
    }

    /// Bounds on what one listener holds, so a client that opens connections
    /// and never reads cannot take the app's memory or descriptors.
    struct Limits {
        /// Connections held at once; one more is closed on arrival.
        var maxConnections = 64
        /// A connection that is not an event stream is closed after this long
        /// without a request.
        var idleTimeout: TimeInterval = 30
        /// Bytes a stream may have queued and unsent before it is closed. A
        /// phone that fell asleep reconnects and gets the current lists.
        var streamBacklog = 1_048_576
        /// The same bound for a voice stream, which carries the reply's audio:
        /// a few minutes of speech, synthesized faster than it is sent.
        var voiceBacklog = 16_777_216
        /// A turn stream with nothing to say gets a comment line this often,
        /// so the phone can tell a quiet turn from a dead connection.
        var turnPing: TimeInterval = 15
        /// Finds that may run at once. Each one captures a pane's scrollback,
        /// and every phone comes in through the same proxy, so the bound is
        /// on the server and not on one caller.
        var maxFinds = 2
        /// How often the manager pane is read for its spinner line while a
        /// turn runs.
        var spinnerPoll: TimeInterval = 1
    }

    enum StartError: Error, Equatable {
        case badPort
        case listener(String)
    }

    /// One accepted connection. Confined to `queue`.
    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        /// The response has no end: the connection takes no more requests.
        var streaming = false
        /// It holds the event stream, so it gets every broadcast.
        var events = false
        var lastWrite = Date()
        /// When the connection last sent a request or was answered.
        var lastActive = Date()
        /// Bytes handed to the connection that it has not sent yet.
        var pending = 0
        /// Runs once when the connection goes away, however it does.
        var onDrop: (() -> Void)?
        /// Its own backlog limit; nil for the listener's `streamBacklog`.
        var backlog: Int?

        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// A stream with nothing to say still gets a comment line this often, so a
    /// proxy does not drop it as idle.
    static let pingInterval: TimeInterval = 15
    /// How long after its last request a phone still counts as looking.
    static let clientWindow: TimeInterval = 60

    private let staticRoot: URL?
    private let sources: Sources
    private let limits: Limits
    private let manager: Manager?
    private let voice: Voice?
    private let serving: Serving?
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.mobile")
    private let work = DispatchQueue(label: "is.rebar.muxmaestro.mobile.work", attributes: .concurrent)

    // Confined to `queue`.
    private var listener: NWListener?
    private var identity: MobileIdentity?
    /// The port the listener is bound to: the one port no mapping may publish.
    private var boundPort: Int?
    private var token: String?
    private var shellPolicyCache: (shell: Data, policy: String)?
    private var snapshot = MobileSnapshot()
    private var threadsBody = MobileSnapshot().threadsJSON()
    private var hostsBody = MobileSnapshot().hostsJSON()
    private var config = MobileConfig()
    private var clients: [ObjectIdentifier: Client] = [:]
    private var board = MobileManagerBoard()
    private var turn: MobileManagerTurn?
    /// The voice turn in flight. One at a time: the Mac has one engine.
    private var voiceTurn: MobileVoiceTurn?
    private var voiceStarting = false
    /// Threads with a write on its way to their pane. One at a time per
    /// thread: a paste and its Enter are not interleaved with another's.
    private var writing = Set<String>()
    /// Finds that are capturing a pane now.
    private var finds = 0
    /// Per thread: a counter that goes into a prompt's id, and the words of
    /// the prompt last seen on its pane. See `sequence(of:)`.
    private var promptSequence: [String: Int] = [:]
    private var promptSeen: [String: String] = [:]
    /// The last `manager` event's state, without the reply text: a reply
    /// grows by `manager-delta` events, not by sending the board again.
    private var managerKey = MobileManager.liveJSON(
        board: MobileManagerBoard(), snapshot: MobileSnapshot(), turn: nil)
    /// Turns this server started that have not ended. The app tells the server
    /// about a running turn too, but only once the turn is on its way.
    private var phoneTurns = 0
    /// Counts turns, so a spinner poll from an earlier turn stops.
    private var turnSerial = 0

    private let activityLock = NSLock()
    private var lastRequestAt = Date.distantPast
    private var streamCount = 0

    init(
        staticRoot: URL?, sources: Sources, limits: Limits = Limits(), manager: Manager? = nil,
        voice: Voice? = nil, serving: Serving? = nil
    ) {
        self.staticRoot = staticRoot
        self.sources = sources
        self.limits = limits
        self.manager = manager
        self.voice = voice
        self.serving = serving
    }

    /// Whether a phone asked for something lately or holds an event stream.
    /// The app uses it to keep host stats fresh only while someone reads them.
    var hasRecentClient: Bool {
        activityLock.lock()
        defer { activityLock.unlock() }
        return streamCount > 0 || Date().timeIntervalSince(lastRequestAt) < Self.clientWindow
    }

    // MARK: Lifecycle

    /// Listen on `127.0.0.1:port` (0 picks a free port). `completion` gets the
    /// bound port once, on the server queue. `token` is the pairing token every
    /// API request must carry.
    func start(
        port: Int, identity: MobileIdentity, token: String,
        completion: @escaping (Result<Int, StartError>) -> Void
    ) {
        queue.async { [self] in
            stopNow()
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)),
                  (0...65535).contains(port)
            else { return completion(.failure(.badPort)) }
            let parameters = NWParameters.tcp
            // Loopback only: no other interface ever accepts a connection.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            parameters.allowLocalEndpointReuse = true
            let listener: NWListener
            do { listener = try NWListener(using: parameters) } catch {
                return completion(.failure(.listener(error.localizedDescription)))
            }
            var reported = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    guard !reported else { return }
                    reported = true
                    let bound = Int(listener?.port?.rawValue ?? nwPort.rawValue)
                    if self?.listener === listener { self?.boundPort = bound }
                    completion(.success(bound))
                case .failed(let error):
                    listener?.cancel()
                    if self?.listener === listener { self?.listener = nil }
                    guard !reported else { return }
                    reported = true
                    completion(.failure(.listener(error.localizedDescription)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.identity = identity
            self.token = token
            self.listener = listener
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.sync { stopNow() }
    }

    private func stopNow() {
        listener?.cancel()
        listener = nil
        identity = nil
        boundPort = nil
        token = nil
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        setStreamCount(0)
    }

    /// Replace the pairing token. Every open stream is closed: a phone holding
    /// the old token is signed out at once.
    func setToken(_ token: String) {
        queue.async {
            guard self.listener != nil else { return }
            self.token = token
            for client in self.clients.values where client.streaming { self.drop(client) }
        }
    }

    /// The latest tree. Pushes an event to open streams when a body changed.
    func update(_ snapshot: MobileSnapshot) {
        queue.async {
            guard self.listener != nil else { return }
            // A pane that starts or stops waiting ends the prompt that was
            // on it: the next one seen there is a new prompt.
            for thread in snapshot.threads
            where (thread.status == .waiting) != (self.snapshot.thread(id: thread.id)?.status == .waiting) {
                self.promptSeen[thread.id] = nil
            }
            let live = Set(snapshot.threads.map(\.id)).union([Self.managerKey])
            self.promptSequence = self.promptSequence.filter { live.contains($0.key) }
            self.promptSeen = self.promptSeen.filter { live.contains($0.key) }
            self.snapshot = snapshot
            let threads = snapshot.threadsJSON()
            let hosts = snapshot.hostsJSON()
            if threads != self.threadsBody {
                self.threadsBody = threads
                self.broadcast(Self.event("threads", threads))
            }
            if hosts != self.hostsBody {
                self.hostsBody = hosts
                self.broadcast(Self.event("hosts", hosts))
            }
            // A card names its thread by id, and the ids come from the tree.
            self.managerChanged()
            let now = Date()
            for client in self.clients.values
            where client.streaming && now.timeIntervalSince(client.lastWrite) >= Self.pingInterval {
                self.write(Data(": ping\n\n".utf8), to: client)
            }
            self.dropIdle(now: now)
        }
    }

    /// The rows of the Mac rail. Kept while the listener is off too, so the
    /// first request after it starts has them.
    func updateManager(_ board: MobileManagerBoard) {
        queue.async {
            self.board = board
            self.managerChanged()
        }
    }

    /// A manager turn started, on the Mac or from a phone. Open streams follow
    /// it, so every screen shows the one conversation.
    func managerTurnBegan(_ prompt: String) {
        queue.async {
            self.turn = MobileManagerTurn(prompt: prompt)
            self.managerChanged()
            self.turnSerial += 1
            self.pollSpinner(serial: self.turnSerial)
        }
    }

    func managerTurnAppended(_ delta: String) {
        queue.async {
            guard !delta.isEmpty, self.turn != nil else { return }
            self.turn?.reply += delta
            guard self.config.allows(.manager) else { return }
            self.broadcast(Self.event("manager-delta", Self.json(["text": delta])))
        }
    }

    func managerTurnEnded() {
        queue.async {
            self.turn = nil
            self.managerChanged()
        }
    }

    /// How many pane lines are read to find the spinner line.
    private static let spinnerLines = 40

    /// While a turn runs, read the pane's own spinner line and send it on when
    /// it changes, so the phone shows what the agent shows.
    private func pollSpinner(serial: Int) {
        guard let manager else { return }
        queue.asyncAfter(deadline: .now() + limits.spinnerPoll) { [weak self] in
            guard let self, self.turn != nil, self.turnSerial == serial else { return }
            self.work.async { [weak self] in
                let line = manager.screen(Self.spinnerLines).flatMap(MobileSpinner.line(in:))
                self?.queue.async {
                    guard let self, self.turn != nil, self.turnSerial == serial else { return }
                    if line != self.turn?.spinner {
                        self.turn?.spinner = line
                        if self.config.allows(.manager) {
                            self.broadcast(Self.event(
                                "manager-spinner", Self.json(["text": line ?? NSNull()])))
                        }
                    }
                    self.pollSpinner(serial: serial)
                }
            }
        }
    }

    private func managerChanged() {
        let key = MobileManager.liveJSON(
            board: board, snapshot: snapshot, turn: turn.map { MobileManagerTurn(prompt: $0.prompt) })
        guard key != managerKey else { return }
        managerKey = key
        if config.allows(.manager) { broadcast(Self.event("manager", managerBody)) }
    }

    /// The `manager` event's data: the cards and the turn with its reply so far.
    private var managerBody: Data {
        MobileManager.liveJSON(board: board, snapshot: snapshot, turn: turn)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The Settings the phone is held to. Applies to the next request, and tells
    /// open streams so the phone hides what was switched off.
    func configure(_ config: MobileConfig) {
        queue.async {
            guard config != self.config else { return }
            let managerOn = config.allows(.manager) && !self.config.allows(.manager)
            self.config = config
            self.broadcast(Self.event("config", config.json()))
            if managerOn { self.broadcast(Self.event("manager", self.managerBody)) }
        }
    }

    // MARK: Connections

    /// Close connections that hold a slot and ask for nothing. Runs on each
    /// tree update and each new connection, so it needs no timer.
    private func dropIdle(now: Date = Date()) {
        for client in clients.values
        where !client.streaming && now.timeIntervalSince(client.lastActive) >= limits.idleTimeout {
            drop(client)
        }
    }

    private func accept(_ connection: NWConnection) {
        dropIdle()
        guard clients.count < limits.maxConnections else { return connection.cancel() }
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .failed, .cancelled:
                if let client { self?.drop(client) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.connection.cancel()
        client.onDrop?()
        client.onDrop = nil
        setStreamCount(clients.values.filter(\.events).count)
    }

    private func setStreamCount(_ count: Int) {
        activityLock.lock()
        streamCount = count
        activityLock.unlock()
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let data, !data.isEmpty, !client.streaming { client.buffer.append(data) }
            if isComplete || error != nil { return self.drop(client) }
            // An event stream takes no more requests; keep reading only to see
            // the phone hang up.
            if client.streaming { return self.receive(client) }
            self.drain(client)
        }
    }

    /// Answer the request at the front of the buffer, then the next one.
    private func drain(_ client: Client) {
        // A take's megabytes are held only for a caller that is already let in.
        var refusal = "bad_request"
        let parsed = MobileHTTP.parse(client.buffer) { [identity, token, config] request in
            if MobileAPI.authorize(request, identity: identity) != .allowed {
                refusal = "forbidden"
                return 403
            }
            guard MobileAPI.hasToken(request, token: token) else {
                refusal = "unpaired"
                return 401
            }
            switch MobileAPI.route(request, config: config) {
            case .disabled:
                // A feature that is off holds no megabytes either.
                refusal = "disabled"
                return 403
            case .api(.upload)
            where (request.header("content-length").flatMap(Int.init) ?? 0) > config.uploadLimit:
                // An upload past the limit in Settings is refused before it is read.
                refusal = "too_large"
                return 413
            default:
                return nil
            }
        }
        switch parsed {
        case .incomplete:
            receive(client)
        case .invalid(let status):
            send(.error(status, refusal), to: client, head: false, close: true)
        case .request(let request, let consumed):
            client.lastActive = Date()
            client.buffer.removeFirst(consumed)
            respond(to: request, client: client)
        }
    }

    private func send(_ response: MobileResponse, to client: Client, head: Bool, close: Bool = false) {
        client.lastWrite = Date()
        client.lastActive = client.lastWrite
        client.connection.send(
            content: response.serialized(head: head, keepAlive: !close),
            completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client else { return }
                if close || error != nil { return self.drop(client) }
                self.drain(client)
            })
    }

    /// Queue `data` on an event stream. A stream that is not being read is
    /// closed once its unsent bytes pass the backlog limit.
    private func write(_ data: Data, to client: Client, close: Bool = false) {
        guard client.pending + data.count <= client.backlog ?? limits.streamBacklog else {
            return drop(client)
        }
        client.lastWrite = Date()
        client.pending += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let client else { return }
            client.pending -= data.count
            if close || error != nil { self?.drop(client) }
        })
    }

    private func broadcast(_ data: Data) {
        for client in clients.values where client.events { write(data, to: client) }
    }

    static func event(_ name: String, _ json: Data) -> Data {
        var data = Data("event: \(name)\ndata: ".utf8)
        data.append(json)
        data.append(Data("\n\n".utf8))
        return data
    }

    // MARK: Requests

    private func respond(to request: MobileRequest, client: Client) {
        let head = request.method == "HEAD"
        guard MobileAPI.authorize(request, identity: identity) == .allowed else {
            return send(.error(403, "forbidden"), to: client, head: head)
        }
        // The API also needs the pairing token; the static bundle does not.
        guard !MobileAPI.needsToken(request) || MobileAPI.hasToken(request, token: token) else {
            return send(.error(401, "unpaired"), to: client, head: head)
        }
        activityLock.lock()
        lastRequestAt = Date()
        activityLock.unlock()

        switch MobileAPI.route(request, config: config) {
        case .api(let endpoint):
            respond(to: endpoint, request: request, client: client, head: head)
        case .disabled:
            send(.error(403, "disabled"), to: client, head: head)
        case .asset(let path):
            send(asset(path), to: client, head: head)
        case .methodNotAllowed:
            send(.error(405, "method_not_allowed"), to: client, head: head)
        case .notFound:
            send(.error(404, "not_found"), to: client, head: head)
        case .unknownAction:
            send(.error(400, "bad_action"), to: client, head: head)
        }
    }

    private func respond(
        to endpoint: MobileEndpoint, request: MobileRequest, client: Client, head: Bool
    ) {
        switch endpoint {
        case .config:
            send(.json(data: config.json()), to: client, head: head)
        case .threads:
            send(.json(data: threadsBody), to: client, head: head)
        case .hosts:
            send(.json(data: hostsBody), to: client, head: head)
        case .events:
            startStream(client)
        case .chat(let id, let after):
            guard let thread = snapshot.thread(id: id), thread.hasChat else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            reply(to: client) { [sources] in
                guard let file = sources.transcript(thread),
                      let page = MobileChat.read(path: file.path, codex: file.codex, after: after)
                else { return .error(404, "not_found") }
                return .json(page.json)
            }
        case .screen(let id, let lines):
            guard let thread = snapshot.thread(id: id) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            reply(to: client) { [sources] in
                Self.screenResponse(sources.screen(thread, lines), lines: lines, request: request)
            }
        case .managerChat(let after):
            guard let manager else {
                return send(.error(503, "unavailable", message: MobileManager.offMessage),
                            to: client, head: head)
            }
            reply(to: client) {
                // No transcript yet is an empty chat, not a missing thread.
                let page = manager.pane().transcript
                    .flatMap { MobileChat.read(path: $0, codex: false, after: after) }
                return .json((page ?? MobileChatPage()).json)
            }
        case .managerScreen(let lines):
            guard let manager else {
                return send(.error(503, "unavailable", message: MobileManager.offMessage),
                            to: client, head: head)
            }
            reply(to: client) {
                Self.screenResponse(manager.screen(lines), lines: lines, request: request)
            }
        case .manager:
            guard let manager else {
                return send(.error(503, "unavailable", message: MobileManager.offMessage),
                            to: client, head: head)
            }
            let (board, snapshot, turn) = (board, snapshot, turn)
            reply(to: client) {
                .json(MobileManager.body(
                    board: board, snapshot: snapshot, turn: turn, status: manager.pane().status))
            }
        case .managerText:
            let field = MobileManager.text(in: request.body)
            guard case .value(let text) = field else {
                return send(field.refusal ?? .error(400, "bad_request"), to: client, head: head)
            }
            startTurn(text, client: client)
        case .managerDismiss:
            let field = MobileManager.key(in: request.body)
            guard case .value(let key) = field else {
                return send(field.refusal ?? .error(400, "bad_request"), to: client, head: head)
            }
            guard let manager else {
                return send(.error(503, "unavailable", message: MobileManager.offMessage),
                            to: client, head: head)
            }
            // Only a review item on the board can be dismissed: the key is
            // never passed on as it came.
            guard MobileManager.hasReview(key, in: board) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            manager.dismiss(key)
            send(.json(["ok": true]), to: client, head: head)
        case .managerPrompt:
            guard let (manager, _, io) = managerPane(client) else { return }
            reply(to: client) {
                .json(MobileReply.promptBody(state: Self.state(manager.pane().status), io: io))
            }
        case .managerAnswer:
            guard let answer = MobileReply.answer(in: request.body) else {
                return send(.error(400, "bad_request"), to: client, head: head)
            }
            managerWrite(client) { target, io, state in
                MobileReply.answer(
                    prompt: answer.prompt, option: answer.option, target: target, io: io, state: state)
            }
        case .managerKey:
            guard let press = MobileReply.key(in: request.body) else {
                return send(.error(400, "bad_key"), to: client, head: head)
            }
            managerWrite(client) { target, io, state in
                MobileReply.press(
                    press.key, prompt: press.prompt, terminal: press.terminal, target: target, io: io,
                    state: state)
            }
        case .voice:
            startVoice(request, client: client)
        case .voiceReplay:
            startReplay(request, client: client)
        case .voiceWarm:
            guard let voice else {
                return send(.error(503, "unavailable", message: MobileVoice.unavailable),
                            to: client, head: head)
            }
            voice.warm(request.query["speaker"] == "1")
            send(.json(["ok": true]), to: client, head: head)
        case .text(let id):
            // The one filter for text that is pasted into a terminal.
            let field = MobileManager.text(in: request.body)
            guard case .value(let text) = field else {
                return send(field.refusal ?? .error(400, "bad_request"), to: client, head: head)
            }
            write(to: id, client: client) { thread, io, state in
                MobileReply.send(text, target: thread.pane, io: io, state: state)
            }
        case .key(let id):
            guard let press = MobileReply.key(in: request.body) else {
                return send(.error(400, "bad_key"), to: client, head: head)
            }
            // Under the thread's lock, like every write: a key is not pressed
            // between another write's paste and its Enter.
            write(to: id, client: client) { thread, io, state in
                MobileReply.press(
                    press.key, prompt: press.prompt, terminal: press.terminal, target: thread.pane,
                    io: io, state: state())
            }
        case .prompt(let id):
            guard let (_, io) = pane(id, client: client) else { return }
            reply(to: client) { [weak self] in
                .json(MobileReply.promptBody(state: self?.state(of: id, io: io), io: io))
            }
        case .answer(let id):
            guard let answer = MobileReply.answer(in: request.body) else {
                return send(.error(400, "bad_request"), to: client, head: head)
            }
            write(to: id, client: client) { thread, io, state in
                MobileReply.answer(
                    prompt: answer.prompt, option: answer.option, target: thread.pane, io: io,
                    state: state())
            }
        case .commands(let id):
            guard let thread = snapshot.thread(id: id) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            reply(to: client) { [sources] in
                .json(["commands": MobileCommands.list(for: thread, home: sources.home).map(\.json)])
            }
        case .upload(let id, let name, let paste):
            let limit = config.uploadLimit
            write(to: id, client: client) { thread, io, state in
                MobileReply.upload(
                    request.body, name: name, thread: thread, io: io, limit: limit, paste: paste,
                    state: state)
            }
        case .tmux(let action):
            // Checked against the tree as it is now; tmux runs off the queue.
            let snapshot = snapshot
            reply(to: client) { [sources] in
                let response = MobileActions.perform(
                    action, body: request.body, snapshot: snapshot, home: sources.home,
                    tmux: sources.tmux)
                if response.status == 200 { sources.changed() }
                return response
            }
        case .dirs(let host):
            guard let dirs = MobileActions.dirs(host: host, snapshot: snapshot) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            send(.json(["dirs": dirs]), to: client, head: head)
        case .find(let id, let raw):
            guard let query = MobileFind.query(raw) else {
                return send(.error(400, "bad_query"), to: client, head: head)
            }
            guard let thread = snapshot.thread(id: id) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            guard finds < limits.maxFinds else {
                return send(.error(409, "busy", message: MobileFind.busy), to: client, head: head)
            }
            finds += 1
            work.async { [weak self, weak client, sources] in
                let response = MobileFind.search(
                    thread: thread, query: query, tmux: sources.tmux(thread.host))
                self?.queue.async {
                    guard let self else { return }
                    // Counted down whether or not the phone still listens.
                    self.finds -= 1
                    guard let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                    self.send(response, to: client, head: false)
                }
            }
        case .artifacts(let id):
            guard let thread = snapshot.thread(id: id) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            guard let source = sources.artifacts else {
                return send(.error(503, "unavailable"), to: client, head: head)
            }
            reply(to: client) { MobileArtifacts.list(thread: thread, source: source) }
        case .file(let id, let artifact):
            guard let thread = snapshot.thread(id: id) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            guard let source = sources.artifacts else {
                return send(.error(503, "unavailable"), to: client, head: head)
            }
            // The id is looked up in the thread's own list; it is never a path.
            reply(to: client) { MobileArtifacts.file(id: artifact, thread: thread, source: source) }
        case .running(let id):
            guard let thread = snapshot.thread(id: id) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            guard let running = sources.running else {
                return send(.error(503, "unavailable"), to: client, head: head)
            }
            let ownPort = boundPort
            reply(to: client) {
                guard let set = running(thread) else { return .error(404, "not_found") }
                return .json(MobileServing.runningJSON(set, ownPort: ownPort))
            }
        case .servers:
            guard let serving, let identity else {
                return send(.error(503, "unavailable"), to: client, head: head)
            }
            reply(to: client) { .json(MobileServing.listJSON(serving.list(), identity: identity)) }
        case .serverOpen:
            openServer(request, client: client)
        case .serverClose:
            guard let port = MobileServing.closeRequest(request.body) else {
                return send(.error(400, "bad_request"), to: client, head: head)
            }
            guard let serving else {
                return send(.error(503, "unavailable"), to: client, head: head)
            }
            reply(to: client) {
                serving.close(port) ? .json(["ok": true]) : .error(404, "not_found")
            }
        }
    }

    // MARK: The manager's own prompt

    /// The lock and the prompt counter of the manager's pane are kept under
    /// this name; no thread id has this shape.
    private static let managerKey = "manager"

    /// The manager's pane, to answer what it waits on. Answers the client and
    /// returns nil when there is none.
    private func managerPane(_ client: Client) -> (manager: Manager, target: String, io: MobilePaneIO)? {
        guard let manager, var pane = manager.io() else {
            send(.error(503, "unavailable", message: MobileManager.offMessage), to: client, head: false)
            return nil
        }
        pane.io.sequence = sequence(of: Self.managerKey)
        return (manager, pane.target, pane.io)
    }

    /// What the manager's pane is doing, as the reply rules take it. nil when
    /// the manager is not running.
    private static func state(_ status: MobileManagerStatus) -> MobilePaneState? {
        switch status {
        case .off: return nil
        case .unknown: return MobilePaneState(status: .unknown)
        case .idle: return MobilePaneState(status: .idle)
        case .busy: return MobilePaneState(status: .busy)
        case .waiting: return MobilePaneState(status: .waiting)
        }
    }

    /// One write to the manager's pane, off the server queue and one at a time.
    private func managerWrite(
        _ client: Client, _ body: @escaping (String, MobilePaneIO, MobilePaneState?) -> MobileResponse
    ) {
        guard let (manager, target, io) = managerPane(client) else { return }
        guard writing.insert(Self.managerKey).inserted else {
            return send(.error(409, "busy", message: MobileReply.sending), to: client, head: false)
        }
        work.async { [weak self, weak client] in
            let state = Self.state(manager.pane().status)
            let response = state == nil
                ? MobileResponse.error(503, "unavailable", message: MobileManager.offMessage)
                : body(target, io, state)
            self?.queue.async {
                guard let self else { return }
                self.writing.remove(Self.managerKey)
                guard let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                self.send(response, to: client, head: false)
            }
        }
    }

    /// Publish one local port on the tailnet. The phone names a thread and a
    /// port number, and the port must be one Running reports for that thread
    /// now: what it is and where it listens come from the Mac, never the phone.
    private func openServer(_ request: MobileRequest, client: Client) {
        guard let ask = MobileServing.openRequest(request.body) else {
            return send(.error(400, "bad_request"), to: client, head: false)
        }
        guard let thread = snapshot.thread(id: ask.thread) else {
            return send(.error(404, "not_found"), to: client, head: false)
        }
        guard let serving, let running = sources.running, let identity else {
            return send(.error(503, "unavailable"), to: client, head: false)
        }
        let ownPort = boundPort
        guard MobileServing.allowed(port: ask.port, ownPort: ownPort) else {
            return send(.error(403, "refused"), to: client, head: false)
        }
        reply(to: client) {
            guard let found = running(thread).map({ MobileServing.mappable(in: $0, ownPort: ownPort) })?[ask.port]
            else { return .error(404, "not_running") }
            let opened = serving.open(ask.port, found.https, thread.id, found.label)
            return MobileServing.response(opened, port: ask.port, identity: identity)
        }
    }

    // MARK: Replies

    /// The thread `id` names in the live tree and its pane. Answers the client
    /// and returns nil when there is none: a stale id never reaches a pane.
    private func pane(_ id: String, client: Client) -> (MobileThread, MobilePaneIO)? {
        guard let thread = snapshot.thread(id: id) else {
            send(.error(404, "not_found"), to: client, head: false)
            return nil
        }
        guard var io = sources.pane(thread) else {
            send(.error(503, "unavailable", message: MobileReply.unreachable), to: client, head: false)
            return nil
        }
        io.sequence = sequence(of: id)
        return (thread, io)
    }

    /// The prompt counter of thread `id`, as `MobilePaneIO.sequence`. It
    /// goes up each time the words on the pane become a prompt they were not
    /// a moment ago: a new prompt, or the same one asked again after the pane
    /// stopped waiting, showed no prompt, or was answered. Blocks on the
    /// server queue, so it is never called from it.
    private func sequence(of id: String) -> (String?) -> Int {
        { [weak self] key in
            guard let self else { return 0 }
            return self.queue.sync {
                if let key, self.promptSeen[id] != key {
                    self.promptSequence[id, default: 0] += 1
                }
                self.promptSeen[id] = key
                return self.promptSequence[id] ?? 0
            }
        }
    }

    /// The state of thread `id` now: its row in the latest tree, then the
    /// pane's own newer state. nil once the thread has gone. Blocks on the
    /// server queue, so it is never called from it.
    private func state(of id: String, io: MobilePaneIO) -> MobilePaneState? {
        queue.sync { snapshot.thread(id: id) }.map { thread in
            var state = io.state(thread)
            // Whatever the source says: a status from another host is a scan's.
            if !thread.host.isLocal { state.remote = true }
            return state
        }
    }

    /// Run one write to a thread's pane off the server queue. `body` gets the
    /// thread, its pane and the status to ask again before it commits.
    private func write(
        to id: String, client: Client,
        _ body: @escaping (MobileThread, MobilePaneIO, @escaping () -> MobilePaneState?) -> MobileResponse
    ) {
        guard let (thread, io) = pane(id, client: client) else { return }
        guard writing.insert(id).inserted else {
            return send(.error(409, "busy", message: MobileReply.sending), to: client, head: false)
        }
        work.async { [weak self, weak client] in
            let response = body(thread, io) { self?.state(of: id, io: io) }
            self?.queue.async {
                guard let self else { return }
                self.writing.remove(id)
                guard let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                self.send(response, to: client, head: false)
            }
        }
    }

    /// A voice take's text into a thread: the same send as typed text. With
    /// `follow`, the reply is then read from the thread's transcript.
    private func threadTurn(
        _ text: String, thread: MobileThread, io: MobilePaneIO, follow: Bool,
        onDelta: @escaping (String) -> Void, completion: @escaping (ManagerTurnOutcome) -> Void
    ) {
        let id = thread.id
        queue.async { [self] in
            guard writing.insert(id).inserted else { return completion(.refused(MobileReply.sending)) }
            work.async { [self] in
                let state = { [weak self] in self?.state(of: id, io: io) }
                let file = follow && thread.hasChat ? sources.transcript(thread) : nil
                let turn = file.map { file in
                    MobileThreadTurn(
                        read: { MobileChat.read(path: file.path, codex: file.codex, after: $0) },
                        status: { state()?.status })
                }
                turn?.mark()
                let response = MobileReply.send(text, target: thread.pane, io: io, state: state)
                queue.async { self.writing.remove(id) }
                guard response.status == 200 else {
                    return completion(.refused(MobileVoice.message(of: response)))
                }
                guard let turn else { return completion(.done(reply: "")) }
                turn.follow(onDelta: onDelta, completion: completion)
            }
        }
    }

    /// A pane's text as the screen routes answer it; 503 when it could not be read.
    private static func screenResponse(
        _ text: String?, lines: Int, request: MobileRequest
    ) -> MobileResponse {
        guard let text else { return .error(503, "unavailable") }
        // A pane is mostly empty rows below its prompt; the phone needs none of them.
        let end = text.lastIndex { !$0.isNewline && !$0.isWhitespace }
        var response = MobileResponse.json([
            "text": end.map { String(text[...$0]) } ?? "",
            "lines": lines, "max": MobileAPI.screenLinesMax,
        ])
        // A scrollback is long and mostly unchanged between polls: a
        // phone that already holds this body gets 304 and no body.
        let etag = MobileAPI.etag(response.body)
        if MobileAPI.isFresh(request, etag: etag) {
            response = MobileResponse(status: 304, headers: ["Cache-Control": "no-store"])
        }
        response.headers["ETag"] = etag
        return response
    }

    /// Build a response off the server queue (a transcript read, a tmux call),
    /// then send it.
    private func reply(to client: Client, _ make: @escaping () -> MobileResponse) {
        work.async { [weak self, weak client] in
            let response = make()
            self?.queue.async {
                guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                self.send(response, to: client, head: false)
            }
        }
    }

    // No Content-Length: a stream ends when either side closes.
    private static let streamHead = Data((
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
            + "Connection: close\r\nX-Accel-Buffering: no\r\nX-Content-Type-Options: nosniff\r\n\r\n"
    ).utf8)

    private func startStream(_ client: Client) {
        client.streaming = true
        client.events = true
        client.buffer.removeAll()
        setStreamCount(clients.values.filter(\.events).count)
        var data = Self.streamHead
        data.append(Self.event("config", config.json()))
        data.append(Self.event("threads", threadsBody))
        data.append(Self.event("hosts", hostsBody))
        if config.allows(.manager) { data.append(Self.event("manager", managerBody)) }
        write(data, to: client)
        receive(client)
    }

    /// One manager turn. A turn that cannot start is a plain error; one that
    /// starts answers with a stream of `delta` events and one `end` event.
    private func startTurn(_ text: String, client: Client) {
        guard let manager else {
            return send(.error(503, "unavailable", message: MobileManager.offMessage),
                        to: client, head: false)
        }
        work.async { [weak self, weak client] in
            let status = manager.pane().status
            self?.queue.async {
                guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                if let refusal = MobileManager.refusal(
                    status: status, turnRunning: self.turn != nil || self.phoneTurns > 0) {
                    return self.send(refusal, to: client, head: false)
                }
                self.phoneTurns += 1
                client.streaming = true
                client.buffer.removeAll()
                self.write(Self.streamHead, to: client)
                self.receive(client)
                self.pingTurn(client)
                // The turn runs to its end even when the phone hangs up: only
                // the writes stop.
                let event = { [weak self, weak client] (name: String, object: [String: Any], last: Bool) in
                    let json = Self.json(object)
                    self?.queue.async {
                        guard let self else { return }
                        if last { self.phoneTurns -= 1 }
                        guard let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                        self.write(Self.event(name, json), to: client, close: last)
                    }
                }
                manager.send(
                    text,
                    { delta in event("delta", ["text": delta], false) },
                    { outcome in event("end", MobileManager.end(outcome), true) })
            }
        }
    }

    /// Keep a turn stream alive on a timer of its own: a turn can be quiet for
    /// a long time, and the tree updates that ping the event stream may not come.
    private func pingTurn(_ client: Client) {
        queue.asyncAfter(deadline: .now() + limits.turnPing) { [weak self, weak client] in
            guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
            if Date().timeIntervalSince(client.lastWrite) >= self.limits.turnPing * 0.9 {
                self.write(Data(": ping\n\n".utf8), to: client)
            }
            self.pingTurn(client)
        }
    }

    // MARK: Voice

    /// Why a voice request cannot start, checked before it costs anything: a
    /// target this server can reach, with its own switch on, an engine, and
    /// no other voice turn running. Whether the models are on disk is asked
    /// off the server queue, by the caller.
    private func voiceRefusal(_ request: MobileRequest) -> MobileResponse? {
        guard let ask = MobileVoiceRequest(query: request.query) else {
            return .error(400, "bad_request")
        }
        switch ask.target {
        case .manager:
            guard config.allows(.manager) else { return .error(403, "disabled") }
            guard manager != nil else {
                return .error(503, "unavailable", message: MobileVoice.unavailable)
            }
        case .thread(let id):
            // A take into a thread types into its pane: the Replies switch.
            guard config.allows(.replies) else { return .error(403, "disabled") }
            guard let thread = snapshot.thread(id: id) else { return .error(404, "not_found") }
            guard sources.pane(thread) != nil else {
                return .error(503, "unavailable", message: MobileReply.unreachable)
            }
        }
        guard let voice else {
            return .error(503, "unavailable", message: MobileVoice.unavailable)
        }
        guard voiceTurn == nil, !voiceStarting else {
            return .error(409, "busy", message: MobileVoice.busy)
        }
        return nil
    }

    /// Turn `client` into the stream of one voice turn and return the turn.
    /// The turn's events go to the client; the last one closes it. A client
    /// that hangs up cancels the turn.
    private func voiceStream(to client: Client, voice: Voice, speaker: Bool) -> MobileVoiceTurn {
        client.streaming = true
        client.backlog = limits.voiceBacklog
        client.buffer.removeAll()
        write(Self.streamHead, to: client)
        receive(client)
        pingTurn(client)
        let turn = MobileVoiceTurn(speech: voice.speech, speaker: speaker) {
            [weak self, weak client] name, object, last in
            let json = Self.json(object)
            self?.queue.async {
                guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                if last {
                    client.onDrop = nil
                    self.voiceTurn = nil
                }
                self.write(Self.event(name, json), to: client, close: last)
            }
        }
        voiceTurn = turn
        client.onDrop = { [weak self, weak turn] in
            turn?.cancel()
            if self?.voiceTurn === turn { self?.voiceTurn = nil }
        }
        return turn
    }

    /// One voice take. A take that cannot start is a plain error; one that
    /// starts answers with a stream: `transcript`, `delta` and `audio` events,
    /// then one `end`.
    private func startVoice(_ request: MobileRequest, client: Client) {
        if let refusal = voiceRefusal(request) { return send(refusal, to: client, head: false) }
        guard let ask = MobileVoiceRequest(query: request.query), let voice else { return }
        if case .thread(let id) = ask.target {
            return startThreadVoice(request, id: id, speaker: ask.speaker, voice: voice, client: client)
        }
        guard let manager else { return }
        voiceStarting = true
        work.async { [weak self, weak client] in
            let ready = voice.speech.modelsReady
            let take = ready ? MobileVoice.take(wav: request.body) : .samples([])
            let status = manager.pane().status
            self?.queue.async {
                guard let self else { return }
                self.voiceStarting = false
                guard let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                guard ready else { return self.send(MobileVoice.modelsMissing, to: client, head: false) }
                // Asked before the models load: a refused take costs nothing.
                if let refusal = MobileManager.refusal(
                    status: status, turnRunning: self.turn != nil || self.phoneTurns > 0) {
                    return self.send(refusal, to: client, head: false)
                }
                guard case .samples(let samples) = take else {
                    if case .refused(let response) = take { self.send(response, to: client, head: false) }
                    return
                }
                // The words go down the path typed text takes: the same send,
                // counted as a phone turn until the manager ends it. The turn
                // runs to its end even when the phone hangs up.
                self.voiceStream(to: client, voice: voice, speaker: ask.speaker)
                    .start(samples: samples) { [weak self] text, onDelta, completion in
                        self?.sendHeard(text, manager: manager, onDelta: onDelta, completion: completion)
                    }
            }
        }
    }

    /// One voice take into a thread. The pane is asked first, so a take into
    /// a pane that is busy or on a prompt costs nothing and types nothing.
    private func startThreadVoice(
        _ request: MobileRequest, id: String, speaker: Bool, voice: Voice, client: Client
    ) {
        guard let thread = snapshot.thread(id: id), let io = sources.pane(thread) else { return }
        voiceStarting = true
        work.async { [weak self, weak client] in
            let ready = voice.speech.modelsReady
            let take = ready ? MobileVoice.take(wav: request.body) : .samples([])
            let refusal = MobileReply.refusal(state: self?.state(of: id, io: io), io: io)
            self?.queue.async {
                guard let self else { return }
                self.voiceStarting = false
                guard let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                guard ready else { return self.send(MobileVoice.modelsMissing, to: client, head: false) }
                if let refusal { return self.send(refusal, to: client, head: false) }
                guard case .samples(let samples) = take else {
                    if case .refused(let response) = take { self.send(response, to: client, head: false) }
                    return
                }
                self.voiceStream(to: client, voice: voice, speaker: speaker)
                    .start(samples: samples) { [weak self] text, onDelta, completion in
                        guard let self else { return completion(.unreachable(MobileReply.unreachable)) }
                        self.threadTurn(
                            text, thread: thread, io: io, follow: speaker, onDelta: onDelta,
                            completion: completion)
                    }
            }
        }
    }

    /// Hand what was heard to the manager. Transcription took time, and the
    /// pane may have started a turn or reached a prompt in it, so the pane is
    /// asked again here, right before the send, and must be idle.
    private func sendHeard(
        _ text: String, manager: Manager, onDelta: @escaping (String) -> Void,
        completion: @escaping (ManagerTurnOutcome) -> Void
    ) {
        work.async { [weak self] in
            let status = manager.pane().status
            guard let self else { return completion(.refused(MobileVoice.unavailable)) }
            self.queue.async {
                if let refusal = MobileManager.refusal(
                    status: status, turnRunning: self.turn != nil || self.phoneTurns > 0) {
                    return completion(.refused(MobileVoice.message(of: refusal)))
                }
                self.phoneTurns += 1
                manager.send(text, onDelta) { [weak self] outcome in
                    self?.queue.async { self?.phoneTurns -= 1 }
                    completion(outcome)
                }
            }
        }
    }

    /// Replay: read the target's last reply again. It answers with the same
    /// stream as a take, without a transcript.
    private func startReplay(_ request: MobileRequest, client: Client) {
        if let refusal = voiceRefusal(request) { return send(refusal, to: client, head: false) }
        guard let ask = MobileVoiceRequest(query: request.query), let voice else { return }
        let transcript: () -> (path: String, codex: Bool)?
        switch ask.target {
        case .manager:
            guard let manager else { return }
            transcript = { manager.pane().transcript.map { ($0, false) } }
        case .thread(let id):
            guard let thread = snapshot.thread(id: id) else { return }
            transcript = { [sources] in thread.hasChat ? sources.transcript(thread) : nil }
        }
        voiceStarting = true
        work.async { [weak self, weak client] in
            let ready = voice.speech.modelsReady
            let reply = MobileVoice.lastReply(in: transcript()
                .flatMap { MobileChat.read(path: $0.path, codex: $0.codex, after: nil) })
            self?.queue.async {
                guard let self else { return }
                self.voiceStarting = false
                guard let client, self.clients[ObjectIdentifier(client)] != nil else { return }
                guard ready else { return self.send(MobileVoice.modelsMissing, to: client, head: false) }
                guard let reply else {
                    return self.send(
                        .error(404, "nothing", message: MobileVoice.nothingToReplay),
                        to: client, head: false)
                }
                self.voiceStream(to: client, voice: voice, speaker: true).replay(reply)
            }
        }
    }

    private func asset(_ path: String) -> MobileResponse {
        guard let staticRoot else { return .error(404, "not_found") }
        var served = path
        var data = try? Data(contentsOf: staticRoot.appendingPathComponent(path))
        if data == nil, MobileAPI.isClientRoute(path) {
            served = "index.html"
            data = try? Data(contentsOf: staticRoot.appendingPathComponent(served))
        }
        guard let data else { return .error(404, "not_found") }
        let shell = served == "index.html"
            ? data : (try? Data(contentsOf: staticRoot.appendingPathComponent("index.html"))) ?? Data()
        return MobileResponse(
            status: 200,
            headers: [
                "Content-Type": MobileAPI.contentType(forPath: served),
                "Cache-Control": MobileAPI.cacheControl(forPath: served),
                "Content-Security-Policy": shellPolicy(for: shell),
            ],
            body: data)
    }

    /// The bundle's policy, worked out once for each shell it is read from.
    private func shellPolicy(for shell: Data) -> String {
        if let cached = shellPolicyCache, cached.shell == shell { return cached.policy }
        let policy = MobileAPI.shellPolicy(html: String(decoding: shell, as: UTF8.self))
        shellPolicyCache = (shell, policy)
        return policy
    }
}
