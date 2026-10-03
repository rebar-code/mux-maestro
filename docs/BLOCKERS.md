# Blockers & documented deferrals

Things that are intentionally not done (with the reason) or that cannot be
verified in this environment. Kept honest so nothing is silently half-finished.

## Input completeness — keyboard dead keys / IME + full modifier side-detection (M5, deferred)

**Status: deferred (known input debt), not done.**

The carry-over fix asked to route `keyDown` through
`NSTextInputClient` / `interpretKeyEvents(_:)` so dead keys (e.g. `⌥e` then `e`
→ `é`) and IME composition (CJK, etc.) work, and to port Ghostty's full
modifier **press/release side-detection** in `flagsChanged`.

What exists today (`TerminalSurfaceView.swift` + `Ghostty+Input.swift`):

- `keyDown`/`keyUp` forward `keycode`, `mods`, `unshifted_codepoint`, and the
  typed `characters` (control chars + function-key PUA filtered) straight to
  `ghostty_surface_key`. This handles direct typing, Enter, Ctrl-C, arrows, etc.
- `GhosttyInput.mods` already maps the sided-modifier device masks
  (`NX_DEVICER*KEYMASK`) so left/right modifiers are distinguished in the mods
  bitfield.
- `flagsChanged` always sends `GHOSTTY_ACTION_PRESS`; it does **not** diff the
  previous flag state to emit a true PRESS vs RELEASE per physical side.

Why deferred (per the M5 brief's explicit guidance to defer rather than
half-do): a correct IME path means adopting `NSTextInputClient` (marked-text
range, `setMarkedText`, `unmarkText`, `firstRect(forCharacterRange:)`,
`hasMarkedText`) and tracking `composing` state into the libghostty key event —
this is a sizable, subtle change. It cannot be pixel-verified in this
environment (screenshots are TCC-blocked here), and IME/dead-key correctness is
exactly the kind of thing that needs visual confirmation. Shipping a
half-working IME path is worse than the current direct path, so it is left as
documented debt.

**To finish later:** mirror Ghostty's `macos/Sources/Ghostty/SurfaceView_AppKit.swift`
`keyDown` → `interpretKeyEvents` → `insertText`/`setMarkedText` flow and its
`flagsChanged` side-detection (compare `event.modifierFlags` against the prior
snapshot to emit per-side PRESS/RELEASE), then verify with a dead-key sequence
and a CJK IME on a machine with screen access.

## M8 remote hosts — SSH auth must be non-interactive (caveat, not a defect)

Remote hosts are reached with `-o BatchMode=yes` so a missing key / passphrase
prompt can never hang the polling subprocess. Consequence: a host whose SSH key
needs interactive entry (a passphrase prompt, a Touch-ID / 1Password-agent
confirmation that isn't already authorized) will probe as **unreachable** rather
than prompting. This is intentional — blocking the UI on an interactive prompt
is worse. The fix for the user is the normal one: load the key into the agent
(`ssh-add`, or authorize the 1Password SSH agent) once; the persistent
ControlMaster connection then keeps it warm. Verified live: with the agent
authorized, `buildbox` lists its full remote tree; `host3` (genuinely offline)
correctly shows unreachable.

Tilde expansion of a remote new-session directory relies on the remote login
shell (ssh joins the argv and re-parses it through the shell), so `~` and
`~/sub` expand on the remote. A path that needs shell *globbing* beyond tilde is
out of scope — type an explicit path.

## M7 timeout test (`testProcessCommandRunnerTimesOutAndReapsChild`) — host flake

This M5/M7 test asserts a hung child is reaped by running
`pgrep -f "sleep 10"` and expecting no match. On a box that *independently* runs
a `sleep 10` (e.g. a `~/tools-proto` session-status monitor loop, which polls
with `sleep 10` between iterations) the pgrep matches that unrelated process and
the test reports a false failure. `ProcessCommandRunner` is byte-identical to
`origin/feat/m7-polish` (M8 did not touch it); the test passes when no unrelated
`sleep 10` is running, and the rest of the suite (82/82) is green regardless.
Same class of host-state flake as the M2 self-test caveat in `STATUS.md`. A
durable fix (out of M8 scope) would tag the test's child with a unique sentinel
arg and `pgrep` for that instead of the generic `sleep 10`.

## CI verification on the private repo

`.github/workflows/ci.yml` runs on `macos-14`, builds/caches
`GhosttyKit.xcframework` (keyed on the pinned Ghostty SHA + Zig version), then
runs `make app` and `make test`. The first run on a cold cache compiles
libghostty from source (a multi-minute Zig build) and may run long; subsequent
runs restore the cached xcframework.

If CI cannot run in this environment — e.g. the private repo has no available
macOS Actions minutes / no self-hosted macOS runner, or hits an org policy /
spending limit — that is the blocker, not a workflow defect. The workflow is
validated for syntax and logic locally; the same `make app` + `make test` it
runs are confirmed green on this machine (`make test` → 49 tests, 0 failures;
`make app` → BUILD SUCCEEDED). See the PR thread for the live CI run status.
