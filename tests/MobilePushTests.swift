import CryptoKit
import Network
import XCTest

/// A token store that lives in memory: the tests never touch the Keychain.
final class MemoryTokenStore: PhoneTokenStore {
    private let lock = NSLock()
    private var value: String?
    private var refusing = false

    init(_ value: String? = nil) { self.value = value }

    var stored: String? { lock.lock(); defer { lock.unlock() }; return value }
    func refuse() { lock.lock(); refusing = true; lock.unlock() }

    func load() -> String? { stored }
    func save(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !refusing else { return false }
        value = token
        return true
    }
}

/// The push service, scripted. Nothing leaves the process.
final class FakePushTransport: PushTransport {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var statuses: [String: Int?] = [:]

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    /// What the service answers for `endpoint` (default 201). nil: no answer.
    func answer(_ endpoint: String, _ status: Int?) {
        lock.lock(); statuses.updateValue(status, forKey: endpoint); lock.unlock()
    }

    func send(_ request: URLRequest, completion: @escaping (Int?) -> Void) {
        lock.lock()
        _requests.append(request)
        let status = statuses[request.url?.absoluteString ?? ""] ?? 201
        lock.unlock()
        completion(status)
    }
}

/// A phone: a key pair, a secret and an endpoint, as a browser would make them.
struct FakePhone {
    let key = P256.KeyAgreement.PrivateKey()
    let auth = WebPushCrypto.randomSalt()
    let endpoint: String

    init(_ endpoint: String = "https://web.push.apple.com/QDemoPhone1") { self.endpoint = endpoint }

    var p256dh: String { Base64URL.encode(key.publicKey.x963Representation) }

    var body: Data {
        try! JSONSerialization.data(withJSONObject: [
            "endpoint": endpoint, "keys": ["p256dh": p256dh, "auth": Base64URL.encode(auth)],
        ])
    }

    func focus(_ thread: String?) -> Data {
        let object: [String: Any] = ["endpoint": endpoint, "thread": thread.map { $0 as Any } ?? NSNull()]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// What the phone's browser reads out of a push message.
    func open(_ request: URLRequest) throws -> [String: Any] {
        let plain = try WebPushTestCrypto.decrypt(request.httpBody ?? Data(), receiver: key, auth: auth)
        return try JSONSerialization.jsonObject(with: plain) as? [String: Any] ?? [:]
    }
}

/// The receiving half of RFC 8291, written apart from the app's sender.
enum WebPushTestCrypto {
    static func decrypt(_ message: Data, receiver: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        let body = Data(message)
        let salt = body.prefix(16)
        let keyLength = Int(body[20])
        let senderPublic = Data(body.dropFirst(21).prefix(keyLength))
        let sealed = Data(body.dropFirst(21 + keyLength))
        let sender = try P256.KeyAgreement.PublicKey(x963Representation: senderPublic)
        let secret = try receiver.sharedSecretFromKeyAgreement(with: sender)
        let info = Data("WebPush: info\0".utf8) + receiver.publicKey.x963Representation + senderPublic
        let ikm = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: auth, sharedInfo: info, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8),
            outputByteCount: 12)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }),
            ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        var plain = try AES.GCM.open(box, using: key)
        XCTAssertEqual(plain.popLast(), 0x02)
        return plain
    }
}

final class MobilePushTests: XCTestCase {
    private let transport = FakePushTransport()
    private let keys = MemoryTokenStore()
    private let store = MemoryTokenStore()
    private var clock = 1_800_000_000

    private func center(limiter: MobilePushLimiter = MobilePushLimiter()) -> MobilePushCenter {
        MobilePushCenter(
            keys: keys, store: store, transport: transport, limiter: limiter,
            now: { [unowned self] in Date(timeIntervalSince1970: TimeInterval(self.clock)) })
    }

    /// Everything the center queued has run.
    private func settle(_ center: MobilePushCenter) { _ = center.count; _ = center.count }

    private func waiting(_ thread: String = "localhost:12") -> MobilePushEvent {
        MobilePushEvent(
            kind: .waiting, thread: thread, name: "acme-app · checkout-fix",
            prompt: "fix the checkout total rounding")
    }

    // MARK: RFC 8291

    private let rfcPlain = "When I grow up, I want to be a watermelon"
    private let rfcAuth = "BTBZMqHH6r4Tts7J_aSIgg"
    private let rfcSalt = "DGv6ra1nlYgDCS1FRnbzlw"
    private let rfcReceiverPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
    private let rfcReceiverPublic =
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    private let rfcSenderPrivate = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
    private let rfcMessage =
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
        + "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
        + "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

    func testEncryptsTheRFC8291ExampleToTheSameBytes() throws {
        let receiver = try XCTUnwrap(MobilePush.publicKey(rfcReceiverPublic))
        let sender = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(Base64URL.decode(rfcSenderPrivate)))
        let message = try WebPushCrypto.encrypt(
            Data(rfcPlain.utf8), receiver: receiver, auth: XCTUnwrap(Base64URL.decode(rfcAuth)),
            sender: sender, salt: XCTUnwrap(Base64URL.decode(rfcSalt)))
        XCTAssertEqual(Base64URL.encode(message), rfcMessage)
        // An 86-byte header, 41 bytes of text, the delimiter and the 16-byte tag.
        XCTAssertEqual(message.count, 144)
    }

    func testTheRFC8291ExampleDecryptsWithTheReceiversKey() throws {
        let receiver = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(Base64URL.decode(rfcReceiverPrivate)))
        let plain = try WebPushTestCrypto.decrypt(
            XCTUnwrap(Base64URL.decode(rfcMessage)), receiver: receiver,
            auth: XCTUnwrap(Base64URL.decode(rfcAuth)))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), rfcPlain)
    }

    func testEachMessageHasItsOwnSaltAndSenderKey() throws {
        let phone = FakePhone()
        let a = try WebPushCrypto.encrypt(Data("x".utf8), receiver: phone.key.publicKey, auth: phone.auth)
        let b = try WebPushCrypto.encrypt(Data("x".utf8), receiver: phone.key.publicKey, auth: phone.auth)
        XCTAssertNotEqual(a.prefix(16), b.prefix(16))
        XCTAssertNotEqual(a.dropFirst(21).prefix(65), b.dropFirst(21).prefix(65))
        XCTAssertEqual(try WebPushTestCrypto.decrypt(a, receiver: phone.key, auth: phone.auth), Data("x".utf8))
    }

    func testRefusesAPlaintextThatDoesNotFitOneRecord() {
        let phone = FakePhone()
        XCTAssertThrowsError(try WebPushCrypto.encrypt(
            Data(count: 4096), receiver: phone.key.publicKey, auth: phone.auth))
        XCTAssertThrowsError(try WebPushCrypto.encrypt(
            Data("x".utf8), receiver: phone.key.publicKey, auth: phone.auth, salt: Data(count: 8)))
    }

    // MARK: VAPID

    func testTheVAPIDTokenIsAnES256JWTThePublicKeyVerifies() throws {
        let key = VAPIDKey()
        let token = try XCTUnwrap(key.token(
            audience: "https://web.push.apple.com", subject: MobilePush.defaultSubject, now: clock))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let header = try JSONSerialization.jsonObject(
            with: XCTUnwrap(Base64URL.decode(parts[0]))) as? [String: String]
        XCTAssertEqual(header, ["alg": "ES256", "typ": "JWT"])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(Base64URL.decode(parts[1]))) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://web.push.apple.com")
        XCTAssertEqual(claims["sub"] as? String, "https://example.com/muxmaestro")
        let expires = try XCTUnwrap(claims["exp"] as? Int)
        XCTAssertGreaterThan(expires, clock)
        XCTAssertLessThanOrEqual(expires, clock + 24 * 3600)
        XCTAssertEqual(claims.count, 3)

        let signature = try XCTUnwrap(Base64URL.decode(parts[2]))
        XCTAssertEqual(signature.count, 64)
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: XCTUnwrap(Base64URL.decode(key.publicKey)))
        XCTAssertTrue(publicKey.isValidSignature(
            try P256.Signing.ECDSASignature(rawRepresentation: signature),
            for: Data((parts[0] + "." + parts[1]).utf8)))
        XCTAssertFalse(publicKey.isValidSignature(
            try P256.Signing.ECDSASignature(rawRepresentation: signature),
            for: Data((parts[0] + "." + parts[1] + "x").utf8)))
        XCTAssertEqual(
            VAPIDKey.authorization(token: "t", publicKey: "k"), "vapid t=t, k=k")
    }

    func testAStoredVAPIDKeyComesBackTheSame() throws {
        let key = VAPIDKey()
        XCTAssertEqual(VAPIDKey(stored: key.stored)?.publicKey, key.publicKey)
        XCTAssertEqual(Base64URL.decode(key.publicKey)?.count, 65)
        XCTAssertNil(VAPIDKey(stored: "not a key"))
        XCTAssertNil(VAPIDKey(stored: ""))
    }

    func testTheContactIsAMailtoOrAnHTTPSURLAndTheDefaultNamesNobody() {
        XCTAssertEqual(MobilePush.subject(MobilePush.defaultSubject), MobilePush.defaultSubject)
        XCTAssertFalse(MobilePush.defaultSubject.contains("@"))
        XCTAssertEqual(MobilePush.subject(" mailto:ops@example.com "), "mailto:ops@example.com")
        XCTAssertEqual(MobilePush.subject("https://example.com/contact"), "https://example.com/contact")
        for bad in ["", "ops@example.com", "http://example.com", "mailto:ops", "mailto:@example.com",
                    "mailto:a b@example.com", "https://", "javascript:alert(1)",
                    "https://example.com/" + String(repeating: "a", count: 300)] {
            XCTAssertNil(MobilePush.subject(bad), bad)
        }
    }

    // MARK: Endpoint rules

    func testAcceptsOnlyTheKnownPushServices() {
        for good in [
            "https://web.push.apple.com/QGdemo-token_123",
            "https://fcm.googleapis.com/fcm/send/abc:APA91bDemo-_",
            "https://updates.push.services.mozilla.com/wpush/v2/gAAAAdemo",
            "https://wns2-by3p.notify.windows.com/w/?token=AwYAAACdemo%2b%2f",
            "https://fcm.googleapis.com:443/fcm/send/abc",
        ] {
            XCTAssertNotNil(MobilePush.endpointURL(good), good)
        }
    }

    func testRefusesEveryOtherEndpoint() {
        for bad in [
            "",
            // Scheme.
            "http://web.push.apple.com/abc", "HTTPS://web.push.apple.com/abc",
            "ftp://fcm.googleapis.com/abc", "file:///etc/hosts", "web.push.apple.com/abc",
            "//web.push.apple.com/abc",
            // Credentials.
            "https://user@web.push.apple.com/abc", "https://user:pass@fcm.googleapis.com/abc",
            "https://fcm.googleapis.com@evil.example/abc",
            "https://fcm.googleapis.com:443@evil.example/abc",
            // Port.
            "https://web.push.apple.com:8443/abc", "https://fcm.googleapis.com:80/abc",
            "https://fcm.googleapis.com:0/abc",
            // Hosts that look like one on the list.
            "https://web.push.apple.com.evil.example/abc",
            "https://evilweb.push.apple.com/abc", "https://push.apple.com/abc",
            "https://sub.web.push.apple.com/abc",
            "https://fcm.googleapis.com./abc", "https://fcm.googleapis.com.evil.example/abc",
            "https://notify.windows.com/abc", "https://evilnotify.windows.com/abc",
            "https://a.notify.windows.com.evil.example/abc", "https://.notify.windows.com/abc",
            "https://a..notify.windows.com/abc", "https://WEB.PUSH.APPLE.COM/abc",
            "https://evil.example/web.push.apple.com", "https://evil.example/?h=fcm.googleapis.com",
            "https://evil.example/#@fcm.googleapis.com", "https://evil.example\\@fcm.googleapis.com/",
            "https://fcm.googleapis.com\\.evil.example/", "https://fcm.googleapis.com%2eevil.example/",
            "https://fcm.googleapis.com#.evil.example/",
            // Addresses.
            "https://127.0.0.1/abc", "https://169.254.169.254/latest/meta-data",
            "https://10.0.0.1/abc", "https://[::1]/abc", "https://2130706433/abc",
            "https://0x7f.1/abc", "https://localhost/abc", "https://devbox/abc",
            // Characters a parser could read two ways.
            "https://web.push.apple.com/a b", "https://web.push.apple.com/a\nb",
            "https://web.push.apple.com/a\tb", " https://web.push.apple.com/abc",
            "https://web.push.apple.com/abc#frag", "https://web.push.apple.com/é",
            // Length.
            "https://web.push.apple.com/" + String(repeating: "a", count: MobilePush.maxEndpointLength),
        ] {
            XCTAssertNil(MobilePush.endpointURL(bad), bad)
        }
    }

    func testChecksThePhonesKeysAreAPointAndSixteenBytes() {
        let phone = FakePhone()
        XCTAssertNotNil(MobilePush.subscription(in: phone.body, now: clock))

        func body(endpoint: String? = nil, p256dh: String? = nil, auth: String? = nil) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "endpoint": endpoint ?? phone.endpoint,
                "keys": ["p256dh": p256dh ?? phone.p256dh, "auth": auth ?? Base64URL.encode(phone.auth)],
            ])
        }
        // 65 bytes with the right first byte, and not on the curve.
        let offCurve = Base64URL.encode(Data([0x04] + [UInt8](repeating: 0x01, count: 64)))
        let compressed = Base64URL.encode(phone.key.publicKey.compressedRepresentation)
        for bad in [
            body(p256dh: offCurve), body(p256dh: compressed), body(p256dh: ""),
            body(p256dh: Base64URL.encode(Data(count: 65))),
            body(p256dh: phone.p256dh + "AAAA"), body(p256dh: phone.p256dh.replacingOccurrences(of: "-", with: "+")),
            body(p256dh: String(repeating: "A", count: 4000)),
            body(auth: Base64URL.encode(Data(count: 15))), body(auth: Base64URL.encode(Data(count: 17))),
            body(auth: ""), body(auth: "not base64!"), body(auth: String(repeating: "A", count: 4000)),
            body(endpoint: "https://evil.example/abc"),
            Data("[]".utf8), Data("{}".utf8), Data("nope".utf8),
            Data(#"{"endpoint":"https://web.push.apple.com/a","keys":"x"}"#.utf8),
        ] {
            XCTAssertNil(MobilePush.subscription(in: bad, now: clock), String(decoding: bad, as: UTF8.self))
        }
        // A body past the cap is not read at all.
        var padded = try! JSONSerialization.jsonObject(with: phone.body) as! [String: Any]
        padded["pad"] = String(repeating: "a", count: MobilePush.maxBodyBytes)
        XCTAssertNil(MobilePush.subscription(
            in: try! JSONSerialization.data(withJSONObject: padded), now: clock))
    }

    // MARK: Subscriptions

    func testSubscribesAndForgets() {
        let center = center()
        let phone = FakePhone()
        XCTAssertEqual(center.subscribe(phone.body).status, 200)
        XCTAssertEqual(center.count, 1)
        // The same phone again is the same subscription.
        XCTAssertEqual(center.subscribe(phone.body).status, 200)
        XCTAssertEqual(center.count, 1)
        XCTAssertEqual(center.subscribe(Data("{}".utf8)).status, 400)
        XCTAssertEqual(center.unsubscribe(phone.focus(nil)).status, 200)
        XCTAssertEqual(center.count, 0)
        // Twice is not an error; a body with no endpoint is.
        XCTAssertEqual(center.unsubscribe(phone.focus(nil)).status, 200)
        XCTAssertEqual(center.unsubscribe(Data("{}".utf8)).status, 400)
    }

    func testHoldsAtMostEightPhones() {
        let center = center()
        let phones = (0..<MobilePush.maxSubscriptions).map { FakePhone("https://fcm.googleapis.com/fcm/send/demo\($0)") }
        for phone in phones { XCTAssertEqual(center.subscribe(phone.body).status, 200) }
        let extra = center.subscribe(FakePhone("https://fcm.googleapis.com/fcm/send/extra").body)
        XCTAssertEqual(extra.status, 409)
        XCTAssertEqual(String(decoding: extra.body, as: UTF8.self), #"{"error":"limit"}"#)
        XCTAssertEqual(center.count, MobilePush.maxSubscriptions)
        // One already held is still accepted.
        XCTAssertEqual(center.subscribe(phones[0].body).status, 200)
    }

    func testSubscriptionsSurviveARestartAndAStoredOneIsCheckedAgain() throws {
        let phone = FakePhone()
        XCTAssertEqual(center().subscribe(phone.body).status, 200)
        XCTAssertEqual(center().count, 1)

        // Something else wrote the Keychain item: a host off the list is not kept.
        var list = try JSONDecoder().decode(
            [MobilePushSubscription].self, from: Data(XCTUnwrap(store.stored).utf8))
        list.append(MobilePushSubscription(
            endpoint: "https://evil.example/abc", p256dh: phone.p256dh,
            auth: Base64URL.encode(phone.auth), addedAt: clock))
        XCTAssertTrue(store.save(String(decoding: try JSONEncoder().encode(list), as: UTF8.self)))
        let reloaded = center()
        XCTAssertEqual(reloaded.count, 1)
        reloaded.notify([waiting()])
        settle(reloaded)
        XCTAssertEqual(transport.requests.map { $0.url?.host }, ["web.push.apple.com"])
    }

    func testThePrivateKeyIsOnlyInTheKeyStore() throws {
        let center = center()
        XCTAssertNil(keys.stored)
        let response = center.keyResponse()
        XCTAssertEqual(response.status, 200)
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: String])["key"]
        let key = try XCTUnwrap(keys.stored.flatMap(VAPIDKey.init(stored:)))
        XCTAssertEqual(sent, key.publicKey)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(key.stored))
        XCTAssertEqual(center.subscribe(FakePhone().body).status, 200)
        XCTAssertFalse(try XCTUnwrap(store.stored).contains(key.stored))
        // The same key the next time.
        XCTAssertEqual(self.center().keyResponse().body, response.body)
    }

    func testANewKeyDropsTheSubscriptionsOfTheOldOne() {
        XCTAssertEqual(center().subscribe(FakePhone().body).status, 200)
        // The Keychain lost the key: phones subscribed with it cannot be reached.
        let lost = MobilePushCenter(keys: MemoryTokenStore(), store: store, transport: transport)
        XCTAssertEqual(lost.keyResponse().status, 200)
        XCTAssertEqual(lost.count, 0)
    }

    func testAKeychainThatRefusesGivesNoKeyAndNoSubscription() {
        keys.refuse()
        let center = center()
        XCTAssertEqual(center.keyResponse().status, 503)
        XCTAssertEqual(center.subscribe(FakePhone().body).status, 503)
        XCTAssertEqual(center.count, 0)
    }

    // MARK: Sending

    func testSendsOneEncryptedMessagePerEventToEachPhone() throws {
        let center = center()
        let phone = FakePhone()
        let other = FakePhone("https://fcm.googleapis.com/fcm/send/demo2")
        _ = center.subscribe(phone.body)
        _ = center.subscribe(other.body)
        center.notify([waiting()])
        settle(center)

        XCTAssertEqual(transport.requests.count, 2)
        let request = try XCTUnwrap(transport.requests.first { $0.url?.absoluteString == phone.endpoint })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "aes128gcm")
        XCTAssertEqual(request.value(forHTTPHeaderField: "TTL"), "1800")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Urgency"), "high")
        XCTAssertLessThanOrEqual(request.timeoutInterval, 10)
        XCTAssertFalse(request.httpShouldHandleCookies)

        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        let key = try XCTUnwrap(keys.stored.flatMap(VAPIDKey.init(stored:)))
        XCTAssertTrue(authorization.hasPrefix("vapid t="))
        XCTAssertTrue(authorization.hasSuffix(", k=\(key.publicKey)"))
        let claims = try XCTUnwrap(Base64URL.decode(String(authorization.split(separator: ".")[1])))
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: claims) as? [String: Any])?["aud"] as? String,
            "https://web.push.apple.com")

        let message = try phone.open(request)
        XCTAssertEqual(message["kind"] as? String, "waiting")
        XCTAssertEqual(message["thread"] as? String, "localhost:12")
        XCTAssertEqual(message["tag"] as? String, request.value(forHTTPHeaderField: "Topic"))
        // The other phone cannot read this one's message.
        XCTAssertThrowsError(try other.open(request))
    }

    func testTheTextIsGenericUnlessSettingsAsksForNames() throws {
        let center = center()
        let phone = FakePhone()
        _ = center.subscribe(phone.body)
        center.notify([waiting(), MobilePushEvent(kind: .done, thread: "localhost:13", name: "acme-app · api")])
        settle(center)
        let generic = try transport.requests.map(phone.open)
        XCTAssertEqual(generic.map { $0["title"] as? String }, ["MuxMaestro", "MuxMaestro"])
        XCTAssertEqual(generic.map { $0["body"] as? String }, ["A thread needs you", "A thread finished"])
        for message in generic {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            XCTAssertFalse(text.contains("acme-app"))
            XCTAssertFalse(text.contains("checkout"))
        }
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Urgency"), "normal")

        center.configure(MobilePushOptions(detail: true))
        let long = String(repeating: "word ", count: 200) + "\nsecond line"
        center.notify([MobilePushEvent(kind: .waiting, thread: "localhost:14", name: "acme-app · web", prompt: long)])
        settle(center)
        let detailed = try phone.open(XCTUnwrap(transport.requests.last))
        XCTAssertEqual(detailed["title"] as? String, "acme-app · web")
        let body = try XCTUnwrap(detailed["body"] as? String)
        XCTAssertTrue(body.hasPrefix("Needs you: word word"))
        XCTAssertLessThanOrEqual(body.count, "Needs you: ".count + MobilePush.maxPromptLength + 1)
        XCTAssertFalse(body.contains("second line"))
    }

    func testThePayloadIsSmallAndCarriesNoSecret() {
        let event = MobilePushEvent(
            kind: .waiting, thread: "localhost:12", name: String(repeating: "n", count: 5000),
            prompt: String(repeating: "p", count: 50_000))
        for detail in [false, true] {
            let payload = MobilePush.payload(event, detail: detail, tag: "tag")
            XCTAssertLessThanOrEqual(payload.count, 512)
            let keys = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?.keys.sorted()
            XCTAssertEqual(keys, ["body", "kind", "tag", "thread", "title", "v"])
        }
    }

    func testTheTopicCollapsesAThreadsMessagesAndNamesNothing() throws {
        let center = center()
        _ = center.subscribe(FakePhone().body)
        center.notify([waiting("devbox:7"), MobilePushEvent(kind: .done, thread: "devbox:7"), waiting("devbox:8")])
        settle(center)
        let topics = transport.requests.compactMap { $0.value(forHTTPHeaderField: "Topic") }
        XCTAssertEqual(topics.count, 3)
        XCTAssertEqual(topics[0], topics[1])
        XCTAssertNotEqual(topics[0], topics[2])
        for topic in topics {
            XCTAssertLessThanOrEqual(topic.count, 32)
            XCTAssertNotNil(Base64URL.decode(topic))
            XCTAssertFalse(topic.contains("devbox"))
        }
    }

    func testDropsASubscriptionThePushServiceSaysIsGone() {
        let center = center()
        let gone = FakePhone("https://fcm.googleapis.com/fcm/send/gone")
        let missing = FakePhone("https://updates.push.services.mozilla.com/wpush/v2/missing")
        let failing = FakePhone("https://web.push.apple.com/QFailing")
        let silent = FakePhone("https://web.push.apple.com/QSilent")
        let kept = FakePhone("https://web.push.apple.com/QKept")
        for phone in [gone, missing, failing, silent, kept] { _ = center.subscribe(phone.body) }
        transport.answer(gone.endpoint, 410)
        transport.answer(missing.endpoint, 404)
        transport.answer(failing.endpoint, 500)
        transport.answer(silent.endpoint, nil)
        center.notify([waiting()])
        settle(center)

        // One try each: a failure is not sent again.
        XCTAssertEqual(transport.requests.count, 5)
        XCTAssertEqual(center.count, 3)
        center.notify([waiting("localhost:13")])
        settle(center)
        XCTAssertEqual(
            Set(transport.requests.dropFirst(5).compactMap { $0.url?.absoluteString }),
            [failing.endpoint, silent.endpoint, kept.endpoint])
    }

    func testNoPushWhileThePhoneShowsThatThread() {
        let center = center()
        let phone = FakePhone()
        let other = FakePhone("https://fcm.googleapis.com/fcm/send/other")
        _ = center.subscribe(phone.body)
        _ = center.subscribe(other.body)
        XCTAssertEqual(center.focus(phone.focus("localhost:12")).status, 200)

        center.notify([waiting("localhost:12")])
        settle(center)
        // The phone that looks at the thread gets nothing; the other one does.
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [other.endpoint])
        center.notify([waiting("localhost:13")])
        settle(center)
        XCTAssertEqual(transport.requests.count, 3)

        // The phone was locked without a word: the claim runs out.
        clock += MobilePushCenter.focusSeconds
        center.notify([MobilePushEvent(kind: .done, thread: "localhost:12")])
        settle(center)
        XCTAssertEqual(transport.requests.count, 5)

        // It says so when it leaves the thread.
        _ = center.focus(phone.focus("localhost:12"))
        XCTAssertEqual(center.focus(phone.focus(nil)).status, 200)
        center.notify([waiting("localhost:12")])
        settle(center)
        XCTAssertEqual(transport.requests.count, 7)
    }

    func testOnlyASubscribedPhoneCanClaimAThread() {
        let center = center()
        let phone = FakePhone()
        XCTAssertEqual(center.focus(phone.focus("localhost:12")).status, 404)
        _ = center.subscribe(phone.body)
        XCTAssertEqual(center.focus(Data("{}".utf8)).status, 400)
        XCTAssertEqual(center.focus(Data(#"{"endpoint":"x","thread":7}"#.utf8)).status, 400)
        let long = String(repeating: "a", count: MobilePush.maxThreadIDLength + 1)
        XCTAssertEqual(center.focus(phone.focus(long)).status, 400)
    }

    func testCapsTheRatePerThreadAndOverall() {
        var limiter = MobilePushLimiter(perThread: 2, overall: 3, window: 300)
        XCTAssertTrue(limiter.allow(thread: "a", now: 0))
        XCTAssertTrue(limiter.allow(thread: "a", now: 10))
        XCTAssertFalse(limiter.allow(thread: "a", now: 20))
        XCTAssertTrue(limiter.allow(thread: "b", now: 20))
        XCTAssertFalse(limiter.allow(thread: "c", now: 30))
        // The window moves on.
        XCTAssertTrue(limiter.allow(thread: "a", now: 300))
        XCTAssertFalse(limiter.allow(thread: "c", now: 309))
        XCTAssertTrue(limiter.allow(thread: "c", now: 310))

        let center = center(limiter: MobilePushLimiter(perThread: 2, overall: 3, window: 300))
        _ = center.subscribe(FakePhone().body)
        center.notify((0..<5).map { _ in waiting("localhost:12") })
        settle(center)
        XCTAssertEqual(transport.requests.count, 2)
        center.notify([waiting("localhost:13"), waiting("localhost:14"), waiting("localhost:15")])
        settle(center)
        XCTAssertEqual(transport.requests.count, 3)
        clock += 300
        center.notify([waiting("localhost:12")])
        settle(center)
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testAnEventSwitchedOffIsNotSent() {
        let center = center()
        _ = center.subscribe(FakePhone().body)
        center.configure(MobilePushOptions(waiting: true, done: false))
        center.notify([MobilePushEvent(kind: .done, thread: "localhost:12"), waiting("localhost:13")])
        settle(center)
        XCTAssertEqual(transport.requests.count, 1)
        center.configure(MobilePushOptions(waiting: false, done: true))
        center.notify([MobilePushEvent(kind: .done, thread: "localhost:12"), waiting("localhost:13")])
        settle(center)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testTheTestNotificationSaysWhatHappened() throws {
        let center = center()
        func test() -> MobilePushCenter.TestResult? {
            var result: MobilePushCenter.TestResult?
            center.sendTest { result = $0 }
            settle(center)
            return result
        }
        XCTAssertEqual(test(), .noPhone)
        let phone = FakePhone()
        _ = center.subscribe(phone.body)
        // Both events off: the test still goes out.
        center.configure(MobilePushOptions(waiting: false, done: false))
        XCTAssertEqual(test(), .sent(1, of: 1))
        let message = try phone.open(XCTUnwrap(transport.requests.last))
        XCTAssertEqual(message["kind"] as? String, "test")
        XCTAssertEqual(message["body"] as? String, "Test notification")
        XCTAssertEqual(message["thread"] as? String, "")
        transport.answer(phone.endpoint, 403)
        XCTAssertEqual(test(), .sent(0, of: 1))
    }

    func testForgetAllDropsEveryPhone() {
        let center = center()
        _ = center.subscribe(FakePhone().body)
        var counts: [Int] = []
        center.onCount = { counts.append($0) }
        center.forgetAll()
        XCTAssertEqual(center.count, 0)
        XCTAssertEqual(counts, [0])
        center.notify([waiting()])
        settle(center)
        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: Events

    private func snapshot(_ statuses: [(pane: String, status: AttentionStatus)]) -> MobileSnapshot {
        let windows = statuses.enumerated().map { index, entry in
            var pane = TmuxPane(id: entry.pane, index: 0, command: "claude", title: "", active: true)
            pane.claudeSessionId = "c\(index)"
            pane.attention = entry.status
            return TmuxWindow(index: index + 1, name: "w\(index)", active: index == 0, panes: [pane])
        }
        return MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: "acme-app", attached: true, windows: windows)])])
    }

    func testOneEventPerChangeIntoWaitingOrFinished() {
        var tracker = MobilePushTracker()
        // The first tree is not news, whatever it holds.
        XCTAssertEqual(tracker.events(in: snapshot([("%1", .waiting), ("%2", .busy), ("%3", .idle)])), [])
        XCTAssertEqual(tracker.events(in: snapshot([("%1", .waiting), ("%2", .busy), ("%3", .idle)])), [])

        let changed = tracker.events(in: snapshot([("%1", .busy), ("%2", .waiting), ("%3", .busy)]))
        XCTAssertEqual(changed.map(\.kind), [.waiting])
        XCTAssertEqual(changed.first?.thread, "localhost:2")
        XCTAssertEqual(changed.first?.name, "acme-app · w1")

        let finished = tracker.events(in: snapshot([("%1", .idle), ("%2", .waiting), ("%3", .waiting)]))
        XCTAssertEqual(finished.map(\.kind), [.done, .waiting])
        XCTAssertEqual(finished.map(\.thread), ["localhost:1", "localhost:3"])
        // Still the same: nothing again.
        XCTAssertEqual(tracker.events(in: snapshot([("%1", .idle), ("%2", .waiting), ("%3", .waiting)])), [])
        // An answered prompt that ends idle is not a finished turn, and an
        // idle pane that starts work is nothing either.
        XCTAssertEqual(tracker.events(in: snapshot([("%1", .busy), ("%2", .idle), ("%3", .unknown)])), [])
    }

    func testAThreadThatComesBackIsNotNews() {
        var tracker = MobilePushTracker()
        _ = tracker.events(in: snapshot([("%1", .busy)]))
        _ = tracker.events(in: snapshot([]))
        XCTAssertEqual(tracker.events(in: snapshot([("%1", .waiting)])), [])
        XCTAssertEqual(tracker.events(in: snapshot([("%1", .busy), ("%2", .waiting)])), [])
    }

    // MARK: Transport

    /// A loopback listener that answers every request with `response` and
    /// counts them.
    private final class Loopback {
        let listener: NWListener
        private let lock = NSLock()
        private var hits = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return hits }
        var port: Int { Int(listener.port?.rawValue ?? 0) }

        init(response: @escaping () -> String) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                    self?.lock.lock(); self?.hits += 1; self?.lock.unlock()
                    connection.send(content: Data(response().utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            listener.start(queue: .global())
            _ = ready.wait(timeout: .now() + 5)
        }
    }

    func testTheTransportDoesNotFollowARedirect() throws {
        let target = try Loopback { "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        let targetPort = target.port
        let redirector = try Loopback {
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(targetPort)/inside\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        }
        defer { target.listener.cancel(); redirector.listener.cancel() }

        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(redirector.port)/push")))
        request.httpMethod = "POST"
        request.httpBody = Data("x".utf8)
        let answered = expectation(description: "answered")
        var status: Int?
        URLSessionPushTransport().send(request) {
            status = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        XCTAssertEqual(status, 307)
        XCTAssertEqual(redirector.count, 1)
        XCTAssertEqual(target.count, 0)
    }
}
