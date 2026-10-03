import Foundation
import Security

/// Where a secret lives. The Keychain in the app, a dictionary in tests.
protocol SecretStore: AnyObject {
    func read() -> String?
    @discardableResult func write(_ secret: String) -> Bool
    @discardableResult func delete() -> Bool
}

/// The user's Vercel AI Gateway key. Session triage is on only while one is
/// saved; there is no separate toggle.
enum GatewayKey {
    static let service = "is.rebar.MuxMaestro.aiGateway"

    /// The app's store. Tests build their own `InMemorySecretStore`.
    static let shared: SecretStore = KeychainSecretStore(service: service)

    /// Posted after the key is saved or removed, on the queue that did it.
    static let didChange = Notification.Name("GatewayKey.didChange")
}

/// A generic password in the login Keychain, one per `service`.
final class KeychainSecretStore: SecretStore {
    private let service: String
    private let account = "default"

    init(service: String) {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let secret = String(data: data, encoding: .utf8), !secret.isEmpty
        else { return nil }
        return secret
    }

    @discardableResult
    func write(_ secret: String) -> Bool {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// A `SecretStore` that forgets on exit. For tests.
final class InMemorySecretStore: SecretStore {
    private let lock = NSLock()
    private var secret: String?

    init(_ secret: String? = nil) {
        self.secret = secret
    }

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secret
    }

    @discardableResult
    func write(_ secret: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.secret = secret
        return true
    }

    @discardableResult
    func delete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        secret = nil
        return true
    }
}

extension GatewayKey {
    /// Saves `key` to `store` only after one tiny jev call accepts it, then posts
    /// `didChange`. A 401, or any other failure, saves nothing and hands back the
    /// error. `completion` runs on the transport's queue.
    static func verifyAndSave(
        _ key: String, store: SecretStore = shared,
        transport: HTTPTransport = URLSessionTransport(),
        completion: @escaping (JevError?) -> Void
    ) {
        JevClient(key: key, transport: transport).evaluate(
            state: ["text": "ok"],
            questions: ["ok": .boolean(instructions: "The text says ok.")]
        ) { result in
            switch result {
            case .success:
                guard store.write(key) else {
                    return completion(.transport("Could not save the key to the Keychain."))
                }
                NotificationCenter.default.post(name: didChange, object: nil)
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }
}
