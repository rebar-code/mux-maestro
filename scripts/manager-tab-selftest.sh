#!/usr/bin/env bash
#
# manager-tab-selftest.sh — drives the REAL app through the Manager tab's whole
# life in the right sidebar: open it, show its terminal, hide it, re-show it,
# share the rail with Tree, Diff and Artifacts, flip the rail's layout, and
# collapse the whole sidebar. After every step the app checks that the
# `mux-manager` terminal is still the same live surface on the same tmux client
# with its scrollback, and at the end that the three voice callbacks still
# reach the tab. `make test` compiles none of this, and the harness in
# manager-rail-click-selftest.sh stubs the terminal out.
#
# Isolated three ways, so it never touches a real session or a real setting:
#   - `TMUX_TMPDIR` puts the app and the fixture on a scratch tmux server;
#   - `HOME` + `CFFIXED_USER_HOME` give the app a scratch home, so the manager's
#     database and the recovery snapshot land in the scratch dir;
#   - the app runs as a copy with its own bundle id. UserDefaults ignores the
#     scratch home (cfprefsd resolves the real one), so without this the run
#     writes the tab state and the window frame into the real app's settings.
# The `mux-manager` session is created here as a plain shell with 300 lines of
# known scrollback, so no agent is launched.
#
# Usage:  scripts/manager-tab-selftest.sh [shots-dir]     (default /tmp/manager-tab)
#         APP=/Applications/MuxMaestro.app scripts/manager-tab-selftest.sh
# Requires: a built app (`make app`) and tmux. The app window takes the
# foreground for about 25 seconds. The PNGs are rendered in-process, so they
# need no Screen Recording grant.

set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_APP=${APP:-build/Release/MuxMaestro.app}
[ -x "$SOURCE_APP/Contents/MacOS/MuxMaestro" ] || { echo "missing $SOURCE_APP — run 'make app' first"; exit 1; }
DOMAIN=is.rebar.MuxMaestro.manager-tab-selftest
SHOTS=${1:-/tmp/manager-tab}
mkdir -p "$SHOTS"

# $TMUX names a socket directly and OVERRIDES $TMUX_TMPDIR, so from inside a tmux
# pane every command below would reach the LIVE server. Unset it first.
unset TMUX TMUX_PANE
REAL_HOME=$HOME
# Resolved, because /tmp is a symlink and tmux reports the real socket path.
SCRATCH=$(cd "$(mktemp -d /tmp/manager-tab-demo.XXXXXX)" && pwd -P)
export TMUX_TMPDIR="$SCRATCH/tmux"
export HOME="$SCRATCH/home"
export CFFIXED_USER_HOME="$HOME"
SUPPORT="$HOME/Library/Application Support/MuxMaestro"
mkdir -p "$TMUX_TMPDIR" "$SUPPORT" "$HOME/.cache" "$SCRATCH/acme-app" "$SCRATCH/devbox-api"

cleanup() {
    # Socket-scoped, so this can only ever reach the scratch server.
    tmux -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# The copy under test: same build, its own defaults domain. Marked as already
# migrated, so it does not inherit the pre-rename app's settings either.
BIN="$SCRATCH/MuxMaestro.app/Contents/MacOS/MuxMaestro"
cp -Rc "$SOURCE_APP" "$SCRATCH/MuxMaestro.app" 2>/dev/null || cp -R "$SOURCE_APP" "$SCRATCH/MuxMaestro.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DOMAIN" "$SCRATCH/MuxMaestro.app/Contents/Info.plist"
codesign --force --sign - --preserve-metadata=entitlements "$SCRATCH/MuxMaestro.app" 2>/dev/null
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
defaults write "$DOMAIN" migratedLegacyDefaults -bool YES

# The voice models are a large download the app starts on launch. Lend it the
# real ones when they exist, so a scratch home does not fetch them again.
[ -d "$REAL_HOME/Library/Application Support/MuxMaestro/models" ] \
    && ln -s "$REAL_HOME/Library/Application Support/MuxMaestro/models" "$SUPPORT/models"
[ -d "$REAL_HOME/.cache/fluidaudio" ] && ln -s "$REAL_HOME/.cache/fluidaudio" "$HOME/.cache/fluidaudio"

# No host name in the status line: the screenshots are published.
printf 'set -g status-right ""\nset -g history-limit 5000\n' > "$HOME/.tmux.conf"

# --- Fixture: two demo sessions and the manager pane ------------------------
shell="exec env PS1='\$ ' /bin/sh"
tmux new-session -d -s acme-app -c "$SCRATCH/acme-app" "$shell"
SOCKET=$(tmux display-message -p '#{socket_path}')
case "$SOCKET" in
    "$TMUX_TMPDIR"/*) ;;
    *) echo "refusing to run: tmux resolves to $SOCKET, not $TMUX_TMPDIR"; exit 1 ;;
esac
tmux new-session -d -s devbox-api -c "$SCRATCH/devbox-api" "$shell"
tmux new-session -d -s mux-manager -c "$SCRATCH" "$shell"
tmux send-keys -t '=mux-manager:' \
    'i=1; while [ $i -le 300 ]; do echo "scrollback line $i"; i=$((i+1)); done' Enter

# --- Run the app's self-test against this server ---------------------------
# `-phone.*`: a launch with the phone link off removes the tailscale mapping for
# its port, and a fresh domain's default port is the real app's port.
MUXMAESTRO_MANAGER_TAB_SELFTEST="$SHOTS" "$BIN" \
    -phone.enabled NO -phone.port 7499 -ApplePersistenceIgnoreState YES \
    > /dev/null 2> "$SCRATCH/stderr" &
pid=$!
( sleep 90; kill "$pid" 2>/dev/null ) &
watchdog=$!
set +e
wait "$pid"
status=$?
set -e
kill "$watchdog" 2>/dev/null || true

sed -n '/^MANAGER TAB SELFTEST/,$p' "$SCRATCH/stderr"
grep -q '^MANAGER TAB SELFTEST' "$SCRATCH/stderr" || { echo "no report — app output:"; tail -20 "$SCRATCH/stderr"; }
ls "$SHOTS"/*.png 2>/dev/null | sed 's/^/  wrote /' || true
exit $status
