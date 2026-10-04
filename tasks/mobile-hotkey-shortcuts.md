# Phone key strip: a compact form and user shortcuts

Spec only. No code is written yet. Asked 2026-10-04.

## Goal

The owner's words:

> "The goal of the maestro/orchestra is that I can talk to one interface that
> commands all of the other sessions so that I don't have to context switch and
> I can just brain dump into you and then you route my requests properly or
> spawn new subagents or answer the questions — that way your context stays
> clear most of the time so that you're not the one actually doing the work,
> and you can also respond to me much faster."

Two asks on the key strip of the maestro screen:

1. A compact form. The strip takes too much room.
2. User-defined shortcuts, like slash commands.

## Decisions in one place

| Question | Decision |
| --- | --- |
| Compact form | Glyph keys in fixed slots, plus one overflow key that opens a sheet. No sideways scroll. |
| Where shortcuts are defined | On the phone. The Mac stores them. |
| What a shortcut does | Inserts text, or sends text. No key presses in v1. |
| May it target another session | Yes. Named sessions, every agent session, or the maestro. Text only. |
| Storage | `UserDefaults` on the Mac through `Settings.swift`. The phone keeps a cache. |
| Fan-out | The phone sends to each target through the existing text route. One result row per target. |
| New dependency | None. |
| Edits to the four frozen files | None in v1. Three later items land there (see "Frozen files"). |

Two parts of the goal need backend work that does not exist. They are scoped
apart, under "Backend work that does not exist yet". This spec does not hide
them in the UI phases.

## What exists today

### The key strip

- `mobile/src/lib/KeyBar.svelte` (143 lines) draws the strip. Added in PR #17.
- The keys are data: `BAR_KEYS` in `mobile/src/lib/reply.ts:14`. 14 keys.
  A key has `send` (a tmux key name), `insert` (a character for the text box),
  or `ctrl` (sticky Ctrl).
- `barKeys(composer)` (`reply.ts:46`) drops the `insert` keys and Ctrl when
  the page has no text box for them.
- Three places mount it:
  - `mobile/src/routes/+page.svelte:191`, the maestro home:
    `<KeyBar {reply} composer={false} hides />`. 9 keys: Esc, Tab, Sh+Tab,
    Ctrl+C, four arrows, Enter.
  - `ThreadView.svelte:498`, a thread's chat: all 14 keys.
  - `ThreadView.svelte:485`, a thread's live terminal: all 14 keys, into the
    terminal socket (`LiveTerm` in `liveterm.svelte.ts` is the sink).
- The strip already scrolls sideways (`data-hscroll`, a fade mask at 86%).

Space it costs, from the CSS (11.5px mono, 8px side padding, 28px minimum,
5px gap; widths are estimates):

| Where | Height | Key content width | Room on a 375pt phone | Hidden |
| --- | --- | --- | --- | --- |
| Maestro home, 9 keys | 38pt (32 + 6 margin) | ~368pt | 307pt | ~61pt, 2 keys |
| Thread, 14 keys | 38pt | ~549pt | 307pt | ~242pt, 44% |

### How a key reaches a pane

1. A tap calls `reply.tap(key)` (`reply.svelte.ts:279`). `reply` is a `KeySink`.
2. A `send` key goes to `Reply.key`, which queues it (`queueKey`, at most 8)
   and posts one key at a time: `sendKey` in `api.ts:283`.
3. The route is `POST /api/threads/<id>/key` or `POST /api/manager/key`
   (`MobileAPI.swift:448-459`), under the `keyBar` capability.
4. `MobileReply.press` (`MobileReply.swift:527`) checks the name against a
   whitelist (`MobileReply.keys`: 8 named keys, `C-a` to `C-z`, `1` to `9`),
   reads the pane's screen, and runs `tmux send-keys -t <pane> <key>`.

### How text reaches a pane

- A thread: `Reply.send` (`reply.svelte.ts:180`) → `sendText` →
  `POST /api/threads/<id>/text` → `MobileReply.send` (`MobileReply.swift:619`).
  The Mac filters the text (`MobileManager.text`: no control characters, at
  most 8192 bytes), checks the pane twice, pastes once (bracketed), waits
  0.3 s, then sends Enter.
- The Mac refuses text when the pane is busy (`409 busy`), is on a prompt
  (`409 waiting`), or shows no input box (`409 no_input`).
- The maestro: `manager.send` → `sendManagerText` → `POST /api/manager/text`.
  This is one turn through `ManagerController.send` and `ManagerPaneDriver`.
  The reply streams back. A turn in flight refuses a second one.
- Voice: `MobileVoice.swift` takes `?target=manager` or a thread id, and then
  uses the same two sends.

**The text route takes any thread id.** It is not bound to the thread on
screen. So the phone can already send text to a session it does not show.

### Slash commands

- `SlashList.svelte` shows when the box holds only `/name` (`slashQuery`,
  `reply.ts:104`). `ThreadView.svelte:488` renders it from `reply.matches`.
- The list is `GET /api/threads/<id>/commands`. `MobileCommands.list`
  (`MobileReply.swift:914`) reads skills and commands from the Mac's disk, then
  adds the agent's built-ins. A pick sets the draft to `/name ` and sends
  nothing.
- The maestro home has no slash list.

### Stored shortcuts: none

- `Settings.swift` holds only app and phone switches in `UserDefaults`. No
  shortcut, snippet or macro key.
- The manager DB has six tables: `sessions`, `agent_state`, `agent_events`,
  `work_log`, `review`, `notifications` (`ManagerStore.swift:577-646`; the live
  file was read in read-only mode and matches). None holds shortcuts.
- The phone's `localStorage` holds drafts, voice picks, text size, collapse
  state and caches. No shortcuts.

### Commands on the Mac

- ⌘K (`SessionPaletteViewController.swift`) switches session, window or pane.
  ⌘P (`FilePaletteViewController.swift`) picks files. Both navigate. Neither
  sends a command to a pane.
- Menu shortcuts are fixed in `AppDelegate.swift`. The Help window lists them
  from a static table (`HelpWindowController.swift:40`).
- The maestro agent has a CLI, `app/MuxMaestro/Resources/manager/mux`:
  `sessions`, `notify`, `review`, `name`, `spin`, `link`, `event`.
  **It has no verb that sends text to a session.** `AGENT.md` lets the agent
  send only "benign, unblocking nudges" to the human's sessions, with raw tmux.

So the Mac has no model of a user command. This is new.

## Compact form

| Option | Height | Width at 375pt | For | Against |
| --- | --- | --- | --- | --- |
| A. Glyphs only (`⎋ ⇥ ⇤ ⌃C`) | 38pt | 9 keys: 292pt, fits. 14 keys: 457pt, does not fit. | Small change. | No room for shortcuts. A thread still scrolls. |
| B. One overflow key | 38pt | Fixed. Never scrolls. | Room for a list with names. | One more tap for the rare keys. |
| C. Scrolling strip | 38pt | 368pt to 549pt of content | Built already. | It is the complaint. Added shortcuts would sit past the fade. |
| D. Long-press menu, no strip | 0pt | 0pt | All the room back. | Hidden. Slow for Esc. The only anchors are in frozen files. |

**Recommendation: A and B together.**

- Every key is one 28pt slot with a glyph: `⎋ ⌃C ↑ ↓ ⏎ ⇥ ⇤ ← → ⌃ / ~ | -`.
  The `aria` names stay as they are.
- The strip holds as many slots as fit: 9 at 375pt, 7 at 320pt, 11 at 430pt.
  The count comes from a pure function of the strip's width.
- The order of `BAR_KEYS` is the priority. The first 5 keys keep their slots.
  Pinned shortcuts take the next slots. The last slot is the overflow key `⋯`.
- At 375pt: 5 keys, 3 pinned shortcuts, `⋯`.
- `⋯` opens a bottom sheet: the other keys, every shortcut with its name, and
  "New shortcut". Names are in the sheet. The strip gains no text.
- The hide-keyboard key stays where it is.

Why: the strip stops scrolling, the rare keys leave it, and shortcuts get a
place with names. It needs no edit to a frozen file.

What it does not do: it does not give back the 38pt row. To get the row back,
the keys must move into the voice controls row. That lands in
`VoiceBar.svelte` and `ThreadView.svelte`, so it joins the queued pass.

Check on a real phone: the glyphs `⎋ ⇥ ⇤ ⌃` must not fall back to a box in
the mono font. If one does, draw it in `Icon.svelte`.

## User shortcuts

### Where they are defined

On the phone, in the sheet. The Mac stores them.

- The owner is often phone-only, so the editor must be on the phone.
- The Mac is the store, so every paired phone shows one list, and a cleared
  browser loses nothing.
- Later the Mac app and the maestro agent can read the same list.
- No Mac editor in v1.

### What a shortcut is

```json
{
  "id": "b1f0c2de",
  "name": "sitrep",
  "glyph": "S",
  "text": "/sitrep",
  "send": true,
  "to": { "kind": "all" },
  "pinned": true
}
```

| Field | Rule |
| --- | --- |
| `name` | `^[a-z0-9][a-z0-9-]{0,23}$`. Unique. It is the slash name. |
| `glyph` | One grapheme. Drawn on the strip when `pinned`. Default: the first letter. |
| `text` | At most 2000 bytes. Must pass the same filter as sent text (`MobileManager.isText`). |
| `send` | `false`: insert into the box on screen. `true`: paste and submit. |
| `to` | `current`, `maestro`, `sessions`, or `all`. |
| `pinned` | Takes a slot on the strip. |

Limits: 40 shortcuts, 20 session matches per shortcut.

### Targets

**A shortcut may target a session that is not on screen.** That is the point
of the feature. The rules:

| `to` | Means | Insert | Send |
| --- | --- | --- | --- |
| `current` | The pane on screen | Yes | Thread: the thread text route. Home: a maestro turn. |
| `maestro` | The maestro pane, from any page | No | `POST /api/manager/text` |
| `sessions` | Each `{host, session, window?}` in `match` | No | The thread text route, once per pane |
| `all` | Every listed thread that has a chat (`Thread.chat`) | No | The same |

- `all` reaches agents on this Mac only. `chat` is true only for a local pane
  with an agent session id (`MobileThread.hasChat`, `MobileAPI.swift:750`).
  The Mac cannot tell which panes on another host run an agent. Name those
  sessions in a `sessions` target.
- Insert needs a box on screen, so insert works only with `current`.
- A match stores names, not thread ids. A thread id is `host:pane number`
  (`MobileAPI.threadID`), and tmux gives new pane numbers after a restart.
- The phone resolves a match against the live thread list when the shortcut
  runs. No `window` means every chat pane of the session.
- The editor picks targets from the live list. Nothing is typed.
- Text only. No key press goes to a pane that is not on screen: a key can
  answer a prompt the human has not read.

### Three ways to run one

1. Tap its glyph on the strip (pinned only).
2. Tap its row in the sheet.
3. Type `/` in a text box. Shortcuts are listed first in the slash list, then
   the agent's commands. A pick runs the shortcut.

Typing `/name` and pressing Send, without a pick, sends the text as typed. A
shortcut never runs from typed text alone, so a name that matches an agent
command hides nothing.

Long-press a shortcut (strip or sheet) to edit it. `longpress.ts` exists.

### The editor

Labels only: Name, Text, Send, To, Pin, Glyph, Delete. A target other than
`current` turns Send on and locks it.

## Storage and sync

- The Mac keeps one JSON value under the `UserDefaults` key `phone.shortcuts`:
  `{ "rev": 7, "shortcuts": [...] }`. `Settings.swift` gets a typed getter and
  setter with the injectable `defaults` parameter the other keys use.
- Not the manager DB. That store belongs to the agent's hooks and the `mux`
  CLI. Nothing there is a user setting.
- New routes, in a new pure file `app/MuxMaestro/MobileShortcuts.swift`:
  - `GET /api/shortcuts` → `{ rev, shortcuts }`
  - `PUT /api/shortcuts` with `{ rev, shortcuts }` → `{ rev }`, or `409 stale`
    when `rev` is old. The phone then loads the list again.
- A new `shortcuts` event on `/api/events`, sent in the first burst and after
  each save. The other phones update from it.
- Capability: `replies`. With it off, the strip shows keys and no shortcuts.
  No new switch in Settings.
- The phone caches the list in `localStorage`, as `manager.svelte.ts` caches
  the board, so the strip draws at once.

**When the Mac app restarts:** the list is read from `UserDefaults` on launch.
The phone's event stream reconnects and gets the `shortcuts` event. Until then
the phone shows its cache. Runs and edits fail with "Not available", as every
write does without the Mac.

**When tmux restarts:** thread ids change. Shortcuts hold names, so they
resolve again. A session that is gone gives a `Closed` row.

**When a session is renamed:** its matches stop resolving and show `Closed`
in the editor. The owner picks the target again. v1 does not rewrite matches.

## Routing and the report

A run with one target behaves as a typed send does today. The outcome goes to
the note line that the page already has.

A run with several targets:

1. The phone resolves the targets from the live list.
2. The sheet stays open and shows one row per target: session, window, status.
3. One button, `Send to 5`. This is the one confirmation. It exists because the
   run hands work to several agents.
4. The phone posts to `/api/threads/<id>/text`, one target after the other.
5. Each row turns into its outcome.

| Outcome | From | Label (exists in `reply.ts`) |
| --- | --- | --- |
| sent | 200 | Sent |
| busy | 409 `busy` | Busy |
| waiting | 409 `waiting` | Waiting on a prompt |
| no_input | 409 `no_input` | No input box |
| not_sent | 409 `not_sent` | Not sent |
| not_found | no match, or 404 | Closed |
| unavailable | 503, or no network | Not available |
| disabled | 403 | Off on the Mac |

- A row links to its thread.
- Nothing is retried on its own. `Retry 2` sends again to the rows that failed.
- Nothing is undone. Text that reached a pane stays there.
- If the Mac goes away mid-run, the rows left become `Not available`.
- The maestro agent is not told. Its context stays clear.

Expected time: at least 0.3 s per target, more for a pane on another host.
Measure with 6 targets before any work on parallel sends.

## Backend work that does not exist yet

Four items. Each needs its own spec. None is part of the UI phases.

1. **Text to a busy pane.** Today the Mac refuses it. When the fleet is at
   work, most agents are mid-turn, so a fan-out reaches only the idle ones and
   reports `Busy` for the rest. `tasks/mobile-send-during-turns.md` (queued
   item 6, not built) is the fix: deliver the text and let the agent queue it.
   A queue on the Mac ("send when idle") is the other way. It is not
   recommended: text that arrives minutes late can land in a changed context.
2. **A runner on the Mac.** `POST /api/shortcuts/<id>/run` would resolve
   targets on the Mac, send, and stream one result per target. The phone could
   sleep mid-run, and voice, the Mac app and the agent could all use it. Until
   it exists, the phone does the fan-out and must stay connected.
3. **Routing by the maestro agent.** The brain-dump half of the goal: say it
   once, and the maestro sends each request to the right session. The `mux`
   CLI has no `send` verb. `AGENT.md` permits only benign nudges, through raw
   tmux, with none of the checks in `MobileReply.send` and no record. This
   needs a `mux send` that goes through the app, a channel from the CLI to the
   app, a result the agent can read, and a new rule in `AGENT.md` on what the
   agent may type into the human's sessions. It is the largest item, and it is
   a policy change, not only code.
4. **Spoken shortcuts.** Say a name, and the shortcut runs. The Mac turns
   speech into text (`MobileVoice.swift`), so the Mac must match the name.
   It depends on item 2.

Without these, the feature still does this: one tap on the maestro screen
sends a stored text to any idle session, or to all of them, and shows what
happened to each.

## Frozen files

Do not edit `ThreadView.svelte`, `Composer.svelte`, `voice.svelte.ts` or
`VoiceBar.svelte` for this work. PR #20 and PR #27 rewrite them, and
`tasks/mobile-queued-behind-20.md` holds six changes behind that.

**v1 needs no edit in them.** This is how:

- `KeyBar` keeps its props, so both mounts in `ThreadView.svelte` stay as
  they are.
- The slash list reads `reply.matches` and calls `reply.pick`. Both are in
  `reply.svelte.ts`. Shortcuts join there.
- The sheet mounts once in `+layout.svelte`, beside `ActionSheet`.
- An insert writes `reply.draft` or `manager.draft`. `Composer` already binds
  them.

Changes that do land in those files. They join the queued pass:

| Change | File |
| --- | --- |
| Give back the 38pt row: keys into the voice controls row | `VoiceBar.svelte`, `ThreadView.svelte` |
| Text to a busy pane (queued item 6) | `Composer.svelte` |
| Spoken shortcuts | `voice.svelte.ts` |

Other collisions, in files that are not frozen:

- PR #20 also edits `KeyBar.svelte`, `reply.ts`, `reply.svelte.ts`, `api.ts`,
  `Icon.svelte`, `manager.svelte.ts`, `+layout.svelte` and `+page.svelte`.
  Start after #20 merges, or expect a merge in each.
- PR #27 moves the maestro's strip and text box into `MaestroInput.svelte`.
  If it merges first, the slash list for the maestro goes there and not in
  `+page.svelte`.

## Files

New:

- `mobile/src/lib/shortcuts.ts`: types, checks, slot count, target
  resolution, outcome labels. Pure. `shortcuts.test.ts` beside it.
- `mobile/src/lib/shortcuts.svelte.ts`: the store. Cache, load, save, run.
- `mobile/src/lib/ShortcutSheet.svelte`: the list, the result rows.
- `mobile/src/lib/ShortcutEditor.svelte`
- `mobile/e2e/shortcuts.spec.ts`
- `app/MuxMaestro/MobileShortcuts.swift`, `tests/MobileShortcutsTests.swift`.
  Both go into `project.pbxproj` by hand, with unique ids.

Changed:

- `reply.ts`: `BarKey.glyph`, key order, `Command.source` gains `shortcut`.
- `KeyBar.svelte`: slots, glyphs, pinned shortcuts, the overflow key.
- `reply.svelte.ts`, `liveterm.svelte.ts`: `KeySink` gains insert and send.
- `manager.svelte.ts`, `+page.svelte`: the same for the maestro, and its
  slash list.
- `api.ts`, `live.svelte.ts`, `types.ts`: the routes and the event.
- `+layout.svelte`: mount the sheet.
- `MobileAPI.swift`, `MobileServer.swift`, `Settings.swift`: routes,
  capability rule, the event, the stored value.
- `mobile/e2e/fixture-server.mjs`, and the specs that name key labels
  (`reply.spec.ts`, `manager.spec.ts`).

Svelte 5 with no `$effect`: the slot count is an attachment that measures the
strip, and the rest is `$derived`.

## Phases

| Phase | Ships | Mac change |
| --- | --- | --- |
| 1 | The compact strip: glyphs, fixed slots, the overflow sheet with the other keys | None |
| 2 | Shortcuts for `current` and `maestro`: store, editor, slash list | Storage, two routes, one event |
| 3 | `sessions` and `all`: fan-out from the phone, result rows | None |

Each phase is one PR. Each needs `pnpm test`, the Playwright spec for its
flow at 375x667 and 430x932, a before and after screenshot with demo data,
and for phase 2 `make test` and `make app`.

## Open questions

1. **Is the problem the row's height or its width?** This spec fixes the
   width and keeps the 38pt row. Giving the row back needs the frozen files.
2. **Direct or through the maestro?** These shortcuts go straight to panes.
   Is routing by the maestro agent (backend item 3) wanted too, and may the
   agent then type real work into the human's sessions?
3. **Fan-out to busy sessions.** Skip them and report `Busy`, as specified
   here? Or wait for send-during-turn so the agents queue the text?
4. Is the one `Send to 5` confirmation right, or should a fan-out run on the
   first tap?
5. Which 5 keys keep fixed slots? The spec assumes `⎋ ⌃C ↑ ↓ ⏎`.
6. Should a session rename rewrite the matches that name it?
7. Should the Mac app show or edit the list?
