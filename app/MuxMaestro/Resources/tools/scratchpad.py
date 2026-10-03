#!/usr/bin/env python3
"""Local scratchpad — agents push visuals (HTML / images / markdown) and you
see them on your phone over Tailscale, live.

Usage:
    python3 scratchpad.py add <file.html|png|svg|gif|md|txt> [--title T]
    echo "<svg>…</svg>" | python3 scratchpad.py push --title "flow v2" [--kind html|svg|md|text]
    python3 scratchpad.py list
    python3 scratchpad.py serve          # run the daemon (foreground)
    python3 scratchpad.py stop
    Flags: --port N (default 7844 / $SCRATCHPAD_PORT), --local, --host H, --open

`add` / `push` copy the content into a shared store (~/Screenshots, or
$SCRATCHPAD_DIR), start the daemon if it isn't running, and print the URL. ONE
daemon serves every session. Index at `/` (history, newest first, with a live
preview of every pad plus the favicon + name of the dir it was pushed from),
each pad at `/s/<id>`, and a live `/latest` view that auto-updates whenever any
agent pushes a new pad — pin that on your phone. Because it's an HTTP server on
a port, it also auto-appears on the tailnet dashboard.

Printed links are always https://<node>.<tailnet>.ts.net:<port>/… — Tailscale
terminates TLS with a real cert for the node, so the link opens on a phone with
nothing to install and the page gets a secure context (working clipboard). The
proxy is configured on first push via `tailscale serve`. Without Tailscale the
tool falls back to a plain http loopback URL and says so.

Every pad view has a ✎ Comment button: drop positional pins on the preview and
the notes POST to <store>/feedback-inbox.jsonl for an agent to act on. The write
path is restricted to loopback + the Tailscale range (not the wider LAN).

Stdlib only — no dependencies, no build step.
"""

import html as html_mod
import http.server
import ipaddress
import json
import mimetypes
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

DEFAULT_PORT = int(os.environ.get("SCRATCHPAD_PORT", "7844"))
HERE = Path(__file__).resolve().parent
ICON_DIR = HERE / "icons"

EXT_KIND = {
    ".html": "html", ".htm": "html",
    ".svg": "image", ".png": "image", ".jpg": "image", ".jpeg": "image",
    ".gif": "image", ".webp": "image", ".avif": "image",
    ".md": "markdown", ".markdown": "markdown",
    ".txt": "text",
    ".mp4": "video", ".webm": "video", ".mov": "video",
}
# Resolve a `--kind` flag (the documented aliases plus canonical names) to the
# (canonical kind used by the renderer, stored file extension).
KIND_RESOLVE = {
    "html": ("html", "html"), "htm": ("html", "html"),
    "svg": ("image", "svg"), "image": ("image", "png"), "png": ("image", "png"),
    "md": ("markdown", "md"), "markdown": ("markdown", "md"),
    "txt": ("text", "txt"), "text": ("text", "txt"),
}

# Where a project keeps its favicon, in priority order (relative to the cwd the
# pad was pushed from). First hit wins.
FAVICON_CANDIDATES = [
    "static/favicon.ico", "static/favicon.svg", "static/favicon.png",
    "public/favicon.ico", "public/favicon.svg", "public/favicon.png",
    "app/favicon.ico", "app/icon.png", "app/icon.svg",
    "src/favicon.ico", "src/app/favicon.ico",
    "favicon.ico", "favicon.svg", "favicon.png",
    "static/favicon-32x32.png", "public/favicon-32x32.png",
]


def find_favicon(cwd):
    base = Path(cwd)
    for rel in FAVICON_CANDIDATES:
        fp = base / rel
        if fp.is_file():
            return fp
    return None


def store_dir():
    d = Path(os.environ.get("SCRATCHPAD_DIR", Path.home() / "Screenshots"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def esc(t):
    return html_mod.escape(str(t)) if t is not None else ""


def slugify(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "pad").lower()).strip("-")
    return s[:48] or "pad"


def time_ago(ts):
    try:
        d = int(time.time() - ts)
    except (TypeError, ValueError):
        return ""
    if d < 60:
        return "just now"
    if d < 3600:
        return f"{d // 60}m ago"
    if d < 86400:
        return f"{d // 3600}h ago"
    return f"{d // 86400}d ago"


# ------------------------------------------------------------------ store ops

def _write(rid, title, kind, ext, content_bytes, source):
    sd = store_dir()
    (sd / f"{rid}.{ext}").write_bytes(content_bytes)
    cwd = os.getcwd()
    meta = {"id": rid, "title": title, "kind": kind, "ext": ext,
            "added_at": int(time.time()), "source": source,
            "cwd": cwd, "dir": Path(cwd).name,
            "session": os.environ.get("CLAUDE_SESSION_ID", "")}
    fav = find_favicon(cwd)
    if fav:
        fext = fav.suffix.lower().lstrip(".") or "ico"
        try:
            (sd / f"{rid}.favicon.{fext}").write_bytes(fav.read_bytes())
            meta["favicon"] = fext
        except OSError:
            pass
    tmp = sd / f"{rid}.meta.json.tmp"
    tmp.write_text(json.dumps(meta))
    tmp.replace(sd / f"{rid}.meta.json")
    return rid


def add_file(path, title):
    p = Path(path)
    if not p.exists():
        sys.exit(f"error: file not found: {p}")
    kind = EXT_KIND.get(p.suffix.lower())
    if not kind:
        sys.exit(f"error: unsupported type {p.suffix} (html/png/jpg/svg/gif/webp/md/txt/mp4/webm)")
    ext = p.suffix.lower().lstrip(".")
    rid = f"{int(time.time())}-{slugify(title or p.stem)}"
    return _write(rid, title or p.stem, kind, ext, p.read_bytes(), p.name)


def push_stdin(title, kind):
    data = sys.stdin.buffer.read()
    canon, ext = KIND_RESOLVE.get((kind or "html").lower(), ("html", "html"))
    rid = f"{int(time.time())}-{slugify(title)}"
    return _write(rid, title or "scratchpad", canon, ext, data, "stdin")


def load_pads():
    out = []
    for fp in store_dir().glob("*.meta.json"):
        try:
            out.append(json.loads(fp.read_text()))
        except (json.JSONDecodeError, OSError):
            continue
    out.sort(key=lambda m: m.get("added_at", 0), reverse=True)
    return out


def content_path(rid):
    for fp in store_dir().glob(f"{rid}.*"):
        if fp.name.endswith(".meta.json") or fp.name.startswith(f"{rid}.favicon."):
            continue
        return fp
    return None


def favicon_path(rid):
    for fp in store_dir().glob(f"{rid}.favicon.*"):
        return fp
    return None


def meta_of(rid):
    fp = store_dir() / f"{rid}.meta.json"
    if not fp.exists():
        return None
    try:
        return json.loads(fp.read_text())
    except (json.JSONDecodeError, OSError):
        return None


# --------------------------------------------------------------------- render

def md_to_html(text):
    """Markdown subset → HTML (headings, bold/italic/code, bullet + numbered
    lists, blockquotes, images, links, rules, fenced code, paragraphs). Enough
    for agent notes; not a full parser."""
    lines = str(text).split("\n")
    out = []
    state = {"ul": False, "ol": False, "code": False, "bq": False}
    def close_lists():
        if state["ul"]:
            out.append("</ul>"); state["ul"] = False
        if state["ol"]:
            out.append("</ol>"); state["ol"] = False
    def close_bq():
        if state["bq"]:
            out.append("</blockquote>"); state["bq"] = False
    def inline(s):
        s = esc(s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = re.sub(r"!\[([^\]]*)\]\(((?:https?:|data:)[^)\s]+)\)", r'<img src="\2" alt="\1">', s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", s)
        s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2" target="_blank" rel="noopener">\1</a>', s)
        return s
    for ln in lines:
        stripped = ln.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            if state["code"]:
                out.append("</code></pre>"); state["code"] = False
            else:
                close_lists(); close_bq()
                out.append("<pre><code>"); state["code"] = True
            continue
        if state["code"]:
            out.append(esc(ln)); continue
        m = re.match(r"(#{1,6})\s+(.*)", ln)
        if m:
            close_lists(); close_bq()
            lvl = len(m.group(1))
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>"); continue
        if re.match(r"\s*[-*+]\s+", ln):
            close_bq()
            if state["ol"]:
                out.append("</ol>"); state["ol"] = False
            if not state["ul"]:
                out.append("<ul>"); state["ul"] = True
            out.append("<li>" + inline(re.sub(r"\s*[-*+]\s+", "", ln, count=1)) + "</li>"); continue
        if re.match(r"\s*\d+\.\s+", ln):
            close_bq()
            if state["ul"]:
                out.append("</ul>"); state["ul"] = False
            if not state["ol"]:
                out.append("<ol>"); state["ol"] = True
            out.append("<li>" + inline(re.sub(r"\s*\d+\.\s+", "", ln, count=1)) + "</li>"); continue
        close_lists()
        if re.match(r"\s*>\s?", ln):
            if not state["bq"]:
                out.append("<blockquote>"); state["bq"] = True
            out.append("<p>" + inline(re.sub(r"\s*>\s?", "", ln, count=1)) + "</p>"); continue
        close_bq()
        if re.match(r"\s*([-*_])(\s*\1){2,}\s*$", ln):
            out.append("<hr>"); continue
        if stripped:
            out.append("<p>" + inline(ln) + "</p>")
    close_lists(); close_bq()
    if state["code"]:
        out.append("</code></pre>")
    return "\n".join(out)


HEAD = """<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<link rel="manifest" href="/manifest.webmanifest"><meta name="theme-color" content="#0b0d10">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Scratchpad">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">"""

STYLE = """<style>
:root{--bg:#0b0d10;--panel:#14181d;--panel2:#1a1f26;--line:#262d36;--txt:#e6e9ef;--dim:#aab4c2;--accent:#5b9dff;--mono:ui-monospace,Menlo,monospace}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
 padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
a{color:inherit}
.wrap{max-width:760px;margin:0 auto;padding:30px 18px 80px}
h1{font-size:22px;margin:0 0 3px;letter-spacing:-.01em}
.sub{font:12px var(--mono);color:var(--dim);margin-bottom:14px}
.livebtn{display:flex;align-items:center;justify-content:center;gap:10px;width:100%;margin:0 0 24px;
 min-height:52px;padding:14px 22px;background:var(--accent);color:#06101f;font-weight:700;font-size:16px;
 text-decoration:none;border-radius:14px;letter-spacing:.01em;-webkit-tap-highlight-color:transparent;
 box-shadow:0 2px 14px rgba(91,157,255,.25)}
.livebtn:active{transform:translateY(1px)}
.livebtn .dot{width:10px;height:10px;border-radius:50%;background:#06101f;animation:pulse 1.6s ease-in-out infinite}
.livebtn .arr{font:14px var(--mono);opacity:.65}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.card{display:flex;flex-direction:column;text-decoration:none;background:var(--panel);border:1px solid var(--line);
 border-radius:12px;overflow:hidden;transition:.15s}
.card:hover{border-color:var(--accent);transform:translateY(-1px)}
.thumb{position:relative;height:104px;background:#0c1116;display:grid;place-items:center;overflow:hidden;border-bottom:1px solid var(--line)}
.thumb img{width:100%;height:100%;object-fit:cover;object-position:top}
.thumb .k{font:11px var(--mono);color:var(--dim);text-transform:uppercase;letter-spacing:.08em}
.mini{position:absolute;top:0;left:0;width:300%;height:300%;border:0;background:#fff;
 transform:scale(.3333);transform-origin:0 0;pointer-events:none}
.minidoc{position:absolute;top:0;left:0;width:300%;height:300%;transform:scale(.3333);transform-origin:0 0;
 pointer-events:none;background:#0c1116;color:var(--txt);padding:12px 14px;overflow:hidden;text-align:left}
.minidoc h1,.minidoc h2,.minidoc h3,.minidoc h4{font-size:15px;margin:6px 0;line-height:1.3}
.minidoc p,.minidoc li{font-size:12px;margin:4px 0}
.minidoc pre{font:11px/1.4 var(--mono);white-space:pre-wrap;color:#bcd4ff;margin:0}
.minidoc code{font:11px var(--mono);color:#bcd4ff}
.minidoc ul,.minidoc ol{padding-left:18px;margin:4px 0}
.minidoc blockquote{border-left:2px solid var(--line);padding-left:8px;margin:4px 0;color:var(--dim)}
.minidoc img{max-width:100%}
.meta{padding:10px 12px}
.t{font-weight:600;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.m{font:11px var(--mono);color:var(--dim);margin-top:3px}
.src{display:flex;align-items:center;gap:6px;margin-top:7px}
.src .fav{width:14px;height:14px;border-radius:3px;object-fit:contain;flex:none}
.src .fav.ph{background:var(--panel2);border:1px solid var(--line)}
.src .dir{font:11px var(--mono);color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.empty{color:var(--dim);font:13px var(--mono);text-align:center;padding:60px 0}
.bar{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid var(--line);
 background:var(--panel);position:sticky;top:0;z-index:5}
.bar a.home{font:12px var(--mono);color:var(--dim);text-decoration:none}
.bar a.home:hover{color:var(--accent)}
.bar .bt{font-weight:600;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bar .bm{font:11px var(--mono);color:var(--dim)}
.live{font:10px var(--mono);color:#3ecf8e;border:1px solid #1d4a2c;background:#0d2818;border-radius:5px;padding:3px 7px;text-transform:uppercase;letter-spacing:.05em}
.frame{width:100%;height:calc(100vh - 52px);border:0;background:#fff;display:block}
.doc{max-width:760px;margin:0 auto;padding:24px 18px 80px}
.doc img{max-width:100%}
.doc pre{background:#0c1116;border:1px solid var(--line);border-radius:10px;padding:14px;overflow:auto;font:12.5px/1.5 var(--mono)}
.doc code{font:13px var(--mono);color:#bcd4ff}
.doc ul,.doc ol{padding-left:22px}
.doc blockquote{margin:10px 0;padding:4px 14px;border-left:3px solid var(--line);color:var(--dim)}
.bar .acts{display:flex;gap:6px;align-items:center;flex:none}
.bar .act{display:grid;place-items:center;width:32px;height:32px;border-radius:8px;border:1px solid var(--line);
 background:var(--panel2);color:var(--dim);font:15px var(--mono);text-decoration:none;cursor:pointer;flex:none;
 -webkit-tap-highlight-color:transparent}
.bar .act:hover{color:var(--accent);border-color:var(--accent)}
.bar .act:active{transform:translateY(1px)}
.imgwrap{min-height:calc(100vh - 52px);display:grid;place-items:center;padding:18px;background:#0c1116}
.imgwrap img,.imgwrap video{max-width:100%;max-height:calc(100vh - 90px)}
.thumb video{width:100%;height:100%;object-fit:cover;object-position:top}
.ptr{position:fixed;top:0;left:50%;transform:translateX(-50%) translateY(-46px);width:34px;height:34px;border-radius:50%;
 background:var(--panel);border:1px solid var(--line);display:grid;place-items:center;color:var(--dim);opacity:0;z-index:60;
 font:16px var(--mono);transition:opacity .15s,transform .15s;-webkit-user-select:none;user-select:none}
.ptr.ready{color:var(--accent);border-color:var(--accent)}
.ptr.spin{transform:translateX(-50%) translateY(16px);opacity:1;animation:sp .7s linear infinite}
@keyframes sp{to{transform:translateX(-50%) translateY(16px) rotate(360deg)}}
/* ---- markup / commenting layer ---- */
#stage{position:relative}
#cf-ov{position:absolute;inset:0;z-index:30;pointer-events:none}
#cf-ov.on{pointer-events:auto;cursor:crosshair;background:rgba(91,157,255,.06)}
.cf-pin{position:absolute;transform:translate(-50%,-100%) rotate(45deg);z-index:31;width:26px;height:26px;
 border-radius:50% 50% 50% 2px;background:var(--accent);color:#06101f;font:12px/26px var(--mono);font-weight:700;
 text-align:center;box-shadow:0 2px 8px rgba(0,0,0,.45);pointer-events:auto;cursor:pointer}
.cf-pin b{display:block;transform:rotate(-45deg)}
.cf-tools{position:fixed;left:0;right:0;bottom:0;z-index:40;display:flex;gap:8px;align-items:center;
 padding:10px 14px calc(10px + env(safe-area-inset-bottom));background:var(--panel);border-top:1px solid var(--line)}
.cf-tools button{font:14px -apple-system,BlinkMacSystemFont,sans-serif;font-weight:600;border:1px solid var(--line);
 background:var(--panel2);color:var(--txt);border-radius:10px;padding:10px 14px;-webkit-tap-highlight-color:transparent}
.cf-tools button.primary{background:var(--accent);color:#06101f;border-color:var(--accent)}
.cf-tools button:disabled{opacity:.4}
.cf-tools .sp{flex:1}
.cf-tools .hint{font:11px var(--mono);color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.cf-sheet{position:fixed;left:0;right:0;bottom:0;z-index:50;background:var(--panel);border-top:1px solid var(--line);
 padding:14px 14px calc(14px + env(safe-area-inset-bottom));transform:translateY(115%);transition:transform .2s}
.cf-sheet.open{transform:none}
.cf-sheet textarea{width:100%;min-height:80px;background:var(--bg);color:var(--txt);border:1px solid var(--line);
 border-radius:10px;padding:10px;font:15px -apple-system,BlinkMacSystemFont,sans-serif;resize:vertical}
.cf-sheet .row{display:flex;gap:8px;margin-top:10px}
.cf-sheet .row button{flex:1;font:14px -apple-system,sans-serif;font-weight:600;border:1px solid var(--line);
 background:var(--panel2);color:var(--txt);border-radius:10px;padding:11px;-webkit-tap-highlight-color:transparent}
.cf-sheet .row button.primary{background:var(--accent);color:#06101f;border-color:var(--accent)}
.cf-toast{position:fixed;left:50%;bottom:84px;transform:translateX(-50%);z-index:60;background:#0d2818;
 border:1px solid #1d4a2c;color:#3ecf8e;font:13px var(--mono);padding:10px 16px;border-radius:10px;opacity:0;
 transition:opacity .2s;pointer-events:none;max-width:80%;text-align:center}
.cf-toast.show{opacity:1}
</style>"""

PTR = """<script>(function(){var i=document.createElement('div');i.className='ptr';i.textContent='\\u2193';
document.body.appendChild(i);var y=0,p=false,d=0,T=70;function top(){return (window.scrollY||0)<=0;}
addEventListener('touchstart',function(e){if(top()){y=e.touches[0].clientY;p=true;d=0;}},{passive:true});
addEventListener('touchmove',function(e){if(!p)return;d=e.touches[0].clientY-y;if(d>0&&top()){var v=Math.min(d,110);
i.style.transform='translateX(-50%) translateY('+(v-46)+'px)';i.style.opacity=Math.min(v/T,1);i.classList.toggle('ready',d>T);
if(d>6&&e.cancelable)e.preventDefault();}else p=false;},{passive:false});
addEventListener('touchend',function(){if(!p)return;p=false;if(d>T){i.textContent='\\u21bb';i.classList.add('spin');location.reload();}
else{i.style.transform='';i.style.opacity=0;i.classList.remove('ready');}},{passive:true});})();</script>"""

SW = """self.addEventListener('install',function(e){self.skipWaiting();});
self.addEventListener('activate',function(e){self.clients.claim();});
self.addEventListener('fetch',function(e){});"""

MANIFEST = json.dumps({
    "name": "Scratchpad", "short_name": "Scratch", "start_url": "/latest", "scope": "/",
    "display": "standalone", "background_color": "#0b0d10", "theme_color": "#0b0d10",
    "icons": [
        {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
        {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
    ],
})

ICON_ROUTES = {
    "/icon-512.png": ("icon-512.png", "image/png"),
    "/icon-192.png": ("icon-192.png", "image/png"),
    "/apple-touch-icon.png": ("apple-touch-icon.png", "image/png"),
}


def page(body, title="Scratchpad", extra=""):
    return ("<!doctype html><html lang=en><head>" + HEAD + extra
            + f"<title>{esc(title)}</title>" + STYLE + "</head><body>" + body + PTR + "</body></html>")


def render_index(pads):
    if not pads:
        body = '<div class="wrap"><h1>Scratchpad</h1><div class="empty">No scratchpads yet.</div></div>'
        return page(body)
    cards = []
    for m in pads:
        rid = esc(m["id"])
        kind = m["kind"]
        if kind == "image":
            thumb = f'<div class="thumb"><img src="/s/{rid}/raw" loading="lazy" alt=""></div>'
        elif kind == "video":
            thumb = (f'<div class="thumb"><video class="mini" src="/s/{rid}/raw#t=0.5" muted playsinline '
                     f'preload="metadata"></video></div>')
        elif kind == "html":
            thumb = (f'<div class="thumb"><iframe class="mini" src="/s/{rid}/raw" loading="lazy" '
                     f'tabindex="-1" aria-hidden="true" scrolling="no" '
                     f'sandbox="allow-scripts allow-popups"></iframe></div>')
        elif kind == "markdown":
            cp = content_path(m["id"])
            snippet = cp.read_text(errors="replace")[:1200] if cp else ""
            thumb = f'<div class="thumb"><div class="minidoc">{md_to_html(snippet)}</div></div>'
        else:
            cp = content_path(m["id"])
            snippet = cp.read_text(errors="replace")[:1200] if cp else ""
            thumb = f'<div class="thumb"><div class="minidoc"><pre>{esc(snippet)}</pre></div></div>'
        src = ""
        d = m.get("dir")
        if d:
            fav = (f'<img class="fav" src="/s/{rid}/favicon" loading="lazy" alt="">'
                   if m.get("favicon") else '<span class="fav ph"></span>')
            src = f'<div class="src">{fav}<span class="dir">{esc(d)}</span></div>'
        cards.append(
            f'<a class="card" href="/s/{rid}">{thumb}'
            f'<div class="meta"><div class="t">{esc(m.get("title") or m["id"])}</div>'
            f'<div class="m">{esc(time_ago(m.get("added_at",0)))} · {esc(kind)}</div>'
            f'{src}</div></a>'
        )
    body = (f'<div class="wrap"><h1>Scratchpad</h1>'
            f'<div class="sub">{len(pads)} pad(s)</div>'
            f'<a class="livebtn" href="/latest"><span class="dot"></span>Live view<span class="arr">↗</span></a>'
            f'<div class="grid">{"".join(cards)}</div></div>')
    return page(body)


def _view_body(m, live=False):
    rid = esc(m["id"])
    badge = '<span class="live" id=livebadge>live</span>' if live else ""
    home = '<a class="home" href="/">← all</a>'
    dl = esc(slugify(m.get("title") or m["id"]) + "." + (m.get("ext") or "txt"))
    actions = (f'<div class="acts">'
               f'<button class="act" id="cf-copy" title="Copy" aria-label="Copy">⧉</button>'
               f'<a class="act" id="cf-dl" href="/s/{rid}/raw" download="{dl}" '
               f'title="Download" aria-label="Download">↓</a></div>')
    bar = (f'<div class="bar">{home}<div class="bt">{esc(m.get("title") or m["id"])}</div>'
           f'{actions}<span class="bm">{esc(time_ago(m.get("added_at",0)))}</span>{badge}</div>')
    if m["kind"] == "html":
        inner = (f'<iframe class="frame" id="frame" src="/s/{rid}/raw" '
                 f'sandbox="allow-scripts allow-popups allow-forms"></iframe>')
    elif m["kind"] == "image":
        inner = f'<div class="imgwrap"><img id="frame" src="/s/{rid}/raw" alt=""></div>'
    elif m["kind"] == "video":
        inner = (f'<div class="imgwrap"><video id="frame" src="/s/{rid}/raw" controls playsinline '
                 f'preload="metadata"></video></div>')
    elif m["kind"] == "markdown":
        cp = content_path(m["id"])
        md = cp.read_text(errors="replace") if cp else ""
        inner = f'<div class="doc" id="frame">{md_to_html(md)}</div>'
    else:
        cp = content_path(m["id"])
        txt = cp.read_text(errors="replace") if cp else ""
        inner = f'<div class="doc" id="frame"><pre>{esc(txt)}</pre></div>'
    stage = f'<div id="stage">{inner}<div id="cf-ov"></div></div>'
    return bar + stage + _markup(m) + _actions_js(m)


# Copy button. Clipboard access depends on the page: over Tailscale the pad is
# served as plain http (not a secure context), so navigator.clipboard is often
# unavailable — we fall back to a hidden-textarea execCommand('copy') for text,
# which works in non-secure contexts. Text kinds (html/markdown/text + svg) copy
# their raw source; raster images try the async Clipboard image API and fall back
# to copying the pad's raw URL.
def _actions_js(m):
    cfg = json.dumps({"id": m["id"], "kind": m["kind"], "ext": m.get("ext") or ""})
    js = """<script>(function(){
var C=__CFG__,btn=document.getElementById('cf-copy');if(!btn)return;var orig=btn.textContent;
function flash(s){btn.textContent=s;setTimeout(function(){btn.textContent=orig;},1200);}
function copyText(t){
 if(navigator.clipboard&&navigator.clipboard.writeText){
  navigator.clipboard.writeText(t).then(function(){flash('\\u2713');},fallback);
 }else{fallback();}
 function fallback(){try{var ta=document.createElement('textarea');ta.value=t;ta.setAttribute('readonly','');
  ta.style.position='fixed';ta.style.top='0';ta.style.opacity='0';document.body.appendChild(ta);
  ta.focus();ta.select();ta.setSelectionRange(0,t.length);var ok=document.execCommand('copy');
  document.body.removeChild(ta);flash(ok?'\\u2713':'\\u26a0');}catch(e){flash('\\u26a0');}}
}
btn.addEventListener('click',function(){
 var raw='/s/'+C.id+'/raw';
 if(C.kind==='image'&&C.ext!=='svg'){
  if(navigator.clipboard&&window.ClipboardItem){
   fetch(raw).then(function(r){return r.blob();}).then(function(b){
    return navigator.clipboard.write([new ClipboardItem({[b.type]:b})]);
   }).then(function(){flash('\\u2713');}).catch(function(){copyText(location.origin+raw);});
  }else{copyText(location.origin+raw);}
  return;
 }
 fetch(raw).then(function(r){return r.text();}).then(copyText).catch(function(){flash('\\u26a0');});
});})();</script>""".replace("__CFG__", cfg)
    return js


# Markup layer: drop positional pins on the preview and POST the comments to the
# daemon. Lives in the PARENT page (same origin as the daemon) — never inside the
# sandboxed pad iframe, which has no allow-same-origin and couldn't POST. Pins are
# coordinate-based (% of the preview box), so it works for html/image/markdown/text
# alike. The daemon writes comments to feedback-inbox.jsonl for the agent to act on.
def _markup(m):
    pad = json.dumps({"id": m["id"], "title": m.get("title") or m["id"]})
    tools = (
        '<div class="cf-tools">'
        '<button id="cf-toggle">✎ Comment</button>'
        '<span class="hint" id="cf-hint"></span><span class="sp"></span>'
        '<button id="cf-clear" hidden>Clear</button>'
        '<button id="cf-send" class="primary" hidden disabled>Send</button></div>'
        '<div class="cf-sheet" id="cf-sheet">'
        '<textarea id="cf-text" placeholder="What about this spot?"></textarea>'
        '<div class="row"><button id="cf-cancel">Cancel</button>'
        '<button id="cf-add" class="primary">Add pin</button></div></div>'
        '<div class="cf-toast" id="cf-toast"></div>'
    )
    js = """<script>(function(){
var PAD=__PAD__,$=function(i){return document.getElementById(i);};
var ov=$('cf-ov'),tg=$('cf-toggle'),hint=$('cf-hint'),clr=$('cf-clear'),snd=$('cf-send'),
sheet=$('cf-sheet'),txt=$('cf-text'),addB=$('cf-add'),canB=$('cf-cancel'),toast=$('cf-toast');
var pins=[],mode=false,pend=null;
function upd(){clr.hidden=snd.hidden=pins.length===0;snd.disabled=pins.length===0;
if(pins.length)snd.textContent='Send ('+pins.length+')';
hint.textContent=mode?(pins.length?'Tap to add more':'Tap the preview to drop a pin'):(pins.length?pins.length+' pin(s)':'');}
function setMode(on){mode=on;ov.classList.toggle('on',on);tg.textContent=on?'✓ Done':'✎ Comment';tg.classList.toggle('primary',on);upd();}
function renum(){pins.forEach(function(p,i){p.n=i+1;});}
function draw(){[].slice.call(ov.querySelectorAll('.cf-pin')).forEach(function(e){e.remove();});
pins.forEach(function(p){var el=document.createElement('div');el.className='cf-pin';
el.style.left=p.x+'%';el.style.top=p.y+'%';el.innerHTML='<b>'+p.n+'</b>';el.title=p.text;
el.addEventListener('click',function(ev){ev.stopPropagation();
if(confirm('Remove pin '+p.n+'?')){pins=pins.filter(function(q){return q!==p;});renum();draw();upd();}});
ov.appendChild(el);});}
ov.addEventListener('click',function(e){if(!mode||e.target!==ov)return;
var r=ov.getBoundingClientRect();pend={x:(e.clientX-r.left)/r.width*100,y:(e.clientY-r.top)/r.height*100};
txt.value='';sheet.classList.add('open');setTimeout(function(){txt.focus();},60);});
function closeSheet(){sheet.classList.remove('open');pend=null;}
addB.addEventListener('click',function(){if(!pend)return;var t=txt.value.trim();if(!t){txt.focus();return;}
pins.push({n:pins.length+1,x:pend.x,y:pend.y,text:t});closeSheet();draw();upd();});
canB.addEventListener('click',closeSheet);
tg.addEventListener('click',function(){setMode(!mode);});
clr.addEventListener('click',function(){if(confirm('Clear all pins?')){pins=[];draw();upd();}});
function toastMsg(s){toast.textContent=s;toast.classList.add('show');setTimeout(function(){toast.classList.remove('show');},2600);}
snd.addEventListener('click',function(){if(!pins.length)return;snd.disabled=true;
fetch('/api/feedback',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({pad_id:PAD.id,pad_title:PAD.title,url:location.href,
comments:pins.map(function(p){return {n:p.n,x:Math.round(p.x*10)/10,y:Math.round(p.y*10)/10,comment:p.text};})})})
.then(function(r){return r.json();}).then(function(d){if(d&&d.ok){toastMsg('Sent '+pins.length+' comment(s)');
pins=[];draw();upd();setMode(false);}else{toastMsg((d&&d.error)||'Send failed');snd.disabled=false;}})
.catch(function(){toastMsg('Send failed');snd.disabled=false;});});
upd();})();</script>""".replace("__PAD__", pad)
    return tools + js


def render_view(m):
    return page(_view_body(m), title=m.get("title") or "Scratchpad")


def render_latest(m):
    if not m:
        body = ('<div class="wrap"><h1>Scratchpad</h1>'
                '<div class="empty">Nothing pushed yet — waiting…</div></div>'
                '<script>setInterval(function(){fetch("/api/latest",{cache:"no-store"})'
                '.then(function(r){return r.json();}).then(function(d){if(d.id)location.reload();})'
                '.catch(function(){});},3000);</script>')
        return page(body)
    body = _view_body(m, live=True)
    poll = (f'<script>var CUR="{esc(m["id"])}";setInterval(function(){{'
            'fetch("/api/latest",{cache:"no-store"}).then(function(r){return r.json();})'
            '.then(function(d){if(d.id&&d.id!==CUR)location.reload();}).catch(function(){});},3000);</script>')
    return page(body + poll, title=m.get("title") or "Scratchpad")


# ---------------------------------------------------------------------- serve

def run_daemon(host, port):
    class H(http.server.BaseHTTPRequestHandler):
        def _send(self, body, ctype="text/html; charset=utf-8", code=200, cache=None):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            if cache:
                self.send_header("Cache-Control", cache)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def _send_file(self, fp, ctype):
            """Serve a stored file with HTTP Range support (iOS Safari will not
            play <video> from a server that ignores Range)."""
            size = fp.stat().st_size
            start, end = 0, size - 1
            rng = self.headers.get("Range")
            partial = False
            if rng and rng.startswith("bytes="):
                a, _, b = rng[6:].partition("-")
                try:
                    start = int(a) if a else max(0, size - int(b))
                    end = int(b) if (b and a) else end
                    partial = True
                except ValueError:
                    start, end, partial = 0, size - 1, False
                end = min(end, size - 1)
                if start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            try:
                with fp.open("rb") as f:
                    f.seek(start)
                    remaining = end - start + 1
                    while remaining > 0:
                        chunk = f.read(min(1 << 20, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            p = self.path.split("?")[0]
            if p in ("/", "/index.html"):
                return self._send(render_index(load_pads()))
            if p == "/latest":
                pads = load_pads()
                return self._send(render_latest(pads[0] if pads else None))
            if p == "/api/latest":
                pads = load_pads()
                return self._send(json.dumps({"id": pads[0]["id"] if pads else None}),
                                  "application/json", cache="no-store")
            if p == "/api/list":
                return self._send(json.dumps(load_pads()), "application/json", cache="no-store")
            if p == "/manifest.webmanifest":
                return self._send(MANIFEST, "application/manifest+json")
            if p == "/sw.js":
                return self._send(SW, "application/javascript")
            if p in ICON_ROUTES:
                fn, ct = ICON_ROUTES[p]
                fp = ICON_DIR / fn
                return self._send(fp.read_bytes(), ct, cache="public, max-age=86400") if fp.exists() else self._send("404", code=404)
            if p.startswith("/s/"):
                parts = p[3:].split("/")
                rid = parts[0]
                m = meta_of(rid)
                if not m:
                    return self._send("<h1>404</h1>", code=404)
                if len(parts) >= 2 and parts[1] == "favicon":
                    fp = favicon_path(rid)
                    if not fp:
                        return self._send("404", code=404)
                    ctype = mimetypes.guess_type(str(fp))[0] or "image/x-icon"
                    return self._send(fp.read_bytes(), ctype, cache="public, max-age=86400")
                if len(parts) >= 2 and parts[1] == "raw":
                    cp = content_path(rid)
                    if not cp:
                        return self._send("404", code=404)
                    ctype = mimetypes.guess_type(str(cp))[0] or "application/octet-stream"
                    if cp.suffix.lower() in (".html", ".htm"):
                        ctype = "text/html; charset=utf-8"
                    return self._send_file(cp, ctype)
                return self._send(render_view(m))
            self.send_response(204)
            self.end_headers()

        # ---- markup comments (write path) ----
        # The write path is gated far more tightly than viewing: the daemon binds
        # 0.0.0.0 so anyone on the LAN can *view* pads, but accepting comments from
        # the LAN would be a remote prompt-injection channel (the agent reads and
        # acts on the inbox). So we accept comment POSTs only from loopback or the
        # Tailscale range (the user's own authenticated devices), plus a same-origin
        # check to block browser CSRF and a body-size cap.
        TRUSTED_NET = ipaddress.ip_network("100.64.0.0/10")  # Tailscale CGNAT
        MAX_POST = 256 * 1024

        def _client_trusted(self):
            ip = self.client_address[0].replace("::ffff:", "")
            try:
                a = ipaddress.ip_address(ip)
            except ValueError:
                return False
            return a.is_loopback or a in self.TRUSTED_NET

        def _same_origin(self):
            origin = self.headers.get("Origin")
            if not origin:
                return True
            host = self.headers.get("Host", "")
            return bool(host) and urlparse(origin).netloc == host

        def _jpost(self, payload, code=200):
            self._send(json.dumps(payload), "application/json", code=code, cache="no-store")

        def do_POST(self):
            if self.path.split("?")[0] != "/api/feedback":
                return self._jpost({"ok": False, "error": "unknown endpoint"}, 404)
            if not self._client_trusted():
                return self._jpost({"ok": False, "error": "forbidden (untrusted client)"}, 403)
            if not self._same_origin():
                return self._jpost({"ok": False, "error": "cross-origin rejected"}, 403)
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self._jpost({"ok": False, "error": "bad content-length"}, 400)
            if length <= 0 or length > self.MAX_POST:
                return self._jpost({"ok": False, "error": "bad body size"}, 413)
            try:
                data = json.loads(self.rfile.read(length).decode("utf-8", "replace"))
            except (json.JSONDecodeError, ValueError):
                return self._jpost({"ok": False, "error": "invalid json"}, 400)
            rid = str(data.get("pad_id") or "")
            m = meta_of(rid)
            rec = {
                "pad_id": rid,
                "pad_title": data.get("pad_title"),
                "source_cwd": (m or {}).get("cwd"),
                "source_dir": (m or {}).get("dir"),
                "comments": data.get("comments") or [],
                "received_at": int(time.time()),
                "received_iso": time.strftime("%Y-%m-%dT%H:%M:%S"),
            }
            with open(store_dir() / "feedback-inbox.jsonl", "a") as f:
                f.write(json.dumps(rec) + "\n")
            print(f"[feedback] {len(rec['comments'])} comment(s) on pad {rid}")
            return self._jpost({"ok": True})

        def log_message(self, *a):
            pass

    try:
        httpd = http.server.ThreadingHTTPServer((host, port), H)
    except OSError:
        return
    print(f"scratchpad on {host}:{port}  (store: {store_dir()})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.shutdown()


def port_open(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def tailscale_bin():
    found = shutil.which("tailscale")
    if found:
        return found
    for p in ("/Applications/Tailscale.app/Contents/MacOS/Tailscale",
              "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"):
        if os.path.exists(p):
            return p
    return None


def _ts(bin_, args, timeout=10):
    try:
        r = subprocess.run([bin_] + args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def _serve_host(bin_, port):
    """The <node>.<tailnet>.ts.net:<port> already fronted by `tailscale serve`."""
    out = _ts(bin_, ["serve", "status", "--json"])
    if not out:
        return None
    try:
        cfg = json.loads(out)
    except json.JSONDecodeError:
        return None
    if not (cfg.get("TCP") or {}).get(str(port), {}).get("HTTPS"):
        return None
    want = f"http://127.0.0.1:{port}"
    for hostport, entry in (cfg.get("Web") or {}).items():
        if not hostport.endswith(f":{port}"):
            continue
        if (entry.get("Handlers") or {}).get("/", {}).get("Proxy") == want:
            return hostport
    return None


def https_base(port):
    """Public https:// base for the pad server, via Tailscale's own TLS.

    Tailscale terminates TLS with a real cert for the node's ts.net name, so the
    link works on a phone with nothing to install. Sets the proxy up on first
    use. Returns None when Tailscale (or tailnet HTTPS) isn't available.
    """
    bin_ = tailscale_bin()
    if not bin_:
        return None
    hostport = _serve_host(bin_, port)
    if not hostport:
        _ts(bin_, ["serve", "--bg", "--yes", "--https", str(port),
                   f"http://127.0.0.1:{port}"], timeout=20)
        hostport = _serve_host(bin_, port)
    return f"https://{hostport}" if hostport else None


def ensure_daemon(host, port):
    if port_open(port):
        return
    log = open(store_dir() / "daemon.log", "ab")
    subprocess.Popen(
        [sys.executable, str(HERE / "scratchpad.py"), "serve", "--host", host, "--port", str(port)],
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
    )
    for _ in range(40):
        if port_open(port):
            return
        time.sleep(0.1)


def announce(rid, host, port, do_open):
    base = https_base(port)
    if base:
        pad = f"{base}/s/{rid}"
        print(f"\n  Scratchpad → {pad}")
        print(f"  Live view  → {base}/latest\n")
    else:
        # No Tailscale HTTPS front end — loopback only, and say so.
        pad = f"http://127.0.0.1:{port}/s/{rid}"
        print(f"\n  Scratchpad → {pad}")
        print(f"  Live view  → http://127.0.0.1:{port}/latest")
        print("  (http, this machine only: `tailscale serve` unavailable)\n")
    if do_open:
        import webbrowser
        webbrowser.open(pad)


def main():
    argv = sys.argv[1:]
    host, port, do_open = "127.0.0.1", DEFAULT_PORT, False  # loopback by default; expose only via the gateway
    title, kind = None, "html"
    pos = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--local":
            host = "127.0.0.1"
        elif a == "--host":
            i += 1; host = argv[i]
        elif a == "--port":
            i += 1; port = int(argv[i])
        elif a == "--title":
            i += 1; title = argv[i]
        elif a == "--kind":
            i += 1; kind = argv[i]
        elif a == "--open":
            do_open = True
        elif a in ("-h", "--help"):
            print(__doc__); return
        else:
            pos.append(a)
        i += 1

    cmd = pos[0] if pos else "serve"
    if cmd == "serve":
        return run_daemon(host, port)
    if cmd == "stop":
        try:
            out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                                 capture_output=True, text=True).stdout.split()
            for pid in out:
                os.kill(int(pid), 15)
            print("stopped")
        except (OSError, ValueError):
            print("not running")
        return
    if cmd == "list":
        for m in load_pads():
            print(f"  /s/{m['id']}  ·  {m['kind']:8}  {m.get('title','')}")
        return
    if cmd == "add":
        if len(pos) < 2:
            sys.exit("usage: scratchpad.py add <file> [--title T]")
        rid = add_file(pos[1], title)
    elif cmd == "push":
        rid = push_stdin(title, kind)
    else:
        sys.exit(f"unknown command: {cmd}")
    ensure_daemon(host, port)
    announce(rid, host, port, do_open)


if __name__ == "__main__":
    main()
