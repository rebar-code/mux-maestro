#!/usr/bin/env bash
# beam-selftest.sh — Layer 2 e2e for beam, no ssh required.
#
# BEAM_FAKE_REMOTE makes beam.sh run "remote" commands locally under a swapped
# HOME and rsync/git target local paths. We scaffold a git project + fake
# .claude/.codex on both a fake Mac HOME and a fake remote HOME, mutate BOTH
# sides (commit both, edit same file both, divergent Claude tails, divergent
# Codex tails), run `beam` then `beam back`, and assert convergence.
set -eo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(mktemp -d)"
[[ -n "${BEAM_SELFTEST_KEEP:-}" ]] || trap 'rm -rf "$ROOT"' EXIT
MAC="$ROOT/mac"
REMOTE="$ROOT/remote"
HOSTID="selfhost"
fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$1"; fails=$((fails+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

export GIT_AUTHOR_NAME=beam GIT_AUTHOR_EMAIL=beam@test
export GIT_COMMITTER_NAME=beam GIT_COMMITTER_EMAIL=beam@test

PROJ_REL="code/proj"
MAC_PROJ="$MAC/$PROJ_REL"
REMOTE_PROJ="$REMOTE/$PROJ_REL"

enc() { local p="$1"; p="${p//\//-}"; p="${p//./-}"; printf %s "$p"; }

mkfixtures() {
  mkdir -p "$MAC_PROJ" "$MAC/.claude/projects" "$MAC/.codex/sessions"
  mkdir -p "$REMOTE/.codex/sessions"
  cd "$MAC_PROJ"
  git -c init.defaultBranch=main init -q
  echo "base" > shared.txt
  echo "readme" > README.md
  git add -A && git commit -q -m "init"
  cd "$ROOT"
}

# a Claude session with a shared prefix (u1) — cwd baked to the given dir.
claude_session() {  # $1=dir  $2=extra-uuid  $3=extra-text
  local d="$1"
  printf '%s\n' "{\"type\":\"mode\",\"mode\":\"normal\",\"sessionId\":\"S\"}"
  printf '%s\n' "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":null,\"timestamp\":\"2026-07-03T01:00:00Z\",\"cwd\":\"$d\",\"message\":\"cd $d\"}"
  printf '%s\n' "{\"type\":\"user\",\"uuid\":\"$2\",\"parentUuid\":\"u1\",\"timestamp\":\"2026-07-03T02:00:00Z\",\"cwd\":\"$d\",\"message\":\"$3\"}"
}

codex_rollout() {  # $1=dir  $2=tail-text
  printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"019a5ff1-1ae2-73e2-8ee2-b9530a9b50be\",\"cwd\":\"$1\"}}"
  printf '%s\n' "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"shared\"}}"
  printf '%s\n' "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"$2\"}}"
}

beam() { HOME="$MAC" BEAM_FAKE_REMOTE="$REMOTE" BEAM_OPTS="Claude history,Codex history" \
         BEAM_NO_SHELL=1 BEAM_CONFLICT=local bash "$HERE/beam.sh" "$@"; }

echo "beam self-test"
echo "== scaffold =="
mkfixtures
pass "scaffolded git project + fake homes"

echo "== first beam (bootstrap) =="
( cd "$MAC_PROJ" && beam "$HOSTID" ) >/tmp/beam-selftest.log 2>&1 || { cat /tmp/beam-selftest.log; fail "bootstrap beam"; }
check "remote dir created" "[ -d '$REMOTE_PROJ/.git' ]"
check "remote has shared.txt" "[ -f '$REMOTE_PROJ/shared.txt' ]"
check "manifest written" "[ -f '$MAC/.claude/beam/$(enc "$MAC_PROJ").json' ]"

echo "== mutate BOTH sides =="
# local: new committed file, WIP edit to shared.txt, untracked file
cd "$MAC_PROJ"
echo "local feature" > feat-local.txt && git add -A && git commit -q -m "local feat"
echo "LOCAL-EDIT" > shared.txt
echo "local wip" > local-only.txt
# local Claude + Codex divergent tails
lkey="$(enc "$MAC_PROJ")"
mkdir -p "$MAC/.claude/projects/$lkey"
claude_session "$MAC_PROJ" u2local "local turn" > "$MAC/.claude/projects/$lkey/S.jsonl"
mkdir -p "$MAC/.codex/sessions/2026/07/03"
codex_rollout "$MAC_PROJ" "LOCAL-CODEX" > "$MAC/.codex/sessions/2026/07/03/rollout-2026-07-03T01-00-00-019a5ff1-1ae2-73e2-8ee2-b9530a9b50be.jsonl"

# remote: different committed file, different WIP edit, divergent sessions
rkey="$(enc "$REMOTE_PROJ")"
( cd "$REMOTE_PROJ" && echo "remote feature" > feat-remote.txt && git add -A && \
  HOME="$REMOTE" git -c user.name=beam -c user.email=beam@test commit -q -m "remote feat" && \
  echo "REMOTE-EDIT" > shared.txt )
mkdir -p "$REMOTE/.claude/projects/$rkey"
claude_session "$REMOTE_PROJ" u2remote "remote turn" > "$REMOTE/.claude/projects/$rkey/S.jsonl"
mkdir -p "$REMOTE/.codex/sessions/2026/07/03"
codex_rollout "$REMOTE_PROJ" "REMOTE-CODEX" > "$REMOTE/.codex/sessions/2026/07/03/rollout-2026-07-03T01-00-00-019a5ff1-1ae2-73e2-8ee2-b9530a9b50be.jsonl"
cd "$ROOT"
pass "mutated both sides (commits, WIP, sessions, codex)"

echo "== beam (push, conflict=local) =="
( cd "$MAC_PROJ" && beam "$HOSTID" ) >>/tmp/beam-selftest.log 2>&1 || { tail -30 /tmp/beam-selftest.log; fail "push beam"; }

echo "== beam back (pull) =="
( cd "$MAC_PROJ" && beam back "$HOSTID" ) >>/tmp/beam-selftest.log 2>&1 || { tail -30 /tmp/beam-selftest.log; fail "beam back"; }

echo "== assertions =="
# `check` decides pass/fail from each command's own exit status, so pipefail is
# unwanted here: `git log | grep -q X` has grep close the pipe on first match,
# git dies with SIGPIPE, and pipefail would spuriously mark a real match failed.
set +e +o pipefail
# 1. git: both commits present on both sides
check "local has local commit" "git -C '$MAC_PROJ' log --oneline | grep -q 'local feat'"
check "local has remote commit" "git -C '$MAC_PROJ' log --oneline | grep -q 'remote feat'"
check "remote has local commit" "git -C '$REMOTE_PROJ' log --oneline | grep -q 'local feat'"
check "remote has remote commit" "git -C '$REMOTE_PROJ' log --oneline | grep -q 'remote feat'"

# 2. WIP conflict resolved to local (BEAM_CONFLICT=local) on both sides
check "local shared.txt = LOCAL-EDIT" "grep -q LOCAL-EDIT '$MAC_PROJ/shared.txt'"
check "remote shared.txt = LOCAL-EDIT" "grep -q LOCAL-EDIT '$REMOTE_PROJ/shared.txt'"
check "local-only.txt pushed to remote" "[ -f '$REMOTE_PROJ/local-only.txt' ]"

# 3. Claude session merged (both tails) on both sides
check "local session has both turns" "grep -q u2local '$MAC/.claude/projects/$lkey/S.jsonl' && grep -q u2remote '$MAC/.claude/projects/$lkey/S.jsonl'"
check "remote session has both turns" "grep -q u2local '$REMOTE/.claude/projects/$rkey/S.jsonl' && grep -q u2remote '$REMOTE/.claude/projects/$rkey/S.jsonl'"
check "local session keeps Mac paths" "grep -q '$MAC_PROJ' '$MAC/.claude/projects/$lkey/S.jsonl' && ! grep -q '$REMOTE_PROJ' '$MAC/.claude/projects/$lkey/S.jsonl'"

# 4. Codex forked on both sides (a second rollout with a new uuid)
mac_forks="$(find "$MAC/.codex/sessions" -name 'rollout-*.jsonl' | grep -vc '019a5ff1-1ae2-73e2-8ee2-b9530a9b50be' || true)"
rem_forks="$(find "$REMOTE/.codex/sessions" -name 'rollout-*.jsonl' | grep -vc '019a5ff1-1ae2-73e2-8ee2-b9530a9b50be' || true)"
check "codex forked on Mac" "[ '$mac_forks' -ge 1 ]"
check "codex forked on remote" "[ '$rem_forks' -ge 1 ]"
check "codex trust entry on remote" "grep -q 'projects' '$REMOTE/.codex/config.toml'"

# 5. backup ref created by beam back
check "backup ref exists" "git -C '$MAC_PROJ' for-each-ref 'refs/beam/backup-*' | grep -q backup"

echo
if [[ "$fails" -eq 0 ]]; then
  printf '\033[32mALL PASS\033[0m  (log: /tmp/beam-selftest.log)\n'
else
  printf '\033[31m%d FAILURE(S)\033[0m  (log: /tmp/beam-selftest.log)\n' "$fails"
  exit 1
fi
