import Foundation

/// Decision + copy for the close confirmation raised by ⌘W. The sidebar's
/// right-click Close/Kill items skip it (`needsConfirm`). Pure string and enum building — no AppKit — so both
/// *what* a close kills and how it is worded are unit-testable and identical
/// everywhere the confirm is raised.
///
/// ⌘W used to always run `kill-window`, so pressing it while working in one pane
/// of a three-pane window killed all three. `action(for:)` picks the focused pane
/// instead whenever other panes would survive it, and the window only when the
/// pane and the window are the same thing.
///
/// Both kills are unrecoverable: every process in the target dies, and killing a
/// session's last window ends the session. The prompt therefore names the exact
/// pane or window, and says out loud when an agent is mid-flight or when the
/// session itself is about to go.
enum CloseWindowPrompt {
    /// One pane of the target window — only the three facts the prompt needs:
    /// which pane ⌘W lands on (`active`), what to call it, and whether an agent
    /// in it is mid-flight. Deliberately not `TmuxPane`, so this layer stays
    /// independent of how the sidebar happens to model a pane.
    struct Pane {
        /// tmux pane id, e.g. "%13" — what `kill-pane` is targeted at and what the
        /// prompt names, matching the sidebar's own "Kill Pane %13".
        let id: String
        /// Whether this is the window's active pane, i.e. the one the human is
        /// typing into when they hit ⌘W.
        let active: Bool
        /// Attention of the agent in this pane (see `TmuxPane.attention`).
        let attention: AttentionStatus

        init(id: String, active: Bool, attention: AttentionStatus = .unknown) {
            self.id = id
            self.active = active
            self.attention = attention
        }
    }

    /// Everything the copy needs about the window under the cursor.
    struct Target {
        let session: String
        /// tmux window index. nil only when the sidebar model hasn't loaded the
        /// session yet, so ⌘W can name the session but not the window.
        let index: Int?
        /// tmux window name; may be empty when tmux reported none.
        let name: String
        /// Rolled-up attention of the window's panes (see `TmuxWindow.attention`).
        let attention: AttentionStatus
        /// True when this is the session's only window, so closing it ends the
        /// session as well.
        let isLastWindow: Bool
        /// The window's panes, in tmux order. Empty when the sidebar tree hasn't
        /// loaded this session — which is why an empty list has to mean "close the
        /// window": there is no pane we can name and kill. See `action(for:)`.
        let panes: [Pane]

        init(
            session: String, index: Int?, name: String,
            attention: AttentionStatus = .unknown, isLastWindow: Bool = false,
            panes: [Pane] = []
        ) {
            self.session = session
            self.index = index
            self.name = name
            self.attention = attention
            self.isLastWindow = isLastWindow
            self.panes = panes
        }
    }

    /// What a confirmed close actually kills.
    enum Action: Equatable {
        /// `kill-pane` on this pane id. Only chosen when other panes survive it.
        case pane(id: String)
        /// `kill-window` on the whole window.
        case window
    }

    /// ⌘W's rule: close the focused pane, unless that pane *is* the window.
    ///
    /// A single-pane window stays a `.window` close. tmux destroys a window once
    /// its last pane dies, so the two are the same event — but routing it through
    /// `kill-window` keeps the confirm honest that the window (and, on the last
    /// window, the session) is ending, instead of under-selling it as "just a
    /// pane". An empty `panes` means the sidebar tree hasn't reached this session,
    /// so there is no pane id to target and the window is the only thing we can
    /// name.
    static func action(for target: Target) -> Action {
        guard target.panes.count > 1,
              let focused = target.panes.first(where: \.active) ?? target.panes.first
        else { return .window }
        return .pane(id: focused.id)
    }

    /// Where a close was asked for.
    enum Source {
        /// A Kill/Close item in the sidebar's right-click menu.
        case contextMenu
        /// ⌘W or the menu bar's Close.
        case keyboard
    }

    /// Whether a close raises the confirm sheet. Choosing Kill/Close from the
    /// sidebar's right-click menu is already a deliberate second step, so a sheet
    /// after it is a double confirm — even for a busy agent. ⌘W sits one
    /// keystroke from typing, so it keeps the sheet (Return confirms).
    static func needsConfirm(_ source: Source) -> Bool {
        source == .keyboard
    }

    /// Label on the default (confirm) button — names the unit being closed, so the
    /// button and the title can never disagree about what is about to die.
    static func confirmTitle(_ action: Action) -> String {
        switch action {
        case .pane: return "Close Pane"
        case .window: return "Close Window"
        }
    }

    /// Alert title — names exactly what is being closed, and where it lives.
    ///
    ///     Close window 17 “watch PR #393 #394 CI” in “dev”?
    ///     Close window 3 in “dev”?            (window has no name)
    ///     Close the active window in “dev”?   (session not loaded yet)
    ///     Close pane %13 of window 17 “agents” in “dev”?
    static func title(_ target: Target, _ action: Action) -> String {
        let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = target.index else {
            if case .pane(let id) = action {
                return "Close pane \(id) in “\(target.session)”?"
            }
            return "Close the active window in “\(target.session)”?"
        }
        let what = name.isEmpty ? "window \(index)" : "window \(index) “\(name)”"
        if case .pane(let id) = action {
            return "Close pane \(id) of \(what) in “\(target.session)”?"
        }
        return "Close \(what) in “\(target.session)”?"
    }

    /// Alert body — the consequence, then any escalation. A pane close reports
    /// *that pane's* status rather than the window's rollup, so a quiet pane
    /// beside a busy one is never described as busy, and it says how much of the
    /// window survives so the ⌘W-closes-everything fear doesn't need testing.
    static func info(_ target: Target, _ action: Action) -> String {
        switch action {
        case .pane(let id):
            var parts = ["This kills the pane and the process running in it."]
            parts += agentWarning(
                target.panes.first { $0.id == id }?.attention ?? .unknown, unit: "pane")
            let others = max(target.panes.count - 1, 0)
            parts.append(
                others == 1
                    ? "The window’s other pane keeps running."
                    : "The window’s other \(others) panes keep running.")
            return parts.joined(separator: " ")
        case .window:
            var parts = ["This kills the tmux window and every process in it."]
            parts += agentWarning(target.attention, unit: "window")
            if target.isLastWindow {
                parts.append("It is the last window, so the session “\(target.session)” ends too.")
            }
            return parts.joined(separator: " ")
        }
    }

    /// The "an agent is mid-flight" sentence, or nothing for the quiet states.
    /// Shared so a pane close and a window close escalate identically apart from
    /// the noun — the warning is about losing an agent either way.
    private static func agentWarning(
        _ attention: AttentionStatus, unit: String
    ) -> [String] {
        switch attention {
        case .busy:
            return ["An agent is running here — closing the \(unit) stops that work."]
        case .waiting:
            return ["An agent here is waiting on you — the pending prompt is lost."]
        case .idle, .unknown:
            return []
        }
    }
}
