import Foundation

// The phone's own log. The web app posts what went wrong on it (errors, failed
// requests, its service worker's state) to `/api/log`, and this Mac keeps the
// lines in a file an agent can read: `mux phone-log`. Errors and metadata
// only: never message text, never anything a person typed.
//
// The file is JSON Lines, in the directory `Settings.phoneLogDirectory` names:
//
//   phone.jsonl      the file written now
//   phone.1.jsonl    the one before it … phone.7.jsonl, the oldest
//
// It is bounded by `MobileLogFile.Limits`: 4 MiB in all, and no line older
// than 8 days. Nothing here touches the app's database.

// MARK: - Lines

enum MobileLog {
    /// The largest batch the server reads. A batch is a few short lines.
    static let maxBodyBytes = 65_536
    /// Lines taken from one batch; the rest of it is dropped.
    static let maxLines = 100
    /// One line on disk, with its newline.
    static let maxLineBytes = 4096
    /// Fields one line may carry besides the ones every line has.
    static let maxFields = 24
    static let textLimit = 300
    static let stackLimit = 2000
    static let listLimit = 12
    /// A line older than this when it arrives is stamped as this old.
    static let maxAge: TimeInterval = 86_400

    static let severities: Set<String> = ["info", "warn", "error"]
    /// What every line has, in the order it is written. A batch cannot set
    /// the time, the builds or the session of its lines through a field.
    private static let fixed: Set<String> = [
        "t", "sev", "kind", "project", "host", "build", "served", "sid", "msg", "age",
    ]

    /// One batch, cleaned: its lines as they go to the file.
    struct Batch: Equatable {
        var sid = ""
        var build = ""
        var lines: [Data] = []
    }

    /// The build the bundle under `staticRoot` is: what SvelteKit wrote as
    /// its version, which is also the name of the service worker's cache.
    static func servedBuild(staticRoot: URL?) -> String? {
        guard let staticRoot,
              let data = try? Data(contentsOf: staticRoot.appendingPathComponent("_app/version.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty
        else { return nil }
        return clip(version, 40)
    }

    /// Read one `/api/log` body. Whatever is not a line this log keeps is
    /// left out; a body that is not a batch gives no lines.
    ///
    /// Every line gets the build the phone runs and the build this Mac serves
    /// (`served`), so a phone on an old bundle shows in each line it sends.
    /// Its time is this Mac's clock less the age the phone gave it: the
    /// phone's own clock is never trusted.
    static func batch(_ body: Data, served: String?, now: Date) -> Batch {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Batch()
        }
        var batch = Batch(
            sid: clip(object["sid"] as? String ?? "", 16),
            build: clip(object["build"] as? String ?? "", 40))
        for case let raw as [String: Any] in (object["lines"] as? [Any] ?? []).prefix(maxLines) {
            let age = min(max((raw["age"] as? NSNumber)?.doubleValue ?? 0, 0) / 1000, maxAge)
            let sev = (raw["sev"] as? String).flatMap { severities.contains($0) ? $0 : nil } ?? "info"
            var fields: [String: Any] = [:]
            for (key, value) in raw where !fixed.contains(key) && isFieldName(key) {
                if let clean = fieldValue(value, limit: key == "stack" ? stackLimit : textLimit) {
                    fields[key] = clean
                }
            }
            if fields.count > maxFields {
                fields = Dictionary(
                    uniqueKeysWithValues: fields.keys.sorted().prefix(maxFields).map { ($0, fields[$0]!) })
            }
            if let line = line(
                at: now.addingTimeInterval(-age), sev: sev,
                kind: clip(raw["kind"] as? String ?? "note", 16),
                project: clip(raw["project"] as? String ?? "", 64),
                host: clip(raw["host"] as? String ?? "", 64),
                build: batch.build, served: served, sid: batch.sid,
                msg: clip(raw["msg"] as? String ?? "", textLimit), fields: fields) {
                batch.lines.append(line)
            }
        }
        return batch
    }

    /// One line as it is written, without its newline: the fixed fields
    /// first, in one order, then the rest by name. nil when it cannot be made
    /// to fit `maxLineBytes`.
    static func line(
        at: Date, sev: String, kind: String, project: String = "", host: String = "",
        build: String, served: String?, sid: String = "", msg: String, fields: [String: Any] = [:]
    ) -> Data? {
        let head: [(String, Any)] = [
            ("t", stamp(at)), ("sev", sev), ("kind", kind), ("project", project), ("host", host),
            ("build", build), ("served", served ?? ""), ("sid", sid), ("msg", msg),
        ]
        // The stack is the long part: a line that is too long loses it first,
        // then everything but the fixed fields.
        for rest in [fields, fields.filter { $0.key != "stack" }, [:]] {
            let pairs = head + rest.keys.sorted().map { ($0, rest[$0]!) }
            let text = "{" + pairs.map { "\(json($0.0)):\(json($0.1))" }.joined(separator: ",") + "}"
            if text.utf8.count < maxLineBytes { return Data(text.utf8) }
        }
        return nil
    }

    /// `2026-10-04T17:02:11.123Z`: sorts as text, and SQLite reads it.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func isFieldName(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.count <= 16,
              first.isASCII, CharacterSet.lowercaseLetters.contains(first)
        else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// A value a line may hold: a short text, a number, a flag, or a short
    /// list of short texts. Anything else is left out.
    private static func fieldValue(_ value: Any, limit: Int) -> Any? {
        switch value {
        case let text as String:
            return clip(text, limit)
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number : nil
        case let list as [Any]:
            return list.prefix(listLimit).compactMap { ($0 as? String).map { clip($0, 64) } }
        default:
            return nil
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    private static func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

/// How many lines a minute the phone may add. A phone that fails in a loop
/// must not turn the whole file over in minutes and push out the lines that
/// say how it began.
struct MobileLogBudget: Equatable {
    var perMinute = 300
    private var windowStart = Date.distantPast
    private var used = 0
    private var told = false

    init(perMinute: Int = 300) { self.perMinute = perMinute }

    /// How many of `wanted` lines may be written now.
    mutating func take(_ wanted: Int, now: Date) -> Int {
        if now.timeIntervalSince(windowStart) >= 60 {
            windowStart = now
            used = 0
            told = false
        }
        let granted = max(0, min(wanted, perMinute - used))
        used += granted
        return granted
    }

    /// True once a minute, the first time lines were refused in it: the file
    /// then says so in one line.
    mutating func shouldTell() -> Bool {
        defer { told = true }
        return !told
    }
}

// MARK: - The file

/// The log on disk: one file that is written, and the ones before it. Not
/// safe to call from two threads; `MobileLogSink` owns one on its own queue.
final class MobileLogFile {
    struct Limits: Equatable {
        /// A file is rotated before a line would take it past this.
        var maxFileBytes = 524_288
        /// Rotated files kept: `phone.1.jsonl` (the newest) to `phone.7.jsonl`.
        var generations = 7
        /// A file is rotated once it is this old, however small it is, so a
        /// quiet log does not keep old lines in a file that still gets new ones.
        var rotateAfter: TimeInterval = 86_400
        /// A file whose newest line is older than this is deleted.
        var maxAge: TimeInterval = 7 * 86_400

        /// The most the log ever holds on disk: 4 MiB.
        var maxTotalBytes: Int { maxFileBytes * (generations + 1) }
        /// The oldest a line on disk can be: 8 days.
        var maxLineAge: TimeInterval { maxAge + rotateAfter }
    }

    static let activeName = "phone.jsonl"

    let directory: URL
    let limits: Limits
    /// Appends bytes to a file, creating it first. The tests give one that
    /// fails as a full disk does.
    var write: (_ data: Data, _ url: URL) throws -> Void = MobileLogFile.appendBytes
    /// Lines that could not be written since the last line that was.
    private(set) var lost = 0
    private let files = FileManager.default

    init(directory: URL, limits: Limits = Limits()) {
        self.directory = directory
        self.limits = limits
    }

    var active: URL { directory.appendingPathComponent(Self.activeName) }

    func rotated(_ generation: Int) -> URL {
        directory.appendingPathComponent("phone.\(generation).jsonl")
    }

    /// The log's files that exist, oldest first.
    var all: [URL] {
        (stride(from: limits.generations, through: 1, by: -1).map(rotated) + [active])
            .filter { files.fileExists(atPath: $0.path) }
    }

    var totalBytes: Int { all.reduce(0) { $0 + size($1) } }

    /// Append whole lines (no newline in them) and keep the log inside its
    /// limits. Returns how many were written. It never throws and never
    /// waits: lines the disk refuses are counted and the next line that is
    /// written says how many.
    @discardableResult
    func append(_ lines: [Data], now: Date) -> Int {
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(now: now)
        var lines = lines
        if lost > 0, !lines.isEmpty, let note = MobileLog.line(
            at: now, sev: "warn", kind: "dropped", build: "", served: nil,
            msg: "\(lost) lines were not written: the disk refused them", fields: ["n": lost]) {
            lines.insert(note, at: 0)
            lost = 0
        }
        var size = size(active)
        if size > 0, now.timeIntervalSince(started(active) ?? now) >= limits.rotateAfter {
            rotate()
            size = 0
        }
        var written = 0
        var pending = Data()
        var count = 0
        for line in lines {
            let bytes = line.count + 1
            guard bytes <= limits.maxFileBytes else {
                lost += 1
                continue
            }
            if size + pending.count + bytes > limits.maxFileBytes {
                written += flush(pending, lines: count)
                pending.removeAll(keepingCapacity: true)
                count = 0
                rotate()
                size = 0
            }
            pending.append(line)
            pending.append(0x0A)
            count += 1
        }
        return written + flush(pending, lines: count)
    }

    /// Delete what is past its age, and any file past the generations kept.
    func prune(now: Date) {
        let names = (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name == Self.activeName {
                if expired(url, now: now) { try? files.removeItem(at: url) }
            } else if let generation = Self.generation(ofFileNamed: name) {
                if generation > limits.generations || expired(url, now: now) {
                    try? files.removeItem(at: url)
                }
            }
        }
    }

    /// `phone.<n>.jsonl` gives n. No other file in the directory is the log's.
    static func generation(ofFileNamed name: String) -> Int? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "phone", parts[2] == "jsonl",
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(parts[1]), n >= 1
        else { return nil }
        return n
    }

    static func appendBytes(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            // The lines name threads and paths on this Mac: the owner's alone.
            guard FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        do { try handle.write(contentsOf: data) } catch {
            // No half line stays behind, and the file is no longer than it was.
            try? handle.truncate(atOffset: end)
            throw error
        }
    }

    /// Whether `error` says the disk (or the quota) is full.
    static func isFull(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain { return [ENOSPC, EDQUOT].contains(Int32(error.code)) }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isFull) ?? false
    }

    private func flush(_ data: Data, lines: Int) -> Int {
        guard lines > 0 else { return 0 }
        while true {
            do {
                try write(data, active)
                return lines
            } catch {
                // A full disk gives up old lines for new ones: the oldest
                // file goes, then the active one. Any other failure keeps
                // what is there and drops what came.
                guard Self.isFull(error), freeOldest() else {
                    lost += lines
                    return 0
                }
            }
        }
    }

    /// Delete the oldest file of the log. False when there is none left.
    private func freeOldest() -> Bool {
        guard let oldest = all.first, size(oldest) > 0 else { return false }
        return (try? files.removeItem(at: oldest)) != nil
    }

    private func rotate() {
        guard limits.generations > 0 else {
            try? files.removeItem(at: active)
            return
        }
        try? files.removeItem(at: rotated(limits.generations))
        for generation in stride(from: limits.generations - 1, through: 1, by: -1)
        where files.fileExists(atPath: rotated(generation).path) {
            try? files.moveItem(at: rotated(generation), to: rotated(generation + 1))
        }
        // A file that will not move is deleted: the log never grows past its
        // limit because a rename failed.
        if (try? files.moveItem(at: active, to: rotated(1))) == nil {
            try? files.removeItem(at: active)
        }
    }

    private func size(_ url: URL) -> Int {
        ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func started(_ url: URL) -> Date? {
        let attributes = try? files.attributesOfItem(atPath: url.path)
        return attributes?[.creationDate] as? Date ?? attributes?[.modificationDate] as? Date
    }

    private func expired(_ url: URL, now: Date) -> Bool {
        guard let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) > limits.maxAge
    }
}

// MARK: - The sink

/// The log as the server uses it. A batch is cleaned and written on the
/// log's own queue, so a slow or full disk never holds a request or the app.
final class MobileLogSink {
    /// Batches that may wait for the disk. One more is dropped.
    static let maxQueued = 32
    /// Phone sessions remembered as already told they run an old build.
    private static let maxFlagged = 32

    private let file: MobileLogFile
    private let served: String?
    private let now: () -> Date
    private let queue = DispatchQueue(label: "muxmaestro.phone-log", qos: .utility)
    private let lock = NSLock()
    private var queued = 0
    private var budget = MobileLogBudget()
    private var flagged: [String] = []

    init(
        directory: URL, served: String?, limits: MobileLogFile.Limits = MobileLogFile.Limits(),
        now: @escaping () -> Date = Date.init
    ) {
        file = MobileLogFile(directory: directory, limits: limits)
        self.served = served
        self.now = now
    }

    /// One `/api/log` body. Returns at once.
    func receive(_ body: Data) {
        enqueue { [self] in
            let now = now()
            let batch = MobileLog.batch(body, served: served, now: now)
            var lines = batch.lines
            let granted = budget.take(lines.count, now: now)
            if granted < lines.count {
                let refused = lines.count - granted
                lines = Array(lines.prefix(granted))
                if budget.shouldTell(), let note = MobileLog.line(
                    at: now, sev: "warn", kind: "dropped", build: batch.build, served: served,
                    sid: batch.sid,
                    msg: "over \(budget.perMinute) lines a minute: the rest of this minute is dropped",
                    fields: ["n": refused]) {
                    lines.append(note)
                }
            }
            if let stale = stale(batch, now: now) { lines.insert(stale, at: 0) }
            if !lines.isEmpty { file.append(lines, now: now) }
        }
    }

    /// The server began to listen: which bundle it serves, and how old the
    /// app's own binary is. "Is the new build the one that runs" is then a
    /// line in the log, not a question for the human.
    func started(port: Int, binary: URL? = Bundle.main.executableURL) {
        enqueue { [self] in
            let now = now()
            var fields: [String: Any] = ["port": port]
            if let binary,
               let built = (try? FileManager.default.attributesOfItem(atPath: binary.path))?[
                   .modificationDate] as? Date {
                fields["app"] = MobileLog.stamp(built)
            }
            if let line = MobileLog.line(
                at: now, sev: "info", kind: "mac", build: served ?? "", served: served,
                msg: "phone server started", fields: fields) {
                file.append([line], now: now)
            }
        }
    }

    /// Wait for what was handed in to be written. For tests.
    func drain() { queue.sync {} }

    /// The line that says a phone runs a build this Mac no longer serves:
    /// once per phone session, so it is found without reading every line.
    private func stale(_ batch: MobileLog.Batch, now: Date) -> Data? {
        guard let served, !batch.build.isEmpty, batch.build != served, !batch.lines.isEmpty,
              !flagged.contains(batch.sid)
        else { return nil }
        flagged.append(batch.sid)
        if flagged.count > Self.maxFlagged { flagged.removeFirst() }
        return MobileLog.line(
            at: now, sev: "warn", kind: "stale", build: batch.build, served: served, sid: batch.sid,
            msg: "the phone runs build \(batch.build); this Mac serves \(served)")
    }

    private func enqueue(_ work: @escaping () -> Void) {
        lock.lock()
        let room = queued < Self.maxQueued
        if room { queued += 1 }
        lock.unlock()
        guard room else { return }
        queue.async { [self] in
            work()
            lock.lock()
            queued -= 1
            lock.unlock()
        }
    }
}
