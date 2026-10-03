# Vendored helper scripts

A **vendored copy** of the scripts MuxMaestro runs, so a shared build works on a
Mac without the author's setup. On first use the app copies this folder
to `~/Library/Application Support/MuxMaestro/tools/` (`BundledTools.swift`) and
runs the scripts from there. For a remote host it pushes `sessions.py` to
`~/.muxmaestro/tools/` over ssh.

| File | Used by |
|---|---|
| `sessions.py` | Attention status, local and remote |
| `spindown.py` | Worktree cleanup after a close |
| `spin.py` | `mux spin` / Start work |

All vendored from upstream.

## Keeping in sync

    make vendor-tools TOOLS_SRC=/path/to/upstream

Maintainer-only. The copies are verbatim. Re-run after changing an upstream
script so the two don't drift.

To add a tool: put the file here, add a `BundledTool` case, and add it to the
`vendor-tools` target. Callers use `BundledTools.path(.<case>)`.

## Checked on a bare Mac

    make tools-selftest

Runs each script with an empty temp HOME and `PATH=/usr/bin:/bin` — no
`~/.claude`, no ports file, no remote host, and no tmux, docker, gh or
treehouse on PATH.

## Runtime dependencies (not bundled)

`python3` 3.9 or later (the Command Line Tools copy is enough). `sessions.py`
uses `tmux` to map sessions to panes. `spindown.py` uses `git`, and `docker`,
`supabase`, `treehouse` and `gh` only when they are present. `spin.py` needs
`git` and `treehouse` on PATH, plus `tmux` to open the agent's window; without
tmux it prints the command to run by hand.
