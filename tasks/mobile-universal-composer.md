# Universal composer: audit and spec

Requirement (2026-10-04): the bottom input section is one thing, the same on
every screen. A maestro-only difference needs approval first.

Audited at `main` `845f951`. All line numbers are from that commit.
No feature code is in this change.

## Short answer

The composer is **not** nearly universal. The text box itself
(`Composer.svelte`) is shared. Everything around it is built twice:

- a thread draws its bottom section in `mobile/src/lib/ThreadView.svelte:475-550` (`.dock`)
- the maestro screen draws its own in `mobile/src/routes/+page.svelte:166-208` (`.foot`)

`ThreadView.svelte:190` switches the thread dock off for the maestro on
purpose: `const docked = $derived(listed && !closed);`. The comment at
`:187-189` says "its page brings its own box". Each feature added to the dock
after that went to threads only. That is the cause of most of the 17 divergences
below.

## Task 1: why the attach button is missing on the maestro screen

The hypothesis is half right. `listed` is the cause, but not through
`artifactsOn`, `serversOn` or a `can(...)` gate on the button.

Three layers, top to bottom:

1. **The page never passes the control.** `AttachButton` and `AttachTiles` are
   not inside `Composer`. They are snippets the caller passes:
   `ThreadView.svelte:524-529` (`above`, `leading`). The maestro page renders
   its own `<Composer>` at `+page.svelte:195-207` and passes neither. The
   thread's copy is unreachable because `docked` is false
   (`ThreadView.svelte:190`, `:475`).
2. **The upload client is thread-only.** `uploadFile` posts to
   `${threadPath(id)}/upload` (`api.ts:352-362`). `Attachments` takes a thread
   id (`attach.svelte.ts:43-46`, `:100-101`). `reply.svelte.ts:60-62` says
   "text, commands and files are a thread's only".
3. **The Mac has no maestro upload route.** `MobileAPI.swift:439-448` lists the
   manager routes: `text`, `dismiss`, `chat`, `screen`, `prompt`, `answer`,
   `key`. Upload exists only as `/api/threads/<id>/upload`
   (`MobileAPI.swift:93`, `:466`). `POST /api/manager/upload` falls to
   `default: return .notFound` (`MobileAPI.swift:491`).

`can('upload')` is not the cause. It only dims the button on a thread
(`ThreadView.svelte:528`).

So passing the button on the maestro page is not enough. It needs layers 2 and
3 too. The Mac side is small: `MobileReply.upload` (`MobileReply.swift:830`)
saves into the pane's `cwd` and returns the path. The maestro pane has a `cwd`
like any pane.

## Task 2: every divergence in the bottom section

"Thread" is `ThreadView.svelte`. "Maestro" is `routes/+page.svelte`.

| # | What differs | Thread | Maestro | Condition | Deliberate? | Recommendation |
|---|---|---|---|---|---|---|
| 1 | Attach button and file tiles | `:524-529` | none (`:195-207`) | `docked` false; no client; no Mac route (Task 1) | Accidental. Added for threads in `b405fc3`, never for the maestro | **unify** |
| 2 | Paste an image into the box | `:522` `onpaste={reply.pasted}` | none | same as 1 | Accidental | **unify** (comes with 1) |
| 3 | Slash command list | `:487-489`, `:520` `oninput={reply.typed}` | none | `fetchCommands` is thread-only (`api.ts:315`); no `/api/manager/commands` on the Mac | Accidental | **unify** |
| 4 | Key strip: `/ ~ \| -` and sticky `Ctrl` | `:498` `composer={repliesOn}` | `:191` `composer={false}` | `barKeys(false)` drops every key without `send` (`reply.ts:46-48`). The maestro box is not bound to `reply.box` or `reply.beforeInput`, so those keys have nothing to type into | Deliberate workaround for divergence 9 | **unify** |
| 5 | Voice bar layout | status line above the keys, controls below (`:495-507`) | one bar below the keys (`:192`) | thread regrouped in `6890597`; the maestro page was not | Accidental drift | **unify** |
| 6 | Status line: place and wording | inside the composer, `note={reply.note}` (`:518`). Short labels: `Too long`, `No answer` (`reply.ts:185-201`). Typing clears it (`reply.svelte.ts:212-213`) | send result in the chat tail (`:109-123`); key result in a `NoteLine` above the keys (`:190`). Sentences: `The message is too long`, `The Mac did not answer` (`manager.svelte.ts:314-320`). Typing does not clear it | two owners: `Reply.note` and `manager.note` | Accidental | **unify** |
| 7 | When Send is disabled | pane busy, waiting, or a prompt card is up, or a file is uploading (`:516`, `reply.svelte.ts:147-150`) | only while a turn is in flight (`:202`, `manager.svelte.ts:114`). With the pane `waiting`, Send is live and the Mac refuses | two `blocked` rules | Accidental | **unify** |
| 8 | Send transport, busy mark, draft timing | one short `POST …/text`; the box keeps the text until the Mac takes it (`reply.svelte.ts:185-205`) | one streamed turn, `POST /api/manager/text` as an event stream (`api.ts:491-495`). `sending` is true for the whole turn. The box empties at once; a refusal puts the text back (`manager.svelte.ts:268-284`, `:257`) | different Mac endpoints | Deliberate | **keep, needs approval**: the maestro answers on the same request, so the phone can follow its own turn. The visible parts (busy mark, draft timing) can still match the thread |
| 9 | Two draft stores | `Reply.draft`, key `thread:<id>` (`reply.svelte.ts:169`) | `manager.draft`, key `manager` (`manager.svelte.ts:25`, `:73-84`). The page's `Reply('manager')` (`:54-68`) also holds a draft and an `Attachments` that nothing uses | maestro text does not go through `Reply` | Accidental. Root of 4 | **unify** |
| 10 | Capability gates | box: `can('replies')` (`:183`). Voice: `repliesOn && can('voice')` (`:186`). Keys: `can('keyBar')` (`:184`) | box: `can('manager')` (`:24`, `:201`). Voice: `managerOn && can('voice')` (`:26`). Keys: `managerOn && can('keyBar')` (`:69`) | the Mac files every `/api/manager/*` path under `.manager` (`MobileAPI.swift:392`). With Replies off and Manager on, the maestro box still sends | Deliberate | **keep, needs approval**: Manager is its own switch in Mac Settings |
| 11 | Off state | box says `Off in MuxMaestro Settings`, a disabled attach button holds its place (`:531-547`) | box says the same, no attach button (`:195-207`) | follows from 1 | Accidental | **unify** |
| 12 | Placeholder | `Reply` (`:512`) | `Ask the manager` (`:27`) | literal strings | Deliberate | **keep, needs approval**: the label says which agent gets the text |
| 13 | Board grabber, drawer, focus lock | none | grabber in the footer (`:175-184`), `BoardSheet` (`:210`), `ui.lockSheet` on focus (`:205-206`), `touch-action: none` on the footer (`:312-315`) | `managerOn` | Deliberate | **keep, needs approval**: the board hangs off the footer. Queued item 1 moves the board into a tab; this divergence then goes away |
| 14 | "Next waiting thread" bar | `:191`, `:482` | none | `listed && repliesOn` | Deliberate fallout of `docked` | **keep, needs approval**: the maestro screen already shows what waits (header chip, board) |
| 15 | Live terminal replaces the composer with keys only | `:173`, `:483-485` | never | `liveOn` needs `listed`; `/api/terminal/<id>` takes a thread id (`MobileAPI.swift:484`) | Deliberate (comment at `:172`) | **keep, needs approval**: the maestro pane has no live terminal route. That is a Mac feature, not a composer change |
| 16 | With the keyboard up | the Next bar and an off voice bar hide (`:650`) | they stay | the rule is scoped to `.dock` | Accidental | **unify** |
| 17 | Two wrappers | `.dock` (`:475-550`) | `.foot` (`:166-208`) | `docked = listed && !closed` (`:190`) | Deliberate, and the root cause | **unify** |

**Count: 17.** Unify: 11. Keep, needs approval: 6 (numbers 8, 10, 12, 13, 14, 15).

### Checked, no divergence

- Send button and talk button: same `Composer.svelte:115-131`.
- Length limit: same. `limitLabel` in `Composer.svelte:77`; 8192 bytes
  (`compose.ts:2`); both senders check `bytesOver` (`reply.svelte.ts:184`,
  `manager.svelte.ts:271`); the Mac holds the same number
  (`MobileManager.swift:191`).
- Text box growth and the Enter rules: same `GrowingText.svelte`.
- Keys that go to the pane (`Esc`, `Tab`, arrows, `Ctrl+C`, `⏎`) and the
  hide-keyboard button: same.
- Prompt card: both draw it (`ThreadView.svelte:194`, `:385`).
- Draft survives a reload: both.

### Gated on `listed`, but not the bottom section

Listed so nothing is hidden. None is covered by this spec.

- Artifacts and Servers tabs: off (`ThreadView.svelte:80-81`). Mac routes are
  thread-only. Queued item 1 already changes the tab list.
- Find button: the maestro page replaces the header (`+page.svelte:78-99`), so
  the button at `ThreadView.svelte:260-266` is not drawn.
- `closed` state (`:96`) and push focus (`:318`): thread only.
- Thinking line and pane status: in the maestro chat tail (`+page.svelte:102-108`);
  a thread shows status in its header.

## Spec: one bottom section

1. **One component.** Move `ThreadView.svelte:475-550` into a new file,
   `mobile/src/lib/ReplyDock.svelte`. It takes a `Reply` and draws, in order:
   Next bar, slash list, voice status, key strip, voice controls, composer
   with attach. `ThreadView` and the maestro page both render it. The maestro
   page stops building its own footer.
2. **One owner of the text.** `Reply` owns the draft, the note, `blocked`, the
   files and the slash list for both screens. `ReplyTarget`
   (`reply.svelte.ts:63-72`) grows three members: send text, load commands,
   upload base. The maestro target sends through `manager.send`
   (divergence 8). `manager.draft` goes away.
3. **Mac.** Add `POST /api/manager/upload` and `GET /api/manager/commands`,
   each calling the same code the thread route calls, with the maestro pane.
4. **Approved differences become inputs**, not a second layout: the label
   (12), the gate (10), the grabber slot (13), the Next bar (14).

Rules that apply: no `$effect` (the dock already uses `{@attach}`; keep that).
No new copy. Reuse `OFF_LABEL`.

### Smallest change that gives the attach button alone

If the button must ship before the full pass: Mac route (step 3, upload
only); `uploadFile` and `Attachments` take a base path instead of a thread id;
the maestro footer passes `above` and `leading`, writes paths into
`manager.draft`, adds `files.pending` to `blocked`, and wires `onpaste`.
It fixes 1, 2 and 11. It does not touch a frozen file.

## Where each change lands

Frozen until PR #20 and PR #27 resolve: `ThreadView.svelte`, `Composer.svelte`,
`voice.svelte.ts`, `VoiceBar.svelte`.

| Change | Files | Frozen file? |
|---|---|---|
| 1, 2, 11 attach on the maestro | `MobileAPI.swift`, `MobileServer.swift`, `api.ts`, `attach.svelte.ts`, maestro footer | No |
| 3 slash list | `MobileAPI.swift`, `MobileServer.swift`, `api.ts`, `reply.svelte.ts`, maestro footer | No |
| 4, 6, 7, 9 one owner | `reply.svelte.ts`, `manager.svelte.ts`, maestro footer | No |
| 5 voice bar layout | maestro footer | No |
| 16 keyboard-up rule | `ThreadView.svelte:650` | **Yes** — joins the queued pass |
| 17 one component | `ThreadView.svelte:475-550` moves out; new `ReplyDock.svelte` | **Yes** — joins the queued pass |

Nothing lands in `Composer.svelte`, `voice.svelte.ts` or `VoiceBar.svelte`.

"Maestro footer" is `routes/+page.svelte` today. PR #27
(`feat/mobile-maestro-anywhere`) moves it into a new
`mobile/src/lib/MaestroInput.svelte` and renders it in two places. That file
is a second, maestro-only composer wrapper: the opposite of this requirement.
Decide before #27 merges whether `MaestroInput.svelte` becomes the shared
`ReplyDock` or is replaced by it.

Overlap with the queued pass (`tasks/mobile-queued-behind-20.md`):

- Item 1 (maestro content into a tab) removes divergence 13.
- Item 3 (icon-only Send) and item 6 (send during a turn) change
  `Composer.svelte` and `blocked`. Do 7 and 8 with item 6, once, for both
  screens.

## Decisions needed

Approve or reject each "keep":

- 8: maestro text stays one streamed turn.
- 10: the maestro box follows the Manager switch, not the Replies switch.
- 12: placeholder differs per screen.
- 13: board grabber stays in the footer until queued item 1 lands.
- 14: no Next bar on the maestro screen.
- 15: no live terminal on the maestro pane.
