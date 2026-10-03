#!/usr/bin/env bash
#
# recovery-selftest.sh — end-to-end proof of exact session recovery, against an
# ISOLATED tmux server. It builds a fixture tree, lets the app snapshot it, kills
# the server, rebuilds from disk, and diffs the result.
#
# Isolation is the whole point: the test kills every session it can see, so it
# must never run on the live tmux server. `TMUX_TMPDIR` moves the socket into a
# scratch directory, and tmux subprocesses inherit it from the app — so the app
# and the fixture agree on a private server while the real one is untouched.
#
# Usage:  scripts/recovery-selftest.sh
# Requires: a built build/Release/MuxMaestro.app (`make app`) and tmux.

set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Release/MuxMaestro.app/Contents/MacOS/MuxMaestro"
[ -x "$APP" ] || { echo "missing $APP — run 'make app' first"; exit 1; }

# $TMUX names a socket directly and OVERRIDES $TMUX_TMPDIR, so running this from
# inside a tmux pane would point every command below at the LIVE server — and the
# cleanup trap would then kill it. Unset it before anything else.
unset TMUX TMUX_PANE
TMUX_TMPDIR=$(mktemp -d /tmp/muxmaestro-recovery-selftest.XXXXXX)
export TMUX_TMPDIR

# Refuse to run unless tmux resolves to the scratch socket. Belt and braces: the
# check costs nothing and the failure mode it guards is destroying real work.
SOCKET=$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)
case "${SOCKET:-$TMUX_TMPDIR/x}" in
    "$TMUX_TMPDIR"/*) ;;
    *) echo "refusing to run: tmux resolves to $SOCKET, not $TMUX_TMPDIR"; exit 1 ;;
esac
FIXTURE=$(mktemp -d /tmp/muxmaestro-recovery-fixture.XXXXXX)
RECOVERY="$HOME/Library/Application Support/MuxMaestro/recovery"

cleanup() {
    # Socket-scoped, so this can only ever reach the scratch server.
    tmux -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
    rm -rf "$TMUX_TMPDIR" "$FIXTURE"
    # Leave the user's own snapshot as we found it.
    if [ -n "${SAVED_TREE:-}" ]; then mv "$SAVED_TREE" "$RECOVERY/tree.json"
    else rm -f "$RECOVERY/tree.json"; fi
    if [ -n "${SAVED_AGENTS:-}" ]; then mv "$SAVED_AGENTS" "$RECOVERY/agents.jsonl"
    else rm -f "$RECOVERY/agents.jsonl"; fi
}
trap cleanup EXIT

mkdir -p "$RECOVERY"
if [ -f "$RECOVERY/tree.json" ]; then
    SAVED_TREE="$RECOVERY/tree.json.selftest-backup"; mv "$RECOVERY/tree.json" "$SAVED_TREE"
fi
if [ -f "$RECOVERY/agents.jsonl" ]; then
    SAVED_AGENTS="$RECOVERY/agents.jsonl.selftest-backup"
    mv "$RECOVERY/agents.jsonl" "$SAVED_AGENTS"
fi

# --- Fixture: 2 sessions, 4 windows, each in its own directory -------------
mkdir -p "$FIXTURE"/{alpha,beta,gamma,delta}
tmux new-session  -d -s "selftest-alpha" -c "$FIXTURE/alpha"
tmux rename-window -t "=selftest-alpha:" "po-import"
tmux new-window   -a -t "selftest-alpha:" -c "$FIXTURE/beta"
tmux rename-window -t "=selftest-alpha:" "calendar"
tmux new-session  -d -s "selftest-beta" -c "$FIXTURE/gamma"
tmux rename-window -t "=selftest-beta:" "portal"
tmux new-window   -a -t "selftest-beta:" -c "$FIXTURE/delta"
tmux rename-window -t "=selftest-beta:" "scoping"

echo "fixture:"
tmux list-panes -a -F '  #{session_name}:#{window_index} #{window_name} #{pane_id} #{pane_current_path}'

# --- agents.jsonl: one record per fixture pane, as the hook would write it --
# Written through the real hook script so the SessionStart payload parsing is
# exercised, not just the reader.
HOOK=app/MuxMaestro/Resources/recovery/record-agent-session.sh
i=0
for pane in $(tmux list-panes -a -F '#{pane_id}'); do
    i=$((i + 1))
    cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}')
    agent=claude; [ $((i % 2)) -eq 0 ] && agent=codex
    printf '{"session_id":"selftest-%s","cwd":"%s","hook_event_name":"SessionStart"}' "$i" "$cwd" \
        | TMUX_PANE="$pane" sh "$HOOK" "$agent"
done
echo "agents.jsonl: $(wc -l < "$RECOVERY/agents.jsonl" | tr -d ' ') record(s)"

# --- Run the app's self-test against this server ---------------------------
set +e
SIDEKICK_RECOVERY_SELFTEST=1 "$APP" 2>&1 >/dev/null
status=$?
set -e
exit $status
