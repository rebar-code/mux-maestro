#!/usr/bin/env bash
#
# server-stats-selftest.sh — renders the REAL HostStatsCell (the stat card under
# an expanded Servers row) from fixture stats run through the real
# HostStats.parse, plus one live fetch of this Mac, at the sidebar's 220 pt
# width in dark and light, and writes PNG snapshots. `make test` never compiles
# AppKit views, and a layout is only checked by looking at it. Exit 0 = every
# expectation held.
#
# Usage:  scripts/server-stats-selftest.sh [out-dir]
# Requires: Xcode (swiftc). Opens a window on screen for about a second.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
SHOTS=${1:-/tmp/server-stats-shots}
mkdir -p "$SHOTS"
OUT=$(mktemp -d /tmp/server-stats-selftest.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

# The palette and the card tint's gradient live in the sidebar, which does not
# compile alone. The gradient is file-private there; lift that here.
{
  echo 'import Cocoa'
  awk '/^enum SidebarPalette/,/^}/' $SRC/SidebarViewController.swift
  awk '/^private func drawPaneAccentGradient/,/^}/' $SRC/SidebarViewController.swift \
    | sed 's/^private func/func/'
} > "$OUT/Extracted.swift"

PURE=$(awk '/isa = PBXSourcesBuildPhase/,/};/' MuxMaestro.xcodeproj/project.pbxproj \
  | grep -o '/\* [A-Za-z0-9+]*\.swift in' | awk '{print $2}' | sort | uniq -d \
  | sed "s|^|$SRC/|")

# shellcheck disable=SC2086
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc \
  -o "$OUT/server-stats" \
  scripts/server-stats/main.swift "$OUT/Extracted.swift" $PURE \
  $SRC/HostStatsCard.swift $SRC/Theme.swift

SERVER_STATS_SHOTS="$SHOTS" "$OUT/server-stats" -NSAppSleepDisabled YES
