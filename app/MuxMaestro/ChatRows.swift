import Foundation

// The Mac's chat view, its pure half: the rows it draws from a transcript, and
// the transcript it holds between reads. The same rules as the phone's chat
// (`mobile/src/lib/toolruns.ts`, `thread.svelte.ts`).

/// One thing the chat draws: a message, or the control that stands for the
/// earlier tool rows of a run.
enum ChatRow: Equatable {
    case message(MobileChatMessage)
    /// `key`: the `n` of the run's first tool row, the same while the run grows.
    case fold(key: UInt64, hidden: Int, open: Bool)
}

enum ChatRows {
    /// How many tool rows at the end of a run stay in view.
    static let toolsShown = 3

    /// The chat's rows, with each run of tool calls cut to its last
    /// `toolsShown`. A run is tool rows with nothing else between them. A
    /// longer run starts with a fold; the rows it stands for follow it only
    /// when its key is in `open`.
    static func rows(_ messages: [MobileChatMessage], open: Set<UInt64>) -> [ChatRow] {
        var out: [ChatRow] = []
        var at = 0
        while at < messages.count {
            var end = at
            while end < messages.count, messages[end].role == .tool { end += 1 }
            if end == at {
                out.append(.message(messages[at]))
                at += 1
                continue
            }
            let run = messages[at..<end]
            let hidden = max(run.count - toolsShown, 0)
            let key = messages[at].n
            let isOpen = open.contains(key)
            if hidden > 0 { out.append(.fold(key: key, hidden: hidden, open: isOpen)) }
            let shown = hidden > 0 && !isOpen ? run.dropFirst(hidden) : run
            out.append(contentsOf: shown.map(ChatRow.message))
            at = end
        }
        return out
    }

    /// What the fold's button says.
    static func foldLabel(hidden: Int, open: Bool) -> String {
        if open { return "Show last \(toolsShown)" }
        return hidden == 1 ? "1 more tool call" : "\(hidden) more tool calls"
    }
}

/// A pane's chat as the Mac holds it between reads of the transcript: the
/// rows so far, the cursor for the next read, and the text sent from the Mac
/// that the transcript does not show yet.
struct ChatFeed: Equatable {
    /// Text sent from the Mac, shown until the transcript has it.
    struct Pending: Equatable {
        let text: String
        /// The cursor and transcript when it was sent: only a row written
        /// after that can be it.
        let after: UInt64
        let session: String
        let sent: Date
    }

    /// The most rows held. Older rows fall off the top.
    static let limit = 400
    /// A pending row the transcript never shows (the agent rewrote it, or it
    /// was refused in the pane) is dropped after this long.
    static let pendingLifetime: TimeInterval = 300

    private(set) var messages: [MobileChatMessage] = []
    /// nil until the first page: the next read is from the tail.
    private(set) var next: UInt64?
    private(set) var session: String?
    private(set) var pending: [Pending] = []

    /// Take one page. Returns whether anything the view draws changed.
    @discardableResult
    mutating func merge(_ page: MobileChatPage, now: Date = Date()) -> Bool {
        let first = next == nil
        let moved = page.reset || (session.map { $0 != page.session } ?? false)
        next = page.next
        session = page.session
        let before = (messages, pending)
        if page.reset || first {
            messages = page.messages
        } else {
            messages.append(contentsOf: page.messages)
        }
        if messages.count > Self.limit { messages.removeFirst(messages.count - Self.limit) }
        resolve(page.messages, anyCursor: moved || first, now: now)
        return messages != before.0 || pending != before.1
    }

    /// Text just sent from the Mac.
    mutating func addPending(_ text: String, now: Date = Date()) {
        pending.append(Pending(text: text, after: next ?? 0, session: session ?? "", sent: now))
    }

    /// Text that never went in: its pending row goes.
    mutating func dropPending(_ text: String) {
        guard let index = pending.lastIndex(where: { $0.text == text }) else { return }
        pending.remove(at: index)
    }

    /// The pane changed: the next page starts over.
    mutating func clear() {
        self = ChatFeed()
    }

    /// Each new user row takes the oldest pending row with the same words.
    /// After a reset the cursors say nothing, so any user row may be one.
    private mutating func resolve(_ new: [MobileChatMessage], anyCursor: Bool, now: Date) {
        for message in new where message.role == .user {
            let words = Self.words(message.text)
            if let index = pending.firstIndex(where: { item in
                Self.words(item.text) == words
                    && (anyCursor || item.session != session || message.n >= item.after)
            }) {
                pending.remove(at: index)
            }
        }
        pending.removeAll { now.timeIntervalSince($0.sent) > Self.pendingLifetime }
    }

    /// Text with its whitespace runs made one space: the transcript keeps
    /// the words, not always the line breaks.
    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
