import Foundation

// The manager half of the phone API: the JSON shapes of the manager home and
// of one manager turn. Pure, like MobileAPI.swift. It adds no manager logic:
// the rows come from `ManagerStore`, and a turn runs through
// `ManagerController.send`, the same path the Mac rail uses.

/// What the manager pane is doing, as the phone shows it.
enum MobileManagerStatus: String, Equatable {
    /// The manager is not running on the Mac.
    case off
    case idle, busy, waiting

    init(_ status: ManagerTurnStatus?) {
        switch status {
        case .busy: self = .busy
        case .waiting: self = .waiting
        case .idle, nil: self = .idle
        }
    }
}

/// One card on the manager home: an agent blocked on the human, or a review
/// item the manager raised.
struct MobileManagerItem: Equatable {
    enum Kind: String { case agent, review }

    let kind: Kind
    /// What `dismiss` takes. Only a review item has one.
    var key: String? = nil
    let title: String
    let detail: String
    var severity: ManagerReviewItem.Severity? = nil
    /// When the agent started waiting, or the review item last changed.
    let at: Int
    let link: ThreadLink?

    func json(in snapshot: MobileSnapshot) -> [String: Any] {
        [
            "key": key ?? NSNull(), "title": title, "detail": detail,
            "severity": severity?.rawValue ?? NSNull(), "at": at,
            "thread": MobileManager.threadID(for: link, in: snapshot) ?? NSNull(),
        ]
    }
}

/// The rows of the Mac rail, as the phone lists them.
struct MobileManagerBoard: Equatable {
    var items: [MobileManagerItem] = []
    var updates: [ManagerUpdate] = []
}

/// The turn in flight: one conversation, whichever side started it.
struct MobileManagerTurn: Equatable {
    var prompt: String
    var reply = ""

    var json: [String: Any] { ["prompt": prompt, "reply": reply] }
}

enum MobileManager {
    /// How many chat rows the home gets. It shows the last few lines only.
    static let chatLimit = 20

    static let busyMessage = "A turn is running"
    static let waitingMessage = "Manager is waiting on a prompt"
    static let offMessage = "Manager is not running"

    /// The phone thread a rail link points at, or nil when no listed thread
    /// matches. The phone opens threads by id, never by a tmux address.
    static func threadID(for link: ThreadLink?, in snapshot: MobileSnapshot) -> String? {
        switch link {
        case nil:
            return nil
        case .thread(let id):
            return snapshot.threads.first { $0.claudeSessionId == id || $0.codexSessionId == id }?.id
        case .open(let session, let window, let pane, let host):
            let rows = snapshot.threads.filter {
                $0.host.name == host && $0.session == session && (window == nil || $0.window == window)
            }
            return (rows.first { $0.pane == pane } ?? rows.first)?.id
        }
    }

    /// The part of the manager home that changes without a request: the cards
    /// and the turn in flight. Also the `manager` event's data.
    static func live(
        board: MobileManagerBoard, snapshot: MobileSnapshot, turn: MobileManagerTurn?
    ) -> [String: Any] {
        let updates: [[String: Any]] = board.updates.map { update in
            let link: ThreadLink? = !update.sessionId.isEmpty
                ? .thread(id: update.sessionId)
                : update.session.isEmpty ? nil : .open(
                    session: update.session, window: update.window, pane: nil,
                    host: update.host.isEmpty ? Host.local.name : update.host)
            return [
                "kind": update.kind.rawValue, "text": update.text, "at": update.at,
                "host": update.host, "session": update.session,
                "thread": threadID(for: link, in: snapshot) ?? NSNull(),
            ]
        }
        return [
            "needsYou": board.items.filter { $0.kind == .agent }.map { $0.json(in: snapshot) },
            "review": board.items.filter { $0.kind == .review }.map { $0.json(in: snapshot) },
            "updates": updates,
            "turn": turn?.json ?? NSNull(),
        ]
    }

    static func liveJSON(
        board: MobileManagerBoard, snapshot: MobileSnapshot, turn: MobileManagerTurn?
    ) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: live(board: board, snapshot: snapshot, turn: turn),
            options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The `GET /api/manager` body: `live` plus the pane's status and the chat
    /// so far, read from the manager pane's own transcript.
    static func body(
        board: MobileManagerBoard, snapshot: MobileSnapshot, turn: MobileManagerTurn?,
        status: MobileManagerStatus, chat: MobileChatPage
    ) -> [String: Any] {
        var out = live(board: board, snapshot: snapshot, turn: turn)
        // A turn in flight is busy, whatever the pane's hooks last wrote.
        out["status"] = (turn != nil && status != .off ? .busy : status).rawValue
        var page = chat
        page.messages = Array(chat.messages.filter { $0.role != .tool }.suffix(chatLimit))
        out["chat"] = page.json
        return out
    }

    /// The `text` of a turn request, or nil when the body is not `{"text": "…"}`
    /// with something in it.
    static func text(in body: Data) -> String? {
        string("text", in: body)
    }

    /// The `key` of a dismiss request.
    static func key(in body: Data) -> String? {
        string("key", in: body)
    }

    private static func string(_ name: String, in body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let value = (object[name] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    /// Why a turn cannot start now, as the response the phone shows; nil when
    /// it can. `ManagerPaneDriver` refuses for the same reasons; asking here
    /// first means the phone gets an error and not a stream that ends at once.
    static func refusal(status: MobileManagerStatus, turnRunning: Bool) -> MobileResponse? {
        if status == .off { return .error(503, "unavailable", message: offMessage) }
        if turnRunning { return .error(409, "busy", message: busyMessage) }
        if status == .waiting { return .error(409, "waiting", message: waitingMessage) }
        return nil
    }

    /// The last event of a turn's stream. `message` is set when there is
    /// something the human must know: the same notes the Mac rail shows.
    static func end(_ outcome: ManagerTurnOutcome) -> [String: Any] {
        switch outcome {
        case .done(let reply):
            return ["outcome": "done", "reply": reply, "message": NSNull()]
        case .permission(let reply):
            return ["outcome": "permission", "reply": reply, "message": "Waiting at the keyboard"]
        case .timeout(let reply):
            return ["outcome": "timeout", "reply": reply, "message": "Still working"]
        case .unreachable(let message):
            return ["outcome": "unreachable", "reply": "", "message": message]
        case .refused(let message):
            return ["outcome": "refused", "reply": "", "message": message]
        }
    }
}
