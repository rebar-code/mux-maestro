#!/usr/bin/env python3
"""Observe running Claude Code sessions.

Reads ~/.claude/sessions/*.json (live PID, cwd, gitBranch, status) and the
per-project sessions-index.json (summaries, first prompt, message counts), then
cross-references against tmux sessions so Sidekick knows which tmux session maps
to which Claude session.

CLI:
    sessions.py list            # all running sessions, JSON
    sessions.py status <name>   # one session by tmux name or session id, JSON
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
SESSIONS_DIR = CLAUDE_DIR / "sessions"
PROJECTS_DIR = CLAUDE_DIR / "projects"


def _pid_alive(pid: int) -> bool:
    try:
        import os

        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False
    except PermissionError:
        return True


def load_live_sessions() -> list[dict]:
    """Read every ~/.claude/sessions/*.json that points at a live process."""
    out: list[dict] = []
    if not SESSIONS_DIR.exists():
        return out
    for f in SESSIONS_DIR.glob("*.json"):
        try:
            data = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        pid = data.get("pid")
        if not isinstance(pid, int) or not _pid_alive(pid):
            continue
        out.append(data)
    return out


def _project_dirname(project_path: str) -> str:
    """Claude Code's project-dir munging: every non-alphanumeric char -> '-'.

    (Not just '/': a cwd containing '.' or '_' maps to '-' too, e.g.
    /Users/me/.claude -> -Users-me--claude.)
    """
    return re.sub(r"[^a-zA-Z0-9]", "-", project_path)


def _index_for_path(project_path: str) -> dict[str, dict]:
    """Map sessionId -> index entry for a given project filesystem path."""
    idx = PROJECTS_DIR / _project_dirname(project_path) / "sessions-index.json"
    result: dict[str, dict] = {}
    if not idx.exists():
        return result
    try:
        data = json.loads(idx.read_text())
    except (json.JSONDecodeError, OSError):
        return result
    for entry in data.get("entries", []):
        sid = entry.get("sessionId")
        if sid:
            result[sid] = entry
    return result


def _fallback_from_jsonl(project_path: str, session_id: str) -> dict:
    """Read summary fields straight from the session transcript.

    sessions-index.json is a lazily rebuilt cache — Claude Code can leave it
    days stale, so recent sessions are often missing from it and would come
    back with null firstPrompt/gitBranch/messageCount. The transcript itself
    is always current.
    """
    path = PROJECTS_DIR / _project_dirname(project_path) / f"{session_id}.jsonl"
    first_prompt = None
    git_branch = None
    count = 0
    try:
        with path.open() as f:
            for line in f:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                kind = d.get("type")
                if kind not in ("user", "assistant"):
                    continue
                count += 1
                if git_branch is None and d.get("gitBranch"):
                    git_branch = d["gitBranch"]
                if first_prompt is None and kind == "user" and not d.get("isMeta"):
                    content = (d.get("message") or {}).get("content")
                    if isinstance(content, list):
                        content = " ".join(
                            b.get("text", "")
                            for b in content
                            if isinstance(b, dict) and b.get("type") == "text"
                        )
                    text = (content or "").strip()
                    # Skip harness wrappers (slash-command echoes, caveats).
                    if text and not text.startswith(("<", "Caveat:")):
                        first_prompt = text[:200]
    except OSError:
        return {}
    if count == 0:
        return {}
    return {
        "firstPrompt": first_prompt,
        "gitBranch": git_branch,
        "messageCount": count,
    }


def _ppid_map() -> dict[int, int]:
    """pid -> parent pid, for walking a process up to its tmux pane shell."""
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid=,ppid="], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    m: dict[int, int] = {}
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                m[int(parts[0])] = int(parts[1])
            except ValueError:
                continue
    return m


def pane_for_pid(pid: int, ppid: dict[int, int] | None = None) -> str | None:
    """The tmux pane whose shell is an ancestor of `pid`.

    A Claude session's pid is a child of the shell that tmux runs in its pane,
    so we map pane -> pane_pid (the shell) and walk `pid` up its parent chain
    until we hit one. This is how a picked session resolves to the exact pane
    voice must `send-keys` into. None if the session isn't in any tmux pane.
    """
    try:
        raw = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if raw.returncode != 0:
        return None
    pane_by_shell: dict[int, str] = {}
    for line in raw.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                pane_by_shell[int(parts[1])] = parts[0]
            except ValueError:
                continue
    parents = ppid if ppid is not None else _ppid_map()
    cur = pid
    seen: set[int] = set()
    while cur and cur not in seen:
        if cur in pane_by_shell:
            return pane_by_shell[cur]
        seen.add(cur)
        cur = parents.get(cur, 0)
    return None


def tmux_sessions() -> list[dict]:
    """List tmux sessions with their current pane path."""
    try:
        raw = subprocess.run(
            [
                "tmux",
                "list-sessions",
                "-F",
                "#{session_name}\t#{session_attached}\t#{pane_current_path}",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    if raw.returncode != 0:
        return []
    sessions = []
    for line in raw.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        sessions.append(
            {"name": parts[0], "attached": parts[1] != "0", "cwd": parts[2]}
        )
    return sessions


def _match_tmux(cwd: str, tmuxes: list[dict]) -> str | None:
    """Find the tmux session whose pane path matches a Claude session cwd."""
    for t in tmuxes:
        if t["cwd"] == cwd:
            return t["name"]
    # Fall back to a prefix match (Claude may have cd'd into a subdir).
    for t in tmuxes:
        if cwd.startswith(t["cwd"]) or t["cwd"].startswith(cwd):
            return t["name"]
    return None


def enrich() -> list[dict]:
    """Full picture: live sessions + index summaries + tmux mapping.

    `pane` is the exact tmux pane id the session's Claude runs in (via pid
    ancestry) — what voice re-targets to. Only interactive sessions sitting in a
    tmux pane are drivable; the rest list with pane=None.
    """
    tmuxes = tmux_sessions()
    ppid = _ppid_map()
    result: list[dict] = []
    for s in load_live_sessions():
        cwd = s.get("cwd", "")
        sid = s.get("sessionId", "")
        pid = s.get("pid")
        index = _index_for_path(cwd).get(sid) or _fallback_from_jsonl(cwd, sid)
        result.append(
            {
                "sessionId": sid,
                "pid": pid,
                "cwd": cwd,
                "gitBranch": s.get("gitBranch") or index.get("gitBranch"),
                "status": s.get("status", "unknown"),
                "kind": s.get("kind"),
                "summary": index.get("summary"),
                "firstPrompt": index.get("firstPrompt"),
                "messageCount": index.get("messageCount"),
                "tmuxSession": _match_tmux(cwd, tmuxes),
                "pane": pane_for_pid(pid, ppid) if isinstance(pid, int) else None,
                # Last-activity ms epoch (status change), for newest-first ordering.
                "updatedAt": s.get("statusUpdatedAt") or s.get("updatedAt") or 0,
            }
        )
    return result


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else "list"
    sessions = enrich()
    if cmd == "list":
        print(json.dumps(sessions, indent=2))
        return 0
    if cmd == "status":
        if len(argv) < 2:
            print("usage: sessions.py status <tmux-name|session-id>", file=sys.stderr)
            return 2
        key = argv[1]
        for s in sessions:
            if key in (s.get("tmuxSession"), s.get("sessionId")):
                print(json.dumps(s, indent=2))
                return 0
        print(json.dumps({"error": f"no running session matching '{key}'"}))
        return 1
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
