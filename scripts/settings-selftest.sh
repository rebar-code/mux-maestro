#!/usr/bin/env bash
#
# settings-selftest.sh — the Settings window end to end in the real app: open
# it from the menu, pick Codex and a model, edit and save the Maestro's
# instructions, restart the Maestro, then read the pane the restart made.
#
# Isolation: the app runs as a copy with its own bundle id, so no setting it
# stores reaches the real defaults domain. `TMUX_TMPDIR` puts tmux on a private
# socket, and `HOME` / `CFFIXED_USER_HOME` point at a scratch home. `claude` and
# `codex` are stubs that print their arguments: no agent is started.
#
# Usage:  scripts/settings-selftest.sh [directory for PNGs]
# Needs:  make app
set -euo pipefail

cd "$(dirname "$0")/.."

BUILT="build/Release/MuxMaestro.app"
[ -d "$BUILT" ] || { echo "missing $BUILT — run 'make app' first"; exit 1; }
TMUX_BIN=$(command -v tmux) || { echo "no tmux on this machine"; exit 1; }

# $TMUX names a socket directly and OVERRIDES $TMUX_TMPDIR: unset it, or a run
# from inside a tmux pane would aim at the live server.
unset TMUX TMUX_PANE
SCRATCH=$(mktemp -d /tmp/muxmaestro-settings-selftest.XXXXXX)
BUNDLE_ID="demo.muxmaestro.settings-selftest"
export TMUX_TMPDIR="$SCRATCH"

cleanup() {
    # Socket-scoped, so this can only ever reach the scratch server.
    "$TMUX_BIN" -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$SCRATCH/home" "$SCRATCH/bin" "$SCRATCH/acme-app"
for agent in claude codex; do
    printf '#!/bin/sh\necho "stub: %s $*"\nexec sleep 600\n' "$agent" > "$SCRATCH/bin/$agent"
    chmod +x "$SCRATCH/bin/$agent"
done

cp -R "$BUILT" "$SCRATCH/MuxMaestro.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$SCRATCH/MuxMaestro.app/Contents/Info.plist"
codesign --force --deep --sign - --preserve-metadata=entitlements "$SCRATCH/MuxMaestro.app" 2>/dev/null
defaults write "$BUNDLE_ID" migratedLegacyDefaults -bool YES

# The pane runs the agent through a login shell. `sh` with a scratch home reads
# no profile of the user's, and the stubs sit ahead of everything else.
export HOME="$SCRATCH/home" SHELL=/bin/sh
export PATH="$SCRATCH/bin:$(dirname "$TMUX_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
"$TMUX_BIN" -f /dev/null new-session -d -s "acme-app" -c "$SCRATCH/acme-app"
SOCKET=$("$TMUX_BIN" display-message -p '#{socket_path}')
case "$SOCKET" in
    "$TMUX_TMPDIR"/*|/private"$TMUX_TMPDIR"/*) ;;
    *) echo "refusing to run: tmux resolves to $SOCKET, not $TMUX_TMPDIR"; exit 1 ;;
esac

SHOTS="${1:-}"
[ -z "$SHOTS" ] || { mkdir -p "$SHOTS"; SHOTS=$(cd "$SHOTS" && pwd); }

set +e
CFFIXED_USER_HOME="$HOME" MUXMAESTRO_SETTINGS_SELFTEST=1 MUXMAESTRO_SETTINGS_SHOTS="$SHOTS" \
    "$SCRATCH/MuxMaestro.app/Contents/MacOS/MuxMaestro" -phone.enabled NO -phone.port 7499 2>/dev/null
status=$?
set -e

START=$("$TMUX_BIN" list-panes -s -t "=mux-manager" -F '#{pane_start_command}' 2>/dev/null | head -1)
SCREEN=$("$TMUX_BIN" capture-pane -p -t "=mux-manager:" 2>/dev/null | grep -m1 'stub:' || true)
echo "  pane start command: $START"
echo "  pane screen:        $SCREEN"
case "$START" in
    *"exec codex --model"*"gpt-5.5"*) echo "  PASS  the restarted Maestro was launched as codex with the model" ;;
    *) echo "  FAIL  the restarted Maestro was not launched as codex with the model"; status=1 ;;
esac
[ "$SCREEN" = "stub: codex --model gpt-5.5" ] \
    && echo "  PASS  codex received --model gpt-5.5" \
    || { echo "  FAIL  codex did not receive --model gpt-5.5"; status=1; }
exit $status
