import CryptoKit
import Foundation

// The pure half of the phone server: HTTP parsing, routing, the auth decision
// and the JSON shapes. No sockets and no AppKit, so the test target compiles it.
// `MobileServer` owns the listener and calls into here.

// MARK: - HTTP

/// One parsed HTTP/1.1 request. Header names are lowercased.
struct MobileRequest: Equatable {
    var method: String
    /// The request path without its query, still percent-encoded.
    var path: String
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body = Data()

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The path's segments, percent-decoded. A segment that does not decode is
    /// kept as sent, so it matches no route.
    var segments: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
    }
}

struct MobileResponse: Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static let reasons = [
        200: "OK", 304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
        431: "Request Header Fields Too Large", 500: "Internal Server Error",
        503: "Service Unavailable",
    ]

    /// A JSON body. API responses are never cacheable: the service worker and
    /// the browser must both go to the network for them.
    static func json(_ object: Any, status: Int = 200) -> MobileResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return json(data: body, status: status)
    }

    static func json(data: Data, status: Int = 200) -> MobileResponse {
        MobileResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
            body: data)
    }

    static func error(_ status: Int, _ code: String) -> MobileResponse {
        json(["error": code], status: status)
    }

    /// An error the phone shows as it is: `message` is the sentence.
    static func error(_ status: Int, _ code: String, message: String) -> MobileResponse {
        json(["error": code, "message": message], status: status)
    }

    /// The bytes to write. A HEAD response keeps `Content-Length` and drops the body.
    func serialized(head: Bool = false, keepAlive: Bool = true) -> Data {
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = keepAlive ? "keep-alive" : "close"
        all["X-Content-Type-Options"] = "nosniff"
        all["Referrer-Policy"] = "no-referrer"
        var text = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "OK")\r\n"
        for key in all.keys.sorted() { text += "\(key): \(all[key] ?? "")\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if !head { data.append(body) }
        return data
    }
}

enum MobileHTTP {
    static let maxHeaderBytes = 32_768
    static let maxBodyBytes = 1_048_576

    /// The largest body a request to `path` may carry. Only a voice take, which
    /// is audio, and an upload, which is a file, get more than `maxBodyBytes`.
    /// The upload's own limit, from Settings, is checked when it is answered.
    static func bodyLimit(method: String, path: String) -> Int {
        guard method == "POST" else { return maxBodyBytes }
        if path == "/api/voice" { return MobileVoice.maxBodyBytes }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        if segments.count == 4, segments[0] == "api", segments[1] == "threads", segments[3] == "upload" {
            return MobileReply.maxUploadBytes
        }
        return maxBodyBytes
    }

    enum Parsed: Equatable {
        /// More bytes are needed.
        case incomplete
        /// Not a request this server answers; reply with the status and close.
        case invalid(Int)
        /// A whole request, and how many bytes of the buffer it used.
        case request(MobileRequest, consumed: Int)
    }

    /// Parse one request from the front of `buffer`.
    ///
    /// `precheck` sees a request that asks for more than `maxBodyBytes` (a
    /// voice take) when its headers are in and before any of its body is
    /// waited for. A status it returns ends the request there, so only a
    /// caller that is allowed in gets the server to hold megabytes for it.
    static func parse(_ buffer: Data, precheck: ((MobileRequest) -> Int?)? = nil) -> Parsed {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .invalid(431) : .incomplete
        }
        let headBytes = buffer.distance(from: buffer.startIndex, to: end.lowerBound)
        guard headBytes <= maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
        else { return .invalid(headBytes > maxHeaderBytes ? 431 : 400) }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              requestLine[1].hasPrefix("/")
        else { return .invalid(400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return .invalid(400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // A chunked body is never sent by the app's own client; refusing it keeps
        // the framing rules to one.
        guard headers["transfer-encoding"] == nil else { return .invalid(400) }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid(400) }
            let limit = bodyLimit(
                method: String(requestLine[0]),
                path: String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? ""))
            guard n <= limit else { return .invalid(413) }
            length = n
        }
        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var request = MobileRequest(method: String(requestLine[0]), path: String(parts[0]))
        if parts.count == 2 { request.query = parseQuery(String(parts[1])) }
        request.headers = headers
        if length > maxBodyBytes, let status = precheck?(request) { return .invalid(status) }

        let bodyStart = headBytes + terminator.count
        guard buffer.count >= bodyStart + length else { return .incomplete }
        let from = buffer.index(buffer.startIndex, offsetBy: bodyStart)
        request.body = Data(buffer[from..<buffer.index(from, offsetBy: length)])
        return .request(request, consumed: bodyStart + length)
    }

    static func parseQuery(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (s: Substring) in
                s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s)
            }
            out[decode(kv[0])] = kv.count == 2 ? decode(kv[1]) : ""
        }
        return out
    }
}

// MARK: - Routing and auth

/// One API route. `capability` switches over every case with no default, so a
/// route added here does not compile until it names the feature it belongs to.
enum MobileEndpoint: Equatable {
    case config
    case threads
    case hosts
    case events
    /// `after` is the cursor a previous chat response returned as `next`.
    case chat(id: String, after: UInt64?)
    /// `lines` is how much scrollback to capture, already clamped.
    case screen(id: String, lines: Int)
    /// The manager home: what needs the human, and the chat so far.
    case manager
    /// One manager turn. The reply streams back.
    case managerText
    case managerDismiss
    /// The manager pane's transcript as chat rows, like a thread's chat.
    case managerChat(after: UInt64?)
    /// The manager pane's terminal text, like a thread's screen.
    case managerScreen(lines: Int)
    /// The prompt the manager's own pane waits on, as choices.
    case managerPrompt
    /// Pick one choice of that prompt, or back out of it.
    case managerAnswer
    /// Press one whitelisted key in the manager's pane.
    case managerKey
    /// One voice take: audio in; transcript, reply and audio stream back.
    case voice
    /// Read the target's last reply again.
    case voiceReplay
    /// A take has started: load the models while the human talks.
    case voiceWarm
    /// Paste text into a thread's pane and submit it.
    case text(id: String)
    /// Press one whitelisted key in a thread's pane.
    case key(id: String)
    /// The prompt a thread's pane waits on, as choices.
    case prompt(id: String)
    /// Pick one choice of that prompt.
    case answer(id: String)
    /// The thread's skills and commands, for the `/` list.
    case commands(id: String)
    /// Save a file in the thread's working directory. With `paste` its path
    /// is pasted into the pane; without, the phone puts it in its reply box.
    case upload(id: String, name: String, paste: Bool)
    /// One session action. The body names its target.
    case tmux(MobileAction)
    /// The directories a host offers for a new session.
    case dirs(host: String)
    /// Find `query` in the thread's scrollback.
    case find(id: String, query: String)
    /// What the thread's agent made: files and links.
    case artifacts(id: String)
    /// One file of that list, named by its id there. Never by a path.
    case file(id: String, artifact: String)
    /// What the thread has running: dev servers, stacks, containers.
    case running(id: String)
    /// The local ports this app has published on the tailnet.
    case servers
    /// Publish one port a thread has running. The body names both.
    case serverOpen
    case serverClose
    /// This Mac's VAPID public key: what a phone subscribes with.
    case pushKey
    /// Keep a phone's push subscription. The body is the browser's own JSON.
    case pushSubscribe
    case pushUnsubscribe
    /// The phone says which thread it shows, so that thread sends it nothing.
    case pushFocus

    var capability: MobileCapability {
        switch self {
        case .config, .threads, .hosts, .events, .chat, .screen: return .access
        case .manager, .managerText, .managerDismiss, .managerChat, .managerScreen, .managerPrompt,
             .managerAnswer, .managerKey:
            return .manager
        case .voice, .voiceReplay, .voiceWarm: return .voice
        case .text, .prompt, .answer, .commands: return .replies
        case .key: return .keyBar
        case .upload: return .upload
        case .tmux(let action): return action.isKill ? .kill : .sessionActions
        case .dirs: return .sessionActions
        case .find: return .find
        case .artifacts, .file: return .artifacts
        case .running, .servers, .serverOpen, .serverClose: return .localServers
        case .pushKey, .pushSubscribe, .pushUnsubscribe, .pushFocus: return .notifications
        }
    }

    /// The one method the endpoint answers. A write is a POST, so it also has
    /// to pass the write checks in `MobileAPI.authorize`.
    var method: String {
        switch self {
        case .config, .threads, .hosts, .events, .chat, .screen, .manager, .managerChat,
             .managerScreen, .managerPrompt, .prompt, .commands,
             .dirs, .find, .artifacts, .file, .running, .servers, .pushKey:
            return "GET"
        case .managerText, .managerDismiss, .managerAnswer, .managerKey, .voice, .voiceReplay,
             .voiceWarm, .text, .key, .answer, .upload, .tmux, .serverOpen, .serverClose,
             .pushSubscribe, .pushUnsubscribe, .pushFocus:
            return "POST"
        }
    }

    /// A second feature the endpoint needs besides its own. Answering the
    /// manager's prompt types into its pane, as a reply to a thread does, so
    /// it needs the switch for that too.
    var also: MobileCapability? {
        switch self {
        case .managerAnswer: return .replies
        case .managerKey: return .keyBar
        default: return nil
        }
    }
}

enum MobileRoute: Equatable {
    case api(MobileEndpoint)
    /// A file of the static bundle, as a path relative to its root.
    case asset(String)
    case methodNotAllowed
    case notFound
    /// `/api/tmux/<action>` with an action that is not a `MobileAction`.
    case unknownAction
    /// The route belongs to a feature whose switch is off.
    case disabled(MobileCapability)
}

/// A phone feature with its own switch in Settings. The server refuses a
/// route whose capability is off, and `/api/config` tells the phone to hide it.
/// A PR that adds a feature adds its Settings row and its routes; the case and
/// the path rule are already here, so the feature is refused until then.
enum MobileCapability: String, CaseIterable {
    /// The master switch: the thread list and the read-only thread view. It is
    /// on whenever the server runs.
    case access
    case manager
    case voice
    /// Text into a thread and answers to its prompts.
    case replies
    /// Key presses from the key bar.
    case keyBar
    case upload
    case sessionActions
    case kill
    /// Find in a thread's scrollback.
    case find
    case artifacts
    case localServers
    case stopServers
    case notifications
    case liveTerminal
}

enum MobileGrouping: String, CaseIterable {
    case recent
    case host
    case directory
}

/// What the Mac allows the phone to do, and the defaults it hands the phone.
struct MobileConfig: Equatable {
    /// Nothing is on unless its switch was turned on.
    var capabilities: Set<MobileCapability> = []
    var grouping = MobileGrouping.recent
    var voice = MobileVoiceDefaults()
    /// The largest file the phone may upload, in bytes.
    var uploadLimit = MobileReply.defaultUploadLimit

    func allows(_ capability: MobileCapability) -> Bool {
        capability == .access || capabilities.contains(capability)
    }

    /// The `/api/config` body.
    func json() -> Data {
        let object: [String: Any] = [
            "capabilities": Dictionary(uniqueKeysWithValues: MobileCapability.allCases.map {
                ($0.rawValue, allows($0))
            }),
            "grouping": grouping.rawValue,
            "voice": voice.json,
            "upload": ["maxBytes": min(uploadLimit, MobileReply.maxUploadBytes)],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }
}

/// Who this Mac is on the tailnet: the only login the server answers, and the
/// only host name it answers as.
struct MobileIdentity: Equatable {
    let login: String
    let dnsName: String
}

enum MobileAuth: Equatable {
    case allowed
    case denied(String)
}

enum MobileAPI {
    /// The header a write must carry. A page on another origin cannot set it
    /// without a CORS preflight, and the server answers none.
    static let writeHeader = "x-muxmaestro"

    /// The feature an API path belongs to; nil for the thread list and the
    /// read-only thread view, which the master switch alone covers.
    static func capability(forSegments segments: [String]) -> MobileCapability? {
        guard segments.first == "api", segments.count >= 2 else { return nil }
        switch segments[1] {
        case "manager": return .manager
        case "voice": return .voice
        case "push": return .notifications
        case "terminal": return .liveTerminal
        case "servers": return segments.last == "stop" ? .stopServers : .localServers
        case "tmux": return segments.count >= 3 && segments[2].hasPrefix("kill") ? .kill : .sessionActions
        case "hosts" where segments.count >= 3: return .sessionActions
        case "threads" where segments.count >= 4:
            switch segments[3] {
            case "text", "prompt", "answer", "commands": return .replies
            case "key": return .keyBar
            case "upload": return .upload
            case "artifacts", "file": return .artifacts
            case "running": return .localServers
            case "find": return .find
            default: return nil
            }
        default: return nil
        }
    }

    static func route(_ request: MobileRequest, config: MobileConfig = MobileConfig()) -> MobileRoute {
        let segments = request.segments
        guard segments.first == "api" else {
            guard request.method == "GET" || request.method == "HEAD" else { return .methodNotAllowed }
            return assetPath(segments).map(MobileRoute.asset) ?? .notFound
        }
        // Checked before the route is matched: a feature that is off refuses
        // every path under it, built or not.
        // The prompt's id is what a key into a waiting pane must carry, so the
        // key bar alone may read it too.
        let promptForKeys = segments.count == 4 && segments[1] == "threads"
            && segments[3] == "prompt" && config.allows(.keyBar)
        if let capability = capability(forSegments: segments), !config.allows(capability),
           !promptForKeys {
            return .disabled(capability)
        }
        // A kill is a session action too: it needs both switches.
        if segments.count >= 2, segments[1] == "tmux", !config.allows(.sessionActions) {
            return .disabled(.sessionActions)
        }
        let endpoint: MobileEndpoint
        switch segments.count {
        case 2 where segments[1] == "config": endpoint = .config
        case 2 where segments[1] == "threads": endpoint = .threads
        case 2 where segments[1] == "hosts": endpoint = .hosts
        case 2 where segments[1] == "events": endpoint = .events
        case 2 where segments[1] == "manager": endpoint = .manager
        case 3 where segments[1] == "manager" && segments[2] == "text": endpoint = .managerText
        case 3 where segments[1] == "manager" && segments[2] == "dismiss": endpoint = .managerDismiss
        case 3 where segments[1] == "manager" && segments[2] == "chat":
            endpoint = .managerChat(after: request.query["after"].flatMap(UInt64.init))
        case 3 where segments[1] == "manager" && segments[2] == "screen":
            endpoint = .managerScreen(lines: screenLines(request.query["lines"]))
        case 3 where segments[1] == "manager" && segments[2] == "prompt": endpoint = .managerPrompt
        case 3 where segments[1] == "manager" && segments[2] == "answer": endpoint = .managerAnswer
        case 3 where segments[1] == "manager" && segments[2] == "key": endpoint = .managerKey
        case 2 where segments[1] == "voice": endpoint = .voice
        case 3 where segments[1] == "voice" && segments[2] == "replay": endpoint = .voiceReplay
        case 3 where segments[1] == "voice" && segments[2] == "warm": endpoint = .voiceWarm
        case 4 where segments[1] == "threads" && segments[3] == "chat":
            endpoint = .chat(id: segments[2], after: request.query["after"].flatMap(UInt64.init))
        case 4 where segments[1] == "threads" && segments[3] == "screen":
            endpoint = .screen(id: segments[2], lines: screenLines(request.query["lines"]))
        case 4 where segments[1] == "threads" && segments[3] == "text":
            endpoint = .text(id: segments[2])
        case 4 where segments[1] == "threads" && segments[3] == "key":
            endpoint = .key(id: segments[2])
        case 4 where segments[1] == "threads" && segments[3] == "prompt":
            endpoint = .prompt(id: segments[2])
        case 4 where segments[1] == "threads" && segments[3] == "answer":
            endpoint = .answer(id: segments[2])
        case 4 where segments[1] == "threads" && segments[3] == "commands":
            endpoint = .commands(id: segments[2])
        case 4 where segments[1] == "threads" && segments[3] == "upload":
            endpoint = .upload(
                id: segments[2], name: request.query["name"] ?? "", paste: request.query["paste"] != "0")
        case 4 where segments[1] == "threads" && segments[3] == "find":
            endpoint = .find(id: segments[2], query: request.query["q"] ?? "")
        case 4 where segments[1] == "threads" && segments[3] == "artifacts":
            endpoint = .artifacts(id: segments[2])
        case 4 where segments[1] == "threads" && segments[3] == "file":
            endpoint = .file(id: segments[2], artifact: request.query["id"] ?? "")
        case 4 where segments[1] == "threads" && segments[3] == "running":
            endpoint = .running(id: segments[2])
        case 2 where segments[1] == "servers": endpoint = .servers
        case 3 where segments[1] == "servers" && segments[2] == "open": endpoint = .serverOpen
        case 3 where segments[1] == "servers" && segments[2] == "close": endpoint = .serverClose
        case 3 where segments[1] == "push" && segments[2] == "key": endpoint = .pushKey
        case 3 where segments[1] == "push" && segments[2] == "subscribe": endpoint = .pushSubscribe
        case 3 where segments[1] == "push" && segments[2] == "unsubscribe": endpoint = .pushUnsubscribe
        case 3 where segments[1] == "push" && segments[2] == "focus": endpoint = .pushFocus
        case 4 where segments[1] == "hosts" && segments[3] == "dirs":
            endpoint = .dirs(host: segments[2])
        case 3 where segments[1] == "tmux":
            // A fixed list: any other word is refused, whatever its method.
            guard let action = MobileAction(rawValue: segments[2]) else { return .unknownAction }
            endpoint = .tmux(action)
        default: return .notFound
        }
        guard config.allows(endpoint.capability) || promptForKeys else {
            return .disabled(endpoint.capability)
        }
        if let also = endpoint.also, !config.allows(also) { return .disabled(also) }
        // The manager's prompt is read by whichever can act on it.
        if endpoint == .managerPrompt, !config.allows(.replies), !config.allows(.keyBar) {
            return .disabled(.replies)
        }
        return request.method == endpoint.method ? .api(endpoint) : .methodNotAllowed
    }

    /// Scrollback lines a screen request gets when it names none, and the most
    /// it can ask for. A pane's history can be far longer; the cap bounds what
    /// one request costs the Mac and the phone.
    static let screenLinesDefault = 2000
    static let screenLinesMax = 10_000

    /// The `lines` query value as a line count: digits only, clamped to
    /// 1...`screenLinesMax`. Anything else reads as the default.
    static func screenLines(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty, raw.count <= 9,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw)
        else { return screenLinesDefault }
        return min(max(value, 1), screenLinesMax)
    }

    /// A validator for a response body: equal bodies give equal tags, so a
    /// phone that sends it back in `If-None-Match` is told "unchanged" instead
    /// of being sent a long scrollback again. FNV-1a; not a security boundary.
    static func etag(_ body: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in body {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\"\(String(hash, radix: 16))-\(body.count)\""
    }

    /// Whether the request already holds the body `etag` names.
    static func isFresh(_ request: MobileRequest, etag: String) -> Bool {
        guard let sent = request.header("if-none-match") else { return false }
        return sent.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces) == etag
        }
    }

    /// The header that carries the pairing token.
    static let tokenHeader = "x-muxmaestro-token"

    /// Whether `request` is for the API, which needs the pairing token. The
    /// static bundle does not: the phone must load it to read the token.
    static func needsToken(_ request: MobileRequest) -> Bool {
        request.segments.first == "api"
    }

    /// Whether `request` carries the pairing token. The Tailscale login and the
    /// host name are public values that any process on this Mac could send to
    /// the loopback port; the token is the secret only a paired phone holds.
    /// Compared in constant time. No token set means nothing is paired.
    static func hasToken(_ request: MobileRequest, token: String?) -> Bool {
        guard let token, !token.isEmpty, let sent = request.header(tokenHeader) else { return false }
        let a = Array(sent.utf8), b = Array(token.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in b.indices { difference |= b[index] ^ (index < a.count ? a[index] : 0) }
        return difference == 0
    }

    /// Every request must come through `tailscale serve` from this Mac's own
    /// tailnet login. `tailscale serve` sets `Tailscale-User-Login` itself and
    /// drops any copy the client sent, so the value is the caller's identity.
    ///
    /// The `Host` check stops DNS rebinding: a page that points its own name at
    /// 127.0.0.1 reaches the listener, but not under this Mac's tailnet name.
    /// A write must also be same-origin and carry `writeHeader`, so a page open
    /// on the Mac cannot post to the loopback port.
    static func authorize(_ request: MobileRequest, identity: MobileIdentity?) -> MobileAuth {
        guard let identity, !identity.login.isEmpty, !identity.dnsName.isEmpty else {
            return .denied("no identity")
        }
        guard let login = request.header("tailscale-user-login"),
              login.caseInsensitiveCompare(identity.login) == .orderedSame
        else { return .denied("login") }
        guard let host = request.header("host"),
              hostName(host).caseInsensitiveCompare(identity.dnsName) == .orderedSame
        else { return .denied("host") }
        guard request.method != "GET", request.method != "HEAD" else { return .allowed }
        guard request.header(writeHeader) != nil else { return .denied("write header") }
        // The origin is this Mac's name on the port the request came to: another
        // `tailscale serve` mapping on the same name is another origin.
        guard let origin = request.header("origin"),
              let url = URL(string: origin), url.scheme == "https",
              (url.host ?? "").caseInsensitiveCompare(identity.dnsName) == .orderedSame,
              (url.port ?? 443) == hostPort(host)
        else { return .denied("origin") }
        return .allowed
    }

    /// The port of a `host[:port]` header; 443 when it names none, as HTTPS does.
    static func hostPort(_ header: String) -> Int? {
        let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? Int(parts[1]) : 443
    }

    /// `host[:port]` without the port. Tailnet names are never IPv6 literals.
    static func hostName(_ header: String) -> String {
        String(header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? "")
    }

    /// The bundle file a URL path names, or nil when a segment could step out of
    /// the bundle. `/` is the app shell.
    static func assetPath(_ segments: [String]) -> String? {
        for segment in segments {
            if segment == "." || segment == ".." || segment.hasPrefix(".") { return nil }
            if segment.contains("/") || segment.contains("\\") || segment.contains("\0") { return nil }
        }
        return segments.isEmpty ? "index.html" : segments.joined(separator: "/")
    }

    /// A path with no file extension is a client-side route: the shell answers.
    static func isClientRoute(_ assetPath: String) -> Bool {
        !(assetPath.split(separator: "/").last ?? "").contains(".")
    }

    static func contentType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// What the shell may load, as a `Content-Security-Policy`. `script-src`
    /// is filled in by `shellPolicy(html:)`.
    static let shellDirectives: [(name: String, value: String)] = [
        ("default-src", "'self'"), ("script-src", "'self'"),
        // Svelte sets styles from script; the bundle has no inline `<style>`.
        ("style-src", "'self' 'unsafe-inline'"),
        // An artifact image is shown from memory: a `blob:` or a `data:` address.
        ("img-src", "'self' data: blob:"), ("media-src", "'self' data: blob:"),
        ("font-src", "'self' data:"), ("connect-src", "'self'"), ("worker-src", "'self'"),
        ("manifest-src", "'self'"), ("frame-src", "'none'"), ("object-src", "'none'"),
        ("base-uri", "'none'"), ("form-action", "'none'"), ("frame-ancestors", "'none'"),
    ]

    private static let scriptTag = try! NSRegularExpression(
        pattern: #"<script\b([^>]*)>(.*?)</script>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let srcAttribute = try! NSRegularExpression(
        pattern: #"(^|\s)src\s*="#, options: [.caseInsensitive])

    /// The policy sent with every file of the bundle. The shell's own inline
    /// scripts (SvelteKit's start-up code) are allowed by the hash of their
    /// text, read from `html`; no other inline script runs. A page made from a
    /// `blob:` address takes the policy of the page that made it, so a file
    /// with a script in it runs nothing even when it is opened as a page.
    static func shellPolicy(html: String) -> String {
        var hashes: [String] = []
        let whole = NSRange(html.startIndex..., in: html)
        for match in scriptTag.matches(in: html, range: whole) {
            guard let attributes = Range(match.range(at: 1), in: html),
                  let text = Range(match.range(at: 2), in: html) else { continue }
            let tag = String(html[attributes])
            guard srcAttribute.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) == nil
            else { continue }
            let digest = Data(SHA256.hash(data: Data(html[text].utf8))).base64EncodedString()
            hashes.append("'sha256-\(digest)'")
        }
        return shellDirectives.map { directive in
            directive.name == "script-src"
                ? ([directive.name, directive.value] + hashes).joined(separator: " ")
                : "\(directive.name) \(directive.value)"
        }.joined(separator: "; ")
    }

    /// Hashed build files never change; everything else (the shell, the service
    /// worker, the manifest) is revalidated on each load.
    static func cacheControl(forPath path: String) -> String {
        path.hasPrefix("_app/immutable/") ? "public, max-age=31536000, immutable" : "no-cache"
    }
}

// MARK: - Threads and hosts

/// One host as the sidebar knows it: the input to `MobileSnapshot.build`.
struct MobileHostInput {
    var host: Host
    var colorHex: String
    var reachability: HostReachability
    var stats: HostStats?
    var sessions: [TmuxSession]
}

/// One row of the phone's thread list: an agent pane, or a window's active pane
/// when the window runs no agent.
struct MobileThread: Equatable {
    /// Host name + pane number. Resolved against the live snapshot on every
    /// request, so a stale id is a 404, never another pane.
    let id: String
    let host: Host
    let hostColor: String
    let session: String
    let window: Int
    let name: String
    let pane: String
    /// Threads in this window.
    var panes = 1
    /// The session's tmux id (`$3`), empty when the tree has none.
    var sessionId = ""
    let command: String
    let cwd: String
    let status: AttentionStatus
    let since: Int?
    let idleStage: IdleStage
    let lastPrompt: LastPrompt?
    let lastActivityAt: Int?
    let sessionActivity: Int
    let claudeSessionId: String?
    let codexSessionId: String?

    /// Transcripts are read from this Mac's disk, so only a local agent has chat.
    var hasChat: Bool { host.isLocal && (claudeSessionId != nil || codexSessionId != nil) }

    var json: [String: Any] {
        [
            "id": id, "host": host.name, "hostColor": hostColor, "local": host.isLocal,
            "session": session, "window": window, "name": name, "pane": pane, "panes": panes,
            "command": command, "cwd": cwd, "status": status.rawValue,
            "since": since ?? NSNull(), "idleStage": idleStage.apiName,
            "lastPrompt": lastPrompt.map { ["text": $0.text, "at": $0.at] as [String: Any] } ?? NSNull(),
            "lastActivityAt": lastActivityAt ?? NSNull(),
            "sessionActivity": sessionActivity, "chat": hasChat,
        ]
    }
}

extension IdleStage {
    var apiName: String {
        switch self {
        case .awake: return "awake"
        case .yawning: return "yawning"
        case .dozing: return "dozing"
        }
    }
}

extension HostReachability {
    var apiName: String {
        switch self {
        case .reachable: return "reachable"
        case .unreachable: return "unreachable"
        case .tmuxMissing: return "tmuxMissing"
        case .unknown: return "unknown"
        }
    }
}

extension HostStats {
    var json: [String: Any] {
        [
            "cpuPercent": cpuPercent ?? NSNull(), "load1": load1 ?? NSNull(),
            "cores": cores ?? NSNull(),
            "memUsedBytes": memUsedBytes ?? NSNull(), "memTotalBytes": memTotalBytes ?? NSNull(),
            "diskFreeBytes": diskFreeBytes ?? NSNull(), "diskTotalBytes": diskTotalBytes ?? NSNull(),
            "uptimeSeconds": uptimeSeconds.map { Int($0) } ?? NSNull(),
        ]
    }
}

struct MobileHostInfo: Equatable {
    let host: Host
    let color: String
    let reachability: HostReachability
    let stats: HostStats?
    let threads: Int

    var json: [String: Any] {
        [
            "name": host.name, "color": color, "local": host.isLocal,
            "reachability": reachability.apiName, "threads": threads,
            "stats": stats?.json ?? NSNull(),
        ]
    }
}

/// Everything the phone lists, taken from the tree the sidebar already polls.
struct MobileSnapshot: Equatable {
    var threads: [MobileThread] = []
    var hosts: [MobileHostInfo] = []

    func thread(id: String) -> MobileThread? { threads.first { $0.id == id } }

    /// The `/api/threads` body. Keys are sorted, so equal snapshots give equal
    /// bytes and the server can tell when to push an event.
    func threadsJSON() -> Data {
        encode(["threads": threads.map(\.json)])
    }

    func hostsJSON() -> Data {
        encode(["hosts": hosts.map(\.json)])
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func build(_ inputs: [MobileHostInput]) -> MobileSnapshot {
        var snapshot = MobileSnapshot()
        for input in inputs {
            var count = 0
            for session in input.sessions {
                for window in session.windows {
                    let rows = threads(in: window, session: session, input: input)
                    count += rows.count
                    snapshot.threads += rows
                }
            }
            snapshot.hosts.append(MobileHostInfo(
                host: input.host, color: input.colorHex, reachability: input.reachability,
                stats: input.stats, threads: count))
        }
        return snapshot
    }

    /// Every pane of `window` that runs an agent; else its one active pane, so a
    /// plain shell still has a row and a terminal view.
    private static func threads(
        in window: TmuxWindow, session: TmuxSession, input: MobileHostInput
    ) -> [MobileThread] {
        var panes = window.panes.filter { $0.claudeSessionId != nil || $0.codexSessionId != nil }
        if panes.isEmpty, let pane = window.agentPane { panes = [pane] }
        return panes.map { pane in
            MobileThread(
                id: threadID(host: input.host, pane: pane.id),
                host: input.host, hostColor: input.colorHex,
                session: session.name, window: window.index, name: windowName(window),
                pane: pane.id, panes: panes.count, sessionId: session.id, command: pane.command,
                cwd: pane.path.isEmpty ? window.cwd : pane.path,
                status: pane.attention, since: pane.agentState?.since,
                idleStage: pane.idleStage, lastPrompt: pane.lastPrompt,
                lastActivityAt: pane.lastActivityAt, sessionActivity: session.activity,
                claudeSessionId: pane.claudeSessionId, codexSessionId: pane.codexSessionId)
        }
    }

    static func threadID(host: Host, pane: String) -> String {
        "\(host.name):\(pane.hasPrefix("%") ? String(pane.dropFirst()) : pane)"
    }

    /// The window name without the 🥱 / 💤 tags: the API sends the stage itself.
    static func windowName(_ window: TmuxWindow) -> String {
        window.name.split(separator: " ", omittingEmptySubsequences: true)
            .filter { !IdleStage.allTags.contains(String($0)) }.joined(separator: " ")
    }
}

// MARK: - Chat

struct MobileChatMessage: Equatable {
    enum Role: String { case user, assistant, tool }

    /// Increases through the transcript; the client keys rows on it.
    let n: UInt64
    let role: Role
    let text: String
    /// The tool's name, for a `tool` row.
    var tool: String? = nil

    var json: [String: Any] {
        var out: [String: Any] = ["n": n, "role": role.rawValue, "text": text]
        if let tool { out["tool"] = tool }
        return out
    }
}

struct MobileChatPage: Equatable {
    var messages: [MobileChatMessage] = []
    /// Pass back as `after` to get only what was written since.
    var next: UInt64 = 0
    /// The client must drop what it holds and show `messages` alone.
    var reset = false

    var json: [String: Any] {
        ["messages": messages.map(\.json), "next": next, "reset": reset]
    }
}

/// A local agent transcript (Claude Code JSONL or a Codex rollout) as chat rows.
enum MobileChat {
    /// How far back the first page reads, and the most rows it returns.
    static let tailBytes: UInt64 = 600_000
    static let firstPageLimit = 200
    /// A reply longer than this is cut; the phone is for triage, not for reading
    /// a whole diff.
    static let maxTextLength = 8000

    /// Read `path` from the cursor `after` (nil: the recent tail).
    static func read(path: String, codex: Bool, after: UInt64?) -> MobileChatPage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var page = MobileChatPage()
        var start = after ?? 0
        // No cursor, a file that was rewritten shorter, or too much to catch up
        // on: start over from the tail.
        if after == nil || start > size || size - start > tailBytes {
            page.reset = after != nil
            start = size > tailBytes ? size - tailBytes : 0
        }
        var data = Data()
        if size > start {
            guard (try? handle.seek(toOffset: start)) != nil,
                  let read = try? handle.read(upToCount: Int(size - start))
            else { return nil }
            data = read
        }
        let tail = after == nil || page.reset
        // A read that starts mid-file starts mid-line: drop that partial line.
        let parsed = messages(in: data, offset: start, codex: codex, skipFirstLine: tail && start > 0)
        page.messages = tail ? Array(parsed.messages.suffix(firstPageLimit)) : parsed.messages
        page.next = parsed.next
        return page
    }

    /// The rows in `data`, which starts at byte `offset` of the transcript.
    /// `next` is the end of the last whole line, so a line still being written
    /// is read on the next call.
    static func messages(
        in data: Data, offset: UInt64, codex: Bool, skipFirstLine: Bool = false
    ) -> (messages: [MobileChatMessage], next: UInt64) {
        var out: [MobileChatMessage] = []
        var lineStart = data.startIndex
        var first = true
        while let newline = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = data[lineStart..<newline]
            let at = offset + UInt64(data.distance(from: data.startIndex, to: lineStart))
            lineStart = data.index(after: newline)
            defer { first = false }
            if first && skipFirstLine { continue }
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            let rows = codex
                ? codexRows(record) : claudeRows(record, line: String(decoding: line, as: UTF8.self))
            // A line is always longer than its row count, so `at + index` stays
            // unique and increasing across lines.
            for (index, row) in rows.enumerated() {
                out.append(MobileChatMessage(
                    n: at + UInt64(index), role: row.role, text: clip(row.text), tool: row.tool))
            }
        }
        return (out, offset + UInt64(data.distance(from: data.startIndex, to: lineStart)))
    }

    private typealias Row = (role: MobileChatMessage.Role, text: String, tool: String?)

    private static func claudeRows(_ record: [String: Any], line: String) -> [Row] {
        // A subagent's records are its own conversation, not this thread's.
        guard record["isSidechain"] as? Bool != true else { return [] }
        switch record["type"] as? String {
        case "assistant":
            return ManagerTranscript.contentBlocks(record).compactMap { block in
                switch block["type"] as? String {
                case "text":
                    guard let text = (block["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                    else { return nil }
                    return (.assistant, text, nil)
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    return (.tool, toolDetail(block["input"] as? [String: Any] ?? [:]), name)
                default:
                    return nil
                }
            }
        case "user", "attachment":
            // The manager's own prompt rules decide what counts as a human
            // prompt (no tool results, harness notes or injected tags).
            guard record["isCompactSummary"] as? Bool != true else { return [] }
            let text = ManagerTranscript.lastUserPromptText(lines: [line])
            return text.isEmpty ? [] : [(.user, text, nil)]
        default:
            return []
        }
    }

    private static func codexRows(_ record: [String: Any]) -> [Row] {
        guard record["type"] as? String == "response_item",
              let payload = record["payload"] as? [String: Any] else { return [] }
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant",
                  let blocks = payload["content"] as? [[String: Any]] else { return [] }
            let kind = role == "user" ? "input_text" : "output_text"
            let text = blocks.filter { $0["type"] as? String == kind }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Codex wraps the context it injects in tags; those are not prompts.
            guard !text.isEmpty, !(role == "user" && text.hasPrefix("<")) else { return [] }
            return [(role == "user" ? .user : .assistant, text, nil)]
        case "function_call":
            let name = payload["name"] as? String ?? "Tool"
            let input = (payload["arguments"] as? String)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            return [(.tool, toolDetail(input ?? [:]), name)]
        default:
            return []
        }
    }

    /// The one argument worth a line: the file, the command, the pattern.
    static func toolDetail(_ input: [String: Any]) -> String {
        for key in ["file_path", "path", "command", "pattern", "query", "url", "description", "prompt"] {
            if let text = input[key] as? String, !text.isEmpty {
                return String(text.split(whereSeparator: \.isNewline).first ?? "").prefixString(200)
            }
            if let argv = input[key] as? [String], !argv.isEmpty {
                return argv.joined(separator: " ").prefixString(200)
            }
        }
        return ""
    }

    private static func clip(_ text: String) -> String {
        text.count > maxTextLength ? text.prefixString(maxTextLength) + "…" : text
    }
}

private extension StringProtocol {
    func prefixString(_ length: Int) -> String { String(prefix(length)) }
}

// MARK: - Tailscale

/// The `tailscale` calls the Phone setting makes, and what it reads back.
enum MobileTailnet {
    static let statusArgv = ["status", "--json"]
    static let serveStatusArgv = ["serve", "status", "--json"]

    /// Publish the loopback listener on the tailnet, HTTPS, on the same port.
    static func serveOnArgv(port: Int) -> [String] {
        ["serve", "--bg", "--https=\(port)", "http://127.0.0.1:\(port)"]
    }

    static func serveOffArgv(port: Int) -> [String] {
        ["serve", "--https=\(port)", "off"]
    }

    /// This Mac's login and tailnet name from `tailscale status --json`.
    static func identity(statusJSON json: String) -> MobileIdentity? {
        // `parseTailscaleStatus` lists this Mac first, when it has a name.
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let me = root["Self"] as? [String: Any],
              let rawName = me["DNSName"] as? String, rawName.count > 1,
              let dnsName = HostAddress.parseTailscaleStatus(json)?.nodes.first?.dnsName,
              let userID = me["UserID"] as? NSNumber,
              let users = root["User"] as? [String: Any],
              let user = users[userID.stringValue] as? [String: Any],
              let login = user["LoginName"] as? String, !login.isEmpty
        else { return nil }
        return MobileIdentity(login: login, dnsName: dnsName)
    }

    /// Whether `tailscale serve` already publishes `port` for something other
    /// than this server. Turning the phone on must not take over a port another
    /// project serves.
    static func portTaken(serveStatusJSON json: String, port: Int) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return false }
        let mine = "http://127.0.0.1:\(port)"
        var handlers: [[String: Any]] = []
        for (name, value) in root["Web"] as? [String: Any] ?? [:] where name.hasSuffix(":\(port)") {
            let entries = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            handlers += entries.values.compactMap { $0 as? [String: Any] }
        }
        if handlers.isEmpty {
            // A raw TCP forward on the port has no web handler to compare.
            return (root["TCP"] as? [String: Any])?["\(port)"] != nil
        }
        return handlers.contains { $0["Proxy"] as? String != mine }
    }

    /// Whether `tailscale serve` still publishes `port` to our own listener: a
    /// mapping left behind by a crash or a forced quit.
    static func servesOurs(serveStatusJSON json: String, port: Int) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return false }
        let mine = "http://127.0.0.1:\(port)"
        for (name, value) in root["Web"] as? [String: Any] ?? [:] where name.hasSuffix(":\(port)") {
            let entries = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            let proxies = entries.values.compactMap { ($0 as? [String: Any])?["Proxy"] as? String }
            if !proxies.isEmpty, proxies.allSatisfy({ $0 == mine }) { return true }
        }
        return false
    }

    /// A new pairing token: 32 random bytes, safe in a URL fragment and a header.
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The link the QR code holds. The token rides in the fragment, which a
    /// browser never sends to a server or a proxy.
    static func pairingURL(identity: MobileIdentity, port: Int, token: String) -> String {
        url(identity: identity, port: port) + "#pair=" + token
    }

    static func url(identity: MobileIdentity, port: Int) -> String {
        port == 443 ? "https://\(identity.dnsName)/" : "https://\(identity.dnsName):\(port)/"
    }
}
