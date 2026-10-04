import Cocoa
import WebKit

/// The in-app help window (Help ▸ MuxMaestro Help / Keyboard Shortcuts): one
/// self-contained page documenting every feature + keyboard shortcut, rendered
/// dark to match the app. Created once and reused; `show(scrollTo:)` can jump to
/// the shortcuts section. The page is a static HTML string (no bundled assets),
/// so it works offline and needs no build step.
final class HelpWindowController: NSWindowController {
    private let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 680))

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "MuxMaestro Help"
        window.minSize = NSSize(width: 480, height: 400)
        window.center()
        self.init(window: window)
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        web.loadHTMLString(Self.html, baseURL: nil)
    }

    /// Bring the help window to front, optionally jumping to an anchor.
    func show(scrollTo anchor: String? = nil) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let anchor {
            web.evaluateJavaScript("location.hash='\(anchor)'", completionHandler: nil)
        }
    }

    /// A keyboard shortcut row: the chord + what it does.
    private struct Key { let combo: String; let desc: String }

    /// Every shortcut, grouped — the single source rendered into the table below.
    private static let shortcutGroups: [(String, [Key])] = [
        ("Navigate", [
            Key(combo: "⌘P", desc: "Go to File — fuzzy file finder for the session's repo"),
            Key(combo: "⇧⌘P", desc: "Go to File (alternate chord)"),
            Key(combo: "⌘K", desc: "Go to Session — fuzzy switcher over sessions, windows and panes, then pane scrollback; type a new name + ↩ to create one"),
            Key(combo: "⌘F", desc: "Find in Session — search the attached pane's scrollback (⏎ older, ⇧⏎ newer, Esc done)"),
            Key(combo: "⇧⌘F", desc: "Search — the repo (ripgrep); the panel's scope switch flips to every pane's scrollback"),
        ]),
        ("Git", [
            Key(combo: "⌥⌘C", desc: "Commit — stage files, write a message, commit → push → open PR"),
            Key(combo: "⌥⌘P", desc: "Pull Requests — every PR your windows are about; ↩ goes to a window"),
        ]),
        ("Sessions & windows", [
            Key(combo: "⌘`", desc: "Cycle Recent Windows — hold ⌘, tap ` to walk the windows you visited last, across every session"),
            Key(combo: "⌘N", desc: "New Window in the selected session"),
            Key(combo: "⌘T", desc: "New Pane"),
            Key(combo: "⌘D", desc: "Split Right"),
            Key(combo: "⇧⌘D", desc: "Split Down"),
            Key(combo: "⌘↩", desc: "Toggle Zoom on the active pane"),
            Key(combo: "⌘W", desc: "Close the focused pane, or archive its window (or close a focused palette)"),
            Key(combo: "⇧⌘R", desc: "Rename Session"),
            Key(combo: "⇧⌘N", desc: "Add Server (remote SSH host)"),
        ]),
        ("Editing (text fields)", [
            Key(combo: "⌘A", desc: "Select All"),
            Key(combo: "⌘C / ⌘V / ⌘X", desc: "Copy / Paste / Cut"),
            Key(combo: "⌘Z / ⇧⌘Z", desc: "Undo / Redo, including Archive Window"),
        ]),
        ("App", [
            Key(combo: "⌘Q", desc: "Quit MuxMaestro"),
        ]),
    ]

    private static var shortcutRows: String {
        shortcutGroups.map { group in
            let rows = group.1.map {
                "<tr><td class=k><kbd>\($0.combo)</kbd></td><td>\(esc($0.desc))</td></tr>"
            }.joined()
            return "<tr class=grp><td colspan=2>\(esc(group.0))</td></tr>\(rows)"
        }.joined()
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let features = """
    <h2 id="features">Features</h2>

    <h3>Sidebar</h3>
    <p>Every tmux session — local and connected remotes — is listed <b>flat</b>, each
    row showing a <b>host icon</b> (💻 local · 🗄 remote) and an <b>attention dot</b>
    (waiting / running / idle, joined from Claude Code session state). The <b>+</b> in
    the <b>SESSIONS</b> header creates a new local session. Drag a row to reorder;
    right-click for per-session actions. The <b>SERVERS</b> section lists saved SSH
    hosts — click one to connect it into the active list.</p>

    <h3>Go to File — ⌘P / ⇧⌘P</h3>
    <p>A floating fuzzy finder over the selected session's repo file names. Type to
    filter, ↑/↓ to move, ↩ to open in your editor.</p>

    <h3>Go to Session — ⌘K</h3>
    <p>A fuzzy switcher across all sessions. Type to search windows and panes too —
    a window matches as <code>session/window</code>, a pane in a split window as
    <code>session/window/command</code>. Below those, each pane whose scrollback
    contains what you typed (3+ characters) shows its newest matching line; picking
    one opens that pane with the find bar on your text. Matched characters are highlighted;
    remote rows show a dimmed <code>host/</code> prefix. If nothing matches what
    you typed, a <b>Create session "&lt;name&gt;"</b> row appears — ↩ makes a new
    local tmux session with that name.</p>

    <h3>Commit — ⌥⌘C</h3>
    <p>A panel bound to the session's repo: check files to stage, write a subject +
    body, then <b>Commit, Push &amp; PR</b> runs the whole flow (<code>git commit</code>
    → <code>git push</code> → <code>gh pr create</code>) with per-step status and the
    real error text on failure. The created PR opens on GitHub.</p>

    <h3>Pull requests</h3>
    <p>Each session whose branch has an open PR shows a green <b>#123</b> chip on its
    row — click it to open the PR. The toolbar <b>PRs</b> dropdown lists every
    session's open PRs.</p>

    <h3>Diff &amp; Tree panels</h3>
    <p>The <b>Diff</b> toolbar button shows the session's uncommitted git diff. The
    <b>Tree</b> button opens the repo file tree; <b>⇧⌘F</b> opens the search panel.
    It opens on <b>This repo</b>, a ripgrep content search of the selected
    session's repo. Its scope switch flips to <b>All panes</b> — every pane's tmux
    scrollback, on every host, with a click on a hit taking you to that pane at that
    line. The <b>Open</b> split-button opens the
    session directory in your editor.</p>

    <h3>Splits &amp; zoom</h3>
    <p><b>⌘D</b> / <b>⇧⌘D</b> split the active pane (tmux-native, persists on the
    server). <b>⌘↩</b> zooms it.</p>

    <h3>Remote hosts</h3>
    <p>Saved from <code>~/.ssh/config</code>. Connect from the SERVERS section; sessions
    run over SSH (with mosh support + ControlMaster reuse). Everything — files, diff,
    search, commit — routes to the right host automatically.</p>
    """

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      body { margin: 0; font: 14px/1.55 -apple-system, system-ui, sans-serif;
             color: #d7d8db; background: #1e1f22; padding: 28px 32px 48px; }
      h1 { font-size: 22px; margin: 0 0 2px; color: #fff; }
      .sub { color: #8a8d93; margin: 0 0 22px; }
      h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .05em;
           color: #8a8d93; margin: 30px 0 10px; border-bottom: 1px solid #34363b; padding-bottom: 6px; }
      h3 { font-size: 15px; color: #fff; margin: 18px 0 4px; }
      p { margin: 4px 0 10px; }
      code { background: #2a2c31; border-radius: 4px; padding: 1px 5px; font-size: 12.5px; }
      a { color: #6ca8ff; }
      table { border-collapse: collapse; width: 100%; }
      td { padding: 5px 8px; border-bottom: 1px solid #2a2c31; vertical-align: top; }
      td.k { width: 150px; white-space: nowrap; }
      tr.grp td { padding-top: 16px; color: #8a8d93; text-transform: uppercase;
                  font-size: 12px; letter-spacing: .04em; border-bottom: none; font-weight: 600; }
      kbd { background: #34363b; border: 1px solid #45474d; border-bottom-width: 2px;
            border-radius: 5px; padding: 2px 7px; font: 12.5px/1 ui-monospace, monospace; color: #fff; }
      .top { display: flex; gap: 8px; margin-bottom: 20px; }
      .top a { background: #2a2c31; border-radius: 6px; padding: 6px 12px; text-decoration: none; color: #d7d8db; }
    </style></head><body>
      <h1>MuxMaestro</h1>
      <p class="sub">A native macOS orchestrator for tmux sessions across local + remote hosts.</p>
      <div class="top"><a href="#shortcuts">Keyboard shortcuts</a><a href="#features">Features</a></div>
      <h2 id="shortcuts">Keyboard shortcuts</h2>
      <table>\(shortcutRows)</table>
      \(features)
    </body></html>
    """
}
