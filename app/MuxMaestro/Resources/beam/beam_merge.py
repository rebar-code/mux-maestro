#!/usr/bin/env python3
"""beam_merge.py — the python3-stdlib merge engine behind beam.sh.

beam.sh (bash) orchestrates transport; every job that needs to parse JSON,
merge session DAGs, rewrite paths, or read/write the per-project manifest is
delegated here. bash never parses JSON — it calls a subcommand and reads the
JSON/TSV this prints to stdout.

Canonical form for everything on disk here is **Mac paths**. Remote files are
pulled in remote form, reverse-rewritten to canonical, merged, then
forward-rewritten into a push-out tree that beam.sh rsyncs back — so both
machines converge after every beam/back.

Subcommands (see argparse at the bottom):
  manifest-get / manifest-set   read / atomically mutate the manifest
  fingerprint                   git/WIP state of a dir -> JSON
  code-plan / code-commit       3-way WIP diff / record the agreed baseline
  sync-claude / sync-codex      merge session history, write local + push-out

All state-mutating subcommands write the manifest atomically (tempfile +
os.replace). Runs on python3 stdlib only; the remote box runs zero python.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid


# --------------------------------------------------------------------------
# path encoding / normalization
# --------------------------------------------------------------------------

def enc(path):
    """/Users/me/x.y -> -Users-me-x-y  (matches beam.sh's enc())."""
    return path.replace("/", "-").replace(".", "-")


def _subs_forward(local_dir, remote_dir, local_home, remote_home):
    """Mac -> remote. Longest FROM first so dir (home+/+rel) beats home."""
    pairs = [(local_dir, remote_dir), (local_home, remote_home)]
    return sorted((p for p in pairs if p[0] != p[1]), key=lambda p: -len(p[0]))


def _subs_reverse(local_dir, remote_dir, local_home, remote_home):
    """remote -> Mac. Longest FROM first."""
    pairs = [(remote_dir, local_dir), (remote_home, local_home)]
    return sorted((p for p in pairs if p[0] != p[1]), key=lambda p: -len(p[0]))


_ENC_RE = re.compile(r'("encrypted_content":")([A-Za-z0-9+/=]*)(")')


def rewrite_line(line, pairs):
    """Literal substring replacement on a raw JSONL line.

    Paths appear in free text, JSON-in-string tool args, and stdout blobs, so a
    byte-level substring replace is safer than parse+reserialize (which would
    drift and break prefix comparisons). Codex reasoning.encrypted_content is
    base64 (alphabet includes '/'), so we mask it out, rewrite, then restore.
    """
    if not pairs:
        return line
    if "encrypted_content" in line:
        stash = []

        def grab(m):
            stash.append(m.group(2))
            return "%s\x00%d\x00%s" % (m.group(1), len(stash) - 1, m.group(3))

        line = _ENC_RE.sub(grab, line)
        for a, b in pairs:
            line = line.replace(a, b)
        for i, v in enumerate(stash):
            line = line.replace("\x00%d\x00" % i, v)
        return line
    for a, b in pairs:
        line = line.replace(a, b)
    return line


def rewrite_text(text, pairs):
    return "".join(rewrite_line(l, pairs) for l in text.splitlines(keepends=True))


# --------------------------------------------------------------------------
# JSONL parsing (torn-tail tolerant)
# --------------------------------------------------------------------------

def parse_jsonl(text):
    """-> list of (raw_line, obj). Skips blank lines; drops any line that fails
    to json.loads (a live session mid-rsync leaves a torn final line — the next
    sync carries it). raw_line has no trailing newline."""
    out = []
    for raw in text.splitlines():
        if raw.strip() == "":
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        out.append((raw, obj))
    return out


def _read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="surrogatepass") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def _write_atomic(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".beamtmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8", errors="surrogatepass") as f:
        f.write(text)
    os.replace(tmp, path)


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8", "surrogatepass")).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# Claude merge — hybrid union
# --------------------------------------------------------------------------

def _classify(obj):
    """('GRAPH', uuid) | ('SNAP', messageId) | ('CTRL', type)."""
    if obj.get("type") == "file-history-snapshot":
        return ("SNAP", obj.get("messageId"))
    if "uuid" in obj:
        return ("GRAPH", obj.get("uuid"))
    return ("CTRL", obj.get("type", "<none>"))


def _max_graph_ts(recs):
    best = ""
    for _, o in recs:
        if "uuid" in o:
            ts = o.get("timestamp", "") or ""
            if ts > best:
                best = ts
    return best


def merge_claude(local_text, remote_text):
    """Merge two canonical (Mac-path) Claude session transcripts.

    GRAPH (uuid/parentUuid DAG) + SNAPSHOT (messageId) union-merged in
    encounter order (parent-before-child holds; dedup drops only later dupes);
    CONTROL (uuid-less, keyed by type) latest-wins per type, appended last so
    file-position "last occurrence wins" resume semantics hold. Idempotent:
    merge(merge(L,R),R) == merge(L,R)."""
    local = parse_jsonl(local_text)
    remote = parse_jsonl(remote_text)
    if not local and not remote:
        return ""

    # longest common raw-line prefix, then the remote tail (local[:n]+local[n:]
    # == local, so the sequence is simply local + remote[n:]).
    n = 0
    while n < len(local) and n < len(remote) and local[n][0] == remote[n][0]:
        n += 1
    seq = local + remote[n:]

    winner_local = _max_graph_ts(local) >= _max_graph_ts(remote)
    winner, loser = (local, remote) if winner_local else (remote, local)

    out = []
    seen_graph = set()
    seen_snap = set()
    graph_uuids = set()
    newest_tip = None
    newest_tip_ts = ""
    ctrl_order = []
    ctrl_seen = set()

    for raw, obj in seq:
        kind, key = _classify(obj)
        if kind == "GRAPH":
            if key in seen_graph:
                continue
            seen_graph.add(key)
            graph_uuids.add(key)
            out.append(raw)
            ts = obj.get("timestamp", "") or ""
            if newest_tip is None or ts >= newest_tip_ts:
                newest_tip, newest_tip_ts = key, ts
        elif kind == "SNAP":
            if key in seen_snap:
                continue
            seen_snap.add(key)
            out.append(raw)
        else:  # CTRL — collect the type, resolve winner below
            if key not in ctrl_seen:
                ctrl_seen.add(key)
                ctrl_order.append(key)

    # winner precedence, last-occurrence-within-a-file wins.
    ctrl_by_type = {}
    for side in (loser, winner):
        for raw, obj in side:
            if _classify(obj)[0] == "CTRL":
                ctrl_by_type[obj.get("type", "<none>")] = (raw, obj)

    for t in ctrl_order:
        raw, obj = ctrl_by_type[t]
        if t == "last-prompt" and "leafUuid" in obj:
            if obj.get("leafUuid") not in graph_uuids and newest_tip is not None:
                obj = dict(obj)
                obj["leafUuid"] = newest_tip
                raw = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
        out.append(raw)

    return "\n".join(out) + "\n" if out else ""


# --------------------------------------------------------------------------
# Codex merge — prefix / fast-forward / fork
# --------------------------------------------------------------------------

def _uuid7():
    if hasattr(uuid, "uuid7"):
        return str(uuid.uuid7())
    # ~10-line RFC 9562 uuidv7 fallback (unix-ms timestamp + random).
    import time
    ms = int(time.time() * 1000)
    rand = uuid.uuid4().int
    val = (ms & 0xFFFFFFFFFFFF) << 80
    val |= (0x7 << 76)
    val |= ((rand >> 0) & 0xFFF) << 64
    val |= (0b10 << 62)
    val |= rand & 0x3FFFFFFFFFFFFFFF
    return str(uuid.UUID(int=val))


_UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


def codex_session_id(recs, fallback_name=""):
    for _, obj in recs:
        if obj.get("type") == "session_meta":
            p = obj.get("payload") or {}
            if p.get("id"):
                return p["id"]
            if p.get("session_id"):
                return p["session_id"]
    m = _UUID_RE.search(fallback_name)
    return m.group(0) if m else None


def codex_cwd(recs):
    for _, obj in recs:
        if obj.get("type") == "session_meta":
            return (obj.get("payload") or {}).get("cwd")
    return None


def _common_prefix(a, b):
    n = 0
    while n < len(a) and n < len(b) and a[n] == b[n]:
        n += 1
    return n


def rewrite_codex_id(raw, obj, newid):
    """Rewrite payload.id / payload.session_id on a session_meta line."""
    if obj.get("type") != "session_meta":
        return raw
    o = json.loads(raw)
    p = o.get("payload")
    if isinstance(p, dict):
        if "id" in p:
            p["id"] = newid
        if "session_id" in p:
            p["session_id"] = newid
    return json.dumps(o, separators=(",", ":"), ensure_ascii=False)


# --------------------------------------------------------------------------
# manifest
# --------------------------------------------------------------------------

def load_manifest(path):
    txt = _read(path)
    if not txt.strip():
        return {}
    try:
        return json.loads(txt)
    except Exception:
        return {}


def save_manifest(path, data):
    _write_atomic(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


def _host_rec(m, host):
    hosts = m.setdefault("hosts", {})
    return hosts.setdefault(host, {})


def _dig(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _set_dotted(obj, dotted, value):
    parts = dotted.split(".")
    cur = obj
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value


# --------------------------------------------------------------------------
# fingerprint
# --------------------------------------------------------------------------

def _git(dir_, *args):
    return subprocess.run(
        ["git", "-C", dir_, *args],
        capture_output=True, text=True,
    )


def fingerprint(dir_, exclude_beam=False):
    is_git = _git(dir_, "rev-parse", "--is-inside-work-tree").returncode == 0
    files = {}
    branch = head = None
    if is_git:
        branch = _git(dir_, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip() or None
        head = _git(dir_, "rev-parse", "HEAD").stdout.strip() or None
        r = _git(dir_, "ls-files", "-co", "--exclude-standard", "-z")
        rels = [p for p in r.stdout.split("\0") if p]
    else:
        rels = []
        for root, dirs, fs in os.walk(dir_):
            if ".git" in dirs:
                dirs.remove(".git")
            for fn in fs:
                full = os.path.join(root, fn)
                rels.append(os.path.relpath(full, dir_))
    for rel in rels:
        if exclude_beam and (rel == "beam" or rel.startswith("beam/")):
            continue
        full = os.path.join(dir_, rel)
        if os.path.isfile(full) and not os.path.islink(full):
            try:
                files[rel] = sha256_file(full)
            except OSError:
                pass
    return {"is_git": is_git, "git_branch": branch, "git_head": head, "files": files}


def _read_remote_hashes(path):
    """sha256sum output: '<hash>  <relpath>' -> {relpath: hash}."""
    out = {}
    if not path:
        return out
    for line in _read(path).splitlines():
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        h, rel = parts
        rel = rel.strip()
        if rel.startswith("./"):  # find(1) emits "./path"; git ls-files does not
            rel = rel[2:]
        out[rel] = h  # NB: not lstrip("./") — that eats the dot off .gitignore etc.
    return out


# --------------------------------------------------------------------------
# code-plan — 3-way diff (baseline x local x remote)
# --------------------------------------------------------------------------

def _state(h, b):
    if h is None and b is None:
        return "absent"
    if h is None:
        return "gone"
    if b is None:
        return "new"
    return "same" if h == b else "changed"


# (lstate, rstate) -> (beam_action, back_action). Only reached when L != R.
_ACTIONS = {
    ("new", "absent"):   ("push", "skip"),
    ("absent", "new"):   ("skip", "pull"),
    ("new", "new"):      ("conflict", "conflict"),
    ("changed", "same"): ("push", "skip"),
    ("same", "changed"): ("skip", "pull"),
    ("gone", "same"):    ("rm-remote", "skip"),
    ("same", "gone"):    ("skip", "rm-local"),
    ("changed", "changed"): ("conflict", "conflict"),
    ("gone", "changed"):    ("conflict", "conflict"),
    ("changed", "gone"):    ("conflict", "conflict"),
}


def code_plan(local_files, remote_files, baseline_files):
    """Yield (path, lstate, rstate, beam_action, back_action) for each path
    that is not already in sync between the two sides."""
    rows = []
    for path in sorted(set(local_files) | set(remote_files) | set(baseline_files)):
        L = local_files.get(path)
        R = remote_files.get(path)
        B = baseline_files.get(path)
        if L == R:
            continue  # in sync (incl. both-absent) — nothing to do
        ls, rs = _state(L, B), _state(R, B)
        beam, back = _ACTIONS.get((ls, rs), ("conflict", "conflict"))
        rows.append((path, ls, rs, beam, back))
    return rows


# ==========================================================================
# subcommand handlers
# ==========================================================================

def cmd_manifest_get(a):
    m = load_manifest(a.manifest)
    if a.host:
        rec = (m.get("hosts") or {}).get(a.host, {})
        if a.field:
            v = _dig(rec, a.field)
            sys.stdout.write("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
            return
        sys.stdout.write(json.dumps(rec))
        return
    if a.field:
        v = _dig(m, a.field)
        sys.stdout.write("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
        return
    sys.stdout.write(json.dumps(m))


def cmd_manifest_set(a):
    m = load_manifest(a.manifest)
    for kv in a.set or []:
        k, _, v = kv.partition("=")
        _set_dotted(m, k, v)
    if a.host:
        rec = _host_rec(m, a.host)
        for kv in a.set_host or []:
            k, _, v = kv.partition("=")
            _set_dotted(rec, k, v)
    save_manifest(a.manifest, m)


def cmd_fingerprint(a):
    sys.stdout.write(json.dumps(fingerprint(a.dir, exclude_beam=a.exclude_beam)))


def cmd_code_plan(a):
    local = fingerprint(a.dir, exclude_beam=a.exclude_beam)["files"]
    remote = _read_remote_hashes(a.remote_hashes)
    m = load_manifest(a.manifest)
    baseline = _dig((m.get("hosts") or {}).get(a.host, {}), "code.files") or {}
    for row in code_plan(local, remote, baseline):
        sys.stdout.write("\t".join(row) + "\n")


def cmd_code_commit(a):
    """Record the agreed baseline: a file both sides now hold identically gets
    its hash stored; a still-diverging file keeps its old baseline so it
    re-conflicts until truly resolved."""
    local = fingerprint(a.dir, exclude_beam=a.exclude_beam)
    remote = _read_remote_hashes(a.remote_hashes)
    m = load_manifest(a.manifest)
    rec = _host_rec(m, a.host)
    code = rec.setdefault("code", {})
    baseline = code.get("files", {})
    lf = local["files"]
    new_baseline = dict(baseline)
    for path in set(lf) | set(remote):
        L, R = lf.get(path), remote.get(path)
        if L is not None and L == R:
            new_baseline[path] = L
        elif L is None and R is None:
            new_baseline.pop(path, None)
        # else: diverged — keep prior baseline (re-conflicts next time)
    code["files"] = new_baseline
    code["is_git"] = local["is_git"]
    code["git_branch"] = local["git_branch"]
    code["git_head"] = local["git_head"]
    save_manifest(a.manifest, m)


# ---- session sync helpers ------------------------------------------------

def _list_jsonl(dir_):
    out = {}
    if not os.path.isdir(dir_):
        return out
    for fn in os.listdir(dir_):
        if fn.endswith(".jsonl"):
            out[fn] = os.path.join(dir_, fn)
    return out


def cmd_sync_claude(a):
    fwd = _subs_forward(a.local_dir, a.remote_dir, a.local_home, a.remote_home)
    rev = _subs_reverse(a.local_dir, a.remote_dir, a.local_home, a.remote_home)

    local_files = _list_jsonl(a.local_proj)
    remote_files = _list_jsonl(a.remote_proj)
    m = load_manifest(a.manifest)
    rec = _host_rec(m, a.host)
    claude = rec.setdefault("claude", {})
    sessions = claude.setdefault("sessions", {})

    summary = []
    for fn in sorted(set(local_files) | set(remote_files)):
        sid = fn[:-6]
        local_text = _read(local_files[fn]) if fn in local_files else ""
        remote_text = rewrite_text(_read(remote_files[fn]), rev) if fn in remote_files else ""
        merged = merge_claude(local_text, remote_text)
        if not merged:
            continue
        _write_atomic(os.path.join(a.local_proj, fn), merged)
        _write_atomic(os.path.join(a.pushout, fn), rewrite_text(merged, fwd))
        sessions[sid] = {"lines": merged.count("\n"), "sha256": sha256_text(merged)}
        summary.append("  claude %s (%d lines)" % (sid, merged.count("\n")))

        # subagents: <sid>/subagents/agent-*.jsonl merged; *.meta.json mtime-wins
        _sync_subagents(a, sid, fwd, rev)

    save_manifest(a.manifest, m)
    sys.stdout.write("\n".join(summary) + ("\n" if summary else ""))


def _sync_subagents(a, sid, fwd, rev):
    l_sub = os.path.join(a.local_proj, sid, "subagents")
    r_sub = os.path.join(a.remote_proj, sid, "subagents")
    if not os.path.isdir(l_sub) and not os.path.isdir(r_sub):
        return
    names = set()
    for d in (l_sub, r_sub):
        if os.path.isdir(d):
            names.update(os.listdir(d))
    out_sub = os.path.join(a.pushout, sid, "subagents")
    for name in sorted(names):
        lp, rp = os.path.join(l_sub, name), os.path.join(r_sub, name)
        if name.endswith(".jsonl"):
            lt = _read(lp) if os.path.exists(lp) else ""
            rt = rewrite_text(_read(rp), rev) if os.path.exists(rp) else ""
            merged = merge_claude(lt, rt)
            if not merged:
                continue
            _write_atomic(os.path.join(l_sub, name), merged)
            _write_atomic(os.path.join(out_sub, name), rewrite_text(merged, fwd))
        elif name.endswith(".meta.json"):
            # latest-mtime wins
            cand = [(os.path.getmtime(p), p) for p in (lp, rp) if os.path.exists(p)]
            if not cand:
                continue
            _, win = max(cand)
            content = _read(win)
            canon = rewrite_text(content, rev) if win == rp else content
            _write_atomic(os.path.join(l_sub, name), canon)
            _write_atomic(os.path.join(out_sub, name), rewrite_text(canon, fwd))


def _find_codex_rollouts(root, cwd):
    """Rollout files under root whose session_meta cwd == cwd. Returns
    {rel: (abspath, recs, sid)}."""
    out = {}
    if not os.path.isdir(root):
        return out
    needle = '"cwd":"%s"' % cwd
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not (fn.startswith("rollout-") and fn.endswith(".jsonl")):
                continue
            full = os.path.join(dirpath, fn)
            text = _read(full)
            if needle not in text:
                continue
            recs = parse_jsonl(text)
            sid = codex_session_id(recs, fn)
            if sid:
                out[os.path.relpath(full, root)] = (full, recs, sid)
    return out


def cmd_sync_codex(a):
    fwd = _subs_forward(a.local_dir, a.remote_dir, a.local_home, a.remote_home)
    rev = _subs_reverse(a.local_dir, a.remote_dir, a.local_home, a.remote_home)
    now = os.environ.get("BEAM_NOW") or _now_stamp()

    local = _find_codex_rollouts(a.local_sessions, a.local_dir)
    # remote temp files are in remote form; reverse-rewrite each into canonical.
    remote = {}
    if os.path.isdir(a.remote_temp):
        for dirpath, _, files in os.walk(a.remote_temp):
            for fn in files:
                if not (fn.startswith("rollout-") and fn.endswith(".jsonl")):
                    continue
                full = os.path.join(dirpath, fn)
                text = rewrite_text(_read(full), rev)
                recs = parse_jsonl(text)
                sid = codex_session_id(recs, fn)
                if sid:
                    remote[sid] = (os.path.relpath(full, a.remote_temp), text, recs)

    local_by_sid = {v[2]: (rel, v[0]) for rel, v in local.items()}

    m = load_manifest(a.manifest)
    rec = _host_rec(m, a.host)
    codex = rec.setdefault("codex", {})
    cx_sessions = codex.setdefault("sessions", {})

    summary = []
    for sid in sorted(set(local_by_sid) | set(remote)):
        l = local_by_sid.get(sid)
        r = remote.get(sid)
        if l and not r:  # local-only -> push
            rel, full = l
            text = _read(full)
            _write_atomic(os.path.join(a.pushout, rel), rewrite_text(text, fwd))
            cx_sessions.setdefault(sid, {})["rel"] = rel
            summary.append("  codex %s push" % sid)
            continue
        if r and not l:  # remote-only -> import
            rrel, rtext, _ = r
            _write_atomic(os.path.join(a.local_sessions, rrel), rtext)
            _write_atomic(os.path.join(a.pushout, rrel), rewrite_text(rtext, fwd))
            cx_sessions.setdefault(sid, {})["rel"] = rrel
            summary.append("  codex %s import" % sid)
            continue
        # both sides present
        rel, full = l
        ltext = _read(full)
        llines = ltext.splitlines()
        rrel, rtext, rrecs = r
        rlines = rtext.splitlines()
        n = _common_prefix(llines, rlines)
        if n == len(llines) and n == len(rlines):
            summary.append("  codex %s identical" % sid)
        elif n == len(llines):  # remote advanced -> fast-forward local
            _write_atomic(full, rtext)
            _write_atomic(os.path.join(a.pushout, rel), rewrite_text(rtext, fwd))
            summary.append("  codex %s ff-local" % sid)
        elif n == len(rlines):  # local advanced -> push local
            _write_atomic(os.path.join(a.pushout, rel), rewrite_text(ltext, fwd))
            summary.append("  codex %s ff-remote" % sid)
        else:  # true divergence -> fork the remote lineage under a new uuid
            newid = _uuid7()
            newname = "rollout-%s-%s.jsonl" % (now, newid)
            y, mo, d = now[:10].split("-")
            newrel = os.path.join(y, mo, d, newname)
            forked = "\n".join(
                rewrite_codex_id(raw, obj, newid) for raw, obj in rrecs
            ) + "\n"
            _write_atomic(os.path.join(a.local_sessions, newrel), forked)
            _write_atomic(os.path.join(a.pushout, newrel), rewrite_text(forked, fwd))
            # keep old uuid = local lineage on both sides
            _write_atomic(os.path.join(a.pushout, rel), rewrite_text(ltext, fwd))
            cx_sessions.setdefault(sid, {}).setdefault("forked_to", []).append(newid)
            summary.append("  codex %s FORK -> %s" % (sid, newid))

    save_manifest(a.manifest, m)
    sys.stdout.write("\n".join(summary) + ("\n" if summary else ""))


def _now_stamp():
    import datetime
    return datetime.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")


# ==========================================================================

def main(argv):
    p = argparse.ArgumentParser(prog="beam_merge.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("manifest-get")
    g.add_argument("--manifest", required=True)
    g.add_argument("--host")
    g.add_argument("--field")
    g.set_defaults(fn=cmd_manifest_get)

    s = sub.add_parser("manifest-set")
    s.add_argument("--manifest", required=True)
    s.add_argument("--host")
    s.add_argument("--set", action="append")
    s.add_argument("--set-host", action="append")
    s.set_defaults(fn=cmd_manifest_set)

    f = sub.add_parser("fingerprint")
    f.add_argument("--dir", required=True)
    f.add_argument("--exclude-beam", action="store_true")
    f.set_defaults(fn=cmd_fingerprint)

    cp = sub.add_parser("code-plan")
    cp.add_argument("--manifest", required=True)
    cp.add_argument("--host", required=True)
    cp.add_argument("--dir", required=True)
    cp.add_argument("--remote-hashes")
    cp.add_argument("--exclude-beam", action="store_true")
    cp.set_defaults(fn=cmd_code_plan)

    cc = sub.add_parser("code-commit")
    cc.add_argument("--manifest", required=True)
    cc.add_argument("--host", required=True)
    cc.add_argument("--dir", required=True)
    cc.add_argument("--remote-hashes")
    cc.add_argument("--exclude-beam", action="store_true")
    cc.set_defaults(fn=cmd_code_commit)

    for name, fn in (("sync-claude", cmd_sync_claude), ("sync-codex", cmd_sync_codex)):
        c = sub.add_parser(name)
        c.add_argument("--manifest", required=True)
        c.add_argument("--host", required=True)
        c.add_argument("--local-dir", required=True)
        c.add_argument("--remote-dir", required=True)
        c.add_argument("--local-home", required=True)
        c.add_argument("--remote-home", required=True)
        c.add_argument("--pushout", required=True)
        if name == "sync-claude":
            c.add_argument("--local-proj", required=True)
            c.add_argument("--remote-proj", required=True)
        else:
            c.add_argument("--local-sessions", required=True)
            c.add_argument("--remote-temp", required=True)
        c.set_defaults(fn=fn)

    a = p.parse_args(argv)
    a.fn(a)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
