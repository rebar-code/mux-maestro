import Foundation

/// One entry of a request's history.
struct RequestHistoryEntry: Equatable {
    var at: String
    var by: String
    var note: String
    /// The human's exact words, when the agent had them.
    var verbatim: String

    /// The agent wrote it; any other name is the human.
    var isAgent: Bool { by == RequestTracker.agent }
}

/// One thing the human asked an agent for, as the rail draws it.
struct TrackedRequest: Equatable {
    var id: String
    var title: String
    /// The tmux session the request belongs to.
    var project: String
    /// When it was asked: an ISO date, or free text that may hold some.
    var asked: String
    /// The file's own word. One this build does not know is an open request.
    var state: String
    /// How the request got to its state, oldest first. Empty in a schema 1 list.
    var history: [RequestHistoryEntry]

    var isDone: Bool { state == RequestState.done.rawValue }
}

struct RequestGroup: Equatable {
    var project: String
    var requests: [TrackedRequest]
}

/// The request list's rules: what is read from the file, and how the rows are
/// ordered and grouped. They are the phone's rules (`mobile/src/lib/requests.ts`),
/// so the Mac's list and the phone's are the same list.
enum RequestList {
    /// The heading of the rows that name no project.
    static let noProject = "Other"

    /// The requests in a list that `RequestTracker` read; nil when it is not one.
    static func parse(_ data: Data) -> [TrackedRequest]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = list["requests"] as? [[String: Any]]
        else { return nil }
        var requests: [TrackedRequest] = []
        for row in rows {
            guard let id = row["id"] as? String, let title = row["title"] as? String,
                  let state = row["state"] as? String
            else { return nil }
            let history = (row["history"] as? [[String: Any]] ?? []).map {
                RequestHistoryEntry(
                    at: $0["at"] as? String ?? "", by: $0["by"] as? String ?? "",
                    note: $0["note"] as? String ?? "", verbatim: $0["verbatim"] as? String ?? "")
            }
            requests.append(TrackedRequest(
                id: id, title: title, project: row["project"] as? String ?? "",
                asked: row["asked"] as? String ?? "", state: state, history: history))
        }
        return requests
    }

    /// What a row sorts by: the last `YYYY-MM-DD` in `asked`, which may be free
    /// text such as "earlier, restated 2026-10-04". Empty when it holds none.
    static func askedKey(_ asked: String) -> String {
        var key = ""
        var index = asked.startIndex
        while let range = asked.range(
            of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression, range: index..<asked.endIndex)
        {
            key = String(asked[range])
            index = range.upperBound
        }
        return key
    }

    /// The done rows, or the open ones, newest first by the day asked; rows with
    /// no date go last. Rows of one day keep the file's order. Each project is
    /// one group, in the order of its newest row.
    static func groups(_ requests: [TrackedRequest], done: Bool) -> [RequestGroup] {
        let rows = requests.filter { $0.isDone == done }
            .enumerated()
            .map { (offset: $0.offset, key: askedKey($0.element.asked), request: $0.element) }
            .sorted { $0.key != $1.key ? $0.key > $1.key : $0.offset < $1.offset }
        var groups: [RequestGroup] = []
        for row in rows {
            let project = row.request.project.isEmpty ? noProject : row.request.project
            if let index = groups.firstIndex(where: { $0.project == project }) {
                groups[index].requests.append(row.request)
            } else {
                groups.append(RequestGroup(project: project, requests: [row.request]))
            }
        }
        return groups
    }

    static func counts(_ requests: [TrackedRequest]) -> (open: Int, done: Int) {
        let done = requests.filter(\.isDone).count
        return (requests.count - done, done)
    }

    /// The chip a row shows. Empty for todo and done: the checkbox says those.
    static func stateLabel(_ state: String) -> String {
        switch state {
        case RequestState.todo.rawValue, RequestState.done.rawValue: return ""
        case RequestState.inProgress.rawValue: return "in progress"
        default: return state
        }
    }
}

/// What the rail's request list shows and what a tick does to it. The view
/// draws `content` and hands every read and write of the file back here.
struct RequestListModel {
    /// What the list area draws.
    enum Content: Equatable {
        /// Nothing was read yet.
        case loading
        /// The list did not read; the text says why and may be empty.
        case failed(String)
        /// The filter holds no rows; the text is the label.
        case empty(String)
        case groups([RequestGroup])
    }

    /// The heading of a list that did not read: the phone's words.
    static let unreadable = "Can't read the request list"

    /// nil: nothing to show, either yet or after a failed read.
    private(set) var requests: [TrackedRequest]?
    /// Set when the list could not be read.
    private var error: String?
    /// Why the last tick was not saved.
    private(set) var note = ""
    /// The id of the row being written.
    private(set) var busy: String?
    /// Show the done rows instead of the open ones.
    var done = false
    /// The ids of the rows whose history is open. Kept across reads and ticks.
    private(set) var expanded: Set<String> = []
    /// Counts the writes, so a read that started before one does not undo it.
    private(set) var writes = 0
    /// The tick being written: the row and the states it moves between.
    private var pending: (id: String, before: String, after: String)?

    var content: Content {
        if let error { return .failed(error) }
        guard let requests else { return .loading }
        let groups = RequestList.groups(requests, done: done)
        return groups.isEmpty ? .empty(done ? "Nothing done" : "Nothing open") : .groups(groups)
    }

    /// A filter's name and its count. No count while there is no list: never a
    /// wrong 0.
    func filterTitle(done: Bool) -> String {
        let name = done ? "Done" : "Open"
        guard let requests else { return name }
        let counts = RequestList.counts(requests)
        return "\(name) \(done ? counts.done : counts.open)"
    }

    /// Open or close one row's history.
    mutating func toggleHistory(_ id: String) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    /// The Retry button: nothing is shown until the answer.
    mutating func retry() {
        error = nil
    }

    mutating func clearNote() {
        note = ""
    }

    /// A read of the file came back. `writes` is the count when the read
    /// started. Answers whether what is drawn changed.
    @discardableResult
    mutating func loaded(_ result: Result<Data, RequestTrackerError>, writes: Int) -> Bool {
        guard writes == self.writes, busy == nil else { return false }
        let before = content
        switch result.map(RequestList.parse) {
        case .success(let list?):
            error = nil
            requests = list
        case .success(nil):
            requests = nil
            error = ""
        case .failure(let failure):
            // Rows that may be stale are not shown as if they were current.
            requests = nil
            error = Self.reason(failure)
        }
        return content != before
    }

    /// Tick an open row done, or a done row back to todo. One write at a time.
    /// The tick shows at once; answers the state to write, or nil for no write.
    mutating func tick(_ id: String) -> RequestState? {
        guard busy == nil, let index = requests?.firstIndex(where: { $0.id == id }),
              let before = requests?[index].state
        else { return nil }
        let after = before == RequestState.done.rawValue ? RequestState.todo : .done
        note = ""
        busy = id
        writes += 1
        pending = (id, before, after.rawValue)
        requests?[index].state = after.rawValue
        return after
    }

    /// The write came back. The file's answer replaces the tick; a failed write
    /// puts the row back and says why. The caller then reads the file again.
    mutating func ticked(_ result: Result<Data, RequestTrackerError>) {
        defer {
            busy = nil
            pending = nil
        }
        switch result.map(RequestList.parse) {
        case .success(let list?):
            error = nil
            requests = list
        case .success(nil):
            requests = nil
            error = ""
        case .failure(let failure):
            if let pending, let index = requests?.firstIndex(where: { $0.id == pending.id }),
               requests?[index].state == pending.after {
                requests?[index].state = pending.before
            }
            note = Self.reason(failure)
        }
    }

    /// Why a read or a write failed, as the phone's API words it.
    static func reason(_ error: RequestTrackerError) -> String {
        switch error {
        case .corrupt(let message), .io(let message): return message
        case .busy: return MobileRequests.busyMessage
        case .unknownRequest: return "Not saved"
        }
    }
}

/// Calls `onChange` on `queue` when a directory changes. Both writers of the
/// request list replace it by rename, and a rename is a change to the directory
/// and not to the file that was open.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    /// nil when the directory cannot be opened: it does not exist yet.
    init?(url: URL, queue: DispatchQueue, onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
