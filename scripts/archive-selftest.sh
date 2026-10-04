#!/usr/bin/env bash
#
# archive-selftest.sh — Archive Window and its undo, end to end in the real app,
# against an ISOLATED tmux server and an isolated home directory.
#
# The app archives a fixture window, undoes it through Edit > Undo, checks the
# window is back with its panes and its row selected, then redoes it.
#
# Isolation: `TMUX_TMPDIR` puts tmux on a private socket, and `CFFIXED_USER_HOME`
# gives the app empty settings, so it shows only the fixture and never writes the
# real recovery snapshot. The phone arguments keep it away from a live phone link.
#
# Usage:  scripts/archive-selftest.sh [directory for PNGs]
# Requires: a built build/Release/MuxMaestro.app (`make app`) and tmux.

set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Release/MuxMaestro.app/Contents/MacOS/MuxMaestro"
[ -x "$APP" ] || { echo "missing $APP — run 'make app' first"; exit 1; }

# $TMUX names a socket directly and OVERRIDES $TMUX_TMPDIR: unset it, or a run
# from inside a tmux pane would aim at the live server.
unset TMUX TMUX_PANE
TMUX_TMPDIR=$(mktemp -d /tmp/muxmaestro-archive-selftest.XXXXXX)
export TMUX_TMPDIR

SOCKET=$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)
case "${SOCKET:-$TMUX_TMPDIR/x}" in
    "$TMUX_TMPDIR"/*) ;;
    *) echo "refusing to run: tmux resolves to $SOCKET, not $TMUX_TMPDIR"; exit 1 ;;
esac

cleanup() {
    # Socket-scoped, so this can only ever reach the scratch server.
    tmux -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
    rm -rf "$TMUX_TMPDIR"
}
trap cleanup EXIT

# --- Fixture: one session, three windows, `api` with two panes ---------------
FIXTURE="$TMUX_TMPDIR/me"
mkdir -p "$FIXTURE"/acme-app/web "$FIXTURE"/home
tmux -f /dev/null new-session -d -s "acme-app" -c "$FIXTURE/acme-app"
tmux rename-window -t "=acme-app:" "shell"
tmux new-window -a -t "acme-app:" -c "$FIXTURE/acme-app"
tmux rename-window -t "=acme-app:" "api"
tmux split-window -v -t "=acme-app:" -c "$FIXTURE/acme-app/web"
tmux new-window -a -t "acme-app:" -c "$FIXTURE/acme-app"
tmux rename-window -t "=acme-app:" "tests"

SHOTS="${1:-}"
[ -z "$SHOTS" ] || mkdir -p "$SHOTS"

set +e
CFFIXED_USER_HOME="$FIXTURE/home" SIDEKICK_ARCHIVE_SELFTEST=1 SIDEKICK_ARCHIVE_SHOTS="$SHOTS" \
    "$APP" -phone.enabled NO -phone.port 7499 2>/dev/null
status=$?
set -e
exit $status
