# Vendored `beam` scripts

These are a **vendored copy** of the `beam` work-session transporter so the
"Beam to server" feature ships *inside* `MuxMaestro.app` — a shared build has no
external dependency.

- `beam.sh` — two-way repo + Claude/Codex history sync with path rewriting, and
  the `takeover` handoff that respawns a tmux pane into the resumed remote session.
- `beam_merge.py` — the python3-stdlib merge engine (idempotent hybrid-union DAG
  merge of Claude transcripts; Codex prefix/fork merge; manifest I/O).
- `beam-selftest.sh` — no-SSH end-to-end self-test against a fake local "remote".

## Provenance / keeping in sync

Vendored from upstream `beam{.sh,_merge.py,-selftest.sh}`.

Maintainers refresh the vendored copy from an upstream checkout:

    make vendor-beam BEAM_SRC=/path/to/upstream/beam

This is a fork by design (it must travel with the app). Re-run `make vendor-beam`
after changing upstream so the two don't drift.

## Runtime dependencies (on the user's Mac — not bundled)

`bash`, `python3`, `rsync`, `git`, `ssh`. `gum` is optional (its TUIs are skipped
via `BEAM_OPTS`/`BEAM_CONFLICT`). `sha256sum`/`shasum` — the script falls back
between them. The app surfaces a friendly error if `python3`/`rsync` are missing.
