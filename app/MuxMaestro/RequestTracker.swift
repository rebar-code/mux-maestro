import Foundation

/// What a request in the list can be. The raw values are the file's own words.
enum RequestState: String, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case blocked
    case review
    case done
}

enum RequestTrackerError: Error, Equatable {
    /// The file is not the list: not JSON, or not this schema. It is left as
    /// it is; nothing is ever written over a file that did not read.
    case corrupt(String)
    /// The file system refused a read or a write.
    case io(String)
    case unknownRequest
    /// The file changed under every attempt to write it.
    case busy
}

/// The list of what the human asked for: `requests.json` in the manager's
/// home. The manager agent keeps the file; the app reads it and changes the
/// state of one request.
///
/// Two writers share the file, so the app's write is built to lose nothing:
/// - It changes two values in the text (the request's `state` and the list's
///   `updated`) and leaves every other byte as the agent wrote it.
/// - The new text goes to a temporary file that is then renamed over the
///   list, so a reader sees the old list or the new one, never a part of one.
/// - If the file changed between the read and the rename, the change is made
///   again on the new text.
/// - A file that does not read is an error. It is never replaced.
struct RequestTracker {
    static let fileName = "requests.json"
    /// The one schema this build reads and writes.
    static let schema = 1
    /// What a list that does not exist yet reads as.
    static let empty = Data(#"{"schema":1,"requests":[]}"#.utf8)

    let url: URL
    var now: () -> Date = Date.init
    /// A file that does not parse is read again this many times, this far
    /// apart: a writer that does not rename leaves it in halves for a moment.
    var readAttempts = 3
    var readPause: TimeInterval = 0.04
    /// How often a write starts again because the file changed under it.
    var writeAttempts = 5
    /// Runs when the new text is ready and before it replaces the file. Tests
    /// write the file here, as the agent could.
    var beforeCommit: (() -> Void)?

    /// One writer at a time in this process: two phones can tick at once.
    private static let lock = NSLock()

    /// The list as it is on disk, once it has been checked.
    func read() -> Result<Data, RequestTrackerError> {
        load().map { $0 ?? Self.empty }
    }

    /// Set one request's state. Answers the list as it is afterwards.
    func setState(_ state: RequestState, of id: String) -> Result<Data, RequestTrackerError> {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // A link is followed, so the rename replaces the file and not the link.
        let file = url.resolvingSymlinksInPath()
        for _ in 0..<max(1, writeAttempts) {
            let before: Data
            switch load() {
            case .failure(let error): return .failure(error)
            case .success(nil): return .failure(.unknownRequest)
            case .success(let data?): before = data
            }
            let after: Data
            switch Self.edit(before, id: id, state: state, stamp: Self.stamp(now())) {
            case .failure(let error): return .failure(error)
            case .success(let data): after = data
            }
            if after == before { return .success(before) }

            let temporary = file.deletingLastPathComponent()
                .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
            if let failure = Self.writeSynced(after, to: temporary, like: file) {
                try? FileManager.default.removeItem(at: temporary)
                return .failure(.io(failure))
            }
            beforeCommit?()
            // The agent wrote meanwhile: its text is the list now. Start again.
            guard (try? Data(contentsOf: file)) == before else {
                try? FileManager.default.removeItem(at: temporary)
                continue
            }
            guard rename(temporary.path, file.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: temporary)
                return .failure(.io(reason))
            }
            return .success(after)
        }
        return .failure(.busy)
    }

    /// The file's bytes once they pass `fault`; nil when there is no file.
    private func load() -> Result<Data?, RequestTrackerError> {
        var failure = RequestTrackerError.corrupt("\(Self.fileName) is not valid JSON")
        for attempt in 0..<max(1, readAttempts) {
            if attempt > 0 { Thread.sleep(forTimeInterval: readPause) }
            guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                failure = .io(error.localizedDescription)
                continue
            }
            guard let fault = Self.fault(in: data) else { return .success(data) }
            failure = .corrupt(fault)
        }
        return .failure(failure)
    }

    // MARK: The text

    /// What is wrong with `data` as a list; nil when it is one.
    static func fault(in data: Data) -> String? {
        guard let list = object(data) else { return "\(fileName) is not valid JSON" }
        guard let version = list["schema"] as? Int else { return "\(fileName) names no schema" }
        guard version == schema else {
            return "\(fileName) has schema \(version); this build reads schema \(schema)"
        }
        guard let requests = list["requests"] as? [[String: Any]] else {
            return "\(fileName) has no list of requests"
        }
        let whole = requests.allSatisfy {
            $0["id"] is String && $0["title"] is String && $0["state"] is String
        }
        return whole ? nil : "\(fileName) has a request without an id, a title or a state"
    }

    /// `text` with the state of request `id` set, and `updated` set to `stamp`
    /// where the list has one. Only those two values change. A request that is
    /// in that state already leaves the text as it is.
    static func edit(
        _ text: Data, id: String, state: RequestState, stamp: String
    ) -> Result<Data, RequestTrackerError> {
        let spans = JSONSpans(text)
        guard let root = spans.root(), let top = spans.members(of: root),
              let list = top.first(where: { $0.key == "requests" }),
              let rows = spans.elements(of: list.value)
        else { return .failure(.corrupt("\(fileName) is not valid JSON")) }

        var found: [Range<Int>] = []
        for row in rows {
            guard let members = spans.members(of: row) else {
                return .failure(.corrupt("\(fileName) has a request that is not an object"))
            }
            guard let name = members.first(where: { $0.key == "id" }),
                  spans.string(name.value) == id
            else { continue }
            guard let value = members.first(where: { $0.key == "state" }) else {
                return .failure(.corrupt("\(fileName) has a request without a state"))
            }
            found.append(value.value)
        }
        guard let target = found.first else { return .failure(.unknownRequest) }
        guard found.count == 1 else {
            return .failure(.corrupt("\(fileName) has \(found.count) requests with the id \(id)"))
        }
        if spans.string(target) == state.rawValue { return .success(text) }

        var changes = [(range: target, value: "\"\(state.rawValue)\"")]
        let updated = top.first { $0.key == "updated" }.map(\.value)
        let stamped = updated.flatMap(spans.string) != nil
        if let updated, stamped { changes.append((updated, "\"\(stamp)\"")) }

        var bytes = [UInt8](text)
        for change in changes.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(change.range, with: Array(change.value.utf8))
        }
        let edited = Data(bytes)

        // The proof: read both texts as JSON. They must differ by those two
        // values and nothing else, or the new text is not used.
        guard var expected = object(text), let got = object(edited),
              var requests = expected["requests"] as? [[String: Any]],
              let index = requests.firstIndex(where: { $0["id"] as? String == id })
        else { return .failure(.corrupt("\(fileName) is not valid JSON")) }
        requests[index]["state"] = state.rawValue
        expected["requests"] = requests
        if stamped { expected["updated"] = stamp }
        guard NSDictionary(dictionary: expected).isEqual(to: got) else {
            return .failure(.corrupt("\(fileName) could not be changed safely"))
        }
        return .success(edited)
    }

    /// The time as the file writes it: `2026-10-04T16:20:00Z`.
    static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Write `data` to a new file at `url`, with the mode of `model`, and wait
    /// until it is on disk. Answers what failed, or nil.
    private static func writeSynced(_ data: Data, to url: URL, like model: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: model.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        guard descriptor >= 0 else { return String(cString: strerror(errno)) }
        defer { close(descriptor) }
        let failed: Bool = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { return true }
                offset += sent
            }
            return false
        }
        guard !failed, fsync(descriptor) == 0 else { return String(cString: strerror(errno)) }
        return nil
    }
}

/// Where the values of a JSON text are, as byte ranges. It is used on a text
/// that already parsed; it reads no value and only finds where each one ends.
/// Text that is not JSON gives nil, never a range outside the text.
struct JSONSpans {
    private let bytes: [UInt8]

    init(_ text: Data) { bytes = [UInt8](text) }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
    private static let ends: Set<UInt8> = space.union([0x2C, 0x5D, 0x7D])

    /// The text's one value.
    func root() -> Range<Int>? {
        // A byte order mark is not part of the value.
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        skipSpace(&index)
        return value(at: &index)
    }

    /// The members of the object at `range`, in the order they are written.
    func members(of range: Range<Int>) -> [(key: String, value: Range<Int>)]? {
        guard bytes.indices.contains(range.lowerBound), bytes[range.lowerBound] == 0x7B else { return nil }
        var index = range.lowerBound + 1
        var found: [(key: String, value: Range<Int>)] = []
        while true {
            skipSpace(&index)
            guard index < range.upperBound else { return nil }
            if bytes[index] == 0x7D { return found }
            guard bytes[index] == Self.quote, let key = value(at: &index), let name = string(key)
            else { return nil }
            skipSpace(&index)
            guard index < range.upperBound, bytes[index] == 0x3A else { return nil }
            index += 1
            skipSpace(&index)
            guard let value = value(at: &index) else { return nil }
            found.append((name, value))
            skipSpace(&index)
            if index < range.upperBound, bytes[index] == 0x2C { index += 1 }
        }
    }

    /// The elements of the array at `range`.
    func elements(of range: Range<Int>) -> [Range<Int>]? {
        guard bytes.indices.contains(range.lowerBound), bytes[range.lowerBound] == 0x5B else { return nil }
        var index = range.lowerBound + 1
        var found: [Range<Int>] = []
        while true {
            skipSpace(&index)
            guard index < range.upperBound else { return nil }
            if bytes[index] == 0x5D { return found }
            guard let value = value(at: &index) else { return nil }
            found.append(value)
            skipSpace(&index)
            if index < range.upperBound, bytes[index] == 0x2C { index += 1 }
        }
    }

    /// The string at `range`, with its escapes read; nil for any other value.
    func string(_ range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty,
              bytes[range.lowerBound] == Self.quote
        else { return nil }
        return (try? JSONSerialization.jsonObject(
            with: Data(bytes[range]), options: .fragmentsAllowed)) as? String
    }

    private func skipSpace(_ index: inout Int) {
        while index < bytes.count, Self.space.contains(bytes[index]) { index += 1 }
    }

    /// The value that starts at `index`. Leaves `index` after it.
    private func value(at index: inout Int) -> Range<Int>? {
        guard index < bytes.count else { return nil }
        let start = index
        switch bytes[index] {
        case Self.quote:
            index += 1
            while index < bytes.count {
                if bytes[index] == Self.backslash {
                    index += 2
                } else if bytes[index] == Self.quote {
                    index += 1
                    return start..<index
                } else {
                    index += 1
                }
            }
            return nil
        case 0x7B, 0x5B:
            var depth = 0
            while index < bytes.count {
                switch bytes[index] {
                case Self.quote:
                    // A bracket inside a string closes nothing.
                    guard value(at: &index) != nil else { return nil }
                    continue
                case 0x7B, 0x5B:
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return start..<index
                    }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            while index < bytes.count, !Self.ends.contains(bytes[index]) { index += 1 }
            return index > start ? start..<index : nil
        }
    }
}

/// The request list on the phone API: `/api/requests`.
enum MobileRequests {
    /// The `{"id": ..., "state": ...}` body of a state change. The state must
    /// be one the list knows.
    static func change(in body: Data) -> (id: String, state: RequestState)? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty,
              let state = (object["state"] as? String).flatMap(RequestState.init(rawValue:))
        else { return nil }
        return (id, state)
    }

    /// The list, or why there is none to show. A list that does not read is an
    /// error the phone shows; it is never sent as an empty list.
    static func response(_ result: Result<Data, RequestTrackerError>) -> MobileResponse {
        switch result {
        case .success(let list): return .json(data: list)
        case .failure(.corrupt(let message)): return .error(500, "corrupt", message: message)
        case .failure(.io(let message)): return .error(500, "unreadable", message: message)
        case .failure(.unknownRequest): return .error(404, "not_found")
        case .failure(.busy):
            return .error(409, "busy", message: "The list is being written. Try again.")
        }
    }
}
