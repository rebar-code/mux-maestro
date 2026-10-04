import CryptoKit
import Foundation

// The pure half of the live terminal's WebSocket (RFC 6455): the upgrade
// decision, the frame parser and the limits. No sockets, so the test target
// compiles it. `MobileServer` owns the connection and calls into here.
//
// A browser cannot set a header on a WebSocket, so the pairing token is not
// in the upgrade request, and it is never in the URL. The upgrade is checked
// for the Tailscale login, the host name and the origin; then the phone sends
// the token as its first message, and the server sends nothing about a pane
// before that message is right.

enum MobileSocket {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    /// The largest message a paired phone may send: typed or pasted bytes.
    static let maxMessageBytes = 4096
    /// The largest first message: a pairing token is far shorter.
    static let maxTokenBytes = 512
    /// The most bytes of terminal output in one frame to the phone.
    static let maxOutputFrame = 32_768

    /// Why the server closes a socket. 4000 and up are this app's own codes;
    /// the phone decides from them whether to connect again.
    enum CloseCode: UInt16 {
        case normal = 1000
        case protocolError = 1002
        case unsupported = 1003
        case policy = 1008
        case badData = 1007
        case tooBig = 1009
        /// The phone did not read fast enough.
        case overloaded = 1013
        case unauthorized = 4401
        case disabled = 4403
        case notFound = 4404
        case idle = 4408
        /// A newer socket from the same phone took its place.
        case replaced = 4409
        /// The pane, its session or the link to its host went away.
        case gone = 4410
        case unavailable = 4503
    }

    enum Upgrade: Equatable {
        /// Answer 101 with `key`.
        case accept(thread: String, key: String)
        case refuse(MobileResponse)
    }

    /// The thread id of `/api/terminal/<id>`; nil for any other path.
    static func thread(_ request: MobileRequest) -> String? {
        let segments = request.segments
        guard segments.count == 3, segments[0] == "api", segments[1] == "terminal",
              !segments[2].isEmpty
        else { return nil }
        return segments[2]
    }

    /// Whether to open the live terminal's socket for `request`. nil when the
    /// request is not for the socket's path at all.
    ///
    /// Nothing here reads the tree: an answer never says whether a thread
    /// exists. That is asked only after the token came.
    static func upgrade(
        _ request: MobileRequest, identity: MobileIdentity?, config: MobileConfig
    ) -> Upgrade? {
        guard let thread = thread(request) else { return nil }
        // The login and the host name, as for every request.
        var read = request
        read.method = "GET"
        guard MobileAPI.authorize(read, identity: identity) == .allowed, let identity else {
            return .refuse(.error(403, "forbidden"))
        }
        guard request.method == "GET" else { return .refuse(.error(405, "method_not_allowed")) }
        guard config.allows(.liveTerminal) else { return .refuse(.error(403, "disabled")) }
        // Nothing rides in the URL: a query could only be a token put where
        // proxies and logs would keep it.
        guard request.query.isEmpty, request.body.isEmpty else {
            return .refuse(.error(400, "bad_request"))
        }
        let tokens = { (name: String) in
            (request.header(name) ?? "").lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard tokens("upgrade").contains("websocket"), tokens("connection").contains("upgrade") else {
            return .refuse(.error(426, "upgrade_required"))
        }
        guard request.header("sec-websocket-version") == "13" else {
            var response = MobileResponse.error(426, "upgrade_required")
            response.headers["Sec-WebSocket-Version"] = "13"
            return .refuse(response)
        }
        guard let key = request.header("sec-websocket-key"),
              Data(base64Encoded: key)?.count == 16
        else { return .refuse(.error(400, "bad_request")) }
        // The one defence against a page on another site opening the socket:
        // a browser always sends the page's origin, and cannot be made to lie.
        guard MobileAPI.sameOrigin(request, identity: identity) else {
            return .refuse(.error(403, "origin"))
        }
        return .accept(thread: thread, key: key)
    }

    static func acceptKey(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
    }

    /// The 101 answer. No subprotocol and no extension is ever agreed.
    static func handshake(key: String) -> Data {
        Data((
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(acceptKey(key))\r\n\r\n"
        ).utf8)
    }

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    /// One whole frame from the server: never masked, never fragmented.
    static func frame(_ opcode: Opcode, _ payload: Data = Data()) -> Data {
        var data = Data([0x80 | opcode.rawValue])
        switch payload.count {
        case ..<126:
            data.append(UInt8(payload.count))
        case ..<65_536:
            data.append(126)
            data.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            data.append(127)
            data.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 0xFF) })
        }
        data.append(payload)
        return data
    }

    static func close(_ code: CloseCode) -> Data {
        frame(.close, Data([UInt8(code.rawValue >> 8), UInt8(code.rawValue & 0xFF)]))
    }

    /// Terminal output as binary frames of at most `maxOutputFrame` bytes.
    static func binaryFrames(_ data: Data) -> Data {
        var out = Data()
        var rest = data[...]
        while !rest.isEmpty {
            let part = rest.prefix(maxOutputFrame)
            out.append(frame(.binary, Data(part)))
            rest = rest.dropFirst(part.count)
        }
        return out
    }

    /// A control message for the phone's own code. Never terminal output.
    static func textFrame(_ object: [String: Any]) -> Data {
        frame(.text, (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8))
    }
}

/// One whole message from the phone.
enum MobileSocketMessage: Equatable {
    case text(Data)
    case binary(Data)
    case ping(Data)
    case pong
    case close
}

/// The frames the phone sends, as messages. It holds at most one frame header
/// and `maxMessage` bytes, whatever it is fed: a length past the limit is
/// refused when its header is read, before any of its payload is kept.
struct MobileSocketReader {
    /// The most bytes one message may hold, over all its fragments.
    var maxMessage: Int

    private var buffer = Data()
    private var partial: (opcode: MobileSocket.Opcode, data: Data)?
    private var failed: MobileSocket.CloseCode?
    private var frames = 0

    init(maxMessage: Int) { self.maxMessage = maxMessage }

    /// Frames read since this was last asked. Every frame counts towards the
    /// rate, a fragment with nothing in it too.
    mutating func takeFrames() -> Int {
        defer { frames = 0 }
        return frames
    }

    enum Fed: Equatable {
        case messages([MobileSocketMessage])
        /// The messages that were whole, then the reason to close.
        case failed([MobileSocketMessage], MobileSocket.CloseCode)
    }

    mutating func feed(_ data: Data) -> Fed {
        if let failed { return .failed([], failed) }
        buffer.append(data)
        var out: [MobileSocketMessage] = []
        while true {
            switch next() {
            case .none:
                return .messages(out)
            case .some(.success(let message)):
                if let message { out.append(message) }
            case .some(.failure(let code)):
                failed = code.code
                buffer = Data()
                partial = nil
                return .failed(out, code.code)
            }
        }
    }

    private struct Failure: Error { let code: MobileSocket.CloseCode }

    /// The next frame of the buffer: nil when more bytes are needed, a nil
    /// message for a fragment that does not end one.
    private mutating func next() -> Result<MobileSocketMessage?, Failure>? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        // No extension is agreed, so the reserved bits are never set.
        guard bytes[0] & 0x70 == 0, let opcode = MobileSocket.Opcode(rawValue: bytes[0] & 0x0F)
        else { return .failure(Failure(code: .protocolError)) }
        // A browser masks every frame it sends. One that is not masked did not
        // come from a browser's WebSocket.
        guard bytes[1] & 0x80 != 0 else { return .failure(Failure(code: .protocolError)) }
        var length = UInt64(bytes[1] & 0x7F)
        var header = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            guard length >= 126 else { return .failure(Failure(code: .protocolError)) }
            header = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
            guard length >= 65_536, length >> 63 == 0 else {
                return .failure(Failure(code: .protocolError))
            }
            header = 10
        }
        let control = opcode.rawValue >= 0x8
        if control {
            guard fin, length <= 125 else { return .failure(Failure(code: .protocolError)) }
        } else {
            switch (opcode, partial != nil) {
            case (.continuation, false), (.text, true), (.binary, true):
                return .failure(Failure(code: .protocolError))
            default:
                break
            }
            guard length + UInt64(partial?.data.count ?? 0) <= UInt64(maxMessage) else {
                return .failure(Failure(code: .tooBig))
            }
        }
        let size = Int(length)
        guard bytes.count >= header + 4, buffer.count >= header + 4 + size else { return nil }
        let mask = Array(bytes[header..<header + 4])
        var payload = [UInt8](buffer.dropFirst(header + 4).prefix(size))
        for index in payload.indices { payload[index] ^= mask[index % 4] }
        buffer = Data(buffer.dropFirst(header + 4 + size))
        frames += 1

        switch opcode {
        case .close:
            // No payload, or a whole code and a reason that is text.
            guard payload.count != 1 else { return .failure(Failure(code: .protocolError)) }
            guard String(validatingUTF8Bytes: payload.dropFirst(2)) != nil else {
                return .failure(Failure(code: .badData))
            }
            return .success(.close)
        case .ping: return .success(.ping(Data(payload)))
        case .pong: return .success(.pong)
        case .text, .binary, .continuation:
            var message = partial ?? (opcode, Data())
            message.data.append(contentsOf: payload)
            guard fin else {
                partial = message
                return .success(nil)
            }
            partial = nil
            guard message.opcode == .text else { return .success(.binary(message.data)) }
            guard String(validatingUTF8Bytes: message.data) != nil else {
                return .failure(Failure(code: .badData))
            }
            return .success(.text(message.data))
        }
    }
}

/// A token bucket: `perSecond` messages a second, `burst` at once.
struct MobileSocketRate {
    let perSecond: Double
    let burst: Double
    private var tokens: Double
    private var last: TimeInterval?

    init(perSecond: Double, burst: Double) {
        self.perSecond = perSecond
        self.burst = burst
        tokens = burst
    }

    /// Whether one more message may come at `now` (seconds, any clock).
    mutating func allow(now: TimeInterval) -> Bool {
        if let last { tokens = min(burst, tokens + max(0, now - last) * perSecond) }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

private extension String {
    /// `bytes` as text, or nil when they are not UTF-8.
    init?<Bytes: Sequence>(validatingUTF8Bytes bytes: Bytes) where Bytes.Element == UInt8 {
        // A decode that repairs nothing: bytes that are not UTF-8 give nil.
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var text = ""
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): text.unicodeScalars.append(scalar)
            case .emptyInput:
                self = text
                return
            case .error: return nil
            }
        }
    }
}
