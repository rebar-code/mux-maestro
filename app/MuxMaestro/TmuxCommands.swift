import Foundation

/// Pure construction of the tmux argument vectors for every session action.
/// No process spawning here so it is fully unit-testable: each function returns
/// the exact `argv` (excluding the tmux binary path) that `TmuxService` runs.
///
/// All session/window names are passed straight through as argv elements — there
/// is **no shell**, so spaces and shell metacharacters in names are safe by
/// construction. Pasted text (the M11 drop-to-send path) is handled by streaming
/// the raw bytes into a tmux buffer (`load-buffer -`) and pasting it, rather than
/// embedding the text in `send-keys`.
enum TmuxCommands {
    /// Dedicated tmux buffer name MuxMaestro uses for paste so it never clobbers
    /// the user's default buffer stack.
    static let sendBuffer = "sidekick"

    /// The two argv vectors that paste text into a session's active pane WITHOUT
    /// pressing Enter — used by the M11 drop-to-send so the dropped file's path
    /// lands in the prompt for the user to run, never auto-executed.
    /// `load-buffer -b sidekick -` reads the text from the process's stdin, so it
    /// never appears in argv — multi-line and metacharacter safe. The caller
    /// pipes the text into the `load` step's stdin.
    static func pastePath(session: String) -> (load: [String], paste: [String]) {
        (
            load: ["load-buffer", "-b", sendBuffer, "-"],
            paste: ["paste-buffer", "-d", "-b", sendBuffer, "-t", session]
        )
    }

    /// Create a detached session named `name` in directory `dir`. tmux requires
    /// the session name to be non-empty; callers should validate first. A nil/empty
    /// `dir` omits `-c` (same convention as `newWindow`/`splitWindow`) — the
    /// move-to-new-session paths derive the directory from a live pane, and an
    /// unreadable one must fall back to tmux's default rather than to a literal `~`,
    /// which tmux would `chdir` to verbatim and fail on.
    static func newSession(name: String, dir: String?) -> [String] {
        var argv = ["new-session", "-d", "-s", name]
        if let dir, !dir.isEmpty {
            argv += ["-c", dir]
        }
        return argv
    }

    /// Run a command (e.g. `claude`) in the active pane of a freshly created
    /// session by typing it followed by Enter. Used right after `newSession`
    /// when the caller opts to launch a program.
    static func sendKeysLine(session: String, line: String) -> [String] {
        ["send-keys", "-t", session, line, "Enter"]
    }

    /// Type a command into a session's active pane WITHOUT pressing Enter — the
    /// session-recovery flow's "staged" mode, leaving `claude --resume <id>`
    /// sitting at the prompt for the user to fire when they get to it.
    static func sendKeysText(session: String, text: String) -> [String] {
        ["send-keys", "-t", session, text]
    }

    /// Reset an agent's conversation in the existing pane before starting a
    /// handoff turn. Claude Code and Codex use different slash commands.
    static func resetForHandoff(target: String, command: String) -> [String] {
        ["send-keys", "-t", target, command, "Enter"]
    }

    /// Start an agent CLI in a fresh shell pane for a new-window handoff.
    static func startAgent(target: String, command: String) -> [String] {
        ["send-keys", "-t", target, command, "Enter"]
    }

    /// Paste handoff text through a private tmux buffer so multiline prompts and
    /// shell metacharacters are passed as data, never as command arguments.
    /// `-p` brackets the paste; without it each newline submits its own turn.
    static func pasteHandoff(target: String, buffer: String) -> (load: [String], paste: [String]) {
        (
            load: ["load-buffer", "-b", buffer, "-"],
            paste: ["paste-buffer", "-p", "-d", "-b", buffer, "-t", target]
        )
    }

    static func submitPastedText(target: String) -> [String] {
        ["send-keys", "-t", target, "Enter"]
    }

    /// Kill a session. Targets the session by EXACT name (`=`) so a name that is a
    /// prefix of another session's can't misfire onto — or ambiguously match — the
    /// wrong one.
    static func killSession(name: String) -> [String] {
        ["kill-session", "-t", "=\(name)"]
    }

    /// Whether a destructive command that exited non-zero actually reached its goal:
    /// tmux prints "can't find session/window/pane: <t>" when the target is already
    /// gone, or "no server running…" when the whole server is down — both mean the
    /// thing you asked to kill is absent, which is exactly what a close wants. Pure
    /// so the classification is unit-tested. Case-insensitive on the captured output.
    static func killReachedGoalDespiteError(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("can't find") || lower.contains("no server running")
    }

    /// Rename a session.
    static func renameSession(from old: String, to new: String) -> [String] {
        ["rename-session", "-t", old, new]
    }

    /// Toggle zoom on a target (a pane id like `%12`, or `session:window`).
    static func toggleZoom(target: String) -> [String] {
        ["resize-pane", "-Z", "-t", target]
    }

    /// Query the zoom flag of a target — returns "1" when zoomed.
    static func zoomFlag(target: String) -> [String] {
        ["display-message", "-p", "-t", target, "#{window_zoomed_flag}"]
    }

    /// What a sidebar selection currently shows, for resolving the zoom target.
    enum ZoomSelection {
        /// A whole session is selected; its active window (index) is shown.
        case session(name: String, activeWindow: Int?)
        /// A specific window is selected.
        case window(session: String, window: Int)
        /// A specific pane is selected (zoomed by id).
        case pane(id: String)
    }

    /// The exact tmux target the zoom toggle must act on so the toolbar button
    /// and the visible surface agree with what selection drove. A selected pane
    /// zooms by its id (matching `selectPane(zoom:)`); a window — or a bare
    /// session, whose active window is on screen — zooms by `session:window`.
    static func zoomTarget(for selection: ZoomSelection) -> String {
        switch selection {
        case .session(let name, let activeWindow):
            if let w = activeWindow { return "\(name):\(w)" }
            return name
        case .window(let session, let window):
            return "\(session):\(window)"
        case .pane(let id):
            return id
        }
    }

    // MARK: Target id construction (window / pane)

    /// The tmux target for a window: `=session:window`. The `=` pins the session to
    /// an EXACT name match so a session whose name is a prefix of another's can't
    /// resolve to the wrong window. Pure so the addressing is unit-tested and the
    /// same string is used everywhere a window is targeted.
    static func windowTarget(session: String, window: Int) -> String {
        "=\(session):\(window)"
    }

    /// The tmux target for a pane: `=session:window.pane`. tmux accepts the bare
    /// pane id (`%12`) on its own, but the fully-qualified form is unambiguous across
    /// sessions/windows, and `=` pins the session to an exact match.
    static func paneTarget(session: String, window: Int, pane: String) -> String {
        "=\(session):\(window).\(pane)"
    }

    /// The target meaning "the next free window index in `session`": `=session:`
    /// with an *empty* window part, which tmux resolves to index -1 (append). The
    /// `=` matters more here than anywhere else — a merge into `web` that
    /// prefix-matched `web-2` would scatter windows into the wrong session with no
    /// undo, so the destination name is pinned exactly.
    static func sessionSlotTarget(session: String) -> String {
        "=\(session):"
    }

    // MARK: Copyable identifier (context menu)

    /// A sidebar row's tmux address, for "Copy tmux ID".
    enum Identifier {
        case session(name: String)
        case window(session: String, window: Int)
        case pane(id: String)
    }

    /// The identifier put on the pasteboard for a right-clicked row: `web`,
    /// `web:1`, `%12`. Plain (no `=` prefix) because this string is read and
    /// retyped by a human or another agent, and every tmux command accepts it as
    /// a target.
    static func copyableIdentifier(for id: Identifier) -> String {
        switch id {
        case .session(let name):
            return name
        case .window(let session, let window):
            return "\(session):\(window)"
        case .pane(let id):
            return id
        }
    }

    /// An agent session UUID shortened for a menu title: `6c4f3c09…ef189d`. The
    /// full id still lands on the clipboard — this is only so the menu says which
    /// id it will copy without a 36-character row. Ids too short to gain anything
    /// are returned unchanged.
    static func abbreviatedSessionId(_ id: String) -> String {
        guard id.count > 15 else { return id }
        return "\(id.prefix(8))…\(id.suffix(6))"
    }

    // MARK: Window actions (M9)

    /// Kill a window (destructive — gate behind a confirmation).
    static func killWindow(target: String) -> [String] {
        ["kill-window", "-t", target]
    }

    /// Rename a window. `--` so a name that starts with `-` is not read as a flag.
    static func renameWindow(target: String, to new: String) -> [String] {
        ["rename-window", "-t", target, "--", new]
    }

    /// `text` as tmux takes it literally where it would otherwise expand formats
    /// (`rename-window`, the `-c` directory): `#` doubled, and a trailing `;`
    /// escaped, because tmux reads an argument that ends in `;` as a command
    /// separator. For a value read back from tmux, such as a restored window's
    /// name or directory.
    static func literal(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "#", with: "##")
        return escaped.hasSuffix(";") ? escaped.dropLast() + "\\;" : escaped
    }

    /// Reapply the tmux layout string after every pane has been recreated.
    static func selectLayout(target: String, layout: String) -> [String] {
        ["select-layout", "-t", target, layout]
    }

    /// Restore a window or pane as the selected item in its session.
    static func selectWindow(target: String) -> [String] {
        ["select-window", "-t", target]
    }

    static func selectPane(target: String) -> [String] {
        ["select-pane", "-t", target]
    }

    /// Turn `allow-rename` on/off for a window. With it off, a program's title
    /// escape (e.g. Claude Code setting the window name to its version string)
    /// can't clobber a name we set — so an AI-renamed window sticks across redraws.
    static func setAllowRename(target: String, on: Bool) -> [String] {
        ["set-window-option", "-t", target, "allow-rename", on ? "on" : "off"]
    }

    /// Set a window user option (a `@`-prefixed key such as `@mm_prs`) to `value`.
    /// User options hold arbitrary strings and expand in `-F` formats as
    /// `#{@key}`, which is how the poll reads them back.
    static func setWindowUserOption(target: String, key: String, value: String) -> [String] {
        ["set-window-option", "-t", target, key, value]
    }

    /// Set a pane's title (`#{pane_title}`) by its pane id (e.g. `%12`). Panes have
    /// no tmux "name"; the title is the closest equivalent and what the breadcrumb
    /// shows for a renamed pane.
    static func setPaneTitle(paneId: String, to new: String) -> [String] {
        ["select-pane", "-t", paneId, "-T", new]
    }

    /// Create a new window in `session` (after the clicked window), optionally in
    /// `cwd`. `new-window -t <session>:` opens a new window in that session; `-a`
    /// inserts it after the current one. A nil/empty cwd omits `-c`.
    /// `printIndex` adds `-P -F #{window_index}` so the caller can go straight to
    /// the window it just made — tmux renumbering makes "the last one" an unsafe
    /// guess. Off by default: the session-recovery rebuild creates windows in
    /// bulk and has no use for the echo.
    /// `printTarget` prints the window index and pane id instead, for a caller
    /// that types into the new pane (the new-window handoff).
    static func newWindow(
        session: String, cwd: String?, printIndex: Bool = false, atIndex: Int? = nil,
        printTarget: Bool = false
    ) -> [String] {
        var argv: [String]
        if let atIndex {
            argv = ["new-window", "-d", "-t", "=\(session):\(atIndex)"]
        } else {
            argv = ["new-window", "-a", "-t", "\(session):"]
        }
        if printTarget {
            argv += ["-P", "-F", "#{window_index}\t#{pane_id}"]
        } else if printIndex {
            argv += ["-P", "-F", "#{window_index}"]
        }
        if let cwd, !cwd.isEmpty {
            argv += ["-c", cwd]
        }
        return argv
    }

    /// Where a freshly created pane landed, from `split-window -P -F` — its
    /// window index and pane id. tmux can put the pane in a window the caller
    /// didn't name (splitting a session target lands in its active window), so
    /// both halves are needed to go there.
    struct CreatedPane: Equatable {
        let window: Int
        let pane: String
    }

    /// Parse `split-window -P -F "#{window_index}\t#{pane_id}"` output. nil when
    /// the command failed or printed something unexpected.
    static func parseCreatedPane(_ text: String?) -> CreatedPane? {
        guard let text else { return nil }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
        guard fields.count == 2, let window = Int(fields[0]), !fields[1].isEmpty
        else { return nil }
        return CreatedPane(window: window, pane: String(fields[1]))
    }

    /// Parse `new-window -P -F "#{window_index}"` output into the new window's
    /// index. nil when the command failed or printed something unexpected.
    static func parseCreatedWindow(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Pane actions (M9)

    /// Kill a pane (destructive — gate behind a confirmation).
    static func killPane(target: String) -> [String] {
        ["kill-pane", "-t", target]
    }

    /// Split a pane. `vertical == false` is a left/right split (`-h`, side by
    /// side); `vertical == true` is a top/bottom split (`-v`, stacked) — matching
    /// tmux's own flag meaning (the flag names the split-line orientation).
    /// `cwd` sets the new pane's working directory via `-c`; pass the split pane's
    /// current path so the new pane opens beside it rather than in the session's
    /// (often `~`) start directory. A nil/empty cwd omits `-c`.
    /// `printTarget` adds `-P -F` printing the new pane's window index AND id, so
    /// the caller can select it without a second round trip to ask where it
    /// landed. Off by default, like `newWindow`'s `printIndex`.
    static func splitWindow(
        target: String, vertical: Bool, cwd: String? = nil, printTarget: Bool = false
    ) -> [String] {
        var argv = ["split-window", vertical ? "-v" : "-h", "-t", target]
        if printTarget { argv += ["-P", "-F", "#{window_index}\t#{pane_id}"] }
        if let cwd, !cwd.isEmpty {
            argv += ["-c", cwd]
        }
        return argv
    }

    /// Swap two panes in place (`swap-pane -s <source> -t <target>`) — the
    /// drag-to-rearrange "center" drop. Both are pane ids (e.g. `%12`).
    static func swapPane(source: String, target: String) -> [String] {
        ["swap-pane", "-s", source, "-t", target]
    }

    /// Move `source` next to `target`, splitting the target's space
    /// (`join-pane -s … -t … -h|-v [-b]`). `horizontal` picks a left/right split
    /// (`-h`) vs top/bottom (`-v`); `before` (`-b`) puts the source on the leading
    /// side (left/top) instead of the trailing side (right/bottom). This is the
    /// drag-to-rearrange edge drop; see `TmuxModel.joinArgs(for:)`.
    static func joinPane(
        source: String, target: String, horizontal: Bool, before: Bool
    ) -> [String] {
        var argv = ["join-pane", "-s", source, "-t", target, horizontal ? "-h" : "-v"]
        if before { argv.append("-b") }
        return argv
    }

    // MARK: Move / merge (sidebar reorganisation)

    /// Move a window to another window slot — the sidebar's "Move to Session" and
    /// "Merge into Session". `kill` (`-k`) destroys whatever already occupies the
    /// destination index; only the move-to-new-session path sets it, to replace the
    /// placeholder window that `new-session` is forced to create so the moved
    /// window ends up as index 0 and the session's only window. An appending move
    /// leaves it off, because tmux errors out on an occupied index instead.
    static func moveWindow(source: String, target: String, kill: Bool = false) -> [String] {
        var argv = ["move-window", "-s", source, "-t", target]
        if kill { argv.append("-k") }
        return argv
    }

    /// Break a pane out into a window of its own at `target` (a *window* target, so
    /// `sessionSlotTarget` sends it to another session). This is the only tmux verb
    /// that moves a pane across sessions: `join-pane` would split the destination's
    /// active window instead of giving the pane a window to itself.
    static func breakPane(source: String, target: String) -> [String] {
        ["break-pane", "-s", source, "-t", target]
    }

    // MARK: Find in Session (⌘F — copy-mode search)

    /// Enter copy-mode on a target (a session name targets its active pane).
    /// A no-op when the pane is already in copy-mode.
    static func copyMode(target: String) -> [String] {
        ["copy-mode", "-t", target]
    }

    /// Leave copy-mode, dropping any active search highlight and returning the
    /// pane to live output. Errors harmlessly when not in copy-mode ("not in a
    /// mode"); callers ignore the result.
    static func exitCopyMode(target: String) -> [String] {
        ["send-keys", "-t", target, "-X", "cancel"]
    }

    /// Search up the scrollback for plain text. The `-text` variant is literal
    /// (never regex) so what the user types is exactly what matches; the needle
    /// is its own argv element — no shell — so metacharacters are safe.
    static func searchBackward(target: String, text: String) -> [String] {
        ["send-keys", "-t", target, "-X", "search-backward-text", text]
    }

    /// Step to the next match. `search-again` repeats the stored search
    /// direction and `search-reverse` goes one step the other way — neither
    /// mutates the stored direction (tmux window-copy.c), and the find bar only
    /// ever starts searches with `search-backward`, so the stored direction is
    /// always up: again == older, reverse == newer, statelessly.
    static func searchStep(target: String, up: Bool) -> [String] {
        ["send-keys", "-t", target, "-X", up ? "search-again" : "search-reverse"]
    }

    /// Read the active search's match count: prints `<count>\t<partial>` where
    /// partial is "1" when tmux stopped counting early (shown as "N+").
    static func searchCount(target: String) -> [String] {
        ["display-message", "-p", "-t", target, "#{search_count}\t#{search_count_partial}"]
    }

    /// Format `searchCount` output as a find-bar label: "14 matches",
    /// "1 match", "100+ matches" (partial count), "no matches", or nil when the
    /// read failed / there is no active search.
    static func searchCountLabel(_ output: String?) -> String? {
        guard let output else { return nil }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        guard let count = Int(parts.first ?? "") else { return nil }
        if count == 0 { return "no matches" }
        let partial = parts.count > 1 && parts[1] == "1"
        return "\(count)\(partial ? "+" : "") match\(count == 1 && !partial ? "" : "es")"
    }

    // MARK: Context-menu target resolution

    /// Resolve which row a sidebar context-menu action targets. `clickedRow` is
    /// the row under the right-click (or -1 when the click missed a row);
    /// `selectedRow` is the current selection (or -1). The clicked row wins so
    /// right-clicking an *unselected* row never operates on a different one; only
    /// when the click missed a row entirely do we fall back to the selection.
    /// Returns nil when neither resolves to a real row (no safe target).
    static func contextMenuRow(clickedRow: Int, selectedRow: Int) -> Int? {
        if clickedRow >= 0 { return clickedRow }
        if selectedRow >= 0 { return selectedRow }
        return nil
    }

    /// Resolve which row an ⌥-hover previews. `optionOnly` is whether ⌥ is the one
    /// modifier held; `hoveredRow` is the row under the pointer (or -1). Returns
    /// nil when there is nothing to switch to: no ⌥, no row, or the row already
    /// selected.
    static func hoverPreviewRow(optionOnly: Bool, hoveredRow: Int, selectedRow: Int) -> Int? {
        guard optionOnly, hoveredRow >= 0, hoveredRow != selectedRow else { return nil }
        return hoveredRow
    }

    // MARK: Validation

    /// tmux session names may not be empty and may not contain `.` or `:`
    /// (those are target separators). Returns a cleaned name, or nil if the
    /// trimmed input is empty.
    static func sanitizedSessionName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Make `desired` unique against `existing` by appending `-2`, `-3`, … until
    /// it no longer collides. tmux rejects a `new-session` whose name already
    /// exists (`duplicate session: …`), so the new-session flow dedupes up front
    /// rather than surfacing a failure for an everyday folder-name collision.
    static func uniqueSessionName(_ desired: String, existing: Set<String>) -> String {
        guard existing.contains(desired) else { return desired }
        var n = 2
        while existing.contains("\(desired)-\(n)") { n += 1 }
        return "\(desired)-\(n)"
    }
}
