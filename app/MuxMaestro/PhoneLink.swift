import Foundation
import Security

/// Where the pairing token is kept between launches.
protocol PhoneTokenStore {
    func load() -> String?
    /// False when the token could not be stored.
    func save(_ token: String) -> Bool
}

/// The pairing token as a generic password in the login Keychain.
struct KeychainTokenStore: PhoneTokenStore {
    var service = "MuxMaestro Phone"
    var account = "pairing-token"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var item: CFTypeRef?
        let find = query.merging(
            [kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(find as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    func save(_ token: String) -> Bool {
        let value = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(value) { $1 } as CFDictionary, nil) == errSecSuccess
    }
}

/// The "Phone" switch: starts the loopback server and publishes it on the
/// tailnet with `tailscale serve`, and takes both away again. Foundation only;
/// the Phone settings draw `state`.
final class PhoneLink {
    enum State: Equatable {
        case off
        case starting
        /// `url` is the address; `pairing` is the same with the pairing token,
        /// for the QR code.
        case on(url: String, pairing: String)
        case failed(String)
    }

    private let server: MobileServer
    private let runner: CommandRunner
    private let tailscalePath: () -> String?
    private let port: () -> Int
    private let keepAwake: () -> Bool
    private let tokens: PhoneTokenStore
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.phone")
    private let notify: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var current = State.off
    /// What `tailscale serve` publishes for us, while it does. Confined to `queue`.
    private var served: (port: Int, identity: MobileIdentity)?
    /// The idle-sleep assertion held while the server is on. Confined to `queue`.
    private var awake: NSObjectProtocol?

    /// Called with each new state, through `notify` (the main queue in the app).
    var onChange: ((State) -> Void)?

    init(
        server: MobileServer,
        runner: CommandRunner = ProcessCommandRunner(timeout: 10),
        tailscalePath: @escaping () -> String? = HostAddress.tailscalePath,
        port: @escaping () -> Int = { Settings.phonePort() },
        keepAwake: @escaping () -> Bool = { Settings.phoneKeepAwake() },
        tokens: PhoneTokenStore = KeychainTokenStore(),
        notify: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.server = server
        self.runner = runner
        self.tailscalePath = tailscalePath
        self.port = port
        self.keepAwake = keepAwake
        self.tokens = tokens
        self.notify = notify
    }

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var isOn: Bool {
        if case .on = state { return true }
        return false
    }

    private func set(_ state: State) {
        lock.lock()
        current = state
        lock.unlock()
        notify { [weak self] in self?.onChange?(state) }
    }

    func turnOn() {
        set(.starting)
        queue.async { self.start() }
    }

    func turnOff() {
        queue.async {
            self.teardown()
            self.set(.off)
        }
    }

    /// Take the listener and the tailnet mapping away before the app exits, so
    /// the phone's URL does not point at a dead port. Blocks until done.
    func shutdown() {
        queue.sync { teardown() }
    }

    /// Make a new pairing token. Every phone paired with the old one is signed
    /// out and must scan the new QR code.
    func rotateToken() {
        queue.async {
            guard let served = self.served else { return }
            let token = MobileTailnet.newToken()
            guard self.tokens.save(token) else { return }
            self.server.setToken(token)
            self.set(self.on(served, token: token))
        }
    }

    /// With the switch off, take away a mapping to our port that a crash or a
    /// forced quit left behind: it would keep the port published on the tailnet.
    func removeLeftoverMapping() {
        queue.async {
            guard self.served == nil, let tailscale = self.tailscalePath() else { return }
            let port = self.port()
            guard let serving = self.runner.run(tailscale, MobileTailnet.serveStatusArgv),
                  MobileTailnet.servesOurs(serveStatusJSON: serving, port: port)
            else { return }
            _ = self.runner.runCapturing(tailscale, MobileTailnet.serveOffArgv(port: port))
        }
    }

    /// Re-read the "Keep Mac awake" setting.
    func refreshKeepAwake() {
        queue.async { self.applyKeepAwake() }
    }

    /// Whether the Mac is being kept awake for the phone right now.
    var isKeepingAwake: Bool {
        queue.sync { awake != nil }
    }

    private func on(_ served: (port: Int, identity: MobileIdentity), token: String) -> State {
        .on(url: MobileTailnet.url(identity: served.identity, port: served.port),
            pairing: MobileTailnet.pairingURL(identity: served.identity, port: served.port, token: token))
    }

    private func start() {
        teardown()
        guard let tailscale = tailscalePath() else { return set(.failed("Tailscale is not installed")) }
        guard let status = runner.run(tailscale, MobileTailnet.statusArgv),
              let identity = MobileTailnet.identity(statusJSON: status)
        else { return set(.failed("Tailscale is not signed in")) }
        let wanted = port()
        if let serving = runner.run(tailscale, MobileTailnet.serveStatusArgv) {
            if MobileTailnet.portTaken(serveStatusJSON: serving, port: wanted) {
                return set(.failed("Tailscale already serves port \(wanted)"))
            }
            // A killed app (a crash, `pkill`, a reinstall) leaves its mapping
            // behind. While Tailscale holds the port for that mapping, the
            // loopback listener cannot bind it, so every later start failed
            // with "Port N is in use". Take our own leftover away first.
            if MobileTailnet.servesOurs(serveStatusJSON: serving, port: wanted) {
                _ = runner.runCapturing(tailscale, MobileTailnet.serveOffArgv(port: wanted))
            }
        }
        // Without a stored token nothing could pair, so nothing is published.
        var stored = tokens.load()
        if stored == nil {
            let fresh = MobileTailnet.newToken()
            if tokens.save(fresh) { stored = fresh }
        }
        guard let token = stored else { return set(.failed("Keychain refused the pairing token")) }
        server.start(port: wanted, identity: identity, token: token) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                guard case .success(let bound) = result else {
                    return self.set(.failed("Port \(wanted) is in use"))
                }
                let (ok, text) = self.runner.runCapturing(tailscale, MobileTailnet.serveOnArgv(port: bound))
                guard ok else {
                    self.server.stop()
                    let reason = text.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty && !$0.hasPrefix("Warning:") }
                    return self.set(.failed(reason ?? "tailscale serve failed"))
                }
                self.served = (bound, identity)
                self.applyKeepAwake()
                self.set(self.on((bound, identity), token: token))
            }
        }
    }

    private func applyKeepAwake() {
        let wanted = served != nil && keepAwake()
        if wanted, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled, reason: "MuxMaestro phone access")
        } else if !wanted, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    private func teardown() {
        server.stop()
        let port = served?.port
        served = nil
        applyKeepAwake()
        guard let port, let tailscale = tailscalePath() else { return }
        _ = runner.runCapturing(tailscale, MobileTailnet.serveOffArgv(port: port))
    }
}
