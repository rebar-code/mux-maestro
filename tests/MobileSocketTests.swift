import XCTest

// The pure half of the live terminal's socket: the upgrade decision, the frame
// parser fed hostile input, and the limits.
final class MobileSocketTests: XCTestCase {
    private let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")
    private var on: MobileConfig { MobileConfig(capabilities: [.liveTerminal]) }

    private func request(
        _ path: String = "/api/terminal/devbox:12", method: String = "GET",
        _ change: (inout [String: String]) -> Void = { _ in }
    ) -> MobileRequest {
        var headers = [
            "host": "devmac.example.ts.net:7433", "tailscale-user-login": "me@example.com",
            "origin": "https://devmac.example.ts.net:7433", "upgrade": "websocket",
            "connection": "keep-alive, Upgrade", "sec-websocket-version": "13",
            "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==", "x-forwarded-for": "100.64.0.7",
        ]
        change(&headers)
        let raw = "\(method) \(path) HTTP/1.1\r\n"
            + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        guard case .request(let request, _) = MobileHTTP.parse(Data(raw.utf8)) else {
            XCTFail("unparsed")
            return MobileRequest(method: method, path: path)
        }
        return request
    }

    private func refusal(_ request: MobileRequest, config: MobileConfig? = nil) -> (Int, String)? {
        guard case .refuse(let response) = MobileSocket.upgrade(
            request, identity: identity, config: config ?? on)
        else { return nil }
        let code = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"]
        return (response.status, code as? String ?? "")
    }

    // MARK: upgrade

    func testAGoodUpgradeIsAcceptedWithTheThread() {
        XCTAssertEqual(
            MobileSocket.upgrade(request(), identity: identity, config: on),
            .accept(thread: "devbox:12", key: "dGhlIHNhbXBsZSBub25jZQ=="))
    }

    func testAcceptKeyIsTheOneOfRFC6455() {
        XCTAssertEqual(
            MobileSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let head = String(decoding: MobileSocket.handshake(key: "dGhlIHNhbXBsZSBub25jZQ=="), as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(head.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertFalse(head.lowercased().contains("sec-websocket-protocol"))
        XCTAssertFalse(head.lowercased().contains("sec-websocket-extensions"))
    }

    func testOtherPathsAreNotTheSocket() {
        XCTAssertNil(MobileSocket.upgrade(request("/api/threads"), identity: identity, config: on))
        XCTAssertNil(MobileSocket.upgrade(request("/api/terminal"), identity: identity, config: on))
        XCTAssertNil(MobileSocket.upgrade(request("/api/terminal/a/b"), identity: identity, config: on))
    }

    func testABadOriginIsRefused() {
        for origin in [
            "https://evil.example.com", "https://devmac.example.ts.net:8443",
            "https://devmac.example.ts.net", "http://devmac.example.ts.net:7433", "null", "",
        ] {
            let got = refusal(request { $0["origin"] = origin })
            XCTAssertEqual(got?.0, 403, origin)
            XCTAssertEqual(got?.1, "origin", origin)
        }
        // No Origin at all: not a browser's socket from the app.
        XCTAssertEqual(refusal(request { $0["origin"] = nil })?.1, "origin")
    }

    func testAMissingOrForeignLoginIsRefused() {
        XCTAssertEqual(refusal(request { $0["tailscale-user-login"] = nil })?.0, 403)
        XCTAssertEqual(refusal(request { $0["tailscale-user-login"] = "you@example.com" })?.1, "forbidden")
    }

    func testAnotherHostNameIsRefused() {
        let got = refusal(request {
            $0["host"] = "evil.example.com:7433"
            $0["origin"] = "https://evil.example.com:7433"
        })
        XCTAssertEqual(got?.1, "forbidden")
    }

    func testTheCapabilityIsOffByDefault() {
        XCTAssertFalse(MobileConfig().allows(.liveTerminal))
        let got = refusal(request(), config: MobileConfig())
        XCTAssertEqual(got?.0, 403)
        XCTAssertEqual(got?.1, "disabled")
        // Every other switch on does not turn it on.
        let others = Set(MobileCapability.allCases).subtracting([.liveTerminal])
        XCTAssertEqual(refusal(request(), config: MobileConfig(capabilities: others))?.1, "disabled")
    }

    func testATokenInTheURLIsRefused() {
        for path in ["/api/terminal/devbox:12?token=demo-token", "/api/terminal/devbox:12?t", "/api/terminal/devbox:12?pair=x&y=1"] {
            let got = refusal(request(path))
            XCTAssertEqual(got?.0, 400, path)
        }
    }

    func testATokenHeaderDoesNotStandInForTheUpgradeChecks() {
        let got = refusal(request {
            $0["x-muxmaestro-token"] = "demo-token"
            $0["origin"] = "https://evil.example.com"
        })
        XCTAssertEqual(got?.1, "origin")
    }

    func testAPlainRequestIsNotUpgraded() {
        XCTAssertEqual(refusal(request { $0["upgrade"] = nil })?.0, 426)
        XCTAssertEqual(refusal(request { $0["connection"] = "keep-alive" })?.0, 426)
        XCTAssertEqual(refusal(request { $0["sec-websocket-version"] = "8" })?.0, 426)
        XCTAssertEqual(refusal(request { $0["sec-websocket-key"] = "short" })?.0, 400)
        XCTAssertEqual(refusal(request { $0["sec-websocket-key"] = nil })?.0, 400)
        XCTAssertEqual(refusal(request(method: "POST"))?.0, 405)
    }

    func testTheRouteBelongsToTheLiveTerminalSwitch() {
        XCTAssertEqual(MobileEndpoint.terminal(id: "devbox:12").capability, .liveTerminal)
        XCTAssertEqual(MobileAPI.route(request(), config: MobileConfig()), .disabled(.liveTerminal))
        XCTAssertEqual(MobileAPI.route(request(), config: on), .api(.terminal(id: "devbox:12")))
    }

    // MARK: token

    func testTokenComparison() {
        XCTAssertTrue(MobileAPI.sameToken("demo-token", token: "demo-token"))
        XCTAssertFalse(MobileAPI.sameToken("demo-toke", token: "demo-token"))
        XCTAssertFalse(MobileAPI.sameToken("demo-token-and-more", token: "demo-token"))
        XCTAssertFalse(MobileAPI.sameToken("", token: "demo-token"))
        XCTAssertFalse(MobileAPI.sameToken("", token: ""))
        XCTAssertFalse(MobileAPI.sameToken("demo-token", token: nil))
        // The server holds the digest alone.
        let digest = MobileAPI.tokenDigest("demo-token")
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(MobileAPI.sameToken("demo-token", digest: digest))
        XCTAssertFalse(MobileAPI.sameToken("demo-toke", digest: digest))
        XCTAssertFalse(MobileAPI.sameToken(digest, digest: digest))
        XCTAssertFalse(MobileAPI.sameToken("demo-token", digest: nil))
        XCTAssertFalse(MobileAPI.sameToken("demo-token", digest: ""))
    }

    // MARK: policy

    func testThePolicyAllowsTheAppsOwnSocketAndNoOther() {
        let socket = MobileAPI.socketOrigin(request(), identity: identity)
        XCTAssertEqual(socket, "wss://devmac.example.ts.net:7433")
        let policy = MobileAPI.shellPolicy(html: "<html></html>", socket: socket)
        XCTAssertTrue(policy.contains("connect-src 'self' wss://devmac.example.ts.net:7433;"))
        XCTAssertFalse(policy.contains("unsafe-eval"))
        XCTAssertFalse(policy.contains("wss:;"))
        XCTAssertFalse(policy.contains("wss://*"))
        XCTAssertEqual(
            MobileAPI.socketOrigin(request { $0["host"] = "devmac.example.ts.net" }, identity: identity),
            "wss://devmac.example.ts.net")
        XCTAssertTrue(MobileAPI.shellPolicy(html: "").contains("connect-src 'self';"))
    }

    // MARK: frames

    /// A frame as a phone sends it.
    static func frame(
        _ opcode: UInt8, _ payload: [UInt8] = [], fin: Bool = true, masked: Bool = true,
        reserved: UInt8 = 0, mask: [UInt8] = [0x11, 0x22, 0x33, 0x44], length: UInt64? = nil
    ) -> Data {
        var data = Data([(fin ? 0x80 : 0) | reserved | opcode])
        let count = length ?? UInt64(payload.count)
        let bit: UInt8 = masked ? 0x80 : 0
        if count < 126 {
            data.append(bit | UInt8(count))
        } else if count < 65_536 {
            data.append(bit | 126)
            data.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            data.append(bit | 127)
            data.append(contentsOf: (0..<8).reversed().map { UInt8((count >> ($0 * 8)) & 0xFF) })
        }
        if masked {
            data.append(contentsOf: mask)
            data.append(contentsOf: payload.enumerated().map { $1 ^ mask[$0 % 4] })
        } else {
            data.append(contentsOf: payload)
        }
        return data
    }

    private func reader(_ max: Int = 64) -> MobileSocketReader { MobileSocketReader(maxMessage: max) }

    func testAMaskedFrameIsOneMessage() {
        var reader = reader()
        XCTAssertEqual(reader.feed(Self.frame(1, Array("hi".utf8))), .messages([.text(Data("hi".utf8))]))
        XCTAssertEqual(reader.feed(Self.frame(2, [0, 255, 27])), .messages([.binary(Data([0, 255, 27]))]))
    }

    func testAnUnmaskedFrameIsAProtocolError() {
        var reader = reader()
        XCTAssertEqual(reader.feed(Self.frame(2, [1], masked: false)), .failed([], .protocolError))
        // And the reader takes nothing after it.
        XCTAssertEqual(reader.feed(Self.frame(2, [1])), .failed([], .protocolError))
    }

    func testBytesOneAtATimeGiveTheSameMessages() {
        var reader = reader()
        let bytes = Self.frame(2, Array("abc".utf8)) + Self.frame(9, [7]) + Self.frame(2, Array("d".utf8))
        var got: [MobileSocketMessage] = []
        for byte in bytes {
            guard case .messages(let messages) = reader.feed(Data([byte])) else { return XCTFail("failed") }
            got += messages
        }
        XCTAssertEqual(got, [.binary(Data("abc".utf8)), .ping(Data([7])), .binary(Data("d".utf8))])
    }

    func testFragmentsJoinAndAControlFrameMayComeBetweenThem() {
        var reader = reader()
        let bytes = Self.frame(2, Array("ab".utf8), fin: false) + Self.frame(9)
            + Self.frame(0, Array("cd".utf8), fin: false) + Self.frame(0, Array("e".utf8))
        XCTAssertEqual(reader.feed(bytes), .messages([.ping(Data()), .binary(Data("abcde".utf8))]))
    }

    func testFragmentsOutOfOrderAreProtocolErrors() {
        var first = reader()
        XCTAssertEqual(first.feed(Self.frame(0, [1])), .failed([], .protocolError))
        var second = reader()
        XCTAssertEqual(
            second.feed(Self.frame(2, [1], fin: false) + Self.frame(2, [2])), .failed([], .protocolError))
    }

    func testAnOversizeFrameIsRefusedFromItsHeaderAlone() {
        var reader = reader(64)
        // The header says 65 bytes; none of them was sent.
        XCTAssertEqual(reader.feed(Self.frame(2, length: 65).prefix(2)), .failed([], .tooBig))
        var huge = self.reader(64)
        XCTAssertEqual(huge.feed(Self.frame(2, length: 1 << 40).prefix(10)), .failed([], .tooBig))
        var exact = self.reader(64)
        XCTAssertEqual(
            exact.feed(Self.frame(2, [UInt8](repeating: 1, count: 64))),
            .messages([.binary(Data(repeating: 1, count: 64))]))
    }

    func testFragmentsCannotAddUpPastTheLimit() {
        var reader = reader(64)
        let part = [UInt8](repeating: 1, count: 40)
        XCTAssertEqual(reader.feed(Self.frame(2, part, fin: false)), .messages([]))
        XCTAssertEqual(reader.feed(Self.frame(0, part)), .failed([], .tooBig))
    }

    func testALengthWithItsTopBitSetIsAProtocolError() {
        var reader = reader()
        var bytes = Data([0x82, 0xFF] as [UInt8])
        bytes.append(contentsOf: [0xFF, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(reader.feed(bytes), .failed([], .protocolError))
    }

    func testALengthThatIsNotTheShortestFormIsAProtocolError() {
        var reader = reader(1 << 20)
        XCTAssertEqual(reader.feed(Data([0x82, 0xFE, 0, 5] as [UInt8])), .failed([], .protocolError))
        var other = self.reader(1 << 20)
        var bytes = Data([0x82, 0xFF] as [UInt8])
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 1, 0])
        XCTAssertEqual(other.feed(bytes), .failed([], .protocolError))
    }

    func testBadOpcodesAndReservedBitsAreProtocolErrors() {
        for opcode: UInt8 in [3, 4, 5, 6, 7, 0xB, 0xC, 0xD, 0xE, 0xF] {
            var reader = reader()
            XCTAssertEqual(reader.feed(Self.frame(opcode, [1])), .failed([], .protocolError), "\(opcode)")
        }
        for reserved: UInt8 in [0x40, 0x20, 0x10] {
            var reader = reader()
            XCTAssertEqual(
                reader.feed(Self.frame(2, [1], reserved: reserved)), .failed([], .protocolError))
        }
    }

    func testControlFramesAreShortAndWhole() {
        var long = reader(1 << 20)
        XCTAssertEqual(
            long.feed(Self.frame(9, [UInt8](repeating: 0, count: 126))), .failed([], .protocolError))
        var split = reader()
        XCTAssertEqual(split.feed(Self.frame(9, [1], fin: false)), .failed([], .protocolError))
    }

    func testTheMessagesBeforeAFailureAreStillGiven() {
        var reader = reader()
        XCTAssertEqual(
            reader.feed(Self.frame(2, [1]) + Self.frame(3, [2])), .failed([.binary(Data([1]))], .protocolError))
    }

    func testACloseWithHalfACodeIsAProtocolError() {
        var reader = reader()
        XCTAssertEqual(reader.feed(Self.frame(8, [3])), .failed([], .protocolError))
        var empty = self.reader()
        XCTAssertEqual(empty.feed(Self.frame(8)), .messages([.close]))
        var bad = self.reader()
        XCTAssertEqual(bad.feed(Self.frame(8, [3, 232, 0xFF, 0xFE])), .failed([], .badData))
    }

    func testTextThatIsNotUTF8IsRefused() {
        var reader = reader()
        XCTAssertEqual(reader.feed(Self.frame(1, [0xC3, 0x28])), .failed([], .badData))
        var split = self.reader()
        // A character cut in two by a fragment is whole once joined.
        XCTAssertEqual(
            split.feed(Self.frame(1, [0xC3], fin: false) + Self.frame(0, [0xA9])),
            .messages([.text(Data([0xC3, 0xA9]))]))
        var binary = self.reader()
        XCTAssertEqual(binary.feed(Self.frame(2, [0xC3, 0x28])), .messages([.binary(Data([0xC3, 0x28]))]))
    }

    func testEveryFrameIsCountedEvenAnEmptyFragment() {
        var reader = reader()
        _ = reader.feed(Self.frame(2, [], fin: false) + Self.frame(0, [], fin: false) + Self.frame(9))
        XCTAssertEqual(reader.takeFrames(), 3)
        XCTAssertEqual(reader.takeFrames(), 0)
    }

    func testCloseAndPong() {
        var reader = reader()
        XCTAssertEqual(reader.feed(Self.frame(10) + Self.frame(8, [3, 232])), .messages([.pong, .close]))
    }

    func testRandomBytesNeverCrashOrGrowTheReader() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var reader = reader(256)
            for _ in 0..<20 {
                let chunk = (0..<Int.random(in: 1...64, using: &generator))
                    .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
                if case .failed = reader.feed(Data(chunk)) { break }
            }
        }
    }

    // MARK: frames out

    func testServerFramesAreNotMaskedAndCarryTheirLength() {
        XCTAssertEqual(MobileSocket.frame(.binary, Data([1, 2])), Data([0x82, 2, 1, 2]))
        let medium = MobileSocket.frame(.binary, Data(repeating: 7, count: 300))
        XCTAssertEqual(Array(medium.prefix(4)), [0x82, 126, 1, 44])
        XCTAssertEqual(medium.count, 304)
        XCTAssertEqual(MobileSocket.close(.unauthorized), Data([0x88, 2, 0x11, 0x31]))
    }

    func testOutputIsCutIntoBoundedBinaryFrames() {
        let data = Data(repeating: 65, count: MobileSocket.maxOutputFrame * 2 + 5)
        let frames = MobileSocket.binaryFrames(data)
        // Two full frames with a 4-byte header, and the rest with a 2-byte one.
        XCTAssertEqual(frames.count, data.count + 10)
        XCTAssertEqual(frames.first, 0x82)
    }

    // MARK: rate

    func testTheRateLimitRefillsWithTime() {
        var rate = MobileSocketRate(perSecond: 10, burst: 3)
        XCTAssertTrue(rate.allow(now: 0))
        XCTAssertTrue(rate.allow(now: 0))
        XCTAssertTrue(rate.allow(now: 0))
        XCTAssertFalse(rate.allow(now: 0))
        XCTAssertFalse(rate.allow(now: 0.05))
        XCTAssertTrue(rate.allow(now: 0.2))
        // A long quiet time gives the burst, not more.
        XCTAssertTrue(rate.allow(now: 100))
        XCTAssertTrue(rate.allow(now: 100))
        XCTAssertTrue(rate.allow(now: 100))
        XCTAssertFalse(rate.allow(now: 100))
    }
}
