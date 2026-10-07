#!/usr/bin/env python3
"""Observe running Claude Code sessions.

Reads ~/.claude/sessions/*.json (live PID, cwd, gitBranch, status) and the
per-project sessions-index.json (summaries, first prompt, message counts), then
cross-references against tmux sessions so Sidekick knows which tmux session maps
to which Claude session.

CLI:
    sessions.py list            # all running sessions, JSON
    sessions.py list --full     # the same, with each transcript's last prompt
                                # and last write, and the live Codex panes
    sessions.py status <name>   # one session by tmux name or session id, JSON

`list --full` is what the app asks a remote host for: the app cannot read that
host's disk, so the script reads the transcripts there. Plain `list` prints
what it always did. An older copy of this script ignores `--full`.

Rows of `list --full`, beside the Claude rows:
    {"agent": "codex", "codexSessionId", "codexPane", "rolloutPath",
     "lastPrompt", "lastWriteAt"}     one for each live Codex process
    {"agent": "meta", "schema": 2}    says this copy knows `--full`
Neither has `sessionId`, `pane`, `tmuxSession` or `status`: a reader of Claude
rows skips them.
"""

from __future__ import annotations

import calendar
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
SESSIONS_DIR = CLAUDE_DIR / "sessions"
PROJECTS_DIR = CLAUDE_DIR / "projects"
CODEX_SESSIONS_DIR = Path.home() / ".codex" / "sessions"
# What `list --full` found last time, so a transcript that did not change is
# not read again. It holds prompt text: the file is private to the user.
TAIL_CACHE = Path.home() / ".muxmaestro" / "cache" / "tails.json"
# Where Linux lists each process's open files.
PROC_DIR = "/proc"

# The output format of `list --full`. The app pushes its copy again when a
# host's copy does not say this.
SCHEMA = 2
# The same limits as the app's own reader (`TranscriptTailReader`).
PROMPT_MAX = 200
TAIL_BYTES = 64_000
PROMPT_CAP_BYTES = 2_000_000
# How much of a rollout's first line holds `session_id`.
ROLLOUT_HEAD_BYTES = 4096
SESSION_ID = re.compile(r"[A-Za-z0-9-]{1,128}\Z")


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


def _pane_shells() -> dict[int, str]:
    """pane_pid (the shell tmux runs in a pane) -> pane id, for every pane."""
    try:
        raw = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if raw.returncode != 0:
        return {}
    pane_by_shell: dict[int, str] = {}
    for line in raw.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                pane_by_shell[int(parts[1])] = parts[0]
            except ValueError:
                continue
    return pane_by_shell


def pane_for_pid(
    pid: int,
    ppid: dict[int, int] | None = None,
    panes: dict[int, str] | None = None,
) -> str | None:
    """The tmux pane whose shell is an ancestor of `pid`.

    A Claude session's pid is a child of the shell that tmux runs in its pane,
    so we map pane -> pane_pid (the shell) and walk `pid` up its parent chain
    until we hit one. This is how a picked session resolves to the exact pane
    voice must `send-keys` into. None if the session isn't in any tmux pane.
    """
    pane_by_shell = panes if panes is not None else _pane_shells()
    parents = ppid if ppid is not None else _ppid_map()
    cur = pid
    seen: set[int] = set()
    while cur and cur not in seen:
        if cur in pane_by_shell:
            return pane_by_shell[cur]
        seen.add(cur)
        cur = parents.get(cur, 0)
    return None


# --- transcript tails (`list --full`) ---------------------------------------
#
# These follow the app's `LastPrompt` and `TranscriptTailReader` (AgentState.swift)
# rule for rule, so a row of a remote host reads like a row of this Mac.

_TIMESTAMP = re.compile(
    r"(\d{4})-(\d\d)-(\d\d)[Tt](\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:[Zz]|([+-])(\d\d):?(\d\d))\Z"
)


def _epoch(stamp: object) -> int | None:
    """Epoch seconds of an ISO 8601 time with a zone, or None."""
    m = _TIMESTAMP.match(stamp) if isinstance(stamp, str) else None
    if not m:
        return None
    try:
        at = calendar.timegm(tuple(int(m.group(i)) for i in range(1, 7)))
    except (ValueError, OverflowError):
        return None
    if m.group(7):
        offset = int(m.group(8)) * 3600 + int(m.group(9)) * 60
        at += -offset if m.group(7) == "+" else offset
    return at


def _first_line(raw: object) -> str | None:
    """The first non-empty line, cut to PROMPT_MAX. None when there is none or
    the text is not a human prompt (it opens with `<`, or is an interrupt)."""
    if not isinstance(raw, str):
        return None
    trimmed = raw.strip()
    if trimmed.startswith("<") or trimmed.startswith("[Request interrupted"):
        return None
    for line in trimmed.splitlines():
        line = line.strip()
        if line:
            return line[:PROMPT_MAX]
    return None


def _shell_command(text: object) -> object:
    """`<bash-input>cmd</bash-input>` as `! cmd`; any other text unchanged."""
    if not isinstance(text, str) or not text.startswith("<bash-input>"):
        return text
    command = text[len("<bash-input>") :].replace("</bash-input>", "").strip()
    return "! " + command


def _blocks(content: object) -> list[dict] | None:
    if isinstance(content, list) and all(isinstance(b, dict) for b in content):
        return content
    return None


def _claude_prompt(entry: dict) -> object:
    """The text of a Claude Code transcript entry when a person typed it.

    Not prompts: tool results, `isMeta` and compact-summary entries. A message
    typed while the agent was busy (a human `queued_command`) counts.
    """
    kind = entry.get("type")
    if kind == "attachment":
        queued = entry.get("attachment")
        if (
            isinstance(queued, dict)
            and queued.get("type") == "queued_command"
            and queued.get("commandMode") == "prompt"
            and isinstance(queued.get("origin"), dict)
            and queued["origin"].get("kind") == "human"
        ):
            return queued.get("prompt")
        return None
    if kind != "user" or entry.get("isMeta") is True or entry.get("isCompactSummary") is True:
        return None
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return _shell_command(content)
    blocks = _blocks(content)
    if blocks is None or any(b.get("type") == "tool_result" for b in blocks):
        return None
    for block in blocks:
        if block.get("type") == "text":
            return _shell_command(block.get("text"))
    return None


def _codex_prompt(entry: dict) -> object:
    """The text of a Codex rollout entry when it is a user message."""
    payload = entry.get("payload")
    if not isinstance(payload, dict):
        return None
    kind = (entry.get("type"), payload.get("type"))
    if kind == ("response_item", "message"):
        blocks = _blocks(payload.get("content"))
        if payload.get("role") != "user" or blocks is None:
            return None
        for block in blocks:
            if block.get("type") == "input_text":
                return block.get("text")
        return None
    if kind == ("event_msg", "user_message"):
        return payload.get("message")
    return None


def _entries(tail: bytes, marker: bytes):
    """The JSON objects in `tail` whose line holds `marker`, newest first.
    Lines that do not parse (the first may be cut) are skipped."""
    for line in reversed(tail.split(b"\n")):
        if marker not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            yield entry


def _last_prompt(tail: bytes, codex: bool) -> dict | None:
    text_of = _codex_prompt if codex else _claude_prompt
    for entry in _entries(tail, b'"user'):
        first = _first_line(text_of(entry))
        if first is not None:
            return {"text": first, "at": _epoch(entry.get("timestamp")) or 0}
    return None


def _newest_timestamp(tail: bytes) -> int | None:
    """The newest top-level `timestamp` in a tail. Not the file's mtime: Claude
    Code appends untimestamped bookkeeping to idle transcripts."""
    for entry in _entries(tail, b'"timestamp"'):
        at = _epoch(entry.get("timestamp"))
        if at is not None:
            return at
    return None


def _read_tail(path: str, codex: bool, size: int, floor: int):
    """(last prompt, end of the last whole line searched, newest timestamp).

    Reads backwards from the end in doubling chunks until a prompt is found, up
    to PROMPT_CAP_BYTES, and never below `floor`: what an earlier run searched.
    """
    prompt = None
    newest = None
    searched_to = floor
    length = TAIL_BYTES
    with open(path, "rb") as f:
        while True:
            offset = max(0, size - length)
            f.seek(offset)
            data = f.read(min(length, size))
            if length == TAIL_BYTES:
                newline = data.rfind(b"\n")
                if newline >= 0:
                    searched_to = max(floor, offset + newline + 1)
                newest = _newest_timestamp(data)
            skip = max(0, floor - offset)
            if skip < len(data):
                prompt = _last_prompt(data[skip:], codex)
            if prompt is not None or offset <= floor or length >= PROMPT_CAP_BYTES:
                break
            length *= 2
    return prompt, searched_to, newest


def _load_tail_cache() -> dict:
    try:
        data = json.loads(TAIL_CACHE.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_tail_cache(cache: dict) -> None:
    """Best effort, through a temp file and a rename. Mode 0600."""
    tmp = f"{TAIL_CACHE}.{os.getpid()}.tmp"
    try:
        TAIL_CACHE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, TAIL_CACHE)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _known_tail(cache: dict, path: str, codex: bool) -> dict | None:
    """The cache's entry for `path` when it is one this script wrote."""
    known = cache.get(path)
    if not isinstance(known, dict) or known.get("codex") is not codex:
        return None
    if not all(type(known.get(k)) is int for k in ("size", "mtime", "searchedTo")):
        return None
    prompt = known.get("prompt")
    if prompt is not None and not (
        isinstance(prompt, dict)
        and isinstance(prompt.get("text"), str)
        and type(prompt.get("at")) is int
    ):
        return None
    if known.get("lastWriteAt") is not None and type(known.get("lastWriteAt")) is not int:
        return None
    return known


def _tail(path: str | None, codex: bool, cache: dict, fresh: dict) -> dict:
    """`lastPrompt` and `lastWriteAt` of the transcript at `path`.

    A file with the size and mtime of the last run is not read. A file that
    grew is searched above what was searched before: a prompt found there
    still stands unless a newer one was appended.
    """
    none = {"lastPrompt": None, "lastWriteAt": None}
    if not path:
        return none
    try:
        st = os.stat(path)
    except OSError:
        return none
    known = _known_tail(cache, path, codex)
    if known and known["size"] == st.st_size and known["mtime"] == st.st_mtime_ns:
        entry = known
    else:
        # A shorter file was written again, not appended to: start over.
        keep = known if known and st.st_size >= known["size"] else None
        floor = min(keep["searchedTo"], st.st_size) if keep else 0
        try:
            prompt, searched_to, newest = _read_tail(path, codex, st.st_size, floor)
        except OSError:
            return none
        entry = {
            "codex": codex,
            "size": st.st_size,
            "mtime": st.st_mtime_ns,
            "searchedTo": searched_to,
            "prompt": prompt or (keep["prompt"] if keep else None),
            "lastWriteAt": newest if newest is not None else (keep.get("lastWriteAt") if keep else None),
        }
    fresh[path] = entry
    return {"lastPrompt": entry["prompt"], "lastWriteAt": entry.get("lastWriteAt")}


def _claude_transcript(cwd: str, session_id: str) -> str | None:
    """Where a Claude session's transcript is: under its cwd's project folder,
    or under another one when the session started somewhere else."""
    if not SESSION_ID.match(session_id or ""):
        return None
    name = f"{session_id}.jsonl"
    if cwd:
        path = PROJECTS_DIR / _project_dirname(cwd) / name
        if path.is_file():
            return str(path)
    try:
        folders = sorted(os.listdir(PROJECTS_DIR))
    except OSError:
        return None
    for folder in folders:
        path = PROJECTS_DIR / folder / name
        if path.is_file():
            return str(path)
    return None


# --- live Codex conversations (`list --full`) --------------------------------
#
# A codex TUI holds its rollout files open for the life of the process, so the
# open files of the codex processes name every live conversation. On Linux that
# is /proc; elsewhere one `lsof`, as the app does on this Mac (CodexSessions.swift).
# The cost does not grow with the number of panes: no subprocess on Linux, one
# `lsof` elsewhere, and a 4 KB read for each codex process.


def _rollout(path: str, root: str) -> str | None:
    """`path` as a rollout under ~/.codex/sessions, or None when it is not one.
    `root` is that folder with links resolved: the system names open files so."""
    if not path.endswith(".jsonl") or not path.startswith(root + os.sep):
        return None
    return str(CODEX_SESSIONS_DIR) + path[len(root) :]


def _parse_lsof(out: str) -> dict[int, list[str]]:
    """`lsof -Fpn` output as pid -> the names of its open files."""
    found: dict[int, list[str]] = {}
    current = None
    for line in out.splitlines():
        if line.startswith("p"):
            try:
                current = int(line[1:])
            except ValueError:
                current = None
        elif line.startswith("n") and current is not None:
            found.setdefault(current, []).append(line[1:])
    return found


def _codex_open_files() -> dict[int, list[str]]:
    """pid -> open file names, for every process whose command starts `codex`."""
    if os.path.isdir(f"{PROC_DIR}/self/fd"):
        found: dict[int, list[str]] = {}
        for entry in os.listdir(PROC_DIR):
            if not entry.isdigit():
                continue
            try:
                with open(f"{PROC_DIR}/{entry}/comm") as f:
                    if not f.read().startswith("codex"):
                        continue
                fds = os.listdir(f"{PROC_DIR}/{entry}/fd")
            except (OSError, ValueError):
                continue
            for fd in fds:
                try:
                    name = os.readlink(f"{PROC_DIR}/{entry}/fd/{fd}")
                except OSError:
                    continue
                found.setdefault(int(entry), []).append(name)
        return found
    lsof = "/usr/sbin/lsof" if os.access("/usr/sbin/lsof", os.X_OK) else shutil.which("lsof")
    if not lsof:
        return {}
    try:
        out = subprocess.run(
            [lsof, "-c", "codex", "-Fpn"], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    # A non-zero exit with no output is "no codex running".
    return _parse_lsof(out.stdout)


def _rollout_session_id(path: str) -> str | None:
    """`payload.session_id` in a rollout's first line: the top-level
    conversation, which the rollouts of its subagents carry too."""
    try:
        with open(path, "rb") as f:
            head = f.read(ROLLOUT_HEAD_BYTES).decode("utf-8", "replace")
    except OSError:
        return None
    m = re.search(r'"session_id"\s*:\s*"([^"\\]*)"', head)
    return m.group(1) if m and SESSION_ID.match(m.group(1)) else None


def _mtime(path: str) -> float:
    try:
        return os.stat(path).st_mtime
    except OSError:
        return -1.0


def codex_sessions(ppid: dict[int, int], panes: dict[int, str], cache: dict, fresh: dict) -> list[dict]:
    """One row for each live Codex process that holds a rollout open.

    Where a process holds several rollouts, the newest by mtime names the
    conversation (a `/new` thread in a long-lived codex). `rolloutPath` is the
    file named for that conversation, or None when it is not open.
    """
    root = os.path.realpath(CODEX_SESSIONS_DIR)
    rows: list[dict] = []
    for pid, names in sorted(_codex_open_files().items()):
        paths = [p for p in (_rollout(n, root) for n in names) if p]
        if not paths:
            continue
        session_id = _rollout_session_id(max(paths, key=_mtime))
        if not session_id:
            continue
        main = next((p for p in paths if p.endswith(f"-{session_id}.jsonl")), None)
        row = {
            "agent": "codex",
            "codexSessionId": session_id,
            "codexPid": pid,
            "codexPane": pane_for_pid(pid, ppid, panes),
            "rolloutPath": main,
        }
        row.update(_tail(main, True, cache, fresh))
        rows.append(row)
    return rows


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


def enrich(full: bool = False) -> list[dict]:
    """Full picture: live sessions + index summaries + tmux mapping.

    `pane` is the exact tmux pane id the session's Claude runs in (via pid
    ancestry) — what voice re-targets to. Only interactive sessions sitting in a
    tmux pane are drivable; the rest list with pane=None.

    `full` adds `lastPrompt` and `lastWriteAt` to each row, then the Codex rows
    and the schema row (see the top of this file).
    """
    tmuxes = tmux_sessions()
    ppid = _ppid_map()
    panes = _pane_shells()
    cache = _load_tail_cache() if full else {}
    fresh: dict = {}
    result: list[dict] = []
    for s in load_live_sessions():
        cwd = s.get("cwd", "")
        sid = s.get("sessionId", "")
        pid = s.get("pid")
        index = _index_for_path(cwd).get(sid) or _fallback_from_jsonl(cwd, sid)
        row = (
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
                "pane": pane_for_pid(pid, ppid, panes) if isinstance(pid, int) else None,
                # Last-activity ms epoch (status change), for newest-first ordering.
                "updatedAt": s.get("statusUpdatedAt") or s.get("updatedAt") or 0,
            }
        )
        if full:
            row.update(_tail(_claude_transcript(cwd, sid), False, cache, fresh))
        result.append(row)
    if full:
        result += codex_sessions(ppid, panes, cache, fresh)
        result.append({"agent": "meta", "schema": SCHEMA})
        if fresh != cache:
            _save_tail_cache(fresh)
    return result


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else "list"
    sessions = enrich(full=cmd == "list" and "--full" in argv[1:])
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
