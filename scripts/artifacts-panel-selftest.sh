#!/usr/bin/env bash
#
# artifacts-panel-selftest.sh — renders the REAL ArtifactsViewController at
# sidebar width, fed by the real ArtifactTranscriptReader over a transcript and
# real files in a temp dir, writes PNG snapshots, and drives selection, the
# Quick Look, markdown and code previews, arrow keys and ↩ through AppKit.
# `make test` never compiles AppKit views. Exit 0 = every expectation held.
#
# Usage:  scripts/artifacts-panel-selftest.sh [out-dir]
# Requires: Xcode (swiftc). An accessory process: it shows a window for a few
# seconds but never takes keyboard focus.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
SHOTS=${1:-/tmp/artifacts-panel}
mkdir -p "$SHOTS"
OUT=$(mktemp -d /tmp/artifacts-panel-selftest.XXXXXX)
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
  -o "$OUT/artifacts-panel" \
  scripts/artifacts-panel/main.swift "$OUT/Extracted.swift" $PURE \
  $SRC/ArtifactsViewController.swift $SRC/Theme.swift

ARTIFACTS_PANEL_SHOTS="$SHOTS" "$OUT/artifacts-panel" -NSAppSleepDisabled YES
