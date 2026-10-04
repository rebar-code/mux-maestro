#!/usr/bin/env python3
"""spin — open a new tmux window running a fresh agent in its own treehouse worktree.

Steps: lease a pooled worktree -> fetch + check out the branch (new off the base
branch, or the existing remote branch) -> launch `claude` (or `codex`) in a new
tmux window of the caller's own session (or of --session, for a caller that is
not in the session the human works in). With --supabase it also gives the
worktree its own Supabase port block; that is off by default because most tasks
never touch the database and a claimed block is one more thing to clean up.

Usage:
  spin.py --branch feat/rate-audit [--base prod] [--agent claude|codex]
          [--prompt "..."] [--repo PATH] [--supabase] [--supabase-start]
          [--session NAME] [--pane %ID] [--work-log DB]
          [--no-window] [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

PORTS_DOC = Path.home() / ".claude" / "local-ports.md"
TMUX_NAME = Path.home() / ".claude" / "scripts" / "tmux-name.sh"
FALLBACK_BASES = ("prod", "production", "main", "master")
ENV_MAX_DEPTH = 4


def die(msg: str) -> "None":
    print(f"spin: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> str:
    proc = subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True
    )
    if check and proc.returncode != 0:
        die(f"`{' '.join(cmd)}` failed:\n{proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout.strip()


def git(args: list[str], cwd: Path, check: bool = True) -> str:
    return run(["git", *args], cwd=cwd, check=check)


def slug(text: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")


# --------------------------------------------------------------------------- repo


def repo_root(start: Path) -> Path:
    out = run(["git", "-C", str(start), "rev-parse", "--show-toplevel"])
    return Path(out)


def default_base(repo: Path) -> str:
    head = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repo, check=False)
    if head.startswith("origin/"):
        return head[len("origin/"):]
    for candidate in FALLBACK_BASES:
        if git(["rev-parse", "--verify", f"refs/remotes/origin/{candidate}"], repo, check=False):
            return candidate
    die("cannot resolve the default branch — pass --base explicitly")
    return ""


def remote_has(repo: Path, ref: str) -> bool:
    return bool(run(["git", "ls-remote", "--heads", "origin", ref], cwd=repo, check=False))


# --------------------------------------------------------------------- treehouse


def lease_worktree(repo: Path, holder: str) -> Path:
    if not shutil.which("treehouse"):
        die("treehouse is not installed (expected on PATH)")
    proc = subprocess.run(
        ["treehouse", "get", "--lease", "--json", "--lease-holder", holder],
        cwd=repo, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        die(f"treehouse get failed:\n{proc.stderr.strip()}")
    try:
        return Path(json.loads(proc.stdout.strip())["path"])
    except (json.JSONDecodeError, KeyError):
        die(f"could not parse treehouse lease JSON: {proc.stdout!r}")
    return Path()


def return_worktree(repo: Path, worktree: Path) -> None:
    subprocess.run(
        ["treehouse", "return", "--force", str(worktree)],
        cwd=repo, capture_output=True, text=True,
    )


# ---------------------------------------------------------------------- supabase


def used_blocks() -> set[int]:
    if not PORTS_DOC.exists():
        return set()
    return {
        int(m)
        for m in re.findall(r"^\|\s*(\d+)\s*\|\s*54\d{3}\s*\|", PORTS_DOC.read_text(), re.M)
    }


def port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def next_free_block() -> int:
    taken = used_blocks()
    # Scan from the bottom, not from max(taken)+1. Starting above the highest
    # row made allocation a one-way ratchet: freeing a block by deleting its row
    # never made it reusable, so the registry only ever climbed toward the 60
    # ceiling. Removing 18 stale rows on 2026-08-20 freed blocks 16-32 and the
    # old rule would still have handed out 34. The guards below are what keep
    # this safe -- a block is skipped unless it is unregistered AND its ports
    # are genuinely unbound.
    block = 1
    while block < 60:
        base = 54320 + block * 10
        if block not in taken and all(port_free(base + off) for off in (1, 2, 3)):
            return block
        block += 1
    die("no free Supabase port block under 54900 — clean up your ports file")
    return 0


def remap_ports(text: str, new_base: int) -> str:
    """Move every Supabase-range port onto the new block, keeping its role.

    Any port in 54320-54999 belongs to some block; its last digit is its role
    (api, db, studio, ...). Remapping by role rather than from a known old base
    also fixes a recycled worktree whose leftover .env still points at the block
    a previous spin claimed.
    """
    def sub(match: re.Match[str]) -> str:
        port = int(match.group(2))
        if 54320 <= port <= 54999:
            return f"{match.group(1)}{new_base + (port - 54320) % 10}"
        return match.group(0)

    return re.sub(r"(^|[^0-9])(\d{5})(?![0-9])", sub, text, flags=re.M)


def setup_supabase(worktree: Path, branch: str, start: bool) -> dict | None:
    config = worktree / "supabase" / "config.toml"
    if not config.exists():
        return None

    text = config.read_text()
    block = next_free_block()
    new_base = 54320 + block * 10

    project_match = re.search(r'^\s*project_id\s*=\s*"([^"]+)"', text, re.M)
    old_project = project_match.group(1) if project_match else worktree.name
    new_project = f"{old_project}-spin-{slug(branch)}"[:60]

    text = remap_ports(text, new_base)
    text = re.sub(
        r'^(\s*project_id\s*=\s*)"[^"]+"', rf'\1"{new_project}"', text, count=1, flags=re.M
    )
    text = re.sub(
        r"^(\s*inspector_port\s*=\s*)\d+", rf"\g<1>{8083 + block}", text, flags=re.M
    )
    config.write_text(text)

    # Hide the rewrite from `git status`. Without this the file reads dirty
    # forever, and a dirty worktree is one treehouse will never reclaim: on
    # 2026-08-19 that had jammed 12 leases for five days with the pool at 16/16,
    # while `treehouse-tidy` exited 0 nightly having released nothing. The
    # repo's own scripts/worktree-supabase.sh has always done this; spin did not.
    git(["update-index", "--skip-worktree", "supabase/config.toml"], worktree, check=False)

    envs = rewrite_env_files(worktree, new_base)
    register_block(block, new_base, new_project, branch, worktree)

    info = {
        "block": block,
        "base": new_base,
        "api": new_base + 1,
        "db": new_base + 2,
        "studio": new_base + 3,
        "project_id": new_project,
        "envs": envs,
        "started": False,
    }

    if start:
        proc = subprocess.run(["supabase", "start"], cwd=worktree, text=True)
        info["started"] = proc.returncode == 0
    return info


def rewrite_env_files(worktree: Path, new_base: int) -> list[str]:
    """Replace symlinked .env files that point at the old stack with rewritten copies.

    treehouse symlinks the source repo's gitignored .env files into the worktree, so
    editing one in place would repoint the ORIGINAL repo at this worktree's stack.
    Tracked files (a committed .env.example) are left alone — rewriting one would
    put a stray port diff in the branch.
    """
    tracked = set(git(["ls-files"], worktree).splitlines())
    changed: list[str] = []
    for path in worktree.rglob(".env*"):
        rel = path.relative_to(worktree)
        if len(rel.parts) > ENV_MAX_DEPTH or "node_modules" in rel.parts:
            continue
        if str(rel) in tracked:
            continue
        if not path.is_file():
            continue
        try:
            body = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        new_body = remap_ports(body, new_base)
        if new_body == body:
            continue
        if path.is_symlink():
            path.unlink()
        path.write_text(new_body)
        changed.append(str(rel))
    return changed


def register_block(block: int, base: int, project_id: str, branch: str, worktree: Path) -> None:
    if not PORTS_DOC.exists():
        return
    lines = PORTS_DOC.read_text().splitlines()
    last_row = max(
        (i for i, line in enumerate(lines) if re.match(r"^\|\s*\d+\s*\|\s*54\d{3}\s*\|", line)),
        default=None,
    )
    if last_row is None:
        return
    row = (
        f"| {block} | {base} | {base + 1} | {project_id} | "
        f"spin worktree {worktree} — branch {branch}, {date.today().isoformat()} |"
    )
    lines.insert(last_row + 1, row)
    PORTS_DOC.write_text("\n".join(lines) + "\n")


# -------------------------------------------------------------------------- tmux


def own_pane() -> str | None:
    if not TMUX_NAME.exists():
        return None
    out = run([str(TMUX_NAME), "--where"], check=False)
    pane = out.split()[0] if out else ""
    return pane if pane.startswith("%") else None


def trim(text: str, limit: int) -> str:
    """Cut to `limit` on a hyphen boundary, so names never end mid-word."""
    if len(text) <= limit:
        return text
    return text[:limit].rsplit("-", 1)[0] if "-" in text[:limit] else text[:limit]


def window_name(repo: Path, branch: str) -> str:
    """`acme-app-rate-audit` — repo plus branch, minus the conventional prefix."""
    name = slug(repo.name)
    head = name.split("-", 1)[0]
    if len(head) < 4:
        head = trim(name, 14)
    tail = branch.split("/", 1)[1] if "/" in branch else branch
    return f"{head}-{trim(slug(tail), 20)}".strip("-")


def settle_window(target: str, name: str) -> tuple[str, str]:
    """Pin a fresh window's name and title, then report `session:index` and its pane."""
    # Without this the running shell renames the window out from under us.
    run(["tmux", "set-option", "-w", "-t", target, "automatic-rename", "off"], check=False)
    run(["tmux", "select-pane", "-t", f"{target}.0", "-T", name], check=False)
    out = run([
        "tmux", "display-message", "-p", "-t", target,
        "#{session_name}:#{window_index}\t#{pane_id}",
    ])
    where, _, pane_id = out.partition("\t")
    return where, pane_id


def open_window(pane: str, name: str, cwd: Path, command: str) -> tuple[str, str]:
    """New window, next to the caller's, in the caller's own session.

    Created with `-d`: spinning an agent must not yank the human's view away
    from whatever they were reading. Without it tmux makes the new window
    current, and every attached client — including MuxMaestro's terminal, which
    shows the session's active window — jumps to the fresh agent.
    """
    # `new-window -t` wants a WINDOW target; a pane id (%N) is rejected outright.
    # Resolve the pane's window id (@N) so the new window lands in this session
    # even when the session name has odd characters.
    window = run(["tmux", "display-message", "-p", "-t", pane, "#{window_id}"])
    target = run([
        "tmux", "new-window", "-d", "-a", "-t", window, "-n", name, "-c", str(cwd),
        "-P", "-F", "#{window_id}", command,
    ])
    return settle_window(target, name)


def open_session_window(session: str, name: str, cwd: Path, command: str) -> tuple[str, str]:
    """New window in a named session, for a caller who is not in it.

    MuxMaestro's manager agent lives in its own session, so "next to my pane" is
    the wrong place: the human would never see the agent. The trailing colon on
    the target is what makes tmux read `NAME` as a session and not as a window of
    the caller's own session.
    """
    target = run([
        "tmux", "new-window", "-d", "-t", f"{session}:", "-n", name, "-c", str(cwd),
        "-P", "-F", "#{window_id}", command,
    ])
    return settle_window(target, name)


def open_pane(pane: str, name: str, cwd: Path, command: str, vertical: bool) -> tuple[str, str]:
    """Split the caller's own pane, so both agents stay on screen together."""
    target = run([
        "tmux", "split-window", "-v" if vertical else "-h", "-t", pane, "-c", str(cwd),
        "-P", "-F", "#{pane_id}", command,
    ])
    run(["tmux", "select-pane", "-t", target, "-T", name], check=False)
    where = run([
        "tmux", "display-message", "-p", "-t", target,
        "#{session_name}:#{window_index}.#{pane_index}",
    ])
    return where, target


def pane_context(pane: str) -> tuple[str, int | None]:
    """The tmux session name and window index a pane sits in."""
    out = run(["tmux", "display-message", "-p", "-t", pane,
               "#{session_name}\t#{window_index}"], check=False)
    session, _, index = out.partition("\t")
    return session, int(index) if index.isdigit() else None


# ---------------------------------------------------------------------- worklog

# Kept identical to the DDL in MuxMaestro's `mux` script and ManagerStore: either
# side may be the first to open the DB.
WORK_LOG_DDL = """
CREATE TABLE IF NOT EXISTS work_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL DEFAULT '',
  agent TEXT NOT NULL DEFAULT '',
  repo TEXT NOT NULL DEFAULT '',
  branch TEXT NOT NULL DEFAULT '',
  prs TEXT NOT NULL DEFAULT '',
  host TEXT NOT NULL DEFAULT 'localhost',
  session TEXT NOT NULL DEFAULT '',
  window INTEGER,
  pane TEXT NOT NULL DEFAULT '',
  cwd TEXT NOT NULL DEFAULT '',
  last_state TEXT NOT NULL DEFAULT '',
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS work_log_session ON work_log(session_id) WHERE session_id <> '';
CREATE INDEX IF NOT EXISTS work_log_last_seen ON work_log(last_seen);
"""


def record_work_log(
    db: Path, agent: str, repo: str, branch: str, pane: str, worktree: Path
) -> int | None:
    """Record the new agent in MuxMaestro's work log, before it says anything.

    The row is `spawned` with an empty session_id, keyed by the pane the agent
    runs in; the agent's own first hook claims it and fills the session id in.
    Best effort by design: the worktree and the window already exist, so a DB
    problem is a warning here, never a failed spin.
    """
    session, window = pane_context(pane)
    now = int(time.time())
    try:
        conn = sqlite3.connect(str(db))
        try:
            conn.execute("PRAGMA busy_timeout=3000")
            conn.executescript(WORK_LOG_DDL)
            cur = conn.execute(
                "INSERT INTO work_log(session_id, agent, repo, branch, prs, host, session,"
                " window, pane, cwd, last_state, first_seen, last_seen)"
                " VALUES('', ?, ?, ?, '', 'localhost', ?, ?, ?, ?, 'spawned', ?, ?)",
                (agent, repo, branch, session, window, pane, str(worktree), now, now),
            )
            conn.commit()
            return cur.lastrowid
        finally:
            conn.close()
    except sqlite3.Error as exc:
        print(f"spin: work log not written ({exc})", file=sys.stderr)
        return None


# -------------------------------------------------------------------------- main


def build_prompt(
    user_prompt: str, worktree: Path, branch: str, base: str, sb: dict | None, name: str
) -> str:
    lines = [
        f"You are in a treehouse worktree at {worktree}, on branch `{branch}` "
        f"(branched off `{base}`). Work only here.",
        f"Your tmux window/pane is already named `{name}` — that name is permanent, it says "
        f"why the window exists. Never rename it to what you are doing now; add status as a "
        f"tag instead (add a tag with your naming script once PR #123 is open, "
        f"`--untag` to drop it).",
    ]
    if sb:
        lines.append(
            f"This worktree owns its own local Supabase stack: project_id "
            f"`{sb['project_id']}`, API {sb['api']}, DB {sb['db']}, Studio {sb['studio']}. "
            f"{'It is already running.' if sb['started'] else 'Run `supabase start` when you need it.'} "
            "`supabase/config.toml` was edited to claim those ports and marked "
            "skip-worktree so it cannot be committed — leave that flag alone, and "
            "never commit rewritten .env files."
        )
    elif (worktree / "supabase" / "config.toml").exists():
        claim = worktree / "scripts" / "worktree-supabase.sh"
        how = (f"run `scripts/worktree-supabase.sh start`"
               if claim.exists()
               else "ask before starting one — this worktree has no isolated ports yet")
        lines.append(
            "No Supabase stack was claimed for this worktree, because most tasks "
            "do not need one. **Never run a bare `supabase start` or `supabase db "
            "reset` here.** The tracked `supabase/config.toml` still pins the "
            "canonical project_id and ports, so a bare start would collide with "
            "the primary checkout's stack and a reset would wipe its database. "
            f"If you need a database, {how} first — it claims a free port block "
            "and a per-checkout project_id."
        )
    lines.append(
        f"When the work is done and merged, release the worktree with "
        f"`treehouse return --force {worktree}`"
        + (f", after `supabase stop --project-id {sb['project_id']}`." if sb else ".")
    )
    if user_prompt:
        lines.append("")
        lines.append(user_prompt)
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(prog="spin")
    ap.add_argument("--branch", required=True, help="branch to create or check out")
    ap.add_argument("--base", help="base branch (default: origin/HEAD, e.g. prod)")
    ap.add_argument("--agent", default="claude", choices=["claude", "codex"])
    ap.add_argument("--prompt", default="", help="first prompt for the new agent")
    ap.add_argument("--model", help="claude only: pass through as `claude --model <id>`")
    ap.add_argument("--repo", default=".", help="repo to branch from (default: cwd)")
    ap.add_argument("--supabase", action="store_true",
                    help="claim a per-worktree stack now (default: off — most tasks "
                         "never touch the DB, and the agent can claim one on demand)")
    ap.add_argument("--no-supabase", action="store_true",
                    help=argparse.SUPPRESS)  # now the default; kept so old callers still run
    ap.add_argument("--supabase-start", action="store_true",
                    help="run `supabase start` now (implies --supabase)")
    ap.add_argument("--session", help="open the window in this tmux session, rather than "
                                      "next to the caller's own pane")
    ap.add_argument("--pane", help="the caller's tmux pane id (default: ask the naming script)")
    ap.add_argument("--work-log", help="The Maestro's DB to record the new agent in")
    ap.add_argument("--no-window", action="store_true", help="set up but do not open tmux")
    ap.add_argument("--into", default="window", choices=["window", "pane"],
                    help="new tmux window (default) or a split of the current pane")
    ap.add_argument("--split", default="h", choices=["h", "v"],
                    help="with --into pane: h = side by side (default), v = stacked")
    ap.add_argument("--name", dest="window_name",
                    help="tmux window/pane name (default: <repo>-<branch>)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.session and args.into == "pane":
        die("--session opens a window in another session; --into pane splits this one")
    if args.pane and not args.pane.startswith("%"):
        die(f"--pane wants a tmux pane id like %12, not {args.pane}")

    repo = repo_root(Path(args.repo).expanduser().resolve())
    base = args.base or default_base(repo)
    branch = args.branch
    existing = remote_has(repo, branch)
    win = args.window_name or window_name(repo, branch)

    if args.dry_run:
        print(f"repo      {repo}")
        print(f"branch    {branch} ({'existing on origin' if existing else 'new'})")
        print(f"base      {base}")
        print(f"agent     {args.agent}")
        print(f"window    {win}")
        want_sb = (args.supabase or args.supabase_start) and not args.no_supabase
        print(f"supabase  {(repo / 'supabase/config.toml').exists() if want_sb else 'skipped (pass --supabase to claim one)'}")
        return

    if not existing and not remote_has(repo, base):
        die(f"base branch `{base}` does not exist on origin")

    git(["fetch", "origin", branch if existing else base], repo)

    worktree = lease_worktree(repo, f"spin:{branch}")
    try:
        if existing:
            git(["checkout", "-B", branch, f"origin/{branch}"], worktree)
        else:
            git(["checkout", "-b", branch, f"origin/{base}"], worktree)
    except SystemExit:
        return_worktree(repo, worktree)
        raise

    # Opt-in. Claiming a stack up front costs a rewritten config.toml and a
    # port-block row that someone has to clean up later; on 2026-08-20, 11 of
    # 17 rows in the ports file pointed at worktrees that no longer existed.
    # Most tasks never touch the DB, so the agent claims one when it needs one.
    want_supabase = (args.supabase or args.supabase_start) and not args.no_supabase
    sb = setup_supabase(worktree, branch, args.supabase_start) if want_supabase else None

    prompt = build_prompt(args.prompt, worktree, branch, base, sb, win)
    model_flag = f" --model {shlex.quote(args.model)}" if args.model and args.agent == "claude" else ""
    command = f"{args.agent}{model_flag} {shlex.quote(prompt)}"

    target = None
    new_pane = None
    if not args.no_window and args.session:
        target, new_pane = open_session_window(args.session, win, worktree, command)
    elif not args.no_window:
        # Only ask the naming script where we are when the answer matters: with
        # --session the caller has already said which session to open in.
        pane = args.pane or own_pane()
        if pane and args.into == "pane":
            target, new_pane = open_pane(pane, win, worktree, command, vertical=args.split == "v")
        elif pane:
            target, new_pane = open_window(pane, win, worktree, command)
        else:
            print("spin: not inside tmux — start the agent yourself:", file=sys.stderr)
            print(f"  cd {worktree} && {command}", file=sys.stderr)

    # Only a real pane is worth logging: without a window there is nothing for an
    # agent hook to claim the row by.
    row = None
    if args.work_log and new_pane:
        row = record_work_log(
            Path(args.work_log).expanduser(), args.agent, repo.name, branch, new_pane, worktree)

    print(f"worktree  {worktree}")
    print(f"branch    {branch} ({'tracking origin/' + branch if existing else 'new off ' + base})")
    if sb:
        print(f"supabase  block {sb['block']} — api {sb['api']}, db {sb['db']}, studio {sb['studio']}")
        print(f"          project_id {sb['project_id']}")
        if sb["envs"]:
            print(f"          env rewritten: {', '.join(sb['envs'])}")
        print("          supabase/config.toml is modified on purpose — do not commit it")
    if target:
        where = "window" if args.session else args.into
        print(f"tmux      {target} — {where} `{win}` ({args.agent} running)")
    if row:
        print(f"work-log  row {row}")
    print(f"release   treehouse return {worktree}")


if __name__ == "__main__":
    main()
