# MuxMaestro — project instructions

## This repository is public

Everything committed here is published: code, comments, test fixtures, commit
messages, branch names, PR text and screenshots.

- No personal names, host names, tailnet names, `/Users/<name>` paths or private
  repo names. Use neutral demo data: `devbox`, `acme-app`, `/Users/me`,
  `example.ts.net`.
- No planning notes or dev diaries in commits. Keep `tasks/` and `STATUS.md`
  local and untracked.
- No keys or tokens, including in fixtures. Secrets belong in the Keychain.
- Screenshots use demo data, not real sessions.

## Build

- `make test` runs the unit tests. The test target does not compile the AppKit
  files (`SidebarViewController`, `AppDelegate`, ...), so a change there also
  needs `make app`.
- `make app` needs `GhosttyKit.xcframework` in the repo root. It is gitignored.
  `make libghostty` builds it from pinned source and takes many minutes; run it
  once per machine. In a new worktree, symlink the framework from a checkout
  that already has it instead of rebuilding.
- The phone web app's bundle (`app/MuxMaestro/Resources/mobile/`) is gitignored.
  `make app` and `make test` build it from `mobile/` when a source changed
  (`make mobile` does only that); it needs node and pnpm. Never commit it. A
  build from the Xcode GUI needs `make mobile` first.
- New source files go into `MuxMaestro.xcodeproj/project.pbxproj` by hand. Give
  them unique IDs and grep for duplicates: a duplicate ID silently drops a file
  from the build ("cannot find X in scope").

## Always verify we're running the newest build

Before diagnosing **any** runtime issue (hang, crash, stale UI, "feature doesn't
work"), confirm which binary is actually running and how old it is. There are
two app copies that drift apart:

- `build/Release/MuxMaestro.app` — what `make app` / `make run` produce
- `/Applications/MuxMaestro.app` — whatever was last copied there

They are frequently different builds, and the running process is often the older
one. Check before anything else:

```sh
ps -Ao pid,lstart,command | grep -i '[M]uxMaestro'          # which binary is live
ls -l build/Release/MuxMaestro.app/Contents/MacOS/MuxMaestro # its build time
ls -l /Applications/MuxMaestro.app/Contents/MacOS/MuxMaestro
git log --oneline --since="<that build time>" --no-merges    # what's missing from it
```

`make install` is the one-step fix: it rebuilds, quits a running instance, copies
over `/Applications/MuxMaestro.app`, and relaunches. Use it instead of copying by
hand. `make app` alone does **not** touch `/Applications`, so a plain relaunch
from the Dock keeps running the old build.

If the running build predates commits on `main`, rebuild and retest **before**
investigating further, and say so explicitly rather than debugging a stale
binary. `CFBundleShortVersionString` is pinned at `0.1.0`, so the binary's mtime
plus `git log` is the only real version signal.

Corollary: don't assume a bug is unfixed just because it reproduced. Check whether
a fix already landed and simply isn't in the running binary. And don't assume it
*is* fixed either — confirm the fix is actually in the source at HEAD.

## Bug reports

Reproduce with a failing test first, trace the real execution path, and never
report a fix as verified on a plausible-looking patch that wasn't observed to
change behavior. Hang/crash reports (spindumps) are strong evidence of
*symptoms* — read the actual thread stacks rather than pattern-matching the
report header to a subsystem you already suspect.
