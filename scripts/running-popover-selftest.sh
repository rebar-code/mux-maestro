#!/usr/bin/env bash
#
# running-popover-selftest.sh — renders the REAL RunningViewController with
# fixture scans run through the real Running core, writes PNG snapshots, and
# clicks its name, link and copy targets with NSEvents dispatched through AppKit.
# `make test` never compiles AppKit views, and a layout is only checked by
# looking at it. Exit 0 = every expectation held.
#
# Usage:  scripts/running-popover-selftest.sh [out-dir]
# Requires: Xcode (swiftc). Opens a window on screen for about two seconds.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
SHOTS=${1:-/tmp/running-popover}
mkdir -p "$SHOTS"
OUT=$(mktemp -d /tmp/running-popover-selftest.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

{
  echo 'import Cocoa'
  awk '/^enum SidebarPalette/,/^}/' $SRC/SidebarViewController.swift
} > "$OUT/Extracted.swift"

PURE=$(awk '/isa = PBXSourcesBuildPhase/,/};/' MuxMaestro.xcodeproj/project.pbxproj \
  | grep -o '/\* [A-Za-z0-9+]*\.swift in' | awk '{print $2}' | sort | uniq -d \
  | sed "s|^|$SRC/|")

# shellcheck disable=SC2086
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc \
  -o "$OUT/running-popover" \
  scripts/running-popover/main.swift "$OUT/Extracted.swift" $PURE \
  $SRC/RunningViewController.swift $SRC/WorktreeRowCell.swift $SRC/Theme.swift

RUNNING_POPOVER_SHOTS="$SHOTS" "$OUT/running-popover" -NSAppSleepDisabled YES
