import Foundation

/// The "Phone" switch: starts the loopback server and publishes it on the
/// tailnet with `tailscale serve`, and takes both away again. Foundation only;
/// the Phone window draws `state`.
final class PhoneLink {
    enum State: Equatable {
        case off
        case starting
        case on(url: String)
        case failed(String)
    }

    private let server: MobileServer
    private let runner: CommandRunner
    private let tailscalePath: () -> String?
    private let port: () -> Int
    private let keepAwake: () -> Bool
    private let queue = DispatchQueue(label: "is.rebar.muxmaestro.phone")
    private let notify: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var current = State.off
    /// The port `tailscale serve` publishes for us, while it does. Confined to `queue`.
    private var servedPort: Int?
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
        notify: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.server = server
        self.runner = runner
        self.tailscalePath = tailscalePath
        self.port = port
        self.keepAwake = keepAwake
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

    private func start() {
        teardown()
        guard let tailscale = tailscalePath() else { return set(.failed("Tailscale is not installed")) }
        guard let status = runner.run(tailscale, MobileTailnet.statusArgv),
              let identity = MobileTailnet.identity(statusJSON: status)
        else { return set(.failed("Tailscale is not signed in")) }
        let wanted = port()
        if let serving = runner.run(tailscale, MobileTailnet.serveStatusArgv),
           MobileTailnet.portTaken(serveStatusJSON: serving, port: wanted) {
            return set(.failed("Tailscale already serves port \(wanted)"))
        }
        server.start(port: wanted, identity: identity) { [weak self] result in
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
                self.servedPort = bound
                self.applyKeepAwake()
                self.set(.on(url: MobileTailnet.url(identity: identity, port: bound)))
            }
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

    private func applyKeepAwake() {
        let wanted = servedPort != nil && keepAwake()
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
        let port = servedPort
        servedPort = nil
        applyKeepAwake()
        guard let port, let tailscale = tailscalePath() else { return }
        _ = runner.runCapturing(tailscale, MobileTailnet.serveOffArgv(port: port))
    }
}
