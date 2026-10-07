# MuxMaestro — Architecture & Build Plan

This is the build spec. It is the source of truth for the autonomous build loop:
each milestone lands as a reviewed PR into `main`; "done" means every objective
below is met, CI is green, and the app runs.

## What it is

A native macOS app (Swift / AppKit) that orchestrates the Claude Code / agent
sessions running in **tmux**. Master–detail UI: a sidebar tree on the left, one
live terminal on the right. The terminal is rendered by **libghostty** (Ghostty's
engine, embedded as `GhosttyKit.xcframework`).

The web/tailnet dashboard built earlier stays only for phone glances; this is the
desktop orchestrator and must feel genuinely native and responsive.

## UI

```
┌ ◆ MuxMaestro ───────────────────────────────────────────────────────────┐
│ SESSIONS (sidebar)        │  my-site · win 1 · pane %12           │
│ 🔴 my-site   needs  │ ┌─────────────────────────────────────────┐│
│   ▸ 0: edit               │ │                                         ││
│   ▾ 1: server  ●          │ │   ONE live libghostty terminal,         ││
│       ▪ %12 nvim          │ │   swaps instantly on sidebar select     ││
│       ▪ %13 pnpm dev ◀    │ │                                         ││
│ 🟢 acme-app       running  │ │                                         ││
│ ⚪ widget-shop            │ └─────────────────────────────────────────┘│
│ [+ new session]           │  [send a prompt ⌄]  [⤢ zoom] [kill] [↗]    │
└───────────────────────────┴─────────────────────────────────────────────┘
```

- **Left — sidebar tree:** session → window → pane. Each session has an attention
  dot: 🔴 red = needs you (permission prompt / waiting), 🟢 green = running,
  ⚪ grey = idle. Needs-you sorts to the top. Expand to windows/panes; click any
  node.
- **Right — one terminal:** a single libghostty surface. Selecting a node in the
  sidebar swaps the terminal to exactly that session/window/pane. **No accordion
  of terminals.**
- **Actions:** new session, kill, rename, zoom a single pane. (Interaction with a
  session is **terminal-direct** — type into the libghostty surface; there is no
  app-level prompt box. The M4 typed send-prompt bar was removed.)
- **Bar / quality:** clean, simple, fast. Keyboard-navigable. Smooth resize.

## How it works

- **Tree data:** shell out to `tmux list-sessions / list-windows / list-panes`
  with `-F` format strings; refresh live (poll ~1–2s or react to tmux hooks).
- **Attention status:** read Claude Code's own session files
  (`~/.claude/sessions/*.json` → `status` = idle | busy | waiting, plus
  `waitingFor`). Reuse the logic in `~/tools-proto/tools/sessions.py` (port it
  to Swift or shell to it). Works on sessions launched anywhere.
- **Selecting a pane:** point the single libghostty surface at the session's PTY
  (`tmux attach -t <session>` via a PTY), and drive `tmux select-window` /
  `select-pane` / `resize-pane -Z` (zoom) so the surface shows exactly the
  selected pane. Swapping sessions swaps the attached PTY/surface.
- **Interaction:** terminal-direct — keystrokes go straight to the libghostty
  surface → the PTY. (The M4 typed send-prompt bar was removed; the
  `load-buffer`/`paste-buffer` plumbing it shared is retained only for M11's
  drop-to-send, which pastes a dropped file's path into the pane without Enter.)
- **Lifecycle:** new = `tmux new-session` (optionally launch `claude`); kill =
  `kill-session`; rename = `rename-session`.

## Remote hosts over SSH (M8)

MuxMaestro was local-only through M7. M8 adds **remote tailnet hosts**: the sidebar
gains a top level — `localhost` (always first) + each `~/.ssh/config` Host alias
— and a remote host's session→window→pane tree, terminal attach, and lifecycle
work exactly like the local host, just dispatched over SSH.

### How it stays "exactly like local"

Every tmux interaction was already built as a pure argv (`TmuxCommands` /
`TmuxModel` format strings) and dispatched through the `CommandRunner` seam. M8
inserts one more seam — **`TmuxTransport`** — that turns a tmux argv into the
concrete `(executable, argv)` to run:

- `LocalTmuxTransport` → `tmux <argv>` (the M1–M7 path, unchanged).
- `SshTmuxTransport` → `ssh <opts> <host> tmux <argv>`.

`TmuxService` is now constructed per host and routes **all** of `loadTree`,
`selectWindow/Pane`, zoom, `sendPrompt`, new/kill/rename, and `sessionCwd`
through its transport. So the entire service is host-agnostic; a remote host is
just a service with the ssh transport. A `HostRegistry` owns one `TmuxService`
per host (local + each remote alias), created lazily and reused so a host's SSH
connection persists across polls.

### SSH connection reuse (responsiveness)

The 1.5 s poll would re-handshake SSH on every command without multiplexing. The
ssh transport sets, on every invocation:

```
-o ControlMaster=auto -o ControlPath=~/.sidekick/ssh-%r@%h:%p
-o ControlPersist=60s -o ConnectTimeout=4 -o BatchMode=yes
```

so all commands to a host share **one** persistent connection. `ConnectTimeout`
bounds the offline case; `BatchMode` prevents any interactive password prompt
from hanging the subprocess. Remote commands use a longer `CommandRunner`
timeout (8 s vs 4 s local) and run on the same off-main driver/poll queues from
M5/M7, so a slow or offline host can't freeze the UI.

### SSH argv quoting (critical)

`ssh` does **not** preserve argv boundaries — it joins the remote command tokens
with spaces and re-parses them through the remote login shell. A raw control
byte (the original `\u{1f}` field separator) gets escaped by the remote shell
into the literal text `\037`, breaking `-F` format strings; a `#` would start a
remote-shell comment. So: (a) the field separator is now an ASCII **tab** (it
survives the round-trip and never collides with a tmux field value), and (b)
`SshTmuxTransport` single-quotes every tmux token so the remote shell receives
it verbatim. Local and remote then use the identical separator + parser.

### Terminal attach (remote)

Selecting a remote session points the single libghostty surface at
`ssh -t <host> tmux new-session -A -s <session>` (PTY forced; attach-or-create),
with the same ControlMaster opts. window/pane select + zoom drive
`ssh <host> tmux select-window/select-pane/resize-pane -Z`. Still one surface,
torn down cleanly on host/session change (the `attachedService` tracks which
host the surface is on so a same-named session on a different host re-attaches).

### Attention status (remote), best-effort + graceful degrade

`RemoteSessionsPyStatusProvider` runs the app's bundled `sessions.py` on the remote
in one round-trip, piping it to `~/.muxmaestro/tools/` first until a read succeeds
(`test -f ~/.muxmaestro/tools/sessions.py && python3 … list --full` after that).
`--full` adds what only the host can read: each transcript's last prompt and last
write, and its live Codex panes (rows with `"agent": "codex"`). If the
command fails it
**degrades explicitly** — logs the reason once and returns nil — so remote
sessions show tmux-level info (attached/activity) with a neutral grey dot rather
than hanging or silently collapsing to unknown.

### Reachability UX

A remote host is probed off-main with a bare `ssh <opts> <host> true`
(connectivity only — doesn't require tmux to be installed). An unreachable host
shows greyed "(unreachable)" and never blocks other hosts or the local tree.
Collapsed remote hosts aren't probed at all (cheap); expanding one triggers a
load. Reachable hosts without tmux simply show an empty tree.

### Lifecycle on remote

new/kill/rename target the selected host's service. The remote new-session dir
picker uses a **typed path** (NSOpenPanel can't browse the remote FS), defaulting
to `~` on the remote. Because `SshTmuxTransport` single-quotes every tmux token,
a naive `'~'` reached the remote shell as a *literal* tilde and tmux created the
session under a directory named `~` (PR#9 review finding). The fix:
`Ssh.shellQuoteAllowingTilde` leaves a **leading** `~` / `~/` / `~user/`
unquoted so the remote shell tilde-expands it to `$HOME`, while still
single-quoting the rest of the token — preserving the uniform per-token quoting
invariant for every other path and argument. So the default dir resolves to the
remote home, and an absolute or space-containing dir is still fully quoted.

**Shell-injection hardening (`shellQuoteAllowingTilde`).** The first cut emitted
the token before the first `/` *unquoted* without checking it was actually a
tilde-expansion token. Because the remote new-session dir is a free-text field
(defaulting to `~`), a value like `~; rm -rf ~/data`, `` ~`id` ``, `~$(touch /x)`,
`~&&id`, `~|id`, `~ ; ls`, or `~user; id` would inject live shell metacharacters
straight into the remote login shell. The fix validates the tilde segment against
`^~[A-Za-z0-9._-]*$` (a bare `~` or a real `~user`) before leaving it bare; any
segment carrying `;` `` ` `` `$` `&` `|` or whitespace fails the check and the
**whole token falls back to full single-quoting** (`shellQuote`), so it reaches
the remote shell as inert literal text. The legit cases (`~`, `~/code/x`,
`~deploy/app`, `/abs/path`, `a~b`) are unchanged; adversarial payloads are
asserted to contain no unquoted metacharacters in `SshConfigTests`.

## Window / pane context actions (M9)

Through M8 the right-click context menu acted only on **session** rows (kill /
rename / new). M9 extends it **down the tree** so windows and panes get their own
actions, reusing the M6 destructive-safety patterns and the M8 per-host routing:

- **Window rows:** New Window (`new-window -a -t <session>:` — inserted after the
  current window), Rename Window (`rename-window -t <session>:<win> <name>`), and
  Archive Window (`kill-window -t <session>:<win>`, behind a confirmation alert;
  Edit > Undo creates the window again and resumes its agents, see `WindowArchive`).
- **Pane rows:** Split Horizontally / Vertically (`split-window -h|-v -t
  <session>:<win>.<pane>`) and Kill Pane (`kill-pane -t <session>:<win>.<pane>`,
  behind a confirmation).
- **Sessions** keep their existing kill / rename / new.

### Safety (reuses M6)

Destructive items (Archive Window, Kill Pane) are gated behind a confirmation sheet.
Every menu item is pinned to the **exact** right-clicked `SidebarNode` via
`NSMenuItem.representedObject` at menu-open time (`menuNeedsUpdate`); the handlers
read that node and **never** re-derive the target from `clickedRow` at action
time (which can reset to -1 and silently fall back to the *selected* row — the
M6 bug). The target-id construction lives in pure, unit-tested `TmuxCommands`
helpers — `windowTarget(session:window:)` → `session:win` and
`paneTarget(session:window:pane:)` → `session:win.pane` — so the addressing is
asserted independent of AppKit.

### Remote-aware

Each action is dispatched through the clicked node's **host service** (M8 made
`TmuxService` per-host over a `TmuxTransport`). A window/pane action on a remote
host therefore goes over SSH automatically — the new `TmuxService` methods
(`killWindow` / `renameWindow` / `newWindow` / `killPane` / `splitPane`) route
through the same `tmux()` seam every other call uses, so they're ssh-quoted and
ControlMaster-reused with zero extra code. After any mutation the controller
refreshes that host's tree. The mutations run on the off-main `driverQueue`
(matching M7) so a hung tmux/ssh call can't freeze the UI; only the confirm
sheet, the rename text prompt, the refresh, and error alerts touch main.

## Add server (M10)

M8 read remote hosts from `~/.ssh/config`; M10 lets you **add** one from the app
(toolbar **Add Server**, menu **⌘⇧N**) without hand-editing ssh config. The flow
is split into a pure core (`AddServer.swift`, fully unit-tested) and thin UI
(`AddServerPrompt` in `Prompts.swift`).

- **Never writes a secret.** `SshAuthMethod` is one of: `onePasswordAgent` (the
  `host3` model — `IdentityAgent` pointed at the 1Password agent socket +
  `IdentitiesOnly yes`, Touch ID gates each use), `keyFile` (an `IdentityFile`
  **path** only), or `defaultAgent` (no Identity directives). The generated
  `Host` block carries only HostName/User/Port metadata and a key *path* or agent
  *reference* — never key contents or a passphrase. Asserted by tests.
- **Managed hosts file.** Entries are written to `~/.ssh/sidekick_hosts`
  (perms 600), kept separate from the user's hand-maintained `~/.ssh/config`.
  Re-adding an alias upserts (replaces its block) rather than duplicating.
- **Idempotent Include, backed up.** `save` ensures `Include ~/.ssh/sidekick_hosts`
  sits at the **very top** of `~/.ssh/config` (Include must precede any `Host *`
  to take effect), inserting it only if absent and **copying the config to a
  timestamped backup first**. `SshConfig.parseHosts`/`loadHosts` now follow
  `Include` directives (tilde + relative + glob expansion, missing-file and
  include-cycle safe) so the new host shows up in the sidebar immediately.
- **Test-on-save.** After persisting, an off-main `ssh -o ConnectTimeout=5 -o
  BatchMode=yes <name> true` probe verifies the host resolves + auths (BatchMode
  blocks a password prompt but still lets the agent / Touch ID satisfy auth). On
  failure the already-saved entry can be kept or removed. All filesystem paths
  are injected, so the whole feature is tested in a temp dir — never the real
  `~/.ssh`.

## File drop onto a session (M11)

Sidebar **session rows are an `NSDraggingDestination`** that accept file URLs
(e.g. from Finder). On a drop onto a session: resolve that session's cwd
(`sessionCwd` via the host's service), copy the file there (`cp` local / `scp`
remote to `<cwd>/`, **reusing M8's ControlMaster opts** so the copy shares the
host's multiplexed connection), then **paste the resulting path into that
pane** — `load-buffer`/`paste-buffer` with the path text on stdin, **no
auto-Enter** (the M11 decision: paste the path for the user to run, never execute
it). `validateDrop` only accepts a file-URL drop *on* a session row and retargets
a drop anywhere in the subtree onto the session. A file dropped on the terminal
takes the same path, with a trailing space after the pasted path.

### Security — scp remote-operand quoting

The scp **remote** operand (`<alias>:<path>`) is not pure argv: scp expands the
remote `<path>` through the remote **login shell** (it runs roughly
`<remote-shell> -c 'scp -t <path>'`), so spaces, `;`, `$()`, backticks, `&&`,
`|`, etc. in that path would execute on the remote host. This is reachable from
a dropped file whose basename carries metacharacters. `copyArgv` therefore shell-quotes the path portion before the
`alias:` prefix — `"\(alias):" + Ssh.shellQuoteAllowingTilde(remotePath)`. Using
`shellQuoteAllowingTilde` (not plain `shellQuote`) keeps a
`~/report.html` tilde-expanding to the remote `$HOME` like the rest of the app;
a malicious leading `~…` (e.g. `~;rm`) fails that helper's tilde-segment
validation and falls back to full single-quoting automatically. The local `cp`
branch stays raw argv (no shell, nothing to quote).

### Design (testable seam)

The command construction is a pure, fully unit-tested core
(`FileTransfer.swift`): `copyArgv` (local `cp` vs remote `scp` + the shared
ControlMaster opts, paths with spaces safe as argv elements), `capturePaneArgv`,
and `dropDestination`. The runtime method (`TmuxService.dropFileToSession`)
threads those through the same `CommandRunner`/`TmuxTransport` seam every other
call uses, so a `FakeRunner` asserts the whole drop sequence — including that the
drop **pastes the remote path text and never sends Enter** — with no real
ssh/scp/tmux spawned. The drop runs on the off-main `driverQueue` (M7); only the
error alert touches main.

## Embedded browser pane (M12)

Through M11 MuxMaestro could only show terminals. M12 adds an **embedded browser**
to preview what your agents are building, right beside the session driving the
build. **Tier 1+2 only** — it loads URLs in a `WKWebView` and can open a
session's listening port; it is **NOT** an agent-scriptable / CDP browser (the
`agent-browser` CLI covers programmatic/headless control, so there is no
DevTools-Protocol surface here).

### Browser pane (`BrowserViewController.swift`)

A `WKWebView` (`import WebKit`) with a native chrome: an editable **address bar**
(Enter to go; a bare `host:port` is normalized to `http://…`), **Back / Forward /
Reload**, and a thin **determinate progress bar** driven off the web view's
`estimatedProgress`. `isInspectable = true` so Safari Web Inspector can attach
(devtools). Back/Forward enablement + the address field track the web view via
KVO observations. The pane lives in the detail area: `DetailViewController` gains
a **Terminal | Browser segmented control** that swaps between the
full-bleed terminal surface and the browser in the same space — both are children,
so swapping never tears down the other's state (the terminal keeps its surface,
the browser keeps its page). Clean and native; no toolbar clutter.

### Auto-open a session's listening port

A toolbar **Open Port** button (+ **⌘B**, + Session menu) detects what the
selected session is serving and opens it:

- **Pane pids → subtree.** The session's pane pids come from
  `tmux list-panes -s -t <session> -F '#{pane_pid}'` (routed through the host's
  transport, so local or ssh-wrapped). `ps -axo pid=,ppid=` gives the full
  parent/child map; `BrowserPorts.descendants` walks it (cycle-safe) so a dev
  server spawned by the pane's shell is attributed to the session.
- **lsof → listening ports.** `lsof -nP -w -iTCP -sTCP:LISTEN -FpcPn` lists every
  listening TCP socket in machine-readable field format;
  `BrowserPorts.parseListeningPorts` keeps only sockets owned by that pid set,
  handling IPv4 / IPv6 / `*` addresses and de-duplicating (port, pid). One port →
  open it directly; several → a small pop-up menu to pick.
- **LOCAL** opens `http://localhost:<port>`. **REMOTE** opens an on-demand SSH
  **local-forward** first — `ssh -fN -L <localPort>:localhost:<remotePort> <host>`
  reusing the M8 ControlMaster opts — then loads `http://localhost:<localPort>`.
  The local end is a kernel-assigned free port (bind :0 + getsockname); forwards
  are cached per host+remote-port so re-opening reuses the existing tunnel.

The lsof/ps parsing, the ssh-forward argv (incl. the ControlMaster opts), and URL
normalization are pure, fully unit-tested helpers in `BrowserPorts.swift` (a
`FakeRunner` covers the service paths — no real lsof/ps/ssh spawned in tests).

### Per-session remembered URL

The last URL shown is remembered per **host+session** (in-memory map keyed
`<host>:<session>`). Selecting a session restores its URL into the browser pane,
so flipping between sessions swaps the preview to match. Opening a port also
records it as that session's remembered URL.

## herdr provider (M13)

Through M12, every session in the sidebar came from **tmux** (local or a remote
ssh host). M13 adds a SECOND, fully separate multiplexer as a session **source**:
**herdr** (`/opt/homebrew/bin/herdr`, v0.6.10) — a "terminal workspace manager
for AI coding agents". herdr is **not** tmux: it runs its own server + sockets
under `~/.config/herdr` and exposes a different CLI, so it never shows up through
tmux discovery. M13 surfaces it alongside the tmux hosts without touching the
tmux path.

### herdr's actual interface (what it exposes, captured from 0.6.10)

herdr's tree is **session → workspace → tab → pane**. Only `session list` takes a
`--json` flag; `tab list` and `pane list` have no flag but already emit JSON
(wrapped in a `{"id":…,"result":{"type":…,"<items>":[…]}}` envelope):

- `herdr session list --json`
  → `{"sessions":[{"name":"default","default":true,"running":true,
     "session_dir":…,"socket_path":…}]}`
- `herdr tab list`
  → `{"result":{"type":"tab_list","tabs":[{"tab_id":"w…:1","workspace_id":"w…",
     "number":1,"label":"1","pane_count":1,"agent_status":"unknown",
     "focused":false}, …]}}`
- `herdr pane list`
  → `{"result":{"type":"pane_list","panes":[{"pane_id":"w…-1","tab_id":"w…:1",
     "workspace_id":"w…","agent":"claude","agent_status":"working","cwd":"/…",
     "focused":false,"terminal_id":…}, …]}}`
- `herdr session attach <name>` — PTY attach (the libghostty surface command).
- `herdr session stop|delete <name>` — session lifecycle.

The tab/pane lists are **server-wide** (not per-session); the running server backs
one session at a time, so all tabs/panes belong to the single running session.
The workspace level is a thin container (usually one per session), so the sidebar
**folds it away** and shows **session → tab → pane** — the same three-level shape
the tmux tree uses (session → window → pane).

### The provider seam

Rather than refactor the concrete `TmuxService` into a protocol (invasive, and it
would risk the working tmux path), M13 adds a **parallel** provider, `HerdrService`,
that mirrors `TmuxService`'s role for the herdr source: `loadTree()` (three list
calls → assembled tree), `attachCommand(session:)`, and `stopSession` / `deleteSession`
lifecycle. It dispatches every herdr invocation through the **same `CommandRunner`
seam** the tmux service uses, so the whole provider is asserted against a
`FakeRunner` with no real herdr spawned. All parsing + argv + the agent-status →
attention mapping live in pure `HerdrModel` (fully unit-tested). **`TmuxService`,
`TmuxModel`, and `TmuxCommands` are untouched** — M13 is purely additive.

### Sidebar integration

`SidebarNode.Kind` gains four additive cases — `herdr(available:)`,
`herdrSession`, `herdrTab`, `herdrPane` — and the sidebar appends a single
top-level **herdr** node as a sibling to localhost + the ssh hosts. It's always
shown (greyed "(not installed)" when herdr is absent, so it's discoverable) and
loads its tree off-main only when expanded (cheap when collapsed, since herdr
isn't on the ssh-config path). The diff/expansion/selection-restore machinery is
reused unchanged.

### Attach + lifecycle

Selecting any herdr row (session/tab/pane) points the single libghostty surface
at `herdr session attach <name>` — the same one-surface, torn-down-on-switch
pattern as the tmux attach path, just a different command. herdr exposes no
clean per-tab/pane surface targeting, so a tab/pane selection attaches the whole
session (herdr shows its focused tab/pane). Right-click on a herdr session offers
**Stop** (non-destructive) and **Delete** (destructive — gated behind the M6
confirmation sheet); the tmux "New Session" fallback is suppressed for herdr rows.

### Attention status

herdr has its own per-pane/tab `agent_status` (idle | working | blocked |
unknown). M13 maps it onto the shared `AttentionStatus` dot so a herdr session
reads the same way a tmux one does: **blocked → needs you (red)**, **working →
running (green)**, **idle/unknown → quiet (grey)**. A session's dot rolls up the
most attention-worthy state across its tabs/panes, mirroring the tmux needs-you
sort. No blocking, no extra round-trips — it's already in the list JSON.

## Diff pane (M14)

Through M13 you could watch an agent work a session, but seeing **what it
actually changed** meant dropping into the terminal and running git by hand. M14
adds a third detail segment — **Diff** — that renders the selected session's
working-directory diff, syntax-highlighted, in a second `WKWebView`. It works for
**local and remote (ssh) hosts** by reusing the M8 per-host transport seam,
exactly like the browser pane's Open-Port path.

### Diff scope + the pure core (`GitDiff.swift`)

The pane shows **all uncommitted changes vs HEAD** (`git diff HEAD` — staged +
unstaged tracked changes) **plus untracked files rendered as additions**, in one
refreshable patch. `GitDiff` is a Foundation-only, fully unit-tested core (like
`BrowserPorts` / `FileTransfer`): it builds the git argv and synthesizes
untracked-file patches.

- **argv builders.** `isRepoArgv` (`rev-parse --is-inside-work-tree`),
  `hasHEADArgv` (`rev-parse --verify -q HEAD`), `branchHeaderArgv`
  (`rev-parse --abbrev-ref HEAD`), and the tracked-diff pair `headDiffArgv`
  (`--no-pager diff --no-color HEAD`) vs `noHeadDiffArgv` (no `HEAD`, for an empty
  repo with no commits yet), chosen by `trackedDiffArgv(cwd:hasHEAD:)`. Plain
  `git diff` exits **0** even with changes (only `--exit-code`/`--no-index` exit
  non-zero), so it's compatible with `ProcessCommandRunner` (which returns nil on
  a non-zero exit).
- **Untracked as additions.** `untrackedListArgv` lists them
  (`ls-files --others --exclude-standard -z`); `untrackedFilePatch` synthesizes a
  `diff --git` "new file" block **in Swift** (not `git diff --no-index`) so we
  never hit the runner's non-zero-exit limit and never mutate the index
  (no `add -N`). It matches git's edge cases: empty file → header only, no
  trailing newline → the `\ No newline at end of file` marker. `combine` joins the
  tracked patch + untracked blocks into one patch string.
- **Bounded.** The untracked count and per-file size are capped
  (`maxUntrackedFiles` / `maxUntrackedFileBytes`) so a huge untracked tree or blob
  can't wedge the pane; what's dropped is surfaced (`untrackedDropped`) and logged.

### Threading it through the host transport (`TmuxService.gitDiff`)

`gitDiff(cwd:)` runs each git command via the **existing** private
`runHostCommand(local:remote:_:)` — `local: gitPath` (`/usr/bin/git`, the macOS
shim), `remote: "git"` — the same helper `listeningPorts` uses, so a **remote
host's diff goes over ssh with the ControlMaster opts for free**. It probes
`hasHEAD`, runs the tracked diff, lists untracked files, fetches each via
`cat` (`local: catPath`, `remote: "cat"`) at the cwd-joined absolute path, and
combines. A non-repo cwd returns `isRepo: false` so the pane shows a friendly
"Not a git repository". Does real work serially — run off-main. A `FakeRunner`
covers both the local (`git -C <cwd> …`) and remote (`ssh <opts> <host> git …`,
quoted) paths — no real git/ssh/cat spawned in tests.

### The pane + the offline renderer (`DiffViewController.swift`)

A `WKWebView` (its own, separate from the browser pane's) with a thin top bar:
a **Refresh** button and a status label ("branch · N files" / "No changes" /
"Not a git repository"). It loads a **vendored, offline** bundle from `file://`:
[`@pierre/diffs`](https://diffs.com) (the Shiki-backed renderer behind diffs.com)
pre-built into one self-contained JS+CSS bundle under
`app/MuxMaestro/Resources/diff/` (source in `web/diff/`, rebuilt with
`make diff-bundle`; the built output is committed so a fresh checkout never
rebuilds and there are **zero runtime network fetches**). The bundle exposes
`window.SidekickDiff.render(patch)` and `setTheme('dark'|'light')`; the patch is
passed as a JSON-encoded argument (never string-interpolated). `isInspectable`
for debugging; theme follows `effectiveAppearance`.

`DetailViewController`'s segmented control grows a third **Diff** segment;
`showPane(.terminal|.browser|.diff)` generalizes the old `showBrowser` toggle,
keeping all three VCs alive so swapping never tears down state. The AppDelegate
wires a **Show Diff** action (toolbar + Session menu, **⌘D**, gated on a
selection): it resolves the selected session's cwd and runs `gitDiff` off-main
(same discipline as Open Port), then renders on main. The pane's **Refresh** and
switching to the Diff tab both recompute for the current session so it's never
stale.

## libghostty embedding

libghostty's embedding C API is **internal/undocumented**; this is the advanced
path (same as cmux). Build `GhosttyKit.xcframework` from Ghostty source with Zig,
link it, and use the C API in `include/ghostty.h` — reference Ghostty's own
`macos/Sources/` for correct usage (surface create, draw, key/mouse input,
resize, PTY wiring). Pin Ghostty to a known-good tag and record the commit + zig
version in `scripts/build-libghostty.sh`.

## Milestones (one PR each)

1. **Toolchain** — install pinned Zig; clone Ghostty (pinned); build
   `GhosttyKit.xcframework`; `make libghostty`; CI builds it (or caches it).
2. **Skeleton** — Swift/AppKit `MuxMaestro.app`: split view, sidebar placeholder, a
   single libghostty surface rendering one `tmux attach`. Proves embedding works.
3. **Sidebar** — live session→window→pane tree with attention dots; click swaps
   the terminal (select-window/select-pane/zoom). Needs-you sorting.
4. **Actions & polish** — new session, kill, rename, zoom; clean
   visual design; keyboard nav; responsiveness pass.
5. **Tests & hardening** — unit tests (tmux parsing, attention mapping, tree
   model), UI smoke tests, error handling (tmux down, session vanished).
6. **Remote hosts over SSH** (added post-plan) — sidebar host level
   (localhost + ssh-config aliases); per-host `TmuxService` over an
   `SshTmuxTransport` with ControlMaster reuse; remote attach / lifecycle /
   attention degrade / reachability. See "Remote hosts over SSH" below.
7. **Window / pane context actions** (added post-plan) — extend the right-click
   context menu down the tree: window rows (kill / rename / new) and pane rows
   (kill / split h+v), reusing M6 destructive-safety + M8 per-host routing. See
   "Window / pane context actions" below.
8. **File drop onto a session** (added post-plan) — drag a file onto a session
   to copy it to the session's cwd and paste the path (no auto-run). See "File
   drop onto a session" above.
9. **Embedded browser pane** (added post-plan) — preview a session's listening
   dev-server port in an in-app `WKWebView`, with a per-session
   remembered URL. See "Embedded browser pane (M12)" above.
10. **herdr provider** (added post-plan) — add **herdr**, a separate non-tmux
   multiplexer, as a second session source via a parallel `HerdrService`
   provider (list / attach / stop / delete + agent-status attention), surfaced
   as its own top-level sidebar node. tmux path untouched. See "herdr provider
   (M13)" above.
11. **Diff pane** (added post-plan) — a third detail segment rendering the
   selected session's working-directory diff (`git diff HEAD` + untracked as
   additions) via a vendored, offline `@pierre/diffs` bundle in a `WKWebView`,
   over the M8 transport so remote (ssh) diffs work for free. See "Diff pane
   (M14)" above. **(final milestone)**

## Quality bar (definition of done)

- UI is simple, clean, and visually nice; interactions feel instant.
- Selecting any node swaps the terminal with no flicker/lag.
- Attention triage is correct and live.
- Good test coverage of the non-UI logic; app launches and works on a fresh
  checkout via `make`.
- CI green on `main`.
