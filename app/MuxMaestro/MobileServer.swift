import Foundation
import Network

/// The phone's HTTP server: a loopback-only listener that serves the static
/// bundle and the read API. `tailscale serve` is the only way in from another
/// device; `MobileAPI.authorize` checks every request it forwards.
///
/// The server never polls. `update(_:)` hands it the tree the sidebar already
/// loads, and it pushes a Server-Sent Event when the bytes it would serve change.
final class MobileServer {
    /// The two reads that go past the snapshot. Both are called off the server
    /// queue and may block.
    struct Sources {
        /// The pane's visible text.
        var screen: (MobileThread) -> String?
        /// The thread's transcript file, and whether it is a Codex rollout.
        var transcript: (MobileThread) -> (path: String, codex: Bool)?
    }

    enum StartError: Error, Equatable {
        case badPort
        case listener(String)
    }

    /// One accepted connection. Confined to `queue`.
    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var streaming = false
        var lastWrite = Date()

        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// A stream with nothing to say still gets a comment line this often, so a
    /// proxy does not drop it as idle.
    static let pingInterval: TimeInterval = 15
    /// How long after its last request a phone still counts as looking.
    static let clientWindow: TimeInterval = 60

    private let staticRoot: URL?
    private let sources: Sources
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.mobile")
    private let work = DispatchQueue(label: "is.rebar.muxmaestro.mobile.work", attributes: .concurrent)

    // Confined to `queue`.
    private var listener: NWListener?
    private var identity: MobileIdentity?
    private var snapshot = MobileSnapshot()
    private var threadsBody = MobileSnapshot().threadsJSON()
    private var hostsBody = MobileSnapshot().hostsJSON()
    private var config = MobileConfig()
    private var clients: [ObjectIdentifier: Client] = [:]

    private let activityLock = NSLock()
    private var lastRequestAt = Date.distantPast
    private var streamCount = 0

    init(staticRoot: URL?, sources: Sources) {
        self.staticRoot = staticRoot
        self.sources = sources
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
    /// bound port once, on the server queue.
    func start(
        port: Int, identity: MobileIdentity,
        completion: @escaping (Result<Int, StartError>) -> Void
    ) {
        queue.async {
            self.stopNow()
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
                    completion(.success(Int(listener?.port?.rawValue ?? nwPort.rawValue)))
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
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        setStreamCount(0)
    }

    /// The latest tree. Pushes an event to open streams when a body changed.
    func update(_ snapshot: MobileSnapshot) {
        queue.async {
            guard self.listener != nil else { return }
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
            let now = Date()
            for client in self.clients.values
            where client.streaming && now.timeIntervalSince(client.lastWrite) >= Self.pingInterval {
                self.write(Data(": ping\n\n".utf8), to: client)
            }
        }
    }

    /// The Settings the phone is held to. Applies to the next request, and tells
    /// open streams so the phone hides what was switched off.
    func configure(_ config: MobileConfig) {
        queue.async {
            guard config != self.config else { return }
            self.config = config
            self.broadcast(Self.event("config", config.json()))
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
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
        setStreamCount(clients.values.filter(\.streaming).count)
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
        switch MobileHTTP.parse(client.buffer) {
        case .incomplete:
            receive(client)
        case .invalid(let status):
            send(.error(status, "bad_request"), to: client, head: false, close: true)
        case .request(let request, let consumed):
            client.buffer.removeFirst(consumed)
            respond(to: request, client: client)
        }
    }

    private func send(_ response: MobileResponse, to client: Client, head: Bool, close: Bool = false) {
        client.lastWrite = Date()
        client.connection.send(
            content: response.serialized(head: head, keepAlive: !close),
            completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client else { return }
                if close || error != nil { return self.drop(client) }
                self.drain(client)
            })
    }

    private func write(_ data: Data, to client: Client) {
        client.lastWrite = Date()
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            if error != nil, let client { self?.drop(client) }
        })
    }

    private func broadcast(_ data: Data) {
        for client in clients.values where client.streaming { write(data, to: client) }
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
        activityLock.lock()
        lastRequestAt = Date()
        activityLock.unlock()

        switch MobileAPI.route(request, config: config) {
        case .config:
            send(.json(data: config.json()), to: client, head: head)
        case .disabled:
            send(.error(403, "disabled"), to: client, head: head)
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
        case .screen(let id):
            guard let thread = snapshot.thread(id: id) else {
                return send(.error(404, "not_found"), to: client, head: head)
            }
            reply(to: client) { [sources] in
                guard let text = sources.screen(thread) else { return .error(503, "unavailable") }
                return .json(["text": text])
            }
        case .asset(let path):
            send(asset(path), to: client, head: head)
        case .methodNotAllowed:
            send(.error(405, "method_not_allowed"), to: client, head: head)
        case .notFound:
            send(.error(404, "not_found"), to: client, head: head)
        }
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

    private func startStream(_ client: Client) {
        client.streaming = true
        client.buffer.removeAll()
        setStreamCount(clients.values.filter(\.streaming).count)
        // No Content-Length: the stream ends when either side closes.
        var data = Data((
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
                + "Connection: close\r\nX-Accel-Buffering: no\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        ).utf8)
        data.append(Self.event("config", config.json()))
        data.append(Self.event("threads", threadsBody))
        data.append(Self.event("hosts", hostsBody))
        write(data, to: client)
        receive(client)
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
        return MobileResponse(
            status: 200,
            headers: [
                "Content-Type": MobileAPI.contentType(forPath: served),
                "Cache-Control": MobileAPI.cacheControl(forPath: served),
            ],
            body: data)
    }
}
