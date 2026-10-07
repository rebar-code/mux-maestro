#!/bin/bash
# Run the vendored helper scripts (app/MuxMaestro/Resources/tools/) the way a
# Mac that isn't the author's would: an empty temp HOME (no ~/.claude, no
# ports file, no remote host) and PATH=/usr/bin:/bin (no tmux, docker, gh or
# treehouse on it). Everything happens under one temp dir, which is
# removed on exit.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOLS="$ROOT/app/MuxMaestro/Resources/tools"
PY=/usr/bin/python3
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/muxmaestro-tools-selftest.XXXXXX")" && pwd -P)

cleanup() {
    rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/home"

failed=0
check() { # check <label> <command…>
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then echo "  PASS  $label"; else echo "  FAIL  $label"; failed=1; fi
}
bare() { (cd "$T" && env -i HOME="$T/home" PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 "$@"); }
g() { env HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -c user.email=selftest@example.invalid -c user.name=selftest "$@"; }

echo "sessions.py"
out=$(bare $PY "$TOOLS/sessions.py" list)
check "list prints [] with no ~/.claude" test "$out" = "[]"
out=$(bare $PY "$TOOLS/sessions.py" list --full | tr -d ' \n')
check "list --full prints only its schema row" test "$out" = '[{"agent":"meta","schema":2}]'

echo "spindown.py"
g init -q --bare -b main "$T/origin.git"
g init -q -b main "$T/repo"
g -C "$T/repo" commit -q --allow-empty -m init
g -C "$T/repo" remote add origin "$T/origin.git"
g -C "$T/repo" push -q -u origin main
g -C "$T/repo" remote set-head origin main
g -C "$T/repo" worktree add -q -b feat/merged "$T/wt-merged" main
g -C "$T/repo" worktree add -q -b feat/dirty "$T/wt-dirty" main
# A Supabase project on a Mac with no Docker: the stop step must skip, not fail.
mkdir -p "$T/wt-merged/supabase"
printf 'project_id = "selftest"\n' >"$T/wt-merged/supabase/config.toml"
echo "work" >"$T/wt-dirty/uncommitted.txt"
spindown() { bare $PY "$TOOLS/spindown.py" --yes --json --worktree "$1" 2>/dev/null; }
field() { $PY -c 'import json, sys; print(json.load(sys.stdin)["targets"][0][sys.argv[1]])' "$1"; }

merged=$(spindown "$T/wt-merged")
check "cleans a merged plain git worktree" test "$(echo "$merged" | field cleaned)" = True
check "removes its directory" test ! -d "$T/wt-merged"
echo "$merged" | grep -q "docker did not answer"
check "skips Supabase with no Docker" test $? -eq 0
dirty=$(spindown "$T/wt-dirty")
check "keeps a worktree with uncommitted work" test "$(echo "$dirty" | field cleaned)" = False
check "leaves its directory" test -d "$T/wt-dirty"

echo "spin.py"
check "prints its usage" bare $PY "$TOOLS/spin.py" --help
# A dry run reads the repo and stops before leasing, so it works on a Mac with
# no treehouse — which is the only part of a real spin that cannot be faked here.
check "dry-runs a repo with no treehouse on PATH" \
    bare $PY "$TOOLS/spin.py" --dry-run --repo "$T/repo" --branch feat/x

echo
if [ "$failed" = 0 ]; then echo "TOOLS SELFTEST PASSED"; else echo "TOOLS SELFTEST FAILED"; fi
exit "$failed"
