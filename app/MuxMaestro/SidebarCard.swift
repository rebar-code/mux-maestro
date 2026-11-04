import Foundation

/// Which part of a session card one sidebar row draws. A card spans a session
/// row and its visible window and pane rows, so each row draws a segment.
enum CardSegment: Equatable {
    /// A session with no visible rows under it: the whole card.
    case single
    /// The session row of an expanded card: rounded top corners.
    case top
    /// A window or pane row inside a card: sides only.
    case middle
    /// The card's last visible row: rounded bottom corners.
    case bottom

    /// The segment for a row. `card` names the session the row belongs to (nil
    /// for a row outside any card), `isHead` is true for the session row itself,
    /// and `nextCard` is the next visible row's `card`. nil: no card.
    static func of(card: String?, isHead: Bool, nextCard: String?) -> CardSegment? {
        guard let card else { return nil }
        let continues = nextCard == card
        switch (isHead, continues) {
        case (true, false): return .single
        case (true, true): return .top
        case (false, true): return .middle
        case (false, false): return .bottom
        }
    }

    var roundsTop: Bool { self == .single || self == .top }
    var roundsBottom: Bool { self == .single || self == .bottom }

    /// Space between two cards. Half sits above a card, half below it.
    static let gap: CGFloat = 12
    /// Extra height on every row in a card, split above and below its content.
    static let rowPadding: CGFloat = 2

    /// Space above the card in this row: half the gap where a card starts.
    var topGap: CGFloat { roundsTop ? Self.gap / 2 : 0 }
    /// Space below the card in this row: half the gap where a card ends.
    var bottomGap: CGFloat { roundsBottom ? Self.gap / 2 : 0 }

    /// The row's height for content that needs `content` points. The gap and
    /// padding add to it, so the content never shrinks.
    func rowHeight(content: CGFloat) -> CGFloat {
        content + Self.rowPadding + topGap + bottomGap
    }

    /// Where the card sits inside the row: clear of the gaps.
    var cardInsets: (top: CGFloat, bottom: CGFloat) { (topGap, bottomGap) }

    /// Where the row's content sits: clear of the gaps, centred in the padding.
    var contentInsets: (top: CGFloat, bottom: CGFloat) {
        (topGap + Self.rowPadding / 2, bottomGap + Self.rowPadding / 2)
    }
}

/// The server colour on a session card. Only the header (the tmux session row,
/// which rounds the card's top) is tinted; window and pane rows stay plain, and
/// herdr sessions have no server, so no colour.
enum CardTint {
    /// The colour to fade in from the left of this row, or nil for no tint.
    /// `hostHex` is the row's server colour, nil for rows with no server.
    static func accentHex(segment: CardSegment?, isSession: Bool, hostHex: String?) -> String? {
        guard isSession, segment?.roundsTop == true else { return nil }
        return hostHex
    }
}

/// The pinned copy of a session row that stays at the top of the sidebar while
/// the session's windows scroll under it, as the phone's session header does.
/// Values are in the outline's flipped coordinates: y grows downward.
enum StickyHeader {
    /// The pinned header's top edge, or nil when nothing is pinned: the session
    /// row is not cut by the top edge, or no row of its card is below the row.
    /// `cardBottom` is where the session's last visible row ends. The header
    /// rides up with it, so the next card pushes it out.
    static func top(
        visibleTop: CGFloat, rowTop: CGFloat, rowHeight: CGFloat, cardBottom: CGFloat
    ) -> CGFloat? {
        guard rowTop < visibleTop, cardBottom > rowTop + rowHeight, cardBottom > visibleTop
        else { return nil }
        return min(visibleTop, cardBottom - rowHeight)
    }
}
