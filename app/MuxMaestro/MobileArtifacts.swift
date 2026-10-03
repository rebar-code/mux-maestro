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
        home: String = NSHomeDirectory()
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
        tempRoots: [String] = tempRoots, home: String = NSHomeDirectory()
    ) -> [MobileArtifactFile] {
        (source?.artifacts ?? []).filter { artifact in
            !isSecret(artifact.path) && permitted(
                resolved(artifact.path) ?? (artifact.path as NSString).standardizingPath,
                cwd: cwd, image: isImage(artifact),
                tempRoots: tempRoots, home: home)
        }.map {
            MobileArtifactFile(artifact: $0, size: $0.exists ? size($0.path) : nil)
        }
    }

    static func fileSize(_ path: String) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue
    }

    /// The `/artifacts` body. Transcripts are on this Mac only, so a thread on
    /// another host says so and nothing is read for it.
    static func list(
        thread: MobileThread, source: (MobileThread) -> MobileArtifactSource?
    ) -> MobileResponse {
        guard thread.host.isLocal else {
            return .json(["files": [], "links": [], "remote": true] as [String: Any])
        }
        let found = source(thread)
        let links = (found?.links ?? []).map { link -> [String: Any] in
            [
                "url": link.url, "host": link.host, "path": link.path,
                "at": link.at.map { max(0, Int($0.timeIntervalSince1970)) } ?? NSNull(),
            ]
        }
        return .json(
            ["files": files(found, cwd: thread.cwd).map(\.json), "links": links, "remote": false] as [String: Any])
    }

    /// The `/file` response: the one file of the thread's list that `id`
    /// names. The list is built again now, so an id from an older list that
    /// the thread no longer has is a 404 like any unknown one.
    static func file(
        id: String, thread: MobileThread, source: (MobileThread) -> MobileArtifactSource?
    ) -> MobileResponse {
        guard thread.host.isLocal,
              let file = files(source(thread), cwd: thread.cwd, size: { _ in nil })
                  .first(where: { $0.id == id })
        else { return .error(404, "not_found") }
        switch read(path: file.artifact.path, cwd: thread.cwd, image: isImage(file.artifact)) {
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
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .missing }
        guard info.st_size <= off_t(limit) else { return .tooLarge }
        guard let real = realPath(of: fd), !isSecret(real),
              permitted(real, cwd: cwd, image: image, tempRoots: tempRoots, home: home)
        else { return .missing }
        // One byte past the limit: a file that grew since `fstat` is still refused.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: limit + 1) ?? Data() else { return .missing }
        return data.count > limit ? .tooLarge : .data(data)
    }
}
