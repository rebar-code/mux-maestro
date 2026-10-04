import Foundation
import Security

/// What a read of the token store came to. "Not there" and "could not be
/// read" are different answers: only the first may be answered with a new
/// secret, because a new one replaces what every paired phone holds.
enum PhoneTokenRead: Equatable {
    case found(String)
    case missing
    /// Locked, refused or broken. The stored value may still be there.
    case failed
}

/// Where the pairing token is kept between launches.
protocol PhoneTokenStore {
    func load() -> String?
    /// False when the token could not be stored.
    func save(_ token: String) -> Bool
    func read() -> PhoneTokenRead
}

extension PhoneTokenStore {
    /// A store that cannot fail to read: nothing loaded is nothing stored.
    func read() -> PhoneTokenRead { load().map(PhoneTokenRead.found) ?? .missing }
}

/// The pairing token as a generic password in the login Keychain.
struct KeychainTokenStore: PhoneTokenStore {
    var service = "MuxMaestro Phone"
    var account = "pairing-token"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> PhoneTokenRead {
        var item: CFTypeRef?
        let find = query.merging(
            [kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        return Self.outcome(status: SecItemCopyMatching(find as CFDictionary, &item), data: item as? Data)
    }

    /// Only `errSecItemNotFound` means there is no token. A denied dialog, a
    /// locked Keychain and every other status mean it could not be read.
    static func outcome(status: OSStatus, data: Data?) -> PhoneTokenRead {
        switch status {
        case errSecSuccess:
            guard let data, let token = String(data: data, encoding: .utf8) else { return .failed }
            return token.isEmpty ? .missing : .found(token)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed
        }
    }

    func load() -> String? {
        if case .found(let token) = read() { return token }
        return nil
    }

    func save(_ token: String) -> Bool {
        let value = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(value) { $1 } as CFDictionary, nil) == errSecSuccess
    }
}

/// Where the ports this app published for dev servers are kept between
/// launches, so a mapping a crash left behind can be found and removed.
protocol PhonePortStore {
    func load() -> [Int: String]
    func save(_ ports: [Int: String])
}

struct DefaultsPortStore: PhonePortStore {
    var defaults = UserDefaults.standard
    var key = "phone.mappedPorts"

    func load() -> [Int: String] {
        var out: [Int: String] = [:]
        for (port, target) in defaults.dictionary(forKey: key) as? [String: String] ?? [:] {
            if let port = Int(port) { out[port] = target }
        }
        return out
    }

    func save(_ ports: [Int: String]) {
        defaults.set(
            Dictionary(uniqueKeysWithValues: ports.map { (String($0.key), $0.value) }), forKey: key)
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
    private let ports: PhonePortStore
    private let now: () -> Date
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.phone")
    private let notify: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var current = State.off
    /// What `tailscale serve` publishes for us, while it does. Confined to `queue`.
    private var served: (port: Int, identity: MobileIdentity)? {
        didSet {
            lock.lock()
            listedOwnPort = served?.port
            lock.unlock()
        }
    }
    /// The idle-sleep assertion held while the server is on. Confined to `queue`.
    private var awake: NSObjectProtocol?
    /// The dev-server ports this app published, by port. Confined to `queue`.
    private var mapped: [Int: MobilePortMapping] = [:]
    /// The same, for readers on other queues. Guarded by `lock`.
    private var listed: [MobilePortMapping] = []
    /// The port the phone server is published on, for the same readers.
    private var listedOwnPort: Int?

    /// Called with each new state, through `notify` (the main queue in the app).
    var onChange: ((State) -> Void)?
    /// Called with the open dev-server mappings when they change, through `notify`.
    var onMappings: (([MobilePortMapping]) -> Void)?

    init(
        server: MobileServer,
        runner: CommandRunner = ProcessCommandRunner(timeout: 10),
        tailscalePath: @escaping () -> String? = HostAddress.tailscalePath,
        port: @escaping () -> Int = { Settings.phonePort() },
        keepAwake: @escaping () -> Bool = { Settings.phoneKeepAwake() },
        tokens: PhoneTokenStore = KeychainTokenStore(),
        ports: PhonePortStore = DefaultsPortStore(),
        now: @escaping () -> Date = Date.init,
        notify: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.server = server
        self.runner = runner
        self.tailscalePath = tailscalePath
        self.port = port
        self.keepAwake = keepAwake
        self.tokens = tokens
        self.ports = ports
        self.now = now
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
            guard let serving = self.runner.run(tailscale, MobileTailnet.serveStatusArgv) else { return }
            self.removeLeftoverPorts(tailscale: tailscale, serving: serving)
            guard MobileTailnet.servesOurs(serveStatusJSON: serving, port: port) else { return }
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
            removeLeftoverPorts(tailscale: tailscale, serving: serving)
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
        // A token that could not be read is not replaced: the phones hold it.
        var stored: String?
        switch tokens.read() {
        case .found(let token):
            stored = token
        case .failed:
            return set(.failed("Keychain did not give the pairing token"))
        case .missing:
            let fresh = MobileTailnet.newToken()
            if tokens.save(fresh) {
                stored = fresh
                // No phone holds the new token, so none is left subscribed.
                server.forgetPhones()
            }
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
                    return self.set(.failed(Self.reason(text) ?? "tailscale serve failed"))
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

    /// The line of `tailscale serve`'s output that says why it failed.
    private static func reason(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("Warning:") }
    }

    // MARK: Dev-server mappings

    /// The dev-server ports this app has published on the tailnet.
    var mappings: [MobilePortMapping] {
        lock.lock()
        defer { lock.unlock() }
        return listed
    }

    /// Publish local `port` on the tailnet: HTTPS on the same port, proxied to
    /// `localhost`. The caller has checked that Running reports the port; the
    /// rules that hold for any port are checked here. Blocks until done.
    ///
    /// A mapped server answers every device on the tailnet, with no pairing
    /// token. That is why each mapping is opened by a tap, counted, and closed
    /// again by `sweepMappings`.
    func openMapping(port: Int, https: Bool, thread: String, label: String) -> MobileServing.Opened {
        queue.sync {
            guard let served, let tailscale = tailscalePath() else {
                return .unavailable("Phone access is off")
            }
            guard MobileServing.allowed(port: port, ownPort: served.port) else { return .refused }
            guard let serving = runner.run(tailscale, MobileTailnet.serveStatusArgv) else {
                return .unavailable("Tailscale did not answer")
            }
            let holder = MobileServing.holder(serveStatusJSON: serving, port: port)
            if let existing = mapped[port],
               MobileServing.proxy(serveStatusJSON: serving, port: port) == existing.target {
                // Open already: the tap counts as use.
                mapped[port]?.openedAt = now()
                publishMappings()
                return .ok
            }
            // A mapping this app did not make, or one that no longer proxies
            // where this app pointed it, is someone's own.
            guard holder == .nobody else { return .taken }
            guard mapped.keys.filter({ $0 != port }).count < MobileServing.maxMappings else {
                return .limit
            }
            // Stored first: a crash right after the command still leaves a record.
            var stored = ports.load()
            stored[port] = MobileServing.target(port: port, https: https)
            ports.save(stored)
            let (ok, text) = runner.runCapturing(
                tailscale, MobileServing.serveOnArgv(port: port, https: https))
            mapped[port] = ok
                ? MobilePortMapping(port: port, thread: thread, label: label, https: https, openedAt: now())
                : nil
            publishMappings(removing: ok ? [] : [port])
            return ok ? .ok : .unavailable(Self.reason(text) ?? "tailscale serve failed")
        }
    }

    /// Close a mapping this app made. False when it has none on `port`.
    func closeMapping(port: Int) -> Bool {
        queue.sync {
            guard mapped[port] != nil else { return false }
            unmap([port])
            return true
        }
    }

    /// Close every mapping: the "Local servers" switch was turned off.
    func closeAllMappings() {
        queue.async { self.unmap(Array(self.mapped.keys)) }
    }

    /// Close the mappings nobody opened for `MobileServing.idleSeconds`, and
    /// those on a port in `gone`: nothing runs there any more.
    func sweepMappings(gone: Set<Int> = []) {
        queue.async {
            self.unmap(MobileServing.stale(Array(self.mapped.values), gone: gone, now: self.now()))
        }
    }

    /// The sweep the app runs with each new tree: close what is stale, and
    /// what `MobileServing.gone` finds for `snapshot`. `running` is what a
    /// thread's pane runs now, or nil when the pane cannot be asked.
    func sweep(snapshot: MobileSnapshot, running: (MobileThread) -> RunningSet?) {
        lock.lock()
        let (open, ownPort) = (listed, listedOwnPort)
        lock.unlock()
        // `running` belongs to the caller's thread, so it is asked here.
        sweepMappings(gone: MobileServing.gone(
            open, snapshot: snapshot, running: running, ownPort: ownPort))
    }

    private func unmap(_ closing: [Int]) {
        let closing = closing.filter { mapped[$0] != nil }.sorted()
        guard !closing.isEmpty else { return }
        if let tailscale = tailscalePath() {
            let serving = runner.run(tailscale, MobileTailnet.serveStatusArgv)
            for port in closing {
                // Gone already, or replaced by someone's own mapping: not ours to remove.
                if let serving,
                   MobileServing.proxy(serveStatusJSON: serving, port: port) != mapped[port]?.target {
                    continue
                }
                _ = runner.runCapturing(tailscale, MobileTailnet.serveOffArgv(port: port))
            }
        }
        for port in closing { mapped[port] = nil }
        publishMappings(removing: closing)
    }

    /// Store the open ports and tell the readers. A stored port is dropped
    /// only when it is in `removing`: one a start could not check yet stays.
    private func publishMappings(removing: [Int] = []) {
        var stored = ports.load()
        for port in removing { stored[port] = nil }
        for mapping in mapped.values { stored[mapping.port] = mapping.target }
        ports.save(stored)
        let list = mapped.values.sorted { $0.port < $1.port }
        lock.lock()
        let changed = listed != list
        listed = list
        lock.unlock()
        if changed { notify { [weak self] in self?.onMappings?(list) } }
    }

    /// Take away the dev-server mappings a crash or a forced quit left behind.
    /// A stored port is removed only when it still proxies to the exact
    /// target this app set for it: the port may by now be another project's,
    /// or someone's own mapping to the same server.
    private func removeLeftoverPorts(tailscale: String, serving: String) {
        let stored = ports.load().filter { mapped[$0.key] == nil }
        guard !stored.isEmpty else { return }
        for (port, target) in stored.sorted(by: { $0.key < $1.key })
        where MobileServing.proxy(serveStatusJSON: serving, port: port) == target {
            _ = runner.runCapturing(tailscale, MobileTailnet.serveOffArgv(port: port))
        }
        publishMappings(removing: Array(stored.keys))
    }

    private func teardown() {
        unmap(Array(mapped.keys))
        server.stop()
        let port = served?.port
        served = nil
        applyKeepAwake()
        guard let port, let tailscale = tailscalePath() else { return }
        _ = runner.runCapturing(tailscale, MobileTailnet.serveOffArgv(port: port))
    }
}
