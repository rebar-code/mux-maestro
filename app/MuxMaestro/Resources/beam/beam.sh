#!/usr/bin/env bash
# beam.sh — two-way work-session sync between this Mac and a remote SSH host.
#
#   beam [host]        push: rsync WIP + git commits + Claude/Codex history to
#                      <host>, then drop into a remote shell there.
#   beam back [host]   pull: bring the remote's work home and converge sessions.
#   beam status [host] read-only: what's diverged, last beam/back, ahead/behind.
#   beam self-test     run the e2e self-test (no ssh; fake local "remote").
#
# `host` is an SSH config Host alias (same as `server`). Omit it after the first
# beam — the chosen host is remembered in the per-project manifest.
#
# `server <host> --beam` still works: it calls `beam.sh <host>` (a non-verb
# first arg dispatches to push), so the old muscle memory is unchanged.
#
# All JSON/merge/manifest work is delegated to beam_merge.py (python3 stdlib).
# The Mac is the sole orchestrator; the remote runs only ssh/rsync/git/sha256sum.
#
# Test / non-interactive knobs:
#   BEAM_OPTS="Claude history,Codex history"  skip the gum toggle TUI
#   BEAM_NO_SHELL=1                            don't drop into a remote shell
#   BEAM_CONFLICT=local|remote|skip           auto-resolve WIP conflicts
#   BEAM_FAKE_REMOTE=/path/to/fake/home       run "remote" ops locally (self-test)
#   BEAM_NO_CLONE=1                            skip the git-clone bootstrap (rsync)
#   BEAM_CLONE_DEPTH=N                         shallow-clone the box's base tree
set -eo pipefail  # not -u: macOS bash 3.2 chokes on "${empty[@]}" under set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MERGE=(python3 "$HERE/beam_merge.py")
home="$HOME"

# path -> Claude/Codex project key:  /Users/me/x.y -> -Users-me-x-y
enc() { local p="$1"; p="${p//\//-}"; p="${p//./-}"; printf %s "$p"; }

# --- remote transport wrappers (honor BEAM_FAKE_REMOTE) --------------------
# In fake mode, $host commands run locally with HOME swapped, and any "host:"
# prefix on an rsync/git path is stripped so it targets the local filesystem.
_ssh() {  # _ssh "<remote shell command>"
  if [[ -n "${BEAM_FAKE_REMOTE:-}" ]]; then HOME="$BEAM_FAKE_REMOTE" bash -c "$1"
  else ssh "$host" "$1"; fi
}
_rsync() {
  if [[ -n "${BEAM_FAKE_REMOTE:-}" ]]; then
    local a args=()
    for a in "$@"; do case "$a" in "$host:"*) args+=("${a#"$host":}") ;; *) args+=("$a") ;; esac; done
    rsync "${args[@]}"
  else rsync "$@"; fi
}
gitremote() {  # git URL for the remote repo
  if [[ -n "${BEAM_FAKE_REMOTE:-}" ]]; then printf %s "$remote_dir"; else printf %s "$host:$remote_dir"; fi
}

# remote command that hashes the WIP file set as "<sha>  <relpath>" lines.
REMOTE_HASH_CMD='H="sha256sum"; command -v sha256sum >/dev/null 2>&1 || H="shasum -a 256";
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -co --exclude-standard -z | xargs -0 $H 2>/dev/null;
  else find . -type f -not -path "./.git/*" -print0 | xargs -0 $H 2>/dev/null; fi'

# --------------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------------
verb=push
case "${1:-}" in
  back)      verb=back;   shift ;;
  pull)      verb=pull;   shift ;;
  status)    verb=status; shift ;;
  push)      verb=push;   shift ;;
  self-test) exec "$HERE/beam-selftest.sh" "${@:2}" ;;
  "" )       verb=push ;;
  *)         verb=push ;;   # non-verb first arg = host for a push
esac
host_arg="${1:-}"
status_local=0
[[ "$host_arg" == "--local" ]] && { status_local=1; host_arg=""; }
[[ "${2:-}" == "--local" ]] && status_local=1

# --- shared preamble: local dir guard + manifest --------------------------
local_dir="$PWD"
# Pull-from-remote mode (BEAM_FROM_DIR set): the caller isn't sitting in the
# project dir — do_pull derives local_dir/rel/manifest from the remote path
# instead, so skip the $PWD-based guards here.
if [[ -z "${BEAM_FROM_DIR:-}" ]]; then
  [[ "$local_dir" != "$home" ]] || { echo "beam: refusing to beam your entire \$HOME" >&2; exit 1; }
  case "$local_dir/" in
    "$home/"*) ;;
    *) echo "beam: $local_dir is not under \$HOME ($home); can't map a remote path" >&2; exit 1 ;;
  esac
  rel="${local_dir#"$home"/}"
  mkdir -p "$home/.claude/beam"
  manifest="$home/.claude/beam/$(enc "$local_dir").json"
  # When the project *is* ~/.claude, don't fingerprint the beam manifests themselves.
  exclude_beam=()
  [[ "$local_dir" == "$home/.claude" ]] && exclude_beam=(--exclude-beam)
else
  exclude_beam=()
fi

pick_host() {
  local config="$home/.ssh/config"
  [[ -f "$config" ]] || return 1
  command -v gum >/dev/null 2>&1 || return 1
  local choice
  choice="$(awk '
    function flush(){ if(alias!="") printf "%s\t%s\t%s\n", alias,(hn?hn:alias),(usr?usr:"-") }
    tolower($1)=="host"{ flush(); alias=""; hn=""; usr=""; for(i=2;i<=NF;i++) if($i!~/[*?]/ && alias=="") alias=$i }
    tolower($1)=="hostname"{ hn=$2 } tolower($1)=="user"{ usr=$2 } END{ flush() }
  ' "$config" | sort -u | column -t -s $'\t' | gum filter --placeholder "Pick a server…" --indicator "→" --height 15)"
  [[ -n "$choice" ]] || return 1
  printf %s "${choice%% *}"
}

resolve_host() {
  local h="$host_arg"
  [[ -n "$h" ]] || h="$("${MERGE[@]}" manifest-get --manifest "$manifest" --field default_host)"
  [[ -n "$h" ]] || h="$(pick_host || true)"
  [[ -n "$h" ]] || { echo "beam: no host given and none remembered for $rel" >&2; exit 1; }
  printf %s "$h"
}

now_stamp() { date +%Y%m%dT%H%M%S; }

# --------------------------------------------------------------------------
# shared: session sync (Claude + Codex + file-history + trust). Uses globals
# host / local_dir / remote_dir / remote_home. Runs on both beam and back.
# --------------------------------------------------------------------------
sync_sessions() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  if [[ "$want_claude" -eq 1 ]]; then
    local lkey rkey lproj rtmp pushout
    lkey="$(enc "$local_dir")"; rkey="$(enc "$remote_dir")"
    lproj="$home/.claude/projects/$lkey"
    rtmp="$tmp/claude_remote"; pushout="$tmp/claude_push"
    mkdir -p "$rtmp" "$pushout"
    if _ssh "test -d '$remote_home/.claude/projects/$rkey'"; then
      _rsync -a "$host:$remote_home/.claude/projects/$rkey/" "$rtmp/"
    fi
    echo "→ merging Claude sessions ..."
    "${MERGE[@]}" sync-claude --manifest "$manifest" --host "$host" \
      --local-dir "$local_dir" --remote-dir "$remote_dir" \
      --local-home "$home" --remote-home "$remote_home" \
      --local-proj "$lproj" --remote-proj "$rtmp" --pushout "$pushout"
    if [[ -n "$(ls -A "$pushout" 2>/dev/null)" ]]; then
      _ssh "mkdir -p '$remote_home/.claude/projects/$rkey'"
      _rsync -a "$pushout/" "$host:$remote_home/.claude/projects/$rkey/"
    fi
    # file-history: content-addressed, two-way, no path rewrite ever.
    local sid
    for f in "$lproj"/*.jsonl; do
      [[ -e "$f" ]] || continue
      sid="$(basename "$f" .jsonl)"
      if [[ -d "$home/.claude/file-history/$sid" ]]; then
        _ssh "mkdir -p '$remote_home/.claude/file-history/$sid'"
        _rsync -a "$home/.claude/file-history/$sid/" "$host:$remote_home/.claude/file-history/$sid/"
      fi
      if _ssh "test -d '$remote_home/.claude/file-history/$sid'"; then
        mkdir -p "$home/.claude/file-history/$sid"
        _rsync -a "$host:$remote_home/.claude/file-history/$sid/" "$home/.claude/file-history/$sid/"
      fi
    done
  fi

  if [[ "$want_codex" -eq 1 ]]; then
    local cxtmp cxpush matches
    cxtmp="$tmp/codex_remote"; cxpush="$tmp/codex_push"
    mkdir -p "$cxtmp" "$cxpush"
    matches="$(_ssh "grep -rlF '\"cwd\":\"$remote_dir\"' '$remote_home/.codex/sessions' 2>/dev/null || true")"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      _rsync -aR "$host:$f" "$cxtmp/"
    done <<<"$matches"
    # rsync -aR mirrors the remote absolute path under cxtmp; flatten to the
    # sessions-relative tree the merge engine expects.
    local flat="$cxtmp$remote_home/.codex/sessions"
    [[ -d "$flat" ]] || flat="$cxtmp"
    echo "→ merging Codex rollouts ..."
    "${MERGE[@]}" sync-codex --manifest "$manifest" --host "$host" \
      --local-dir "$local_dir" --remote-dir "$remote_dir" \
      --local-home "$home" --remote-home "$remote_home" \
      --local-sessions "$home/.codex/sessions" --remote-temp "$flat" --pushout "$cxpush"
    if [[ -n "$(ls -A "$cxpush" 2>/dev/null)" ]]; then
      _ssh "mkdir -p '$remote_home/.codex/sessions'"
      _rsync -a "$cxpush/" "$host:$remote_home/.codex/sessions/"
    fi
    # trust the project on the remote so `codex resume` will run there.
    _ssh "mkdir -p '$remote_home/.codex' && touch '$remote_home/.codex/config.toml' && \
      grep -qF 'projects.\"$remote_dir\"' '$remote_home/.codex/config.toml' || \
      printf '\n[projects.\"%s\"]\ntrust_level = \"trusted\"\n' '$remote_dir' >> '$remote_home/.codex/config.toml'"
    "${MERGE[@]}" manifest-set --manifest "$manifest" --host "$host" --set-host codex.trust_added=1
  fi
}

# --------------------------------------------------------------------------
# shared: WIP guarded rsync via code-plan. $1 = beam|back (which action column)
# --------------------------------------------------------------------------
resolve_conflict() {  # $1=path — converge both sides on the winner
  local choice="${BEAM_CONFLICT:-}"
  if [[ -z "$choice" ]]; then
    if command -v gum >/dev/null 2>&1; then
      choice="$(gum choose local remote skip --header "WIP conflict: $1")"
    else choice=skip; fi
  fi
  case "$choice" in
    local)  (cd "$local_dir" && _rsync -aR "$1" "$host:$remote_dir/") ;;
    remote) mkdir -p "$(dirname "$local_dir/$1")"; _rsync -a "$host:$remote_dir/$1" "$local_dir/$1" ;;
    *)      echo "  ⚠ skipped $1 (still conflicting — will re-flag next beam)" ;;
  esac
}

wip_sync() {  # $1 = beam|back
  local col; [[ "$1" == "back" ]] && col=5 || col=4
  local hashes="$tmpw/remote_hashes.txt"
  _ssh "cd '$remote_dir' && { $REMOTE_HASH_CMD; }" > "$hashes" || true
  local rows; rows="$("${MERGE[@]}" code-plan --manifest "$manifest" --host "$host" \
    --dir "$local_dir" --remote-hashes "$hashes" "${exclude_beam[@]}")"
  [[ -n "$rows" ]] || { echo "  WIP in sync"; return 0; }
  local path ls rs beamact backact act
  while IFS=$'\t' read -r path ls rs beamact backact; do
    [[ -n "$path" ]] || continue
    [[ "$col" == 5 ]] && act="$backact" || act="$beamact"
    case "$act" in
      push)      echo "  push  $path";      (cd "$local_dir" && _rsync -aR "$path" "$host:$remote_dir/") ;;
      pull)      echo "  pull  $path";      mkdir -p "$(dirname "$local_dir/$path")"; _rsync -a "$host:$remote_dir/$path" "$local_dir/$path" ;;
      rm-remote) echo "  rm→   $path";      _ssh "rm -f '$remote_dir/$path'" ;;
      rm-local)  echo "  rm←   $path";      rm -f "$local_dir/$path" ;;
      conflict)  echo "  conflict $path";   resolve_conflict "$path" ;;
      skip)      echo "  ⚠ remote-only change: $path (run \`beam back\` to pull)" ;;
    esac
  done <<<"$rows"
}

# --------------------------------------------------------------------------
# toggles (bootstrap file selection). Only meaningful for the first beam and
# for opt-in extras (node_modules/.env) that git would otherwise exclude.
# --------------------------------------------------------------------------
load_toggles() {
  local choices
  if [[ -n "${BEAM_OPTS:-}" ]]; then
    choices="${BEAM_OPTS//,/$'\n'}"
  elif command -v gum >/dev/null 2>&1; then
    choices="$(gum choose --no-limit \
      --header="Beam  $rel  →  $host:$remote_dir" \
      --selected="pnpm install on remote,Claude history,Codex history" \
      "node_modules (mac→linux native may break)" \
      ".env / secrets (shared box — careful)" \
      "pnpm install on remote" "Claude history" "Codex history" || true)"
  else
    choices="Claude history"$'\n'"Codex history"
  fi
  want() { grep -qF "$1" <<<"$choices"; }
  want_node=0;   want "node_modules"   && want_node=1
  want_env=0;    want ".env"           && want_env=1
  want_pnpm=0;   want "pnpm install"   && want_pnpm=1
  want_claude=0; want "Claude history" && want_claude=1
  want_codex=0;  want "Codex history"  && want_codex=1
  return 0  # never let a non-matching final `want` (set -e) abort the caller
}

push_extras() {  # opt-in files git ignores
  if [[ "$want_env" -eq 1 && -e "$local_dir/.env" ]]; then
    _rsync -a "$local_dir/.env" "$host:$remote_dir/.env"
  fi
  if [[ "$want_node" -eq 1 && -d "$local_dir/node_modules" ]]; then
    _rsync -a "$local_dir/node_modules" "$host:$remote_dir/"
  fi
  if [[ "$want_pnpm" -eq 1 ]]; then
    _ssh "cd '$remote_dir' && { command -v pnpm >/dev/null 2>&1 && pnpm install || { command -v npm >/dev/null 2>&1 && npm install || echo 'beam: no pnpm/npm on remote'; }; }"
  fi
}

# First-beam fast path: seed $remote_dir by cloning the repo's git remote ON the
# box (fat pipe, packed transfer) instead of rsyncing .git from the Mac (slow up
# a home connection — a big .git dominates the first beam). Returns 0 iff
# $remote_dir now exists as a clone; on any failure it removes the partial dir
# and returns 1 so the caller falls back to the rsync bootstrap. Layering of
# local-only commits + WIP + .env is left to the normal "remote exists"
# convergence path, so this only changes how the base tree gets there.
clone_bootstrap() {
  [[ -n "${BEAM_FAKE_REMOTE:-}" ]] && return 1   # self-test exercises the rsync path
  [[ "${BEAM_NO_CLONE:-0}" == "1" ]] && return 1
  is_git || return 1
  local url branch depth=()
  url="$(git -C "$local_dir" remote get-url origin 2>/dev/null || true)"
  [[ -n "$url" ]] || return 1
  branch="$(git -C "$local_dir" rev-parse --abbrev-ref HEAD)"
  [[ -n "${BEAM_CLONE_DEPTH:-}" ]] && depth=(--depth "$BEAM_CLONE_DEPTH")
  echo "→ first beam — cloning $url on $host (base tree; skips .git rsync) ..."
  _ssh "mkdir -p '$(dirname "$remote_dir")'"
  if _ssh "git clone ${depth[*]} '$url' '$remote_dir'" 2>&1 | sed 's/^/  /'; then
    # put the box on local's branch so the commit-sync step fast-forwards cleanly.
    _ssh "cd '$remote_dir' && { git checkout '$branch' 2>/dev/null || git checkout -b '$branch'; }" 2>&1 | sed 's/^/  /' || true
    return 0
  fi
  echo "  ⚠ clone failed — falling back to rsync bootstrap"
  _ssh "rm -rf '$remote_dir'"
  return 1
}

record_agreement() {
  "${MERGE[@]}" code-commit --manifest "$manifest" --host "$host" \
    --dir "$local_dir" --remote-hashes "$tmpw/remote_hashes.txt" "${exclude_beam[@]}"
}

is_git() { git -C "$local_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# ==========================================================================
# verbs
# ==========================================================================

do_push() {
  host="$(resolve_host)"
  echo "→ resolving remote \$HOME on $host ..."
  remote_home="$(_ssh 'printf %s "$HOME"')"
  [[ -n "$remote_home" ]] || { echo "beam: couldn't resolve remote \$HOME on $host" >&2; exit 1; }
  remote_dir="$remote_home/$rel"
  load_toggles

  tmpw="$(mktemp -d)"; trap 'rm -rf "$tmpw"' EXIT

  # First contact: try seeding the box from its own git remote (clone on the box)
  # before deciding bootstrap-vs-sync. A successful clone makes $remote_dir exist,
  # so the convergence path below layers local commits + WIP on top of it.
  if ! _ssh "test -d '$remote_dir'"; then
    clone_bootstrap || true
  fi

  if _ssh "test -d '$remote_dir'"; then
    echo "→ $remote_dir exists — syncing code (git + WIP) ..."
    if is_git; then
      local branch rbranch
      branch="$(git -C "$local_dir" rev-parse --abbrev-ref HEAD)"
      rbranch="$(_ssh "cd '$remote_dir' && git rev-parse --abbrev-ref HEAD 2>/dev/null" || true)"
      if [[ -n "$rbranch" && "$rbranch" != "$branch" ]]; then
        echo "  ⚠ remote is on '$rbranch', local on '$branch' — skipping commit merge (WIP guard still runs)"
      else
        echo "→ pushing commits ($branch) ..."
        git -C "$local_dir" push "$(gitremote)" "+refs/heads/$branch:refs/beam/mac/$branch" 2>&1 | sed 's/^/  /' || true
        _ssh "cd '$remote_dir' && { git merge --ff-only refs/beam/mac/$branch 2>/dev/null || git merge --no-edit refs/beam/mac/$branch; }" 2>&1 | sed 's/^/  /' || \
          echo "  ⚠ remote merge left conflicts — resolve them on $host"
      fi
    fi
    echo "→ WIP files ..."
    wip_sync beam
    push_extras
    record_agreement
  else
    echo "→ first beam — bootstrapping $remote_dir on $host ..."
    _ssh "mkdir -p '$remote_dir'"
    if is_git; then
      local list; list="$(mktemp)"
      git -C "$local_dir" ls-files -co --exclude-standard | while IFS= read -r p; do
        [ -e "$local_dir/$p" ] && printf '%s\n' "$p"; done > "$list"
      _rsync -a --files-from="$list" "$local_dir/" "$host:$remote_dir/"
      rm -f "$list"
      [[ -d "$local_dir/.git" ]] && _rsync -a "$local_dir/.git/" "$host:$remote_dir/.git/"
    else
      local ex=()
      [[ "$want_node" -eq 0 ]] && ex+=(--exclude "node_modules")
      [[ "$want_env"  -eq 0 ]] && ex+=(--exclude ".env")
      [[ -f "$local_dir/.gitignore" ]] && ex+=(--exclude-from "$local_dir/.gitignore")
      _rsync -a "${ex[@]}" "$local_dir/" "$host:$remote_dir/"
    fi
    push_extras
    : > "$tmpw/remote_hashes.txt"
    _ssh "cd '$remote_dir' && { $REMOTE_HASH_CMD; }" > "$tmpw/remote_hashes.txt" || true
    record_agreement
  fi

  sync_sessions

  "${MERGE[@]}" manifest-set --manifest "$manifest" --host "$host" \
    --set "default_host=$host" \
    --set-host "remote_home=$remote_home" --set-host "remote_dir=$remote_dir" \
    --set-host "last_beam_at=$(now_stamp)"

  echo "✓ beamed  $rel  →  $host:$remote_dir"

  # ---- handoff: land in a *persistent remote tmux*, resuming a session if asked.
  #   BEAM_RESUME_SID=<id>  resume that Claude session in the remote tmux window
  #   BEAM_HANDOFF=takeover replace THIS tmux pane (BEAM_PANE) with the remote
  #                         resumed session — the seamless /beam skill handoff.
  #   BEAM_HANDOFF=detach   set the remote tmux up detached, print the attach
  #                         command, don't touch this terminal.
  #   BEAM_NO_TMUX=1        old behavior: a bare remote login shell, no tmux
  #   BEAM_NO_SHELL=1       no handoff at all (tests) — unless detach/takeover asked
  [[ -n "${BEAM_FAKE_REMOTE:-}" ]] && return 0
  case "${BEAM_HANDOFF:-}" in detach|takeover) ;; *) [[ "${BEAM_NO_SHELL:-0}" == "1" ]] && return 0 ;; esac

  local sess="beam-$(enc "$rel")"
  local runcmd="exec bash -l"
  [[ -n "${BEAM_RESUME_SID:-}" ]] && runcmd="claude --resume ${BEAM_RESUME_SID} || true; exec bash -l"

  if [[ "${BEAM_HANDOFF:-}" == "detach" || "${BEAM_HANDOFF:-}" == "takeover" ]]; then
    # Stand up (or reuse) a persistent remote tmux running the resumed session.
    # It lives on the remote: the Mac can go offline, the phone can mosh in and
    # attach to the same tmux.
    local dcmd="command -v tmux >/dev/null 2>&1 || { echo 'beam: tmux not on remote' >&2; exit 3; }; \
tmux has-session -t '$sess' 2>/dev/null || tmux new-session -d -s '$sess' -c '$remote_dir' '$runcmd'"
    _ssh "$dcmd" || { echo "beam: could not start remote tmux session on $host" >&2; return 3; }

    if [[ "${BEAM_HANDOFF:-}" == "takeover" ]]; then
      # Replace the caller's tmux pane with an attach to the remote session, so
      # the window seamlessly *becomes* the remote resumed Claude. Only reached
      # after the remote session is confirmed up, so a failed beam never kills
      # the local pane. Requires running inside tmux (BEAM_PANE / $TMUX_PANE).
      local pane="${BEAM_PANE:-$TMUX_PANE}"
      if [[ -n "$pane" ]] && command -v tmux >/dev/null 2>&1; then
        echo "→ handing this pane over to $host:$sess ..."
        exec tmux respawn-pane -k -t "$pane" "ssh -t $host tmux attach -t $sess"
      fi
      echo "beam: not in a tmux pane — falling back to detach; attach manually below" >&2
    fi

    echo "✓ remote session live in tmux '$sess' on $host"
    echo "   attach:  ssh -t $host tmux attach -t $sess"
    echo "   phone:   mosh $host -- tmux attach -t $sess   (survives your Mac going offline)"
    return 0
  fi

  # Interactive handoff: replace THIS terminal with the remote tmux (+resume if asked).
  local rcmd
  if [[ "${BEAM_NO_TMUX:-0}" == "1" ]]; then
    rcmd="cd '$remote_dir' && exec bash -l"
  else
    rcmd="command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s '$sess' -c '$remote_dir' '$runcmd' || { cd '$remote_dir'; exec bash -l; }"
  fi
  exec ssh -t "$host" "$rcmd"
}

do_back() {
  host="$(resolve_host)"
  if [[ -z "$("${MERGE[@]}" manifest-get --manifest "$manifest" --host "$host" --field remote_dir)" ]]; then
    echo "beam: no manifest for $rel on $host — run \`beam $host\` first" >&2; exit 1
  fi
  echo "→ resolving remote \$HOME on $host ..."
  remote_home="$(_ssh 'printf %s "$HOME"')"
  remote_dir="$remote_home/$rel"
  load_toggles

  tmpw="$(mktemp -d)"; trap 'rm -rf "$tmpw"' EXIT

  # Backup local WIP before anything writes.
  if is_git; then
    local backup snap; backup="refs/beam/backup-$(now_stamp)"
    # `git stash create` prints nothing (exit 0) on a clean tree — fall back to HEAD.
    snap="$(git -C "$local_dir" stash create 2>/dev/null || true)"
    [[ -n "$snap" ]] || snap="$(git -C "$local_dir" rev-parse HEAD)"
    git -C "$local_dir" update-ref "$backup" "$snap"
    echo "→ local WIP backed up at $backup"
    local branch
    branch="$(git -C "$local_dir" rev-parse --abbrev-ref HEAD)"
    echo "→ fetching remote commits ..."
    git -C "$local_dir" fetch "$(gitremote)" "+refs/heads/*:refs/beam/$host/*" 2>&1 | sed 's/^/  /' || true
    if git -C "$local_dir" rev-parse --verify -q "refs/beam/$host/$branch" >/dev/null; then
      git -C "$local_dir" merge --ff-only "refs/beam/$host/$branch" 2>/dev/null || \
        git -C "$local_dir" merge --no-rebase --no-edit "refs/beam/$host/$branch" 2>&1 | sed 's/^/  /' || \
        echo "  ⚠ merge conflicts — resolve, commit, then re-run \`beam back\`"
    fi
  fi

  echo "→ WIP files ..."
  wip_sync back
  record_agreement
  sync_sessions

  "${MERGE[@]}" manifest-set --manifest "$manifest" --host "$host" \
    --set-host "last_back_at=$(now_stamp)"
  echo "✓ brought  $host:$remote_dir  →  $rel"
}

# Pull a project FROM a server to this Mac, resuming a session id if asked — the
# server→Mac (and, chained with do_push, server→server) direction the app drives.
#
# Unlike `back`, this needs no prior manifest/local checkout: with BEAM_FROM_DIR
# set to the remote project path, it derives the Mac-side rel/local_dir/manifest
# from the remote $HOME, and bootstraps a fresh local checkout by rsyncing the
# remote repo down (symmetric to do_push's first-beam bootstrap) when the Mac has
# nothing yet. Then it converges repo + Claude/Codex history home (the same
# two-way, path-rewriting merge). The APP does the local `claude --resume` +
# reveal (via recoverSession), so there is no pane handoff here.
do_pull() {
  host="$(resolve_host)"
  echo "→ resolving remote \$HOME on $host ..."
  remote_home="$(_ssh 'printf %s "$HOME"')"
  [[ -n "$remote_home" ]] || { echo "beam: couldn't resolve remote \$HOME on $host" >&2; exit 1; }

  if [[ -n "${BEAM_FROM_DIR:-}" ]]; then
    remote_dir="$BEAM_FROM_DIR"
    rel="${remote_dir#"$remote_home"/}"
    [[ "$rel" != "$remote_dir" ]] || {
      echo "beam: $remote_dir is not under remote \$HOME ($remote_home)" >&2; exit 1; }
    local_dir="$home/$rel"
    case "$local_dir/" in
      "$home/"*) ;;
      *) echo "beam: refusing to pull outside \$HOME ($local_dir)" >&2; exit 1 ;;
    esac
    mkdir -p "$home/.claude/beam"
    manifest="$home/.claude/beam/$(enc "$local_dir").json"
  else
    remote_dir="$remote_home/$rel"
  fi

  _ssh "test -d '$remote_dir'" || { echo "beam: $remote_dir does not exist on $host" >&2; exit 1; }
  load_toggles

  tmpw="$(mktemp -d)"; trap 'rm -rf "$tmpw"' EXIT

  if [[ ! -e "$local_dir/.git" && -z "$(ls -A "$local_dir" 2>/dev/null)" ]]; then
    echo "→ first pull — bootstrapping $local_dir from $host ..."
    mkdir -p "$local_dir"
    if _ssh "test -d '$remote_dir/.git'"; then
      local list; list="$(mktemp)"
      _ssh "cd '$remote_dir' && git ls-files -co --exclude-standard" > "$list" || true
      _rsync -a --files-from="$list" "$host:$remote_dir/" "$local_dir/" || true
      rm -f "$list"
      _rsync -a "$host:$remote_dir/.git/" "$local_dir/.git/"
    else
      _rsync -a "$host:$remote_dir/" "$local_dir/"
    fi
    record_agreement
  else
    echo "→ converging $local_dir with $host ..."
    if is_git; then
      local backup snap; backup="refs/beam/backup-$(now_stamp)"
      snap="$(git -C "$local_dir" stash create 2>/dev/null || true)"
      [[ -n "$snap" ]] || snap="$(git -C "$local_dir" rev-parse HEAD)"
      git -C "$local_dir" update-ref "$backup" "$snap"
      echo "→ local WIP backed up at $backup"
      local branch; branch="$(git -C "$local_dir" rev-parse --abbrev-ref HEAD)"
      echo "→ fetching remote commits ..."
      git -C "$local_dir" fetch "$(gitremote)" "+refs/heads/*:refs/beam/$host/*" 2>&1 | sed 's/^/  /' || true
      if git -C "$local_dir" rev-parse --verify -q "refs/beam/$host/$branch" >/dev/null; then
        git -C "$local_dir" merge --ff-only "refs/beam/$host/$branch" 2>/dev/null || \
          git -C "$local_dir" merge --no-rebase --no-edit "refs/beam/$host/$branch" 2>&1 | sed 's/^/  /' || \
          echo "  ⚠ merge conflicts — resolve, commit, then re-run"
      fi
    fi
    echo "→ WIP files ..."
    wip_sync back
    record_agreement
  fi

  sync_sessions

  "${MERGE[@]}" manifest-set --manifest "$manifest" --host "$host" \
    --set "default_host=$host" \
    --set-host "remote_home=$remote_home" --set-host "remote_dir=$remote_dir" \
    --set-host "last_back_at=$(now_stamp)"

  echo "✓ pulled  $host:$remote_dir  →  $local_dir"
}

do_status() {
  host="$(resolve_host)"
  local rd rh lb bk
  rd="$("${MERGE[@]}" manifest-get --manifest "$manifest" --host "$host" --field remote_dir)"
  rh="$("${MERGE[@]}" manifest-get --manifest "$manifest" --host "$host" --field remote_home)"
  lb="$("${MERGE[@]}" manifest-get --manifest "$manifest" --host "$host" --field last_beam_at)"
  bk="$("${MERGE[@]}" manifest-get --manifest "$manifest" --host "$host" --field last_back_at)"
  echo "project:    $rel"
  echo "host:       $host"
  echo "remote_dir: ${rd:-<none>}"
  echo "last beam:  ${lb:-never}     last back: ${bk:-never}"
  if is_git; then
    local changed
    changed="$(git -C "$local_dir" status --porcelain 2>/dev/null | grep -c . || true)"
    echo "local WIP changes: $changed file(s)"
    local branch
    branch="$(git -C "$local_dir" rev-parse --abbrev-ref HEAD)"
    if git -C "$local_dir" rev-parse --verify -q "refs/beam/$host/$branch" >/dev/null; then
      local ab
      ab="$(git -C "$local_dir" rev-list --left-right --count "$branch...refs/beam/$host/$branch" 2>/dev/null || echo '? ?')"
      echo "vs last fetched remote ($host/$branch):  ahead/behind = $ab"
    fi
  fi
  if [[ "$status_local" -eq 1 ]]; then
    echo "(--local: skipped remote probe)"; return 0
  fi
  remote_home="${rh:-$(_ssh 'printf %s "$HOME"' 2>/dev/null || true)}"
  [[ -n "$remote_home" ]] || { echo "remote: unreachable"; return 0; }
  remote_dir="${rd:-$remote_home/$rel}"
  tmpw="$(mktemp -d)"; trap 'rm -rf "$tmpw"' EXIT
  local hashes="$tmpw/remote_hashes.txt"
  if _ssh "test -d '$remote_dir'"; then
    _ssh "cd '$remote_dir' && { $REMOTE_HASH_CMD; }" > "$hashes" 2>/dev/null || true
    local rows n
    rows="$("${MERGE[@]}" code-plan --manifest "$manifest" --host "$host" --dir "$local_dir" --remote-hashes "$hashes" "${exclude_beam[@]}")"
    n="$(printf '%s' "$rows" | grep -c . || true)"
    echo "diverged WIP files: $n"
    [[ -n "$rows" ]] && printf '%s\n' "$rows" | awk -F'\t' '{printf "   %-40s local=%s remote=%s\n",$1,$2,$3}'
    if [[ "$n" -gt 0 ]]; then echo "verdict: run \`beam\` (push) or \`beam back\` (pull) to converge"; else echo "verdict: in sync"; fi
  else
    echo "remote dir does not exist yet — run \`beam $host\`"
  fi
}

case "$verb" in
  push)   do_push ;;
  back)   do_back ;;
  pull)   do_pull ;;
  status) do_status ;;
esac
