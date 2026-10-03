#!/bin/sh
# record-agent-session.sh — MuxMaestro exact session recovery.
#
# Installed as a SessionStart hook for Claude Code (~/.claude/settings.json) and
# Codex (~/.codex/hooks.json), both of which pass the same JSON on stdin:
#
#   {"session_id":"<uuid>","cwd":"/path","hook_event_name":"SessionStart",…}
#
# It records that session id against the tmux pane it is running in, so after a
# reboot MuxMaestro can rebuild the tmux tree and stage `claude --resume <id>` /
# `codex resume <id>` in the right pane — a join on pane id, not a guess.
#
# $1 is the agent name ("claude" or "codex"), supplied by the installer.
#
# This runs on every session start, so it must never break one: no dependency
# beyond /bin/sh + sed, and every failure path exits 0 silently.

set -u

agent="${1:-claude}"

# Not under tmux (a bare terminal, a CI run, an SSH shell) — nothing to record.
[ -n "${TMUX_PANE:-}" ] || exit 0

payload=$(cat 2>/dev/null) || exit 0

# The two fields are a UUID and a filesystem path — no embedded quotes in
# practice, so a first-match sed extraction is enough and keeps this dependency
# free. A field that doesn't match yields an empty string and aborts the record.
field() {
    printf '%s' "$payload" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

session_id=$(field session_id)
cwd=$(field cwd)

[ -n "$session_id" ] && [ -n "$cwd" ] || exit 0

dir="$HOME/Library/Application Support/MuxMaestro/recovery"
mkdir -p "$dir" 2>/dev/null || exit 0

# One line per session start, appended. MuxMaestro reads the file back with
# "last line wins per pane", so a pane reused by a second session resolves to
# the newer one and no close event is needed.
printf '{"pane":"%s","agent":"%s","sessionId":"%s","cwd":"%s","at":"%s"}\n' \
    "$TMUX_PANE" "$agent" "$session_id" "$cwd" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    >> "$dir/agents.jsonl" 2>/dev/null

exit 0
