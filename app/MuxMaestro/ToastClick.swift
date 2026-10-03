import Foundation

/// What a click on the manager toast does, by where it landed. Pure so the unit
/// tests can pin it; `ManagerToastOverlay.clicked(_:)` acts on the answer.
enum ToastClick: Equatable {
    case dismiss
    case openLink(ThreadLink)
    case open

    /// `inCloseButton` is true only while the × is showing. The × wins over a
    /// link under it, and a link wins over the toast's own target.
    static func action(inCloseButton: Bool, link: ThreadLink?) -> ToastClick {
        if inCloseButton { return .dismiss }
        if let link { return .openLink(link) }
        return .open
    }
}
