import Foundation

// The card half of the phone API: a review row the human answers from the
// phone. Pure, like MobileAPI.swift.
//
// The rules, in one place:
// - A card is a pointer (`mux point`) with a `review_card` row under the same
//   key. The Maestro writes both with `mux point --action`.
// - The phone names a card and one of its actions. It never sends the text and
//   never names a pane: both are read from the row the agent wrote.
// - The answer goes to the pane the card names as its source. A source that
//   matches no pane, or more than one, takes no answer: a guess could put the
//   answer into another session.
// - The text goes in through `MobileReply.send`, the one path that types into
//   a thread's pane: one bracketed paste, the checks, then a separate Enter.

/// What `mux point --action` adds to a pointer.
struct ManagerCard: Equatable {
    /// The card format this build reads. A row with another version is not a
    /// card here: the review row is still listed, without its buttons.
    static let version = 1

    struct Action: Equatable {
        let label: String
        /// What a tap pastes into the pane that asked.
        let text: String
    }

    /// The action that was delivered, and when.
    struct Answer: Equatable {
        let label: String
        let at: Int
    }

    /// The pane that asked, as tmux names it (`%12`). nil when the row names
    /// only a session or a window.
    var pane: String? = nil
    var body = ""
    var actions: [Action] = []
    var answer: Answer? = nil

    /// The card of one `review_card` row. nil for a version this build does
    /// not know, and for actions that are not the JSON `mux` writes.
    static func row(
        version: Int, pane: String, body: String, actions: String, answer: String, answeredAt: Int?
    ) -> ManagerCard? {
        guard version == Self.version,
              let list = (try? JSONSerialization.jsonObject(with: Data(actions.utf8))) as? [[String: Any]]
        else { return nil }
        let parsed = list.compactMap { entry -> Action? in
            guard let label = entry["label"] as? String, !label.isEmpty,
                  let text = entry["text"] as? String, !text.isEmpty else { return nil }
            return Action(label: label, text: text)
        }
        guard parsed.count == list.count else { return nil }
        return ManagerCard(
            pane: pane.isEmpty ? nil : pane, body: body, actions: parsed,
            answer: answer.isEmpty ? nil : Answer(label: answer, at: answeredAt ?? 0))
    }
}

/// A pointer that carries a card, as the phone gets it.
struct MobileCard: Equatable {
    /// Where the question came from, and so where an answer goes.
    struct Source: Equatable {
        let host: String
        let session: String
        var window: Int? = nil
        var pane: String? = nil
    }

    let title: String
    let source: Source
    let card: ManagerCard

    init(title: String, source: Source, card: ManagerCard) {
        self.title = title
        self.source = source
        self.card = card
    }

    /// nil for a review row with no card.
    init?(_ review: ManagerReviewItem) {
        guard let card = review.card else { return nil }
        self.init(
            title: review.text,
            source: Source(
                host: review.host, session: review.session, window: review.window, pane: card.pane),
            card: card)
    }
}

enum MobileCards {
    /// The most buttons one card shows, and the longest label and body, in
    /// characters. `mux` refuses more; the DB is a file, so they are cut here too.
    static let maxActions = 4
    static let maxLabelCharacters = 40
    static let maxBodyCharacters = 280

    static let goneMessage = "Session is gone"
    static let ambiguousMessage = "More than one pane matches"
    static let answeredMessage = "Already answered"
    static let changedMessage = "Card changed"
    static let badTextMessage = "Answer cannot be typed"

    /// Why a card's source names no one pane.
    enum Miss: Error, Equatable {
        case gone
        case ambiguous

        var refusal: MobileResponse {
            switch self {
            case .gone: return .error(404, "source_gone", message: goneMessage)
            case .ambiguous: return .error(409, "source_ambiguous", message: ambiguousMessage)
            }
        }
    }

    // MARK: Routing

    /// The thread an answer to a card goes to: the routing decision.
    ///
    /// A pane id is the address. It must be listed now, on the host the card
    /// names, and still in the session the card names: a tmux server that
    /// restarted hands the same ids out again. The window is not compared,
    /// because a pane keeps its id when its window moves.
    ///
    /// With no pane id the session, or the window in it, must hold exactly one
    /// thread. Unlike a link, an answer never falls back to the first match.
    static func target(
        of source: MobileCard.Source, in snapshot: MobileSnapshot
    ) -> Result<MobileThread, Miss> {
        let rows = snapshot.threads.filter { $0.host.name == source.host }
        if let pane = source.pane {
            guard let thread = rows.first(where: { $0.pane == pane }),
                  source.session.isEmpty || thread.session == source.session
            else { return .failure(.gone) }
            return .success(thread)
        }
        guard !source.session.isEmpty else { return .failure(.gone) }
        let matches = rows.filter {
            $0.session == source.session && (source.window == nil || $0.window == source.window)
        }
        switch matches.count {
        case 0: return .failure(.gone)
        case 1: return .success(matches[0])
        default: return .failure(.ambiguous)
        }
    }

    /// Names one state of a card's question. The phone sends it back with a
    /// tap, so a tap on a card that has since changed is refused instead of
    /// picking whatever action now has that position.
    static func id(key: String, card: MobileCard) -> String {
        MobileReply.hash(
            [key, card.title, card.source.host, card.source.session, card.source.pane ?? ""]
                + card.card.actions.flatMap { [$0.label, $0.text] })
    }

    /// One tap: the card, the action's position on it, and the card's id as
    /// the phone showed it.
    struct Ask: Equatable {
        let key: String
        let action: Int
        let card: String
    }

    /// The body of an act request: `{"key": "…", "action": 0, "card": "…"}`.
    static func ask(in body: Data) -> Ask? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty,
              key.utf8.count <= MobileManager.maxKeyBytes,
              let number = object["action"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), number.intValue >= 0,
              let card = object["card"] as? String, !card.isEmpty
        else { return nil }
        return Ask(key: key, action: number.intValue, card: card)
    }

    /// What a tap comes to.
    enum Route: Equatable {
        /// Paste `text` into `thread`'s pane and submit it.
        case deliver(thread: MobileThread, label: String, text: String)
        case refuse(MobileResponse)
    }

    /// Decide what one tap does. `board` is the board with this server's own
    /// deliveries on it (`withDelivered`), so a second tap finds the answer.
    static func route(_ ask: Ask, board: MobileManagerBoard, snapshot: MobileSnapshot) -> Route {
        guard let card = board.items.first(where: { $0.kind == .review && $0.key == ask.key })?.card
        else { return .refuse(.error(404, "not_found")) }
        guard id(key: ask.key, card: card) == ask.card else {
            return .refuse(.error(409, "changed", message: changedMessage))
        }
        guard card.card.answer == nil else {
            return .refuse(.error(409, "answered", message: answeredMessage))
        }
        guard card.card.actions.prefix(maxActions).indices.contains(ask.action) else {
            return .refuse(.error(400, "bad_action"))
        }
        let action = card.card.actions[ask.action]
        // The same filter as text the phone types: a control character in a
        // terminal is a key press.
        guard action.text.utf8.count <= MobileManager.maxTextBytes,
              action.text.unicodeScalars.allSatisfy(MobileManager.isText)
        else { return .refuse(.error(400, "bad_action", message: badTextMessage)) }
        switch target(of: card.source, in: snapshot) {
        case .failure(let miss): return .refuse(miss.refusal)
        case .success(let thread): return .deliver(thread: thread, label: action.label, text: action.text)
        }
    }

    // MARK: Delivered answers

    // The app reads the review list on a timer, so the board hears of an
    // answer a moment after it reached the pane. Until then the server keeps
    // the answer itself, by the card's id, and shows it on the board: a second
    // tap in that moment sends nothing, and the phone sees "sent" at once.

    /// The deliveries the board does not show yet: the card is still listed,
    /// as the same question, with no answer. One the board shows, or whose
    /// card is gone or was asked anew, is dropped.
    static func pending(
        _ delivered: [String: ManagerCard.Answer], in board: MobileManagerBoard
    ) -> [String: ManagerCard.Answer] {
        guard !delivered.isEmpty else { return delivered }
        let open = Set(board.items.compactMap { item -> String? in
            guard let key = item.key, let card = item.card, card.card.answer == nil else { return nil }
            return id(key: key, card: card)
        })
        return delivered.filter { open.contains($0.key) }
    }

    /// `board` with each of `delivered` set on its card.
    static func withDelivered(
        _ delivered: [String: ManagerCard.Answer], on board: MobileManagerBoard
    ) -> MobileManagerBoard {
        guard !delivered.isEmpty else { return board }
        var out = board
        out.items = board.items.map { item in
            guard let key = item.key, let card = item.card, card.card.answer == nil,
                  let answer = delivered[id(key: key, card: card)] else { return item }
            var answered = card.card
            answered.answer = answer
            var item = item
            item.card = MobileCard(title: card.title, source: card.source, card: answered)
            return item
        }
        return out
    }

    // MARK: JSON

    /// The phone's route to a thread: `/t/<id>`, the id as one path segment.
    static func route(toThread id: String) -> String {
        "/t/" + (id.addingPercentEncoding(withAllowedCharacters: segment) ?? id)
    }

    private static let segment = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")

    /// A card's body as the phone shows it: its line breaks stay, any other
    /// control character and every zero-width or text-direction character
    /// goes, and a long text is cut with an ellipsis.
    static func bodyText(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { MobileManager.pointerLine(String($0), limit: maxBodyCharacters) }
            .filter { !$0.isEmpty }
        let body = lines.joined(separator: "\n")
        guard body.count > maxBodyCharacters else { return body }
        return String(body.prefix(maxBodyCharacters - 1)) + "…"
    }

    /// The card as the phone draws it: format version 1. The action texts
    /// stay on the Mac, and so does the tmux address: the phone names an
    /// action by its position and a pane by its thread id. `opens` is the
    /// thread the pointer opens, for a card whose own source names no one pane.
    static func json(
        key: String, card: MobileCard, in snapshot: MobileSnapshot, opens: String? = nil
    ) -> [String: Any] {
        let source = try? target(of: card.source, in: snapshot).get()
        let body = bodyText(card.card.body)
        return [
            "v": ManagerCard.version,
            "id": id(key: key, card: card),
            "title": MobileManager.pointerLine(card.title),
            "body": body.isEmpty ? NSNull() : body,
            "source": source?.id ?? NSNull(),
            "actions": card.card.actions.prefix(maxActions).map {
                ["label": MobileManager.pointerLine($0.label, limit: maxLabelCharacters)]
            },
            "link": (source?.id ?? opens).map(route(toThread:)) ?? NSNull(),
            "answered": card.card.answer.map { ["label": $0.label, "at": $0.at] as [String: Any] }
                ?? NSNull(),
        ]
    }

    /// The answer to a tap that was delivered.
    static func delivered(thread: MobileThread, answer: ManagerCard.Answer) -> [String: Any] {
        [
            "ok": true, "thread": thread.id,
            "answered": ["label": answer.label, "at": answer.at] as [String: Any],
        ]
    }
}
