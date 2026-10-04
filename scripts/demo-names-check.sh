#!/bin/bash
# Check that no real project name is in the tree. This repository is public, so
# fixtures and examples use demo data (`acme-app`, `widget-shop`, `devbox`).
#
# The blocklist holds SHA-256 hashes, not the names: a list in clear text would
# publish them again. Every word of every tracked file and path is lowercased
# and hashed, and so is every pair of neighbouring words joined together. That
# catches a two-word name however it is written: `Two Words`, `two-words`,
# `two_words`, `TwoWords`.
#
# To block another name: lowercase it, drop everything but a-z, and add
#   printf '%s' thename | shasum -a 256
set -euo pipefail
cd "$(dirname "$0")/.."

git ls-files -z | python3 -c '
import hashlib, re, sys

BLOCKED = {
    "0bcd1861e491d3547dba181c05faaf6cb310eabd4b51a4b858e0d122cbc5041a",
    "17ebc0d03f469a1378f4d96a6580fc92abbea510cd8b5ec55dd85cba70fdc5f5",
    "a20b56d70621ea7fcadc09349c73733844a8c70ed9d275acc1ae40049a027d74",
    "e4e06d76dc46c90c2e1d742e7aabf1997ece3ad220fc3d112f9ea8b93515e6c0",
    "b14cddc7fc490d732e6f9e3658ede0a3fd3dd3f65ea7cbd50f091afc3b5fea4f",
    "18a523c2ed3c225668b24ce158a23242ac8752556f1ebad8e53661aee0b7730d",
    "8b6a21b6335f78f6d775ef2cd700413c7714bee6cacbdb2f2a218c4f48d5b801",
}
WORD = re.compile(r"[a-z]+")
verdict = {}  # candidate -> blocked?, so each distinct word is hashed once


def blocked(candidate):
    hit = verdict.get(candidate)
    if hit is None:
        hit = hashlib.sha256(candidate.encode()).hexdigest() in BLOCKED
        verdict[candidate] = hit
    return hit


def hits(line):
    words = WORD.findall(line.lower())
    return any(blocked(w) for w in words) or any(
        blocked(a + b) for a, b in zip(words, words[1:]))


found = []
for path in filter(None, sys.stdin.read().split("\0")):
    if hits(path):
        found.append(path)
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        continue  # a submodule or a dangling symlink
    if b"\0" in data[:8192]:
        continue  # binary
    for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
        if hits(line):
            found.append("%s:%d" % (path, number))

if found:
    print("demo-names-check: a blocked project name is in the tree:")
    print("\n".join("  " + f for f in found))
    print("Use demo data instead: acme-app, widget-shop, devbox.")
    sys.exit(1)
print("demo-names-check: ok")
'
