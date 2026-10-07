import Foundation

// The manager half of the phone API: the JSON shapes of the manager home and
// of one manager turn. Pure, like MobileAPI.swift. It adds no manager logic:
// the rows come from `ManagerStore`, and a turn runs through
// `ManagerController.send`, the same path the Mac rail uses.

/// What the manager pane is doing, as the phone shows it.
enum MobileManagerStatus: String, Equatable {
    /// The manager is not running on the Mac.
    case off
    /// It runs, but what its pane is doing is not known yet. Not idle: the
    /// pane may be on a prompt.
    case unknown
    case idle, busy, waiting

    init(_ status: ManagerTurnStatus?) {
        switch status {
        case .busy: self = .busy
        case .waiting: self = .waiting
        case .idle: self = .idle
        case nil: self = .unknown
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
    /// A review item `mux point` wrote: it points the human at a session.
    var pointer = false
    /// The pointer's buttons, when the Maestro gave it any.
    var card: MobileCard? = nil

    func json(in snapshot: MobileSnapshot) -> [String: Any] {
        let thread = MobileManager.threadID(for: link, in: snapshot)
        var out: [String: Any] = [
            "key": key ?? NSNull(), "title": title, "detail": detail,
            "severity": severity?.rawValue ?? NSNull(), "at": at,
            "thread": thread ?? NSNull(),
        ]
        // Left out of a row with no buttons: its shape is what it always was.
        if let key, let card {
            out["card"] = MobileCards.json(key: key, card: card, in: snapshot, opens: thread)
        }
        return out
    }

    /// The same shape for a pointer. The CLI checks a pointer's text, but an
    /// agent drives the CLI and the DB is a file, so the text is cut to one
    /// short line again here.
    func pointJSON(in snapshot: MobileSnapshot) -> [String: Any] {
        var out = json(in: snapshot)
        out["title"] = MobileManager.pointerLine(title)
        out["detail"] = MobileManager.pointerLine(detail)
        return out
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
    /// The pane's own spinner line while it works ("Incubating… 4m 48s"); nil
    /// when none could be read.
    var spinner: String? = nil

    var json: [String: Any] {
        ["prompt": prompt, "reply": reply, "spinner": spinner ?? NSNull()]
    }
}

/// The line an agent's pane shows while it works: a verb and the time so far.
enum MobileSpinner {
    /// The glyphs Claude Code animates at the start of that line.
    static let glyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "*", "+", "✺", "✹", "✸"]
    /// How far up from the end of the pane the line is looked for.
    static let tail = 15

    /// The spinner line in a pane capture as "Verb… 4m 48s" (the time is left
    /// out when the pane shows none), or nil when the pane shows no spinner.
    static func line(in capture: String) -> String? {
        let lines = strip(capture).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines.suffix(tail).reversed() {
            guard let glyph = line.first, glyphs.contains(glyph),
                  let ellipsis = line.firstIndex(of: "…") else { continue }
            let verb = line[line.index(after: line.startIndex)...ellipsis]
                .trimmingCharacters(in: .whitespaces)
            guard verb.count > 1, verb.count <= 60 else { continue }
            let rest = line[line.index(after: ellipsis)...]
            return [verb, elapsed(in: String(rest))].compactMap { $0 }.joined(separator: " ")
        }
        return nil
    }

    /// The time in the line's brackets: "(4m 48s · ↓ 2.1k tokens · esc to
    /// interrupt)" gives "4m 48s".
    static func elapsed(in text: String) -> String? {
        guard let open = text.firstIndex(of: "(") else { return nil }
        let inside = text[text.index(after: open)...].prefix { $0 != ")" }
        return inside.components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { part in
                let words = part.split(separator: " ")
                return !words.isEmpty && words.count <= 3 && words.allSatisfy { word in
                    guard let unit = word.last, "hms".contains(unit) else { return false }
                    return !word.dropLast().isEmpty && word.dropLast().allSatisfy(\.isNumber)
                }
            }
    }

    /// The text without its colour and cursor escapes.
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

enum MobileManager {
    static let busyMessage = "A turn is running"
    static let paneBusyMessage = ManagerPaneDriver.busyMessage
    static let waitingMessage = ManagerPaneDriver.waitingMessage
    static let notReadyMessage = ManagerPaneDriver.notReadyMessage
    static let offMessage = "Maestro is not running"

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
            if let named = rows.first(where: { $0.pane == pane }) { return named.id }
            // No window named: a session of several windows is pointed at for
            // the one that waits, else for the one that works.
            let urgent = window != nil ? nil
                : rows.first { $0.status == .waiting } ?? rows.first { $0.status == .busy }
            return (urgent ?? rows.first)?.id
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
            "review": board.items.filter { $0.kind == .review && !$0.pointer }
                .map { $0.json(in: snapshot) },
            "points": newest(board.items.filter { $0.kind == .review && $0.pointer })
                .map { $0.pointJSON(in: snapshot) },
            "updates": updates,
            "turn": turn?.json ?? NSNull(),
        ]
    }

    /// The most pointers the phone is sent. The CLI keeps the same number.
    static let maxPointers = ManagerReviewItem.maxPointers

    /// The `maxPointers` newest of `pointers`, in the order they came. The CLI
    /// keeps no more than that, but the DB is a file anyone can write.
    static func newest(_ pointers: [MobileManagerItem]) -> [MobileManagerItem] {
        guard pointers.count > maxPointers else { return pointers }
        let kept = Set(pointers.indices
            .sorted { (pointers[$0].at, $1) > (pointers[$1].at, $0) }
            .prefix(maxPointers))
        return pointers.indices.filter(kept.contains).map { pointers[$0] }
    }

    /// The longest title or reason of a pointer, in characters.
    static let maxPointerCharacters = 120

    /// A pointer's text as one short line: a line break or a tab becomes a
    /// space, any other control character is dropped, and a long text is cut
    /// with an ellipsis. Zero-width and text-direction characters are dropped
    /// too: they can hide or reorder what the human reads.
    static func pointerLine(_ text: String, limit: Int = maxPointerCharacters) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0x2028, 0x2029: scalars.append(" ")
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069: continue
            default: if isText(scalar) { scalars.append(scalar) }
            }
        }
        let line = String(scalars).trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }

    /// Whether a board holds a review item with `key`: what dismiss may name.
    /// A pointer is a review item, so dismiss clears it too.
    static func hasReview(_ key: String, in board: MobileManagerBoard) -> Bool {
        board.items.contains { $0.kind == .review && $0.key == key }
    }

    static func liveJSON(
        board: MobileManagerBoard, snapshot: MobileSnapshot, turn: MobileManagerTurn?
    ) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: live(board: board, snapshot: snapshot, turn: turn),
            options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The `GET /api/manager` body: `live` plus the pane's status. The chat is
    /// its own route, `/api/manager/chat`, read the way a thread's chat is.
    static func body(
        board: MobileManagerBoard, snapshot: MobileSnapshot, turn: MobileManagerTurn?,
        status: MobileManagerStatus, dozing: Bool = false
    ) -> [String: Any] {
        var out = live(board: board, snapshot: snapshot, turn: turn)
        // A turn in flight is busy, whatever the pane's hooks last wrote.
        let shown = turn != nil && status != .off ? .busy : status
        out["status"] = shown.rawValue
        // Only an idle pane sleeps, the rule a thread's row follows.
        out["idleStage"] = (dozing && shown == .idle ? IdleStage.dozing : .awake).apiName
        return out
    }

    /// Whether the manager's pane sleeps: its session is there and every
    /// window of it dozes.
    static func dozing(_ sessions: [TmuxSession]) -> Bool {
        guard let session = sessions.first(where: { $0.name == ManagerHome.sessionName }),
              !session.windows.isEmpty
        else { return false }
        return session.windows.allSatisfy { $0.idleStage == .dozing }
    }

    /// The most text one turn takes, in UTF-8 bytes, and the longest review key.
    static let maxTextBytes = 8192
    static let maxKeyBytes = 256

    /// What a request body held.
    enum Field: Equatable {
        case value(String)
        /// Not `{"<name>": "…"}`, nothing in it, or a character that is not text.
        case invalid
        case tooLong

        /// The response for a body that cannot be used; nil for a value.
        var refusal: MobileResponse? {
            switch self {
            case .value: return nil
            case .invalid: return .error(400, "bad_request")
            case .tooLong: return .error(413, "too_large")
            }
        }
    }

    /// The `text` of a turn request. It is pasted into a terminal, so it must
    /// be text only: a control character there is a key press (Escape starts a
    /// key sequence, U+0003 is Ctrl-C, a carriage return is Enter). Newline
    /// and tab are the two that are text.
    static func text(in body: Data) -> Field {
        guard let text = string("text", in: body) else { return .invalid }
        guard text.utf8.count <= maxTextBytes else { return .tooLong }
        return text.unicodeScalars.allSatisfy(isText) ? .value(text) : .invalid
    }

    /// C0 controls except newline and tab, DEL, and the C1 controls are keys
    /// to a terminal, not text.
    static func isText(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return true
        case 0x00...0x1F, 0x7F...0x9F: return false
        default: return true
        }
    }

    /// The `key` of a dismiss request.
    static func key(in body: Data) -> Field {
        guard let key = string("key", in: body) else { return .invalid }
        return key.utf8.count <= maxKeyBytes ? .value(key) : .tooLong
    }

    private static func string(_ name: String, in body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let value = (object[name] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    /// Why a turn cannot start now, as the response the phone shows; nil when
    /// it can. The phone sends only into an idle pane. A busy pane may reach a
    /// permission prompt between the paste and the Enter, and the Enter would
    /// answer it; a waiting pane is already on one. With `queue` a busy pane
    /// is no refusal, as in `MobileReply.verify`: the human asked for the
    /// agent to hold the text. A turn the app follows still refuses: it
    /// follows one turn at a time.
    static func refusal(
        status: MobileManagerStatus, turnRunning: Bool, queue: Bool = false
    ) -> MobileResponse? {
        if status == .off { return .error(503, "unavailable", message: offMessage) }
        if turnRunning { return .error(409, "busy", message: busyMessage) }
        if status == .waiting { return .error(409, "waiting", message: waitingMessage) }
        if status == .busy, !queue { return .error(409, "busy", message: paneBusyMessage) }
        if status == .unknown { return .error(503, "not_ready", message: notReadyMessage) }
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
