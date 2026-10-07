import Foundation

// A remote agent's transcript, copied to a file on this Mac. Every reader of a
// transcript (the phone's chat, a voice turn's read-back, the artifacts list)
// takes a path, so a copy with the session's own name lets them all read a
// remote session as they read a local one.
//
// The copy is brought up to date when it is asked for, inside the request that
// wants it, and at most once a second for one session. No timer runs. Only
// whole lines are written, so a reader never sees half a message.
//
// Foundation only: the test target compiles it and feeds it a fake remote.

final class RemoteTranscriptMirror {
    /// The most of a transcript's end that the first copy takes.
    static let cap = 8_388_608
    /// The least time between two fetches of one session.
    static let interval: TimeInterval = 1
    /// A copy nobody touched for this long is deleted at launch.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    /// The far side: three commands on the session's host. Each may block on
    /// ssh, and answers nil when it failed.
    struct Remote {
        /// The path of the session's transcript on its host.
        var locate: () -> String?
        /// The size of the file at `path`, in bytes.
        var size: (_ path: String) -> Int?
        /// The bytes of the file at `path` from byte `from` (0 is its first) to its end.
        var fetch: (_ path: String, _ from: Int) -> Data?
    }

    private final class Entry {
        let lock = NSLock()
        var remotePath: String?
        var synced = Date.distantPast
    }

    private let root: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// `root` holds one folder for each host.
    init(root: URL = RemoteTranscriptMirror.defaultRoot, now: @escaping () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches.appendingPathComponent("MuxMaestro/transcripts", isDirectory: true)
    }

    /// A session id as an agent gives it: letters, digits and `-`. Checked
    /// before the id is a file name here or a pattern for `find` there.
    static func isSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A host's name as one folder name: nothing in it can leave `root`.
    static func folder(host: String) -> String? {
        let name = String(host.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
                ? character : "_"
        })
        guard !name.isEmpty, name.count <= 128, !name.hasPrefix(".") else { return nil }
        return name
    }

    /// Whether `path`, as a host gave it, is the rollout of the Codex
    /// conversation `sessionId` under `directory` (the host's
    /// `~/.codex/sessions`, no `/` at its end): inside it with no `..` step,
    /// and named `rollout-…-<id>.jsonl`.
    static func isRollout(_ path: String, sessionId: String, under directory: String) -> Bool {
        guard isSessionID(sessionId), !directory.isEmpty, path.hasPrefix(directory + "/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return false }
        let steps = path.dropFirst(directory.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard let name = steps.last, !steps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return false }
        return name.hasPrefix("rollout-") && name.hasSuffix("-\(sessionId).jsonl")
    }

    /// The path of the copy for `sessionId` of `host`, or nil when the id or
    /// the host has no safe name. A Claude copy is `<id>.jsonl`. A Codex copy
    /// is `codex.<id>.jsonl`: no id has a `.`, so the two never share a file,
    /// and the chat still tells sessions apart by the name.
    func path(host: String, sessionId: String, codex: Bool = false) -> String? {
        guard Self.isSessionID(sessionId), let folder = Self.folder(host: host) else { return nil }
        return root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(codex ? "codex." : "")\(sessionId).jsonl").path
    }

    /// The copy of the transcript of `sessionId` on `host`, brought up to
    /// date. nil when there is no copy: the id is not one, the transcript was
    /// not found, or its host could not be reached and nothing was copied
    /// before. A copy made earlier is still answered when the host is away.
    func file(host: String, sessionId: String, codex: Bool = false, remote: Remote) -> String? {
        guard let path = path(host: host, sessionId: sessionId, codex: codex) else { return nil }
        let entry = entry(path)
        entry.lock.lock()
        defer { entry.lock.unlock() }
        let exists = { FileManager.default.fileExists(atPath: path) }
        guard now().timeIntervalSince(entry.synced) >= Self.interval else { return exists() ? path : nil }
        entry.synced = now()
        sync(path: path, entry: entry, remote: remote)
        return exists() ? path : nil
    }

    private func entry(_ path: String) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[path] { return entry }
        let entry = Entry()
        entries[path] = entry
        return entry
    }

    // MARK: The copy on disk

    /// Where in the remote file the copy's first byte is: kept beside the
    /// copy, so a new launch goes on from where the last one stopped.
    private static func startPath(_ path: String) -> String { path + ".start" }

    private static func localSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    /// The remote offset the copy has reached, or nil when there is no copy.
    private static func reached(_ path: String) -> Int? {
        guard let size = localSize(path),
              let text = try? String(contentsOfFile: startPath(path), encoding: .utf8),
              let start = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), start >= 0
        else { return nil }
        return start + size
    }

    private static func forget(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: startPath(path))
    }

    private func sync(path: String, entry: Entry, remote: Remote) {
        if entry.remotePath == nil { entry.remotePath = remote.locate() }
        guard let far = entry.remotePath else { return }
        if let reached = Self.reached(path) {
            guard let more = remote.fetch(far, reached) else { return }
            if !more.isEmpty { return Self.append(more, to: path) }
            // Nothing new, or the file there is now shorter than the copy:
            // it was written again, and the copy is of a file that is gone.
            guard let size = remote.size(far), size < reached else { return }
            Self.forget(path)
        }
        first(path: path, far: far, remote: remote)
    }

    /// The first copy: the whole file, or its last `cap` bytes from the start
    /// of a line.
    private func first(path: String, far: String, remote: Remote) {
        guard let size = remote.size(far) else { return }
        var start = max(0, size - Self.cap)
        guard var data = remote.fetch(far, start) else { return }
        if start > 0 {
            // The cut fell inside a line: the copy starts after it.
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return }
            let dropped = data.distance(from: data.startIndex, to: newline) + 1
            start += dropped
            data = Data(data.dropFirst(dropped))
        }
        let folder = (path as NSString).deletingLastPathComponent
        guard (try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { return }
        // The folders may be older than this rule.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        Self.forget(path)
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: attributes),
              FileManager.default.createFile(
                atPath: Self.startPath(path), contents: Data(String(start).utf8), attributes: attributes)
        else { return Self.forget(path) }
        Self.append(data, to: path)
    }

    /// Write `data` up to its last newline. The rest is half a line: it is
    /// fetched again, whole, the next time.
    private static func append(_ data: Data, to path: String) {
        guard let newline = data.lastIndex(of: UInt8(ascii: "\n")),
              let handle = FileHandle(forWritingAtPath: path)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data[data.startIndex...newline])
    }

    // MARK: Old copies

    /// Delete the copies last written more than `maxAge` ago.
    func purge() {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        for folder in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let folderPath = root.appendingPathComponent(folder).path
            for name in (try? fm.contentsOfDirectory(atPath: folderPath)) ?? [] where name.hasSuffix(".jsonl") {
                let path = (folderPath as NSString).appendingPathComponent(name)
                guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      modified < cutoff
                else { continue }
                Self.forget(path)
            }
        }
    }
}
