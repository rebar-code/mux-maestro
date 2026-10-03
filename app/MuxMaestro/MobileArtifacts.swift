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
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".netrc", ".npmrc", "credentials",
    ]
    private static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keychain"]
    private static let secretFolders: Set<String> = [".ssh", ".aws", ".gnupg"]

    /// Whether `path` looks like it holds a secret. An agent that edits a
    /// `.env` lists it like any file it made; the phone never gets it.
    static func isSecret(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard let name = parts.last else { return false }
        return name.hasPrefix(".env") || secretNames.contains(name)
            || secretExtensions.contains((name as NSString).pathExtension)
            || parts.dropLast().contains(where: secretFolders.contains)
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

    /// The files of `source` the phone may see, in the scanner's order.
    static func files(
        _ source: MobileArtifactSource?, size: (String) -> Int? = fileSize
    ) -> [MobileArtifactFile] {
        (source?.artifacts ?? []).filter { !isSecret($0.path) }.map {
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
            ["files": files(found).map(\.json), "links": links, "remote": false] as [String: Any])
    }

    /// The `/file` response: the one file of the thread's list that `id`
    /// names. The list is built again now, so an id from an older list that
    /// the thread no longer has is a 404 like any unknown one.
    static func file(
        id: String, thread: MobileThread, source: (MobileThread) -> MobileArtifactSource?
    ) -> MobileResponse {
        guard thread.host.isLocal,
              let file = files(source(thread), size: { _ in nil }).first(where: { $0.id == id })
        else { return .error(404, "not_found") }
        switch read(path: file.artifact.path, cwd: thread.cwd) {
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
    /// - the path the system gives for the open file must be the listed path,
    ///   or lie inside the thread's own directory. A listed path that passes
    ///   through a symlinked folder to somewhere else is refused.
    static func read(path: String, cwd: String, limit: Int = maxFileBytes) -> FileRead {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .missing }
        guard info.st_size <= off_t(limit) else { return .tooLarge }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return .missing }
        let real = String(cString: buffer)
        guard unaliased(real) == unaliased(path) || isInside(real, directory: cwd) else {
            return .missing
        }
        // One byte past the limit: a file that grew since `fstat` is still refused.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: limit + 1) ?? Data() else { return .missing }
        return data.count > limit ? .tooLarge : .data(data)
    }

    /// `path` without the `/private` that macOS puts under `/tmp`, `/var` and
    /// `/etc`: those three are fixed links of the system, not an escape.
    static func unaliased(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] {
            let long = "/private" + alias
            if path == long || path.hasPrefix(long + "/") { return String(path.dropFirst(8)) }
        }
        return path
    }

    /// Whether the resolved `real` path is in `directory` once that is
    /// resolved too. The root directory contains everything, so it never counts.
    static func isInside(_ real: String, directory: String) -> Bool {
        guard !directory.isEmpty, let resolved = realpath(directory, nil) else { return false }
        defer { free(resolved) }
        let root = String(cString: resolved)
        return root != "/" && real.hasPrefix(root + "/")
    }
}
