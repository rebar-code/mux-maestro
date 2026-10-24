import Foundation

// keygate, the secrets broker, as a review card reaches it. Optional: with no
// keygate installed nothing here runs, and every row is a plain row.
//
// The rules, in one place:
// - Any process of this user writes review rows. A row's keygate id is only a
//   pointer to a request. keygate's own dialog (Touch ID) or its phone page
//   (Face ID) shows the request and takes the decision.
// - Maestro never calls keygate's approve or deny API, holds no key, signature
//   or secret, and types nothing into a pane for a keygate card.
// - The id passes `isValidID` at every boundary: `mux`, the store, the button,
//   the phone API and the phone page.
// - keygate is one absolute path, run with an argument array, no shell and a
//   fixed environment. It runs only when root owns the file and its folder,
//   and no group or other user can write either.
// - The phone link's origin comes only from `keygate info --json`, never from
//   the row, and is https.
// - There is no `muxmaestro://` route for this: any web page can open a URL
//   scheme. The Mac action is a button in the app.

enum Keygate {
    static let binaryPath = "/usr/local/bin/keygate"
    /// The longest request id keygate makes.
    static let maxIDLength = 64

    /// 1 to 64 lowercase hex characters: `^[a-f0-9]{1,64}$`.
    static func isValidID(_ id: String) -> Bool {
        (1...maxIDLength).contains(id.utf8.count)
            && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The id when it is valid, nil for anything else (an empty column too).
    static func validID(_ id: String?) -> String? {
        guard let id, isValidID(id) else { return nil }
        return id
    }

    /// `keygate approve <id>`: keygate opens its dialog and asks for Touch ID.
    static func approveArguments(id: String) -> [String]? {
        isValidID(id) ? ["approve", id] : nil
    }

    static let infoArguments = ["info", "--json"]

    /// The child's environment: a fixed PATH and the few variables that say who
    /// the user is. Nothing else is passed on, so a `KEYGATE_*` variable in the
    /// app's own environment cannot point keygate at another socket or helper.
    static func environment(from inherited: [String: String]) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
            if let value = inherited[name] { env[name] = value }
        }
        return env
    }

    // MARK: The binary

    /// What `lstat` says about one path.
    struct FileFacts: Equatable {
        enum Kind: Equatable { case file, directory, other }
        let kind: Kind
        let owner: uid_t
        let mode: mode_t
    }

    static func facts(atPath path: String) -> FileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: FileFacts.Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        default: kind = .other
        }
        return FileFacts(kind: kind, owner: info.st_uid, mode: info.st_mode)
    }

    /// Whether keygate may run: a regular file (not a link) that root owns,
    /// that someone may execute, in a folder root owns, and no group or other
    /// user can write either. A folder this user can write would let a process
    /// swap the file between this check and the launch.
    static func binaryIsTrusted(
        path: String = binaryPath, facts: (String) -> FileFacts? = Keygate.facts(atPath:)
    ) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        guard path.hasPrefix("/"), let file = facts(path), let dir = facts(folder) else {
            return false
        }
        let writable = mode_t(S_IWGRP | S_IWOTH)
        return file.kind == .file && file.owner == 0 && file.mode & writable == 0
            && file.mode & mode_t(S_IXUSR | S_IXGRP | S_IXOTH) != 0
            && dir.kind == .directory && dir.owner == 0 && dir.mode & writable == 0
    }

    // MARK: The phone link

    /// The longest origin taken from `keygate info`.
    static let maxOriginLength = 512

    /// `web_origin` from `keygate info --json`, as `https://host[:port]`. nil
    /// when keygate has none, or names anything but a bare https origin.
    static func origin(fromInfo data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["web_origin"] as? String else { return nil }
        return origin(raw)
    }

    static func origin(_ raw: String) -> String? {
        guard raw.utf8.count <= maxOriginLength,
              raw.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }),
              let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil
        else { return nil }
        return "https://\(host)" + (parts.port.map { ":\($0)" } ?? "")
    }

    /// `<origin>/?id=<id>`: keygate's phone page, on that request.
    static func phoneLink(origin raw: String, id: String) -> URL? {
        guard let origin = origin(raw), isValidID(id) else { return nil }
        return URL(string: "\(origin)/?id=\(id)")
    }

    // MARK: Running it

    /// Run keygate and wait at most `timeout` for it to exit. Its stdout on exit
    /// 0; nil when it is not trusted, does not start, fails or runs too long.
    /// Blocks: call it off the main thread.
    /// `path` is for tests; the app always runs `binaryPath`.
    static func run(_ arguments: [String], timeout: TimeInterval, path: String = binaryPath) -> Data? {
        guard binaryIsTrusted(path: path) else { return nil }
        let runner = ProcessCommandRunner(
            timeout: timeout, environment: environment(from: ProcessInfo.processInfo.environment))
        return runner.runData(path, arguments, stdin: nil)
    }

    /// Start `keygate approve <id>` and return at once: keygate's dialog waits
    /// for the human. `exited` runs when keygate ends, on a background queue.
    /// false when the id or the binary fails its check, or the process does
    /// not start; `exited` does not run then.
    @discardableResult
    static func approve(
        id: String, path: String = binaryPath, exited: (() -> Void)? = nil
    ) -> Bool {
        guard let arguments = approveArguments(id: id), binaryIsTrusted(path: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited?() }
        do { try process.run() } catch { return false }
        return true
    }

    /// keygate's phone origin, or nil when keygate is missing, untrusted or has
    /// none. Blocks for up to 3 s: call it off the main thread.
    static func fetchOrigin() -> String? {
        run(infoArguments, timeout: 3).flatMap(origin(fromInfo:))
    }
}

/// keygate's phone origin, as the last `keygate info` said. A fetch runs off
/// the main thread, and only when asked: the app asks while a keygate row is
/// listed, so with no keygate rows nothing runs. Main-thread API.
final class KeygateOrigin {
    /// How long one answer is kept before the next ask fetches again.
    static let maxAge: TimeInterval = 60

    private(set) var value: String?
    private var fetchedAt: Date?
    private var fetching = false
    private let fetch: () -> String?
    private let queue: DispatchQueue
    /// The value changed. Called on the main thread.
    var onChange: (() -> Void)?

    init(
        fetch: @escaping () -> String? = Keygate.fetchOrigin,
        queue: DispatchQueue = DispatchQueue(label: "is.rebar.muxmaestro.keygate")
    ) {
        self.fetch = fetch
        self.queue = queue
    }

    /// Fetch again when the last answer is older than `maxAge`.
    func refreshIfStale(now: Date = Date()) {
        guard !fetching, fetchedAt.map({ now.timeIntervalSince($0) >= Self.maxAge }) ?? true else {
            return
        }
        fetching = true
        queue.async { [fetch] in
            let fresh = fetch()
            DispatchQueue.main.async {
                self.fetching = false
                self.fetchedAt = Date()
                guard fresh != self.value else { return }
                self.value = fresh
                self.onChange?()
            }
        }
    }
}
