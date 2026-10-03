#!/usr/bin/env python3
"""spindown — undo one spin: stop the stack, free the ports, return the worktree.

spin leaves seven kinds of state behind. Six of them outlive the worktree, so
`treehouse return` alone is not cleanup -- it is the step that makes the rest
unreachable, because it restores supabase/config.toml and erases the only
record of which stack belonged to this branch:

  1. a leased treehouse worktree            treehouse return --force
     (a plain `git worktree add` checkout)  git worktree remove
  2. a local Supabase stack (~10 containers) supabase stop --project-id
  3. a remote stack                             remote-stack script: down
  4. a row in the ports file                  deleted here
  5. dev-server port locks in run/ports/     port-claim script: release
  6. tmux windows (agent + PR monitors)      tmux kill-window
  7. the local branch                        git branch -D

Order is the whole point: stack before worktree, worktree before branch.

Dry run by default; --yes applies. Every destructive step is gated on the
worktree being clean AND holding no commits absent from its base -- patch
identity, not PR state, because both have lied here in both directions.

Usage:
  spindown.py                        # target = the worktree you are standing in
  spindown.py --branch feat/x        # target by branch
  spindown.py --pr 1084              # target by merged PR
  spindown.py --worktree ~/.treehouse/...
  spindown.py --all                  # every spin lease whose work is merged
  spindown.py --orphans              # stacks/rows/locks with nothing behind them
  spindown.py --worktree <path> --yes --json   # one JSON result on stdout
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

TREEHOUSE_ROOT = Path.home() / ".treehouse"
PORTS_DOC = Path.home() / ".claude" / "local-ports.md"
PORT_LOCKS = Path.home() / ".claude" / "run" / "ports"
CLAIM_PORT = Path.home() / ".claude" / "scripts" / "claim-port.sh"
REMOTE_SUPABASE = Path.home() / ".claude" / "scripts" / "remote-supabase.sh"
SPIN_SCRIPTS = Path.home() / ".claude" / "skills" / "spin" / "scripts"

# Files spin rewrites on purpose. Counting config.toml as work is what wedged
# treehouse-tidy for eleven nightly runs; the same filter has to apply here.
BY_DESIGN = {"supabase/config.toml"}

# Supabase truncates project_id to 40 chars in container names.
STACK_NAME_LIMIT = 40
SUPABASE_SERVICES = sorted(
    ("analytics", "auth", "db", "edge_runtime", "imgproxy", "inbucket", "kong",
     "pg_meta", "pooler", "realtime", "rest", "storage", "studio", "vector"),
    key=len, reverse=True,
)

# Window naming must match spin's exactly or cleanup kills the wrong window.
sys.path.insert(0, str(SPIN_SCRIPTS))
try:
    from spin import window_name, slug  # noqa: E402
except ImportError:  # pragma: no cover - spin is a hard dependency
    def slug(text: str) -> str:
        return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")

    def window_name(repo: Path, branch: str) -> str:
        tail = branch.split("/", 1)[1] if "/" in branch else branch
        return f"{slug(repo.name).split('-', 1)[0]}-{slug(tail)[:20]}".strip("-")


# ------------------------------------------------------------------ primitives


def sh(cmd: list[str], cwd: Path | None = None, timeout: int = 180,
       raw: bool = False) -> tuple[int, str, str]:
    """raw=True keeps stdout byte-exact. `git status --porcelain` starts entries
    with a significant space (" M path"), and stripping it shifts every path one
    character left -- which silently turned supabase/config.toml into
    "upabase/config.toml" and defeated the BY_DESIGN filter."""
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, "", str(exc)
    return p.returncode, p.stdout if raw else p.stdout.strip(), p.stderr.strip()


def git(path: Path, *args: str, timeout: int = 180,
        raw: bool = False) -> tuple[int, str, str]:
    return sh(["git", "-C", str(path), *args], timeout=timeout, raw=raw)


def die(msg: str) -> None:
    print(f"spindown: {msg}", file=sys.stderr)
    sys.exit(1)


def live_cwds() -> list[tuple[int, str, str]]:
    """(pid, command, cwd) for every process, in one lsof pass (~0.5s)."""
    code, out, _ = sh(["lsof", "-a", "-d", "cwd", "-Fpcn"], timeout=90)
    if code != 0 and not out:
        return []
    procs, pid, comm = [], 0, "?"
    for ln in out.splitlines():
        if ln.startswith("p"):
            pid, comm = int(ln[1:] or 0), "?"
        elif ln.startswith("c"):
            comm = ln[1:]
        elif ln.startswith("n"):
            procs.append((pid, comm, ln[1:]))
    return procs


def inside(path: Path, cwds: list[tuple[int, str, str]]) -> list[tuple[int, str]]:
    """Processes whose cwd is in this worktree."""
    s = str(path)
    return [(pid, comm) for pid, comm, cwd in cwds if cwd == s or cwd.startswith(s + "/")]


def parents() -> dict[int, int]:
    code, out, _ = sh(["ps", "-eo", "pid=,ppid="], timeout=60)
    if code != 0:
        return {}
    tree = {}
    for ln in out.splitlines():
        parts = ln.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            tree[int(parts[0])] = int(parts[1])
    return tree


def descends_from(pid: int, roots: set[int], tree: dict[int, int]) -> bool:
    seen = set()
    while pid > 1 and pid not in seen:
        if pid in roots:
            return True
        seen.add(pid)
        pid = tree.get(pid, 0)
    return False


def pane_pids(window_ids: list[str]) -> set[int]:
    pids = set()
    for wid in window_ids:
        code, out, _ = sh(["tmux", "list-panes", "-t", wid, "-F", "#{pane_pid}"])
        if code == 0:
            pids.update(int(x) for x in out.split() if x.isdigit())
    return pids


# ---------------------------------------------------------------------- target


class Target:
    """One spin's worth of state. Any field may be missing; steps tolerate it."""

    def __init__(self, branch: str | None = None, worktree: Path | None = None,
                 repo: Path | None = None, lease_id: str | None = None,
                 pr: int | None = None):
        self.branch = branch
        self.worktree = worktree
        self.repo = repo
        self.lease_id = lease_id
        self.pr = pr
        self.project_id = read_project_id(worktree) if worktree else None
        self.block_base: int | None = None

    def __str__(self) -> str:
        return f"{self.branch or '?'} @ {tilde(self.worktree) if self.worktree else 'no worktree'}"


def tilde(path: Path) -> str:
    return str(path).replace(str(Path.home()), "~")


def read_project_id(worktree: Path) -> str | None:
    """Top-level project_id from supabase/config.toml; stop at the first section."""
    cfg = worktree / "supabase" / "config.toml"
    try:
        text = cfg.read_text(errors="replace")
    except OSError:
        return None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            break
        if s.startswith("project_id"):
            return s.partition("=")[2].strip().strip('"').strip("'") or None
    return None


def leases() -> list[dict]:
    """Every leased worktree treehouse knows about, with its state row."""
    out = []
    for state_file in sorted(TREEHOUSE_ROOT.glob("*/treehouse-state.json")):
        try:
            state = json.loads(state_file.read_text())
        except (OSError, ValueError):
            continue
        # A fully pruned pool serialises as {"worktrees": null}.
        for wt in state.get("worktrees") or []:
            if wt.get("leased"):
                out.append(wt)
    return out


def repo_root(start: Path) -> Path | None:
    """The git root at or above `start`. acme-app's cwd is one level above its
    git root (`acme-app/` holds `acme-app-monorepo/`), so a bare cwd is not a
    repo and every gh call from there fails."""
    code, out, _ = sh(["git", "-C", str(start), "rev-parse", "--show-toplevel"])
    return Path(out) if code == 0 and out else None


def source_repo(worktree: Path) -> Path | None:
    """The main checkout behind a worktree (parent of the shared .git dir)."""
    code, out, _ = git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return Path(out).parent if code == 0 and out else None


def branch_of(worktree: Path) -> str | None:
    code, out, _ = git(worktree, "rev-parse", "--abbrev-ref", "HEAD")
    return out if code == 0 and out not in ("", "HEAD") else None


def resolve(args: argparse.Namespace) -> list[Target]:
    if args.all:
        found = []
        for wt in leases():
            holder = wt.get("lease_holder") or ""
            if not holder.startswith("spin:"):
                continue
            path = Path(wt["path"])
            found.append(Target(branch=holder[len("spin:"):],
                                worktree=path if path.is_dir() else None,
                                repo=source_repo(path) if path.is_dir() else None,
                                lease_id=wt.get("lease_id")))
        return found

    if args.worktree:
        path = Path(args.worktree).expanduser().resolve()
        if not path.is_dir():
            die(f"{path} is not a directory")
        return [from_worktree(path)]

    branch = args.branch
    if args.pr:
        repo = repo_root(Path(args.repo or ".").expanduser().resolve())
        if repo is None:
            die(f"{args.repo or Path.cwd()} is not inside a git repo — pass --repo")
        code, out, err = sh(["gh", "pr", "view", str(args.pr), "--json",
                             "headRefName,state,mergedAt"], cwd=repo)
        if code != 0:
            die(f"gh pr view {args.pr} failed: {err or out}")
        branch = json.loads(out)["headRefName"]

    if branch:
        for wt in leases():
            if (wt.get("lease_holder") or "") == f"spin:{branch}":
                path = Path(wt["path"])
                return [Target(branch=branch,
                               worktree=path if path.is_dir() else None,
                               repo=source_repo(path) if path.is_dir() else None,
                               lease_id=wt.get("lease_id"), pr=args.pr)]
        # No lease: the worktree may already be gone, or it was never a spin.
        repo = repo_root(Path(args.repo or ".").expanduser().resolve()) or Path.cwd()
        code, out, _ = git(repo, "worktree", "list", "--porcelain")
        path = None
        if code == 0:
            current = None
            for line in out.splitlines():
                if line.startswith("worktree "):
                    current = Path(line.split(" ", 1)[1])
                elif line == f"branch refs/heads/{branch}" and current:
                    path = current
                    break
        t = from_worktree(path) if path and path.is_dir() else Target(branch=branch)
        t.branch, t.pr = branch, args.pr
        t.repo = t.repo or repo
        return [t]

    # No target given: use the worktree we are standing in.
    root_path = repo_root(Path.cwd().resolve())
    if root_path is None:
        die("not in a git repo — pass --branch, --worktree, --pr, --all or --orphans")
    if TREEHOUSE_ROOT not in root_path.parents:
        die(f"{tilde(root_path)} is not a treehouse worktree — pass --branch/--worktree, "
            "or --orphans to sweep leftovers")
    return [from_worktree(root_path)]


def from_worktree(path: Path) -> Target:
    lease_id = None
    for wt in leases():
        if Path(wt["path"]) == path:
            lease_id = wt.get("lease_id")
    return Target(branch=branch_of(path), worktree=path,
                  repo=source_repo(path), lease_id=lease_id)


# ----------------------------------------------------------------------- gates


def default_ref(path: Path) -> str | None:
    code, out, _ = git(path, "symbolic-ref", "refs/remotes/origin/HEAD")
    if code == 0 and out:
        return out.removeprefix("refs/remotes/")
    for cand in ("origin/prod", "origin/main", "origin/master"):
        if git(path, "rev-parse", "--verify", cand)[0] == 0:
            return cand
    return None


def dirty_paths(path: Path) -> list[str] | None:
    code, out, _ = git(path, "status", "--porcelain", "-z", "--untracked-files=all",
                       raw=True)
    if code != 0:
        return None
    return [e[3:] for e in out.split("\0") if len(e) > 3 and e[3:] not in BY_DESIGN]


def unique_commits(path: Path, base: str) -> list[str] | None:
    """Commits whose PATCH is absent from base.

    Not `merge-base --is-ancestor` and not the PR state: stale tracking refs
    once made 27 merged commits look unpushed, and six branches with a MERGED
    PR held commits prod had never seen. Patch identity got both right.
    """
    code, out, _ = git(path, "cherry", base, "HEAD")
    if code != 0:
        return None
    return [ln[2:] for ln in out.splitlines() if ln.startswith("+")]


def pr_state(repo: Path | None, branch: str | None) -> str | None:
    """MERGED / OPEN / CLOSED for the branch's PR — reported, never trusted alone."""
    if not repo or not branch:
        return None
    code, out, _ = sh(["gh", "pr", "list", "--head", branch, "--state", "all",
                       "--json", "number,state", "--limit", "1"], cwd=repo, timeout=60)
    if code != 0:
        return None
    try:
        rows = json.loads(out)
    except ValueError:
        return None
    return rows[0]["state"] if rows else None


def gate(t: Target, cwds: list[tuple[int, str, str]], force: bool,
         keep_tmux: bool = False) -> tuple[bool, list[str]]:
    """(safe to destroy, reasons). Reasons are printed either way."""
    notes = []
    state = pr_state(t.repo, t.branch)
    if state:
        notes.append(f"PR is {state}")

    if t.worktree is None or not t.worktree.is_dir():
        notes.append("worktree already gone — cleaning up what it left behind")
        return True, notes

    if Path.cwd().resolve() == t.worktree or t.worktree in Path.cwd().resolve().parents:
        return False, notes + ["you are standing in it — cd out first, "
                               "`treehouse return` would kill this shell"]

    busy = inside(t.worktree, cwds)
    if busy and not force:
        # The commonest blocker after a merge is the spun agent's OWN tmux
        # window, still sitting in the worktree. That window is on this
        # cleanup's kill list, so counting it as "in use" would make the
        # worktree permanently unreclaimable. Anything else is a real user.
        doomed = pane_pids([w for w, _, _ in doomed_windows(t)]) if not keep_tmux else set()
        tree = parents() if doomed else {}
        outsiders = [(pid, comm) for pid, comm in busy
                     if not descends_from(pid, doomed, tree)]
        if outsiders:
            who = ", ".join(f"{c}({p})" for p, c in outsiders[:3])
            return False, notes + [f"{len(outsiders)} process(es) still inside it: {who}"]
        notes.append(f"{len(busy)} process(es) inside it belong to its own tmux window")

    base = default_ref(t.worktree)
    if base is None:
        return force, notes + ["no remote default branch to compare against"]
    git(t.worktree, "fetch", "--prune", "origin", base.split("/", 1)[1], timeout=300)

    dirty = dirty_paths(t.worktree)
    if dirty is None:
        return force, notes + ["git could not read the worktree"]
    unique = unique_commits(t.worktree, base)
    if unique is None:
        return force, notes + [f"could not compare against {base}"]

    if dirty or unique:
        why = []
        if unique:
            why.append(f"{len(unique)} commit(s) not in {base}")
        if dirty:
            why.append("uncommitted: " + ", ".join(dirty[:3])
                       + ("..." if len(dirty) > 3 else ""))
        return force, notes + ["HAS WORK — " + "; ".join(why)]

    notes.append(f"clean, every commit is in {base}")
    return True, notes


# ----------------------------------------------------------------------- steps


def running_stacks() -> set[str] | None:
    code, out, _ = sh(["docker", "ps", "--format", "{{.Names}}"], timeout=180)
    if code != 0:
        return None
    stacks = set()
    for name in out.split():
        # supabase_<service>_<project_id>; pg_meta and edge_runtime contain an
        # underscore themselves, so match the service explicitly, longest first.
        for svc in SUPABASE_SERVICES:
            prefix = f"supabase_{svc}_"
            if name.startswith(prefix) and name[len(prefix):]:
                stacks.add(name[len(prefix):])
                break
    return stacks


def stack_matches(stack: str, project_id: str) -> bool:
    return stack == project_id or (
        len(stack) == STACK_NAME_LIMIT and project_id.startswith(stack))


def step_local_stack(t: Target, apply: bool, drop_volumes: bool) -> list[str]:
    """FIRST. treehouse return restores config.toml, which erases project_id."""
    if not t.project_id:
        return []
    running = running_stacks()
    if running is None:
        return ["supabase: skipped — docker did not answer"]
    if not any(stack_matches(s, t.project_id) for s in running):
        return [f"supabase: {t.project_id} is not running"]
    if not apply:
        return [f"supabase: would stop {t.project_id}"
                + (" and drop volumes" if drop_volumes else "")]
    cmd = ["supabase", "stop", "--project-id", t.project_id, "--yes"]
    if drop_volumes:
        cmd.append("--no-backup")
    code, _, err = sh(cmd, cwd=t.worktree, timeout=900)
    return [f"supabase: stopped {t.project_id}" if code == 0
            else f"supabase: stop failed — {err.splitlines()[-1] if err else '?'}"]


def step_remote_stack(t: Target, apply: bool) -> list[str]:
    """Remote stacks are keyed by an id the agent chose — usually the branch."""
    if not REMOTE_SUPABASE.exists() or not t.branch:
        return []
    code, out, _ = sh([str(REMOTE_SUPABASE), "list"], timeout=120)
    if code != 0:
        return []
    keys = {slug(t.branch), slug(t.branch.split("/", 1)[-1])}
    if t.project_id:
        keys.add(t.project_id)
    hits = [ln.split()[0] for ln in out.splitlines()
            if ln.strip() and any(k and k in ln for k in keys)]
    lines = []
    for stack in dict.fromkeys(hits):
        if not apply:
            lines.append(f"remote supabase: would stop {stack} on the remote host")
            continue
        code, _, err = sh([str(REMOTE_SUPABASE), "down", stack], timeout=600)
        lines.append(f"remote supabase: stopped {stack}" if code == 0
                     else f"remote supabase: down {stack} failed — {err[-120:]}")
    return lines


def own_window() -> str | None:
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return None
    code, out, _ = sh(["tmux", "display-message", "-p", "-t", pane, "#{window_id}"])
    return out if code == 0 else None


def tmux_windows() -> list[tuple[str, str, str]]:
    code, out, _ = sh(["tmux", "list-windows", "-a", "-F",
                       "#{window_id}\t#{session_name}:#{window_index}\t#{window_name}"])
    if code != 0:
        return []
    return [tuple(ln.split("\t", 2)) for ln in out.splitlines() if ln.count("\t") == 2]


def window_targets(t: Target) -> list[str]:
    """Names spin and pr-workflow give this branch's windows."""
    names = []
    if t.repo and t.branch:
        names.append(window_name(t.repo, t.branch))
    if t.worktree and t.branch:
        names.append(window_name(t.worktree, t.branch))
    return [n for n in dict.fromkeys(names) if n]


def doomed_windows(t: Target) -> list[tuple[str, str, str]]:
    """The tmux windows this cleanup owns: the spun agent's, and its PR monitor.

    Never the caller's own window. Called by the gate too, so a worktree is not
    judged "in use" by the very shell this is about to kill.
    """
    bases = window_targets(t)
    mine = own_window()
    hits = []
    for wid, target, name in tmux_windows():
        if wid == mine:
            continue
        low = name.lower()
        # spin's own window, possibly carrying status tags (`name 👀123`) or an
        # older `-pr123` suffix from the agent.
        hit = any(low == b or low.startswith(b + "-") or low.startswith(b + " ")
                  for b in bases)
        # a PR monitor: names vary ("monitor-pr-448", "PR#450 monitor").
        if not hit and t.pr:
            hit = bool(re.search(rf"(?<!\d){t.pr}(?!\d)", name)) and (
                "pr" in low or "monitor" in low)
        if hit:
            hits.append((wid, target, name))
    return hits


def step_tmux(t: Target, apply: bool) -> list[str]:
    lines = []
    for wid, target, name in doomed_windows(t):
        if not apply:
            lines.append(f"tmux: would kill {target} `{name}`")
            continue
        code, _, err = sh(["tmux", "kill-window", "-t", wid])
        lines.append(f"tmux: killed {target} `{name}`" if code == 0
                     else f"tmux: kill {target} failed — {err}")
    return lines


def lock_owner(lock: Path) -> str:
    """Who claimed this port. Two writers use two schemas for the same fact:
    the port-claim script writes `project`, the worktree script writes `claimed_by`."""
    try:
        data = json.loads(lock.read_text())
    except (OSError, ValueError):
        return ""
    return str(data.get("project") or data.get("claimed_by") or "")


def listening(port: int) -> bool:
    code, _, _ = sh(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], timeout=30)
    return code == 0


def step_port_locks(t: Target, apply: bool) -> list[str]:
    """Release dead locks belonging to this worktree. A LIVE port is never touched."""
    if not PORT_LOCKS.is_dir():
        return []
    # Only branch-unique keys. The worktree directory is named after the REPO,
    # so matching on it released ports another agent on the same repo had
    # claimed (54500-54504 in the 2026-08-26 dry run).
    keys = {k for k in (
        t.project_id,
        slug(t.branch.split("/", 1)[-1]) if t.branch else None,
    ) if k and len(k) > 3}
    block_ports = set(range(t.block_base, t.block_base + 10)) if t.block_base else set()
    lines = []
    for lock in sorted(PORT_LOCKS.glob("*.json")):
        try:
            port = int(lock.stem)
        except ValueError:
            continue
        owner = lock_owner(lock)
        # A block port whose lock names a DIFFERENT project was re-claimed by
        # someone else after this row was written; the row is stale, the lock
        # is not. Only take an unowned lock on block-membership alone.
        hit = any(k in owner for k in keys) or (port in block_ports and not owner)
        if not hit:
            continue
        if listening(port):
            lines.append(f"ports: {port} still LIVE — left claimed ({owner})")
            continue
        if not apply:
            lines.append(f"ports: would release {port} ({owner})")
            continue
        code, _, err = sh([str(CLAIM_PORT), "release", str(port)]) if CLAIM_PORT.exists() \
            else (0, "", "")
        if code != 0:
            lines.append(f"ports: release {port} failed — {err}")
            continue
        lock.unlink(missing_ok=True)
        lines.append(f"ports: released {port} ({owner})")
    return lines


ROW = re.compile(r"^\|\s*(\d+)\s*\|\s*(54\d{3})\s*\|")


def step_ports_doc(t: Target, apply: bool) -> list[str]:
    """Drop this spin's row from the Supabase registry — the registry is the lock."""
    if not PORTS_DOC.exists():
        return []
    keys = [k for k in (t.project_id, str(t.worktree) if t.worktree else None) if k]
    if t.branch:
        keys.append(f"branch {t.branch},")
    lines = PORTS_DOC.read_text().splitlines()
    keep, dropped = [], []
    for line in lines:
        m = ROW.match(line)
        if m and "spin" in line and any(k in line for k in keys):
            dropped.append(line)
            t.block_base = t.block_base or int(m.group(2))
            continue
        keep.append(line)
    if not dropped:
        return []
    out = [f"ports doc: {'would drop' if not apply else 'dropped'} block "
           f"{ROW.match(d).group(1)} ({d.split('|')[4].strip()})" for d in dropped]
    if apply:
        PORTS_DOC.write_text("\n".join(keep) + "\n")
    return out


def step_worktree(t: Target, apply: bool) -> list[str]:
    """LAST among the worktree steps: this restores config.toml and drops the lease."""
    if t.worktree is None or not t.worktree.is_dir():
        return []
    if not t.lease_id and TREEHOUSE_ROOT not in t.worktree.parents:
        return step_plain_worktree(t, apply)
    if not apply:
        return [f"treehouse: would return {tilde(t.worktree)}"]
    cmd = ["treehouse", "return", "--force", str(t.worktree)]
    if t.lease_id:
        cmd += ["--if-lease-id", t.lease_id]
    code, out, err = sh(cmd, cwd=t.repo or Path.home(), timeout=600)
    return [f"treehouse: returned {tilde(t.worktree)}" if code == 0
            else f"treehouse: return failed — {(err or out).splitlines()[-1:] or '?'}"]


def step_plain_worktree(t: Target, apply: bool) -> list[str]:
    """A `git worktree add` checkout that no treehouse pool owns. git made it, so
    git removes it. --force only because the gate already passed: the one thing
    left that plain `worktree remove` refuses is a BY_DESIGN file."""
    if not t.repo or t.repo == t.worktree:
        return [f"git: {tilde(t.worktree)} is not a linked worktree — left alone"]
    if not apply:
        return [f"git: would remove worktree {tilde(t.worktree)}"]
    code, out, err = git(t.repo, "worktree", "remove", "--force", str(t.worktree))
    if code != 0:
        return [f"git: worktree remove failed — {((err or out).splitlines() or ['?'])[-1]}"]
    git(t.repo, "worktree", "prune")
    return [f"git: removed worktree {tilde(t.worktree)}"]


def step_branch(t: Target, apply: bool, delete_remote: bool) -> list[str]:
    """Delete the merged local branch in the source repo, and prune stale refs."""
    if not t.repo or not t.branch or not t.repo.is_dir():
        return []
    lines = []
    if git(t.repo, "rev-parse", "--verify", f"refs/heads/{t.branch}")[0] == 0:
        if not apply:
            lines.append(f"git: would delete local branch {t.branch}")
        else:
            code, _, err = git(t.repo, "branch", "-D", t.branch)
            lines.append(f"git: deleted local branch {t.branch}" if code == 0
                         else f"git: branch -D failed — {err}")
    if delete_remote and sh(["git", "ls-remote", "--heads", "origin", t.branch],
                            cwd=t.repo)[1]:
        if not apply:
            lines.append(f"git: would delete origin/{t.branch}")
        else:
            code, _, err = git(t.repo, "push", "origin", "--delete", t.branch, timeout=300)
            lines.append(f"git: deleted origin/{t.branch}" if code == 0
                         else f"git: remote delete failed — {err}")
    if apply:
        git(t.repo, "fetch", "--prune", "origin", timeout=300)
        git(t.repo, "worktree", "prune")
    return lines


# --------------------------------------------------------------------- orphans


def known_project_ids() -> set[str]:
    ids = set()
    globs = (
        (TREEHOUSE_ROOT, "*/*/*/supabase/config.toml"),
        (Path.home() / "code" / "github", "*/supabase/config.toml"),
        (Path.home() / "code" / "github", "*/*/supabase/config.toml"),
        (Path.home() / "code" / "github", "*/.worktrees/*/supabase/config.toml"),
    )
    for root, pattern in globs:
        if not root.is_dir():
            continue
        for cfg in root.glob(pattern):
            pid = read_project_id(cfg.parent.parent)
            if pid:
                ids.add(pid)
    return ids


def sweep_orphans(apply: bool, drop_volumes: bool) -> list[str]:
    """State with nothing behind it: dead rows, dead locks, stackless containers."""
    lines = []

    # 1. Registry rows whose worktree is gone.
    if PORTS_DOC.exists():
        kept, dropped = [], []
        for line in PORTS_DOC.read_text().splitlines():
            m = re.search(r"spin worktree (\S+)", line)
            if m and ROW.match(line) and not Path(m.group(1)).is_dir():
                dropped.append(line)
                continue
            kept.append(line)
        for d in dropped:
            lines.append(f"ports doc: {'dropped' if apply else 'would drop'} stale row — "
                         f"{d.split('|')[4].strip()}")
        if dropped and apply:
            PORTS_DOC.write_text("\n".join(kept) + "\n")

    # 2. Port locks with nothing listening and no lease behind them.
    live_paths = {str(Path(wt["path"])) for wt in leases()}
    if PORT_LOCKS.is_dir():
        for lock in sorted(PORT_LOCKS.glob("*.json")):
            try:
                port = int(lock.stem)
            except ValueError:
                continue
            owner = lock_owner(lock)
            try:
                age_h = (time.time() - lock.stat().st_mtime) / 3600
            except OSError:
                continue
            # 24h floor: a lock claimed minutes ago belongs to an agent whose
            # server has not booted yet, and stealing it is worse than leaking it.
            if age_h < 24 or listening(port):
                continue
            if any(owner and owner in p for p in live_paths):
                continue
            lines.append(f"ports: {'released' if apply else 'would release'} dead lock "
                         f"{port} ({owner or 'unknown'}, idle {age_h/24:.0f}d)")
            if apply:
                lock.unlink(missing_ok=True)

    # 3. Supabase stacks whose project_id has no worktree or repo behind it.
    running = running_stacks()
    if running is None:
        lines.append("supabase: skipped — docker did not answer")
    else:
        known = known_project_ids()
        for stack in sorted(running):
            if any(stack_matches(stack, pid) for pid in known):
                continue
            if not apply:
                lines.append(f"supabase: would stop orphan {stack}")
                continue
            cmd = ["supabase", "stop", "--project-id", stack, "--yes"]
            if drop_volumes:
                cmd.append("--no-backup")
            code, _, err = sh(cmd, timeout=900)
            lines.append(f"supabase: stopped orphan {stack}" if code == 0
                         else f"supabase: stop {stack} failed — {err[-120:]}")

    # 4. Remote stacks idle past their TTL.
    if REMOTE_SUPABASE.exists() and apply:
        code, out, _ = sh([str(REMOTE_SUPABASE), "reap"], timeout=600)
        if code == 0 and out:
            lines.append("remote supabase: " + out.replace("\n", "; ")[:200])

    return lines or ["nothing orphaned"]


# ------------------------------------------------------------------------ main


def clean(t: Target, apply: bool, args: argparse.Namespace) -> list[str]:
    """Order is load-bearing: stack -> ports -> tmux -> worktree -> branch."""
    lines = []
    lines += step_local_stack(t, apply, args.drop_volumes)
    if not args.no_remote:
        lines += step_remote_stack(t, apply)
    lines += step_ports_doc(t, apply)      # sets block_base for the lock step
    lines += step_port_locks(t, apply)
    if not args.keep_tmux:
        lines += step_tmux(t, apply)
    lines += step_worktree(t, apply)
    lines += step_branch(t, apply, args.delete_remote)
    return lines or ["nothing left to clean"]


def main() -> int:
    ap = argparse.ArgumentParser(prog="spindown", description=__doc__.splitlines()[0])
    ap.add_argument("--branch", help="branch whose spin state to clean up")
    ap.add_argument("--worktree", help="worktree path to clean up")
    ap.add_argument("--pr", type=int, help="PR number; resolves to its head branch")
    ap.add_argument("--repo", help="source repo (default: cwd)")
    ap.add_argument("--all", action="store_true",
                    help="every spin lease whose work is merged and clean")
    ap.add_argument("--orphans", action="store_true",
                    help="sweep state with nothing behind it (rows, locks, stacks)")
    ap.add_argument("--yes", action="store_true", help="apply (default is a dry run)")
    ap.add_argument("--force", action="store_true",
                    help="clean up even with unmerged commits or a live process")
    ap.add_argument("--keep-tmux", action="store_true", help="leave tmux windows alone")
    ap.add_argument("--delete-remote", action="store_true",
                    help="also delete origin/<branch> (GitHub usually does this)")
    ap.add_argument("--no-remote", action="store_true", help="skip the remote host stack check")
    ap.add_argument("--drop-volumes", action="store_true",
                    help="delete Supabase data volumes, not just the containers")
    ap.add_argument("--json", action="store_true",
                    help="print one JSON result to stdout; human output goes to stderr")
    args = ap.parse_args()

    # --json keeps stdout parseable: every human line goes to stderr instead.
    stdout, report = sys.stdout, []
    if args.json:
        sys.stdout = sys.stderr
    code = run(args, report)
    if args.json:
        print(json.dumps({"targets": report, "applied": args.yes}), file=stdout)
    return code


def run(args: argparse.Namespace, report: list[dict]) -> int:
    apply = args.yes
    held = 0

    if args.orphans and not (args.all or args.branch or args.worktree or args.pr):
        print("--- orphaned state" + ("" if apply else " (dry run)") + " ---")
        for line in sweep_orphans(apply, args.drop_volumes):
            print(f"  {line}")
        if not apply:
            print("\nDry run. Re-run with --yes to apply.")
        return 0

    targets = resolve(args)
    if not targets:
        print("No spin worktrees leased.")
        return 0

    cwds = live_cwds()
    for t in targets:
        print(f"\n=== {t}")
        ok, notes = gate(t, cwds, args.force, args.keep_tmux)
        for note in notes:
            print(f"  · {note}")
        row = {"worktree": str(t.worktree) if t.worktree else None, "branch": t.branch,
               "cleaned": False, "skipped": [], "actions": []}
        report.append(row)
        if not ok:
            held += 1
            row["skipped"] = notes[-1:]  # the gate appends its blocking reason last
            print("  SKIPPED — left completely alone" +
                  ("" if args.force else " (pass --force to override)"))
            continue
        row["actions"] = clean(t, apply, args)
        # Every step reports its own failure as "... failed — why".
        row["cleaned"] = apply and not any(" failed" in ln for ln in row["actions"])
        for line in row["actions"]:
            print(f"  {'✓' if apply else '·'} {line}")

    if args.orphans:
        print("\n--- orphaned state" + ("" if apply else " (dry run)") + " ---")
        for line in sweep_orphans(apply, args.drop_volumes):
            print(f"  {line}")

    if held:
        print(f"\n{held} target(s) hold work and were left alone.")
    if not apply:
        print("\nDry run. Re-run with --yes to apply.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
