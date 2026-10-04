import CryptoKit
import Foundation

// Web Push for the phone: the subscription rules, the message encryption
// (RFC 8291, `aes128gcm` of RFC 8188), the VAPID header (RFC 8292), and the
// rules that decide when a thread is worth a notification. Foundation and
// CryptoKit only, so the test target compiles it. Nothing here writes a log:
// an endpoint is a secret, and so is what a notification says.

// MARK: - Encoding

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// nil for anything outside the URL-safe alphabet. Padding is not accepted:
    /// a browser sends none.
    static func decode(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }) else { return nil }
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard padded.count % 4 != 1 else { return nil }
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

// MARK: - Subscriptions

/// One phone's push subscription, as its browser made it.
struct MobilePushSubscription: Equatable, Codable {
    /// The push service URL for this phone. The Mac posts to it, so it is only
    /// ever a URL that `MobilePush.endpointURL` accepts.
    let endpoint: String
    /// The phone's P-256 public key, uncompressed, base64url.
    let p256dh: String
    /// The phone's 16-byte authentication secret, base64url.
    let auth: String
    var addedAt: Int
}

enum MobilePush {
    /// Phones held at once. One more is refused until one is removed.
    static let maxSubscriptions = 8
    static let maxEndpointLength = 1024
    /// The largest subscribe, unsubscribe or focus body.
    static let maxBodyBytes = 4096
    /// The largest notification, before encryption. One record of 4096 bytes
    /// holds it, and every push service takes it.
    static let maxPayloadBytes = 2048
    static let maxSubjectLength = 200
    static let maxThreadIDLength = 256

    /// The push services of the browsers a phone can run. The Mac calls no
    /// other host: the endpoint comes from the phone, and a URL the Mac would
    /// fetch for anyone is a way into the networks the Mac can reach.
    static let hosts: Set<String> = [
        "web.push.apple.com", "fcm.googleapis.com", "updates.push.services.mozilla.com",
    ]
    /// Windows gives each channel its own host under this name.
    static let hostSuffixes = [".notify.windows.com"]

    /// A neutral contact for the VAPID token. Settings can replace it.
    static let defaultSubject = "https://example.com/muxmaestro"

    private static let endpointScalars = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?&=%+,;!*'()$"
            .unicodeScalars)

    static func allows(host: String) -> Bool {
        if hosts.contains(host) { return true }
        // Every label is a plain DNS label, so `a..b` and `.b` match nothing.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return false }
        return hostSuffixes.contains { host.count > $0.count && host.hasSuffix($0) }
    }

    /// The URL to post to, or nil when `raw` is not a push service's: HTTPS
    /// only, no user or password, the default port, a host on the list, and
    /// no character a URL parser could read two ways.
    static func endpointURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, raw.utf8.count <= maxEndpointLength,
              raw.unicodeScalars.allSatisfy(endpointScalars.contains),
              raw.hasPrefix("https://"),
              let parts = URLComponents(string: raw), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              // A subscription is a path on the service, never the service itself.
              parts.path.count > 1,
              parts.port == nil || parts.port == 443,
              let host = parts.host, host == host.lowercased(), allows(host: host),
              // The authority as written, not as a parser decodes it: a host with
              // a percent escape, `:0443` and an empty port are other spellings.
              authority(of: raw) == host || authority(of: raw) == host + ":443",
              let url = parts.url, url.host == host,
              // What is sent is exactly what was checked.
              url.absoluteString == raw
        else { return nil }
        return url
    }

    /// What stands between `https://` and the path, exactly as sent.
    private static func authority(of raw: String) -> String {
        String(raw.dropFirst("https://".count).prefix { $0 != "/" && $0 != "?" })
    }

    /// The phone's public key: 65 bytes that are a point on P-256.
    static func publicKey(_ p256dh: String) -> P256.KeyAgreement.PublicKey? {
        guard p256dh.utf8.count <= 100, let data = Base64URL.decode(p256dh),
              data.count == 65, data.first == 0x04
        else { return nil }
        return try? P256.KeyAgreement.PublicKey(x963Representation: data)
    }

    static func authSecret(_ auth: String) -> Data? {
        guard auth.utf8.count <= 32, let data = Base64URL.decode(auth), data.count == 16 else { return nil }
        return data
    }

    private static func object(_ body: Data) -> [String: Any]? {
        guard body.count <= maxBodyBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// The subscription in a subscribe body, or nil when any part of it fails
    /// a rule above.
    static func subscription(in body: Data, now: Int) -> MobilePushSubscription? {
        guard let root = object(body),
              let endpoint = root["endpoint"] as? String, endpointURL(endpoint) != nil,
              let keys = root["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String, publicKey(p256dh) != nil,
              let auth = keys["auth"] as? String, authSecret(auth) != nil
        else { return nil }
        return MobilePushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth, addedAt: now)
    }

    static func endpoint(in body: Data) -> String? {
        guard let endpoint = object(body)?["endpoint"] as? String,
              !endpoint.isEmpty, endpoint.utf8.count <= maxEndpointLength
        else { return nil }
        return endpoint
    }

    /// What a focus body says: the phone's endpoint, and the thread it shows
    /// (nil: none, or the app is in the background).
    static func focus(in body: Data) -> (endpoint: String, thread: String?)? {
        guard let root = object(body), let endpoint = endpoint(in: body) else { return nil }
        if root["thread"] == nil || root["thread"] is NSNull { return (endpoint, nil) }
        guard let thread = root["thread"] as? String, !thread.isEmpty,
              thread.utf8.count <= maxThreadIDLength
        else { return nil }
        return (endpoint, thread)
    }

    /// A VAPID contact a push service accepts: a `mailto:` address or an
    /// `https:` URL. nil for anything else.
    static func subject(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maxSubjectLength,
              text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value != 0x7F })
        else { return nil }
        if text.hasPrefix("mailto:") {
            let address = text.dropFirst("mailto:".count).split(separator: "@", omittingEmptySubsequences: false)
            return address.count == 2 && !address[0].isEmpty && address[1].contains(".") ? text : nil
        }
        guard text.hasPrefix("https://"), let host = URLComponents(string: text)?.host, !host.isEmpty
        else { return nil }
        return text
    }

    /// The `Topic` of a thread's messages: a push service keeps only the
    /// newest message of a topic for a phone that is offline. A keyed hash,
    /// with a key the push service never sees (this Mac's private key), so
    /// the service cannot guess a thread id and check it against the topic.
    static func topic(thread: String, secret: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(("topic\n" + thread).utf8), using: SymmetricKey(data: secret))
        return Base64URL.encode(Data(code.prefix(18)))
    }
}

// MARK: - Encryption (RFC 8291)

enum WebPushCrypto {
    static let recordSize: UInt32 = 4096

    enum Failure: Error { case tooLarge, badSalt }

    /// `plaintext` as one `aes128gcm` record for the phone that holds
    /// `receiver` and `auth`. `sender` and `salt` are new for every message;
    /// the tests pass the RFC's.
    static func encrypt(
        _ plaintext: Data, receiver: P256.KeyAgreement.PublicKey, auth: Data,
        sender: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        salt: Data = randomSalt()
    ) throws -> Data {
        guard salt.count == 16 else { throw Failure.badSalt }
        let senderPublic = sender.publicKey.x963Representation
        // The header, the padding byte and the tag must fit the one record.
        guard plaintext.count + 1 + 16 <= Int(recordSize) - 21 - senderPublic.count else {
            throw Failure.tooLarge
        }
        let secret = try sender.sharedSecretFromKeyAgreement(with: receiver)
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(receiver.x963Representation)
        keyInfo.append(senderPublic)
        let ikm = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: auth, sharedInfo: keyInfo, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8),
            outputByteCount: 12)
        // 0x02 ends the last record; there is no padding after it.
        let sealed = try AES.GCM.seal(
            plaintext + [0x02], using: key,
            nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))

        var out = salt
        withUnsafeBytes(of: recordSize.bigEndian) { out.append(contentsOf: $0) }
        out.append(UInt8(senderPublic.count))
        out.append(senderPublic)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    static func randomSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

// MARK: - VAPID (RFC 8292)

/// The key pair that says a push comes from this Mac. The phone subscribes
/// with the public half; the push service checks each message's token with it.
struct VAPIDKey {
    let key: P256.Signing.PrivateKey

    /// How long a token is good for. A push service refuses more than a day.
    static let lifetime = 12 * 3600

    init() { key = P256.Signing.PrivateKey() }

    /// From what `stored` returned. nil when it is not a P-256 private key.
    init?(stored: String) {
        guard let raw = Base64URL.decode(stored),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
        else { return nil }
        self.key = key
    }

    /// The private key, for the Keychain and nowhere else.
    var stored: String { Base64URL.encode(key.rawRepresentation) }

    /// The public key as the phone's `applicationServerKey`.
    var publicKey: String { Base64URL.encode(key.publicKey.x963Representation) }

    /// An ES256 token for the push service at `audience` (its origin).
    func token(audience: String, subject: String, now: Int) -> String? {
        let header = Base64URL.encode(Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8))
        let claims: [String: Any] = ["aud": audience, "exp": now + Self.lifetime, "sub": subject]
        guard let body = try? JSONSerialization.data(
            withJSONObject: claims, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        let signed = header + "." + Base64URL.encode(body)
        guard let signature = try? key.signature(for: Data(signed.utf8)) else { return nil }
        return signed + "." + Base64URL.encode(signature.rawRepresentation)
    }

    static func authorization(token: String, publicKey: String) -> String {
        "vapid t=\(token), k=\(publicKey)"
    }
}

// MARK: - Events

/// Something on a thread that is worth a notification.
struct MobilePushEvent: Equatable {
    enum Kind: String {
        /// The thread's pane asks a question or a permission.
        case waiting
        /// The agent finished its turn.
        case done
        /// The button in Settings.
        case test
    }

    let kind: Kind
    /// The thread to open. Empty for a test.
    let thread: String
    /// Session and window, for the text when Settings allows it.
    var name = ""
    /// The thread's last prompt line, for the same.
    var prompt: String?

    init(kind: Kind, thread: String, name: String = "", prompt: String? = nil) {
        self.kind = kind
        self.thread = thread
        self.name = name
        self.prompt = prompt
    }

    init(kind: Kind, thread: MobileThread) {
        self.init(
            kind: kind, thread: thread.id, name: "\(thread.session) · \(thread.name)",
            prompt: thread.lastPrompt?.text)
    }
}

/// Remembers each thread's status, so each change into "needs you" or
/// "finished" is one event.
struct MobilePushTracker {
    private var seen: [String: AttentionStatus] = [:]

    /// The events of this tree. A thread seen for the first time gives none:
    /// turning the phone on, or a host that comes back, is not news.
    mutating func events(in snapshot: MobileSnapshot) -> [MobilePushEvent] {
        var next: [String: AttentionStatus] = [:]
        var out: [MobilePushEvent] = []
        for thread in snapshot.threads {
            next[thread.id] = thread.status
            guard let before = seen[thread.id], before != thread.status else { continue }
            if thread.status == .waiting {
                out.append(MobilePushEvent(kind: .waiting, thread: thread))
            } else if before == .busy, thread.status == .idle {
                out.append(MobilePushEvent(kind: .done, thread: thread))
            }
        }
        seen = next
        return out
    }
}

/// At most `perThread` notifications for one thread and `overall` for all of
/// them in any `window` seconds. A thread that flips between two states, or
/// twenty threads that finish together, do not buzz the phone without end.
struct MobilePushLimiter {
    var perThread = 4
    var overall = 20
    var window = 300

    private var sent: [(thread: String, at: Int)] = []

    init(perThread: Int = 4, overall: Int = 20, window: Int = 300) {
        self.perThread = perThread
        self.overall = overall
        self.window = window
    }

    /// Whether one more for `thread` is within the caps. A yes is counted.
    mutating func allow(thread: String, now: Int) -> Bool {
        sent.removeAll { now - $0.at >= window }
        guard sent.count < overall, sent.filter({ $0.thread == thread }).count < perThread else {
            return false
        }
        sent.append((thread, now))
        return true
    }
}

/// What Settings says about notifications, apart from the switch itself.
struct MobilePushOptions: Equatable {
    var waiting = true
    var done = true
    /// The text names the session and quotes the last prompt. Off: the text
    /// says only that a thread needs you or finished.
    var detail = false
    var subject = MobilePush.defaultSubject

    func allows(_ kind: MobilePushEvent.Kind) -> Bool {
        switch kind {
        case .waiting: return waiting
        case .done: return done
        case .test: return true
        }
    }
}

extension MobilePush {
    static let maxPromptLength = 120
    static let maxNameLength = 80

    /// The notification the service worker shows, as JSON. The thread id is
    /// what a tap opens. It never holds the pairing token, a file, or more of
    /// a prompt than `maxPromptLength`, and that much only with `detail`.
    static func payload(_ event: MobilePushEvent, detail: Bool, tag: String) -> Data {
        var title = "MuxMaestro"
        var body: String
        switch event.kind {
        case .waiting: body = "A thread needs you"
        case .done: body = "A thread finished"
        case .test: body = "Test notification"
        }
        if detail, event.kind != .test {
            if !event.name.isEmpty { title = clip(event.name, maxNameLength) }
            body = event.kind == .waiting ? "Needs you" : "Finished"
            if let prompt = event.prompt, !prompt.isEmpty { body += ": " + clip(prompt, maxPromptLength) }
        }
        let object: [String: Any] = [
            "v": 1, "kind": event.kind.rawValue, "thread": event.thread, "tag": tag,
            "title": title, "body": body,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > length ? String(line.prefix(length)) + "…" : line
    }
}

// MARK: - Transport

/// What a push service said to one message.
struct PushAnswer: Equatable {
    /// The HTTP status, or nil when there was no answer.
    var status: Int?
    /// The start of the answer's body, or why there was none. A push service
    /// names its reason here ("BadJwtToken"); Settings shows it for a test.
    var text = ""

    /// One printable line, cut short: it is shown in a label.
    static func clip(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
            .trimmingCharacters(in: .whitespaces)
        return clean.count > 120 ? String(clean.prefix(120)) + "…" : clean
    }

    /// "403 BadJwtToken", "410", "No answer: timed out".
    var summary: String {
        guard let status else { return text.isEmpty ? "No answer" : "No answer: \(text)" }
        return text.isEmpty ? String(status) : "\(status) \(text)"
    }
}

/// The one call that leaves the Mac. The tests replace it; nothing in them
/// reaches a push service.
protocol PushTransport {
    /// Post `request`. `completion` may come on any queue.
    func send(_ request: URLRequest, completion: @escaping (PushAnswer) -> Void)
}

/// `URLSession` with the rules a call to a phone-supplied URL needs: a short
/// timeout, no redirect followed, no cookie or cache kept.
final class URLSessionPushTransport: NSObject, PushTransport, URLSessionTaskDelegate {
    static let requestTimeout: TimeInterval = 10

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: URLRequest, completion: @escaping (PushAnswer) -> Void) {
        session.dataTask(with: request) { data, response, error in
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                return completion(PushAnswer(
                    status: nil, text: PushAnswer.clip(error?.localizedDescription ?? "")))
            }
            let body = String(decoding: (data ?? Data()).prefix(400), as: UTF8.self)
            completion(PushAnswer(status: status, text: PushAnswer.clip(body)))
        }.resume()
    }

    /// A redirect is never followed: the host it names passed no check. The
    /// 3xx itself is the answer.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Center

/// The phones that asked for notifications, and the sending. Its own serial
/// queue: the Keychain and the push service never hold up the server queue.
final class MobilePushCenter {
    /// What "Send test notification" came to.
    enum TestResult: Equatable {
        case noPhone
        /// The Keychain did not answer, or too many tests in a minute.
        case unavailable
        /// How many phones' push services took the message, of how many, and
        /// what the first one that did not take it said ("" when all did).
        case sent(Int, of: Int, error: String)
    }

    /// How long a phone's "I show this thread" lasts without a new one. The
    /// phone repeats it while the thread is on screen.
    static let focusSeconds = 60
    static let ttlSeconds = 1800
    /// A push service answers 403 when it will not take this Mac's messages
    /// for a subscription. After this many in a row, with none accepted
    /// between, the subscription is dropped. A test does not count.
    static let maxRefusals = 5

    private let keys: PhoneTokenStore
    private let store: PhoneTokenStore
    private let transport: PushTransport
    private let now: () -> Date
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.push")

    // Confined to `queue`.
    private var options = MobilePushOptions()
    private var limiter: MobilePushLimiter
    /// The test button's own allowance: a burst of events does not disable it,
    /// and it does not use up theirs.
    private var testLimiter = MobilePushLimiter(perThread: 6, overall: 6, window: 60)
    private var loaded: [MobilePushSubscription]?
    private var vapid: VAPIDKey?
    private var focused: [String: (thread: String, at: Int)] = [:]
    private var tokens: [String: (token: String, madeAt: Int)] = [:]
    private var refusals: [String: Int] = [:]
    /// The phones were forgotten and the Keychain did not take the empty
    /// list. Nothing is sent to them, and the write is tried again.
    private var forgetPending = false

    /// Called with the number of subscribed phones when it changes, on the
    /// center's queue.
    var onCount: ((Int) -> Void)?

    init(
        keys: PhoneTokenStore = KeychainTokenStore(account: "vapid-key"),
        store: PhoneTokenStore = KeychainTokenStore(account: "push-subscriptions"),
        transport: PushTransport = URLSessionPushTransport(),
        limiter: MobilePushLimiter = MobilePushLimiter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.keys = keys
        self.store = store
        self.transport = transport
        self.limiter = limiter
        self.now = now
    }

    private var seconds: Int { Int(now().timeIntervalSince1970) }

    func configure(_ options: MobilePushOptions) {
        queue.async {
            // A new contact needs new tokens.
            if options.subject != self.options.subject { self.tokens.removeAll() }
            self.options = options
        }
    }

    /// The subscribed phones. Blocks on the Keychain.
    var count: Int { queue.sync { subscriptions()?.count ?? 0 } }

    /// Read the count off the caller's queue; `onCount` gets it.
    func reportCount() {
        queue.async { self.onCount?(self.subscriptions()?.count ?? 0) }
    }

    // MARK: Storage

    /// The stored phones, or nil when the Keychain could not be read. nil is
    /// never treated as "none": a list written over one that was not read
    /// would drop every phone.
    private func subscriptions() -> [MobilePushSubscription]? {
        // A forget the Keychain refused: try the write again. Until it is
        // taken, the list in memory is the empty one.
        if forgetPending { save([]) }
        if let loaded { return loaded }
        var stored: [MobilePushSubscription] = []
        switch store.read() {
        case .failed: return nil
        case .missing: break
        case .found(let text):
            stored = (try? JSONDecoder().decode([MobilePushSubscription].self, from: Data(text.utf8))) ?? []
        }
        // What the Keychain held is checked like what a phone sends.
        let valid = Array(stored.filter(Self.valid).prefix(MobilePush.maxSubscriptions))
        loaded = valid
        return valid
    }

    private static func valid(_ subscription: MobilePushSubscription) -> Bool {
        MobilePush.endpointURL(subscription.endpoint) != nil
            && MobilePush.publicKey(subscription.p256dh) != nil
            && MobilePush.authSecret(subscription.auth) != nil
    }

    /// False when the Keychain refused the list; nothing changes then.
    @discardableResult
    private func save(_ list: [MobilePushSubscription]) -> Bool {
        guard let data = try? JSONEncoder().encode(list),
              store.save(String(decoding: data, as: UTF8.self))
        else { return false }
        let changed = loaded?.count != list.count
        loaded = list
        // Any list that was stored replaces the one that had to be forgotten.
        forgetPending = false
        focused = focused.filter { entry in list.contains { $0.endpoint == entry.key } }
        refusals = refusals.filter { entry in list.contains { $0.endpoint == entry.key } }
        if changed { onCount?(list.count) }
        return true
    }

    /// This Mac's key pair, made on first use. A new pair orphans every
    /// subscription made with the old one, so those are dropped with it.
    ///
    /// A pair is made only when the Keychain says there is none. A read that
    /// fails (a locked Keychain, a refused dialog) gives nil and changes
    /// nothing: the key and the phones are still there for the next read.
    private func key() -> VAPIDKey? {
        if let vapid { return vapid }
        switch keys.read() {
        case .failed:
            return nil
        case .found(let stored):
            if let found = VAPIDKey(stored: stored) {
                vapid = found
                return found
            }
        case .missing:
            break
        }
        // The phones first: an old list must not outlive the key it was made for.
        guard subscriptions() != nil, save([]) else { return nil }
        let fresh = VAPIDKey()
        guard keys.save(fresh.stored) else { return nil }
        vapid = fresh
        tokens.removeAll()
        return fresh
    }

    // MARK: Routes (called off the server queue; they block on the Keychain)

    func keyResponse() -> MobileResponse {
        queue.sync {
            guard let key = key() else { return .error(503, "unavailable") }
            return .json(["key": key.publicKey])
        }
    }

    func subscribe(_ body: Data) -> MobileResponse {
        queue.sync {
            guard let subscription = MobilePush.subscription(in: body, now: seconds) else {
                return .error(400, "bad_subscription")
            }
            guard key() != nil, var list = subscriptions() else { return .error(503, "unavailable") }
            if let index = list.firstIndex(where: { $0.endpoint == subscription.endpoint }) {
                // The same phone again: nothing to store unless its keys changed.
                let held = list[index]
                if held.p256dh == subscription.p256dh, held.auth == subscription.auth {
                    return .json(["ok": true])
                }
                list[index] = subscription
            } else {
                guard list.count < MobilePush.maxSubscriptions else { return .error(409, "limit") }
                list.append(subscription)
            }
            return save(list) ? .json(["ok": true]) : .error(503, "unavailable")
        }
    }

    func unsubscribe(_ body: Data) -> MobileResponse {
        queue.sync {
            guard let endpoint = MobilePush.endpoint(in: body) else { return .error(400, "bad_request") }
            guard let list = subscriptions() else { return .error(503, "unavailable") }
            let rest = list.filter { $0.endpoint != endpoint }
            if rest.count != list.count, !save(rest) { return .error(503, "unavailable") }
            return .json(["ok": true])
        }
    }

    /// The phone says which thread it shows. Only a subscribed phone is
    /// believed; 404 tells a phone the Mac no longer holds its subscription.
    func focus(_ body: Data) -> MobileResponse {
        queue.sync {
            guard let focus = MobilePush.focus(in: body) else { return .error(400, "bad_request") }
            guard let list = subscriptions() else { return .error(503, "unavailable") }
            guard list.contains(where: { $0.endpoint == focus.endpoint }) else {
                return .error(404, "not_found")
            }
            focused[focus.endpoint] = focus.thread.map { ($0, seconds) }
            return .json(["ok": true])
        }
    }

    /// Forget every phone: there is a new pairing code, so every phone was
    /// signed out. Written even over a list that could not be read.
    ///
    /// If the Keychain refuses the write, the phones are forgotten in memory
    /// all the same: a signed-out phone gets nothing from this run of the
    /// app, and the write is tried again on every later use.
    func forgetAll() {
        queue.async {
            if !self.forgetPending, self.subscriptions()?.isEmpty == true { return }
            guard !self.save([]) else { return }
            let had = self.loaded?.count
            self.loaded = []
            self.focused.removeAll()
            self.refusals.removeAll()
            self.forgetPending = true
            if had != 0 { self.onCount?(0) }
        }
    }

    // MARK: Sending

    /// Send one notification per event to every phone that does not show that
    /// thread now. Returns at once.
    func notify(_ events: [MobilePushEvent]) {
        guard !events.isEmpty else { return }
        queue.async {
            for event in events where self.options.allows(event.kind) {
                self.deliver(event, completion: nil)
            }
        }
    }

    func sendTest(completion: @escaping (TestResult) -> Void) {
        queue.async {
            self.deliver(MobilePushEvent(kind: .test, thread: ""), completion: completion)
        }
    }

    private func deliver(_ event: MobilePushEvent, completion: ((TestResult) -> Void)?) {
        let at = seconds
        let test = event.kind == .test
        guard let all = subscriptions() else { completion?(.unavailable); return }
        let targets = all.filter { subscription in
            guard let focus = focused[subscription.endpoint] else { return true }
            return !(focus.thread == event.thread && at - focus.at < Self.focusSeconds)
        }
        guard !targets.isEmpty else { completion?(.noPhone); return }
        guard let key = key(),
              test ? testLimiter.allow(thread: "", now: at) : limiter.allow(thread: event.thread, now: at)
        else {
            completion?(.unavailable)
            return
        }
        let tag = MobilePush.topic(thread: test ? "test" : event.thread, secret: key.key.rawRepresentation)
        let payload = MobilePush.payload(event, detail: options.detail, tag: tag)
        var pending = targets.count
        var accepted = 0
        var failure = ""
        let finish = { completion?(.sent(accepted, of: targets.count, error: failure)) }
        for subscription in targets {
            guard let request = request(to: subscription, payload: payload, event: event, tag: tag, key: key, at: at)
            else {
                pending -= 1
                if failure.isEmpty { failure = "Not sent" }
                continue
            }
            transport.send(request) { [weak self] answer in
                self?.queue.async {
                    guard let self else { return }
                    if let status = answer.status, (200..<300).contains(status) {
                        accepted += 1
                        self.refusals[subscription.endpoint] = nil
                    } else {
                        if failure.isEmpty { failure = answer.summary }
                        self.failed(subscription.endpoint, status: answer.status, counts: !test)
                    }
                    pending -= 1
                    if pending == 0 { finish() }
                }
            }
        }
        if pending == 0 { finish() }
    }

    /// A message the push service did not take. 404 and 410 say the phone
    /// unsubscribed. 403 says this Mac may not send to it; that can also be a
    /// contact the service does not like, so it takes `maxRefusals` in a row.
    /// Anything else (429, 5xx, no answer) may pass, and the phone is kept.
    private func failed(_ endpoint: String, status: Int?, counts: Bool) {
        switch status {
        case 404, 410:
            remove(endpoint)
        case 403 where counts:
            let count = (refusals[endpoint] ?? 0) + 1
            refusals[endpoint] = count
            if count >= Self.maxRefusals { remove(endpoint) }
        default:
            break
        }
    }

    private func remove(_ endpoint: String) {
        guard let list = subscriptions() else { return }
        let rest = list.filter { $0.endpoint != endpoint }
        if rest.count != list.count { save(rest) }
    }

    /// One push message. Sent once: a failure is not tried again, and the
    /// next event is a new message.
    private func request(
        to subscription: MobilePushSubscription, payload: Data, event: MobilePushEvent, tag: String,
        key: VAPIDKey, at: Int
    ) -> URLRequest? {
        guard payload.count <= MobilePush.maxPayloadBytes,
              let url = MobilePush.endpointURL(subscription.endpoint), let host = url.host,
              let receiver = MobilePush.publicKey(subscription.p256dh),
              let auth = MobilePush.authSecret(subscription.auth),
              let body = try? WebPushCrypto.encrypt(payload, receiver: receiver, auth: auth),
              let token = token(audience: "https://\(host)", key: key, at: at)
        else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: URLSessionPushTransport.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(Self.ttlSeconds), forHTTPHeaderField: "TTL")
        request.setValue(event.kind == .done ? "normal" : "high", forHTTPHeaderField: "Urgency")
        request.setValue(tag, forHTTPHeaderField: "Topic")
        request.setValue(
            VAPIDKey.authorization(token: token, publicKey: key.publicKey),
            forHTTPHeaderField: "Authorization")
        return request
    }

    /// One token per push service, used for an hour: a service may refuse a
    /// sender that signs a new one for every message.
    private func token(audience: String, key: VAPIDKey, at: Int) -> String? {
        if let held = tokens[audience], at - held.madeAt < 3600 { return held.token }
        let subject = MobilePush.subject(options.subject) ?? MobilePush.defaultSubject
        guard let token = key.token(audience: audience, subject: subject, now: at) else { return nil }
        tokens[audience] = (token, at)
        return token
    }
}
