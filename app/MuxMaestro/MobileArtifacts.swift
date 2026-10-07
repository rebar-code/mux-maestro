import CryptoKit
import Foundation

// What a thread's agent made, for the phone: the list the Artifacts panel
// shows, and one file of it. The phone names a file by an id from the list and
// never by a path, so nothing it sends reaches the filesystem. Foundation only,
// so the test target compiles it.

/// What the transcript of one thread says it made, before the phone's rules.
typealias MobileArtifactSource = (artifacts: [Artifact], links: [ArtifactWebItem])

enum MobileArtifactKind: String {
    case image, pdf, markdown, html, code, text, other
}

/// One file of a thread's list as the phone gets it.
struct MobileArtifactFile: Equatable {
    let artifact: Artifact
    /// Bytes on disk now; nil for a file that is gone.
    let size: Int?

    var id: String { MobileArtifacts.id(path: artifact.path) }

    var json: [String: Any] {
        [
            "id": id, "name": artifact.name, "dir": artifact.parentDir,
            "kind": MobileArtifacts.kind(of: artifact).rawValue,
            "mime": MobileArtifacts.contentType(for: artifact),
            "size": size ?? NSNull(),
            "at": max(0, Int(artifact.at.timeIntervalSince1970)),
            "exists": artifact.exists,
        ]
    }
}

/// The disk of a thread's host, as the artifact rules ask it. This Mac's is
/// `local`; a remote host's is answered over ssh (`RemoteArtifactFiles`). The
/// rules themselves (`isSecret`, `permitted`) always run here, on the answers.
struct MobileArtifactDisk {
    /// The user's home folder there.
    var home: String
    /// The folders screenshots are written to there.
    var tempRoots: [String]
    /// The path the host gives for what `path` names, links resolved. nil
    /// when nothing is there.
    var resolved: (String) -> String?
    var size: (String) -> Int?
    /// Open the listed `path` and read it, at most `limit` bytes. A symlink
    /// as the last component is not followed and only a regular file is
    /// read. `permitted` is asked about the real path of the file that was
    /// opened; a file it refuses is `.missing`.
    var open: (_ path: String, _ limit: Int, _ permitted: (String) -> Bool) -> MobileArtifacts.FileRead

    static let local = local()

    static func local(
        tempRoots: [String] = MobileArtifacts.tempRoots, home: String = NSHomeDirectory()
    ) -> MobileArtifactDisk {
        MobileArtifactDisk(
            home: home, tempRoots: tempRoots, resolved: MobileArtifacts.resolved,
            size: MobileArtifacts.fileSize, open: MobileArtifacts.openLocal)
    }
}

enum MobileArtifacts {
    /// The largest file the phone is sent. A larger one answers 413.
    static let maxFileBytes = 10 * 1_048_576

    /// On every file response. An artifact is untrusted: if a browser ever
    /// showed one as a page of its own, `sandbox` gives it an origin that is
    /// not the app's (no pairing token, no API), and it loads nothing.
    static let contentSecurityPolicy =
        "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:"

    /// What the phone sends back to name a file: the first 16 bytes of the
    /// path's SHA-256. It says nothing a path would, and it is only ever
    /// looked up in the thread's own list.
    static func id(path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static let secretNames: Set<String> = [
        "credentials", "credentials.json", "kubeconfig", "secrets.json", "secrets.yml",
        "secrets.yaml", "secret.json", "terraform.tfstate", "terraform.tfstate.backup", "htpasswd",
        "authorized_keys", "known_hosts", "shadow", "passwd", "master.key",
    ]
    private static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keychain", "jks", "keystore", "kdbx", "ovpn", "tfvars", "asc",
        "gpg",
    ]

    /// Whether the file's name says it holds a secret. A transcript lists such
    /// a file like any other the agent touched; the phone never gets it.
    static func isSecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        return secretNames.contains(name) || secretExtensions.contains(ext)
            || name.hasSuffix("_history")
            // A private key by its usual name; the `.pub` half is not one.
            || (name.hasPrefix("id_") && ext != "pub")
            || name.hasPrefix("service-account") || name.hasPrefix("serviceaccount")
    }

    /// Whether a path below a root has a dotfile or a dot-folder in it. Those
    /// hold settings, tokens and history (`.env`, `.git`, `.aws`), not work.
    static func hidden(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// The folders screenshots are written to. An image there is offered
    /// though it is outside the thread's folder; nothing else is.
    static let tempRoots: [String] = {
        var roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        // This user's own temp folder, as it is named and as it resolves.
        let own = (NSTemporaryDirectory() as NSString).standardizingPath
        for root in [own, resolved(own) ?? own] where root.count > 1 && !roots.contains(root) {
            roots.append(root)
        }
        return roots
    }()

    /// The path the system gives for what `path` names, with every link
    /// resolved and in the letter case on disk. nil when nothing is there.
    static func resolved(_ path: String) -> String? {
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return realPath(of: fd)
    }

    private static func realPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return fcntl(fd, F_GETPATH, &buffer) == -1 ? nil : String(cString: buffer)
    }

    /// `path` below `root`, or nil when it is not inside it.
    private static func below(_ path: String, root: String) -> String? {
        guard root.count > 1, path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// The one rule for what the phone may have, applied to a path whose links
    /// are resolved: it lies in the thread's own folder, or it is an image in
    /// a temp folder, and nothing below that root is hidden. The home folder
    /// and the folders above it are never a thread's own folder. A transcript can
    /// name any path on the Mac (an edit that was refused is still listed), so
    /// being listed is not enough.
    static func permitted(
        _ real: String, cwd: String, image: Bool, tempRoots: [String] = tempRoots,
        home: String = NSHomeDirectory(), resolved: (String) -> String? = resolved
    ) -> Bool {
        // Each root as it is named and as it resolves: a file that is gone
        // is judged by its name, one that is there by where it really is.
        let folder = (cwd as NSString).standardizingPath
        let own = [folder, resolved(folder)].compactMap { $0 }
        // A thread started in the home folder, or above it, has no folder of
        // its own: everything the user keeps would be inside it.
        let homes = [(home as NSString).standardizingPath, resolved(home)].compactMap { $0 }
        let tooWide = own.contains { root in homes.contains { $0 == root || $0.hasPrefix(root + "/") } }
        let temp = image ? tempRoots + tempRoots.compactMap(resolved) : []
        return ((tooWide ? [] : own) + temp).contains { root in
            below(real, root: root).map { !hidden($0) } ?? false
        }
    }

    private static func isImage(_ artifact: Artifact) -> Bool {
        kind(of: artifact) == .image
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "out", "err", "diff", "patch",
    ]

    static func kind(of artifact: Artifact) -> MobileArtifactKind {
        let ext = (artifact.path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ext == "html" || ext == "htm" { return .html }
        if artifact.isMarkdown { return .markdown }
        if artifact.isCode { return .code }
        return textExtensions.contains(ext) ? .text : .other
    }

    /// A fixed map: the type never comes from the file's bytes or the phone.
    static func contentType(for artifact: Artifact) -> String {
        switch kind(of: artifact) {
        case .image:
            switch (artifact.path as NSString).pathExtension.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            default: return "image/svg+xml"
            }
        case .pdf: return "application/pdf"
        case .html: return "text/html; charset=utf-8"
        case .markdown, .code, .text: return "text/plain; charset=utf-8"
        case .other: return "application/octet-stream"
        }
    }

    /// The transcript of a local thread as `ArtifactScanner` reads it: what the
    /// app hands the server as its artifact source. nil when there is nothing
    /// to read (a remote thread, no agent, no transcript).
    static func scan(thread: MobileThread, reader: ArtifactTranscriptReader) -> MobileArtifactSource? {
        guard thread.host.isLocal,
              let path = reader.transcript(
                  claudeSessionId: thread.claudeSessionId, codexSessionId: thread.codexSessionId),
              let mentions = reader.mentions(transcript: path)
        else { return nil }
        let fm = FileManager.default
        return (
            ArtifactScanner.resolve(
                mentions, fileExists: { fm.fileExists(atPath: $0) },
                mtime: { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }),
            ArtifactScanner.web(urls: mentions.urls, running: [], runningKnown: false).links)
    }

    /// The files of `source` the phone may see, in the scanner's order. A
    /// file that is gone is judged by the path it had.
    static func files(
        _ source: MobileArtifactSource?, cwd: String, size: (String) -> Int? = fileSize,
        tempRoots: [String] = tempRoots, home: String = NSHomeDirectory(),
        resolved: (String) -> String? = resolved
    ) -> [MobileArtifactFile] {
        (source?.artifacts ?? []).filter { artifact in
            !isSecret(artifact.path) && permitted(
                resolved(artifact.path) ?? (artifact.path as NSString).standardizingPath,
                cwd: cwd, image: isImage(artifact),
                tempRoots: tempRoots, home: home, resolved: resolved)
        }.map {
            MobileArtifactFile(artifact: $0, size: $0.exists ? size($0.path) : nil)
        }
    }

    /// The same list, asked of `disk`: the thread's host.
    static func files(
        _ source: MobileArtifactSource?, cwd: String, disk: MobileArtifactDisk, sizes: Bool = true
    ) -> [MobileArtifactFile] {
        files(
            source, cwd: cwd, size: sizes ? disk.size : { _ in nil }, tempRoots: disk.tempRoots,
            home: disk.home, resolved: disk.resolved)
    }

    static func fileSize(_ path: String) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue
    }

    /// The disk of a thread that was given none: this Mac's for a local
    /// thread. A remote thread has none of its own, and then lists nothing.
    private static func own(_ thread: MobileThread) -> MobileArtifactDisk? {
        thread.host.isLocal ? .local : nil
    }

    /// The `/artifacts` body. `disk` is the thread's host; with none (a host
    /// that cannot be asked) the list is empty and nothing is read.
    static func list(
        thread: MobileThread, source: (MobileThread) -> MobileArtifactSource?,
        disk: MobileArtifactDisk? = nil
    ) -> MobileResponse {
        guard let disk = disk ?? own(thread) else { return .json(["files": [], "links": []] as [String: Any]) }
        let found = source(thread)
        let links = (found?.links ?? []).map { link -> [String: Any] in
            [
                "url": link.url, "host": link.host, "path": link.path,
                "at": link.at.map { max(0, Int($0.timeIntervalSince1970)) } ?? NSNull(),
            ]
        }
        return .json(
            ["files": files(found, cwd: thread.cwd, disk: disk).map(\.json), "links": links] as [String: Any])
    }

    /// The `/file` response: the one file of the thread's list that `id`
    /// names. The list is built again now, so an id from an older list that
    /// the thread no longer has is a 404 like any unknown one.
    static func file(
        id: String, thread: MobileThread, source: (MobileThread) -> MobileArtifactSource?,
        disk: MobileArtifactDisk? = nil
    ) -> MobileResponse {
        guard let disk = disk ?? own(thread),
              let file = files(source(thread), cwd: thread.cwd, disk: disk, sizes: false)
                  .first(where: { $0.id == id })
        else { return .error(404, "not_found") }
        switch read(path: file.artifact.path, cwd: thread.cwd, image: isImage(file.artifact), disk: disk) {
        case .missing:
            return .error(404, "not_found")
        case .tooLarge:
            return .error(413, "too_large")
        case .data(let data):
            return MobileResponse(
                status: 200,
                headers: [
                    "Content-Type": contentType(for: file.artifact),
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": contentSecurityPolicy,
                    "Content-Disposition": "attachment",
                    "Cross-Origin-Resource-Policy": "same-origin",
                ],
                body: data)
        }
    }

    /// The words of the one file `id` names, for the play button: a markdown
    /// or text file only, found and read by the rules of `file`, cut to
    /// `MobileVoice.maxArtifactCharacters`. nil when there is nothing to say.
    static func speech(
        id: String, thread: MobileThread, source: (MobileThread) -> MobileArtifactSource?,
        disk: MobileArtifactDisk? = nil
    ) -> String? {
        guard let disk = disk ?? own(thread),
              let file = files(source(thread), cwd: thread.cwd, disk: disk, sizes: false)
                  .first(where: { $0.id == id }),
              [.markdown, .text].contains(kind(of: file.artifact)),
              case .data(let data) = read(
                  path: file.artifact.path, cwd: thread.cwd, image: false, disk: disk),
              let text = String(data: data, encoding: .utf8),
              !text.allSatisfy(\.isWhitespace)
        else { return nil }
        return String(text.prefix(MobileVoice.maxArtifactCharacters))
    }

    enum FileRead: Equatable {
        case data(Data)
        case tooLarge
        /// Not there, not a plain file, or not the file the list names.
        case missing
    }

    /// Read the listed `path`, and only it. The file is opened once and every
    /// check is made on that open file, so nothing can be swapped in between
    /// the check and the read:
    /// - a symlink as the last component is not followed;
    /// - it must be a regular file, no larger than `limit`;
    /// - the path the system gives for the open file must pass `permitted`.
    ///   A listed path that goes through a symlinked folder to somewhere else
    ///   is refused, and one written in another letter case is still found.
    static func read(
        path: String, cwd: String, image: Bool, limit: Int = maxFileBytes,
        tempRoots: [String] = tempRoots, home: String = NSHomeDirectory()
    ) -> FileRead {
        read(path: path, cwd: cwd, image: image, limit: limit, disk: .local(tempRoots: tempRoots, home: home))
    }

    /// The same read on `disk`. The rules are applied here, to the real path
    /// the host gave for the file it opened, whatever host that is.
    static func read(
        path: String, cwd: String, image: Bool, limit: Int = maxFileBytes, disk: MobileArtifactDisk
    ) -> FileRead {
        disk.open(path, limit) { real in
            !isSecret(real) && permitted(
                real, cwd: cwd, image: image, tempRoots: disk.tempRoots, home: disk.home,
                resolved: disk.resolved)
        }
    }

    /// `MobileArtifactDisk.open` for this Mac.
    static func openLocal(path: String, limit: Int, permitted: (String) -> Bool) -> FileRead {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .missing }
        guard info.st_size <= off_t(limit) else { return .tooLarge }
        guard let real = realPath(of: fd), permitted(real) else { return .missing }
        // One byte past the limit: a file that grew since `fstat` is still refused.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: limit + 1) ?? Data() else { return .missing }
        return data.count > limit ? .tooLarge : .data(data)
    }
}

// MARK: - A remote host's files

/// The files of a remote host, for the artifact rules: what is there, where
/// it really is, and the bytes of one file. Two fixed `python3` programs run
/// on the host; a path is always an argument to one, never part of its text.
/// The host only reports. What the phone may have is decided on this Mac.
final class RemoteArtifactFiles {
    /// What the host says about one path.
    struct Stat: Equatable {
        /// With every link resolved.
        var real: String
        var size: Int
        var modified: Date
    }

    /// Paths asked about in one run.
    static let maxPaths = 400
    /// How long an answer is believed: one request asks about a path many times.
    static let life: TimeInterval = 10

    /// Prints one JSON object: each argument that names something, with its
    /// real path, size and time of change.
    static let statScript = #"""
        import json, os, sys
        out = {}
        for p in sys.argv[1:]:
            try:
                st = os.stat(p)
                out[p] = {"real": os.path.realpath(p), "size": st.st_size, "mtime": st.st_mtime}
            except OSError:
                pass
        json.dump(out, sys.stdout)
        """#

    /// Opens argument 1 without following a link in its last part, checks
    /// that it is a regular file of at most argument 2 bytes, and prints one
    /// line of JSON (the real path of the file it opened, or an error), then
    /// the bytes. The real path comes from the open file, not from the name.
    static let readScript = #"""
        import fcntl, json, os, stat, sys
        def say(head, body=b""):
            sys.stdout.buffer.write(json.dumps(head).encode() + b"\n" + body)
            sys.exit(0)
        path, limit = sys.argv[1], int(sys.argv[2])
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            say({"error": "missing"})
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            say({"error": "missing"})
        if st.st_size > limit:
            say({"error": "too_large"})
        real = None
        try:
            real = os.readlink("/proc/self/fd/%d" % fd)
        except OSError:
            try:
                real = fcntl.fcntl(fd, getattr(fcntl, "F_GETPATH", 50), b"\0" * 1024).split(b"\0")[0].decode()
            except Exception:
                real = None
        if not real or not real.startswith("/"):
            say({"error": "missing"})
        data = b""
        while len(data) <= limit:
            more = os.read(fd, min(1048576, limit + 1 - len(data)))
            if not more:
                break
            data += more
        if len(data) > limit:
            say({"error": "too_large"})
        say({"real": real}, data)
        """#

    /// Run `python3` on the host with `script` and `args`; its output.
    private let run: (_ script: String, _ args: [String], _ slow: Bool) -> Data?
    private let home: () -> String?
    private let now: () -> Date
    private let lock = NSLock()
    private var known: [String: (stat: Stat?, at: Date)] = [:]

    init(
        run: @escaping (_ script: String, _ args: [String], _ slow: Bool) -> Data?,
        home: @escaping () -> String?, now: @escaping () -> Date = Date.init
    ) {
        self.run = run
        self.home = home
        self.now = now
    }

    static func parseStat(_ data: Data) -> [String: Stat]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: Stat] = [:]
        for (path, value) in object {
            guard let fields = value as? [String: Any], let real = fields["real"] as? String,
                  real.hasPrefix("/"), let size = (fields["size"] as? NSNumber)?.intValue,
                  let modified = (fields["mtime"] as? NSNumber)?.doubleValue
            else { continue }
            out[path] = Stat(real: real, size: size, modified: Date(timeIntervalSince1970: modified))
        }
        return out
    }

    /// The answer of `readScript`: its head line, then the file's bytes.
    static func parseRead(_ data: Data, limit: Int) -> (real: String, data: Data)? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let head = try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline]) as? [String: Any],
              let real = head["real"] as? String, real.hasPrefix("/")
        else { return nil }
        let body = Data(data[data.index(after: newline)...])
        return body.count <= limit ? (real, body) : nil
    }

    private static func tooLarge(_ data: Data) -> Bool {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) ?? Optional(data.endIndex),
              let head = try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline]) as? [String: Any]
        else { return false }
        return head["error"] as? String == "too_large"
    }

    /// Ask the host about `paths` in one run. Only absolute paths are asked
    /// about: a word that starts with `-` is never handed to `python3`.
    func learn(_ paths: [String]) {
        let asked = Array(Set(paths.filter { $0.hasPrefix("/") })).sorted().prefix(Self.maxPaths)
        guard !asked.isEmpty, let out = run(Self.statScript, Array(asked), false),
              let stats = Self.parseStat(out)
        else { return }
        let at = now()
        lock.lock()
        known = known.filter { at.timeIntervalSince($0.value.at) < Self.life }
        for path in asked { known[path] = (stats[path], at) }
        lock.unlock()
    }

    /// What the host said about `path`, asking it when that is not known.
    func stat(_ path: String) -> Stat? {
        for attempt in 0..<2 {
            lock.lock()
            let hit = known[path]
            lock.unlock()
            if let hit, now().timeIntervalSince(hit.at) < Self.life { return hit.stat }
            if attempt == 0 { learn([path]) }
        }
        return nil
    }

    /// The host's disk for the artifact rules. nil when its home is not known.
    func disk() -> MobileArtifactDisk? {
        guard let home = home(), home.hasPrefix("/") else { return nil }
        return MobileArtifactDisk(
            home: home, tempRoots: ["/tmp"],
            resolved: { [self] in stat($0)?.real },
            size: { [self] in stat($0)?.size },
            open: { [self] path, limit, permitted in
                guard path.hasPrefix("/"), let out = run(Self.readScript, [path, String(limit)], true)
                else { return .missing }
                if Self.tooLarge(out) { return .tooLarge }
                guard let read = Self.parseRead(out, limit: limit), permitted(read.real) else { return .missing }
                return .data(read.data)
            })
    }

    /// The files a transcript mentions, as they are on the host: one run
    /// asks about all of them and about the roots the rules compare with.
    func source(mentions: ArtifactMentions, cwd: String) -> MobileArtifactSource {
        let paths = Array(mentions.made.keys) + Array(mentions.imageCandidates.keys)
            + Array(mentions.namedCandidates.keys)
        learn([cwd, (cwd as NSString).standardizingPath, home() ?? "", "/tmp"] + paths)
        return (
            ArtifactScanner.resolve(
                mentions, fileExists: { [self] in stat($0) != nil }, mtime: { [self] in stat($0)?.modified }),
            ArtifactScanner.web(urls: mentions.urls, running: [], runningKnown: false).links)
    }
}
