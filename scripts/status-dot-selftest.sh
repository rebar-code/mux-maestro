#!/usr/bin/env bash
#
# status-dot-selftest.sh — draws the REAL AttentionDotView in each state,
# writes one PNG, and checks which states are solid, which are
# rings, and that the working arc's bright end leads. `make test` never
# compiles AppKit views, and a dot is only checked by looking at it.
# Exit 0 = every expectation held.
#
# Usage:  scripts/status-dot-selftest.sh [out-dir]
# Requires: Xcode (swiftc). Opens no window.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
SHOTS=${1:-/tmp/status-dot}
mkdir -p "$SHOTS"
OUT=$(mktemp -d /tmp/status-dot-selftest.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

{
  echo 'import Cocoa'
  awk '/^enum SidebarPalette/,/^}/' $SRC/SidebarViewController.swift
  awk '/^final class AttentionDotView/,/^}/' $SRC/SidebarViewController.swift
  awk '/^enum AttentionStatus/,/^}/' $SRC/TmuxModel.swift
  awk '/^enum StatusIndicator/,/^}/' $SRC/TmuxModel.swift
} > "$OUT/Extracted.swift"

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc \
  -o "$OUT/status-dot" scripts/status-dot/main.swift "$OUT/Extracted.swift" $SRC/Theme.swift

STATUS_DOT_SHOTS="$SHOTS" "$OUT/status-dot"
