#!/usr/bin/env bash
#
# link-preview-selftest.sh — runs a REAL libghostty TerminalSurfaceView that
# prints demo URLs, with the REAL LinkPreviewViewController beside it. Sends
# mouse moves with and without ⌘ through the surface, checks which URL reached
# the preview and that the terminal kept focus, and writes PNG snapshots.
# `make test` never compiles AppKit views. Exit 0 = every expectation held.
#
# Usage:  scripts/link-preview-selftest.sh [out-dir]
# Requires: Xcode (swiftc), GhosttyKit.xcframework, network for the demo pages.
# It moves the pointer once and shows a window for a few seconds.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
GK=GhosttyKit.xcframework/macos-arm64
SHOTS=${1:-/tmp/link-preview}
mkdir -p "$SHOTS"
OUT=$(mktemp -d /tmp/link-preview-selftest.XXXXXX)
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
  -o "$OUT/link-preview" \
  -I "$GK/Headers" -L "$GK" -lghostty-fat -lstdc++ -framework Carbon \
  scripts/link-preview/main.swift "$OUT/Extracted.swift" $PURE \
  $SRC/TerminalSurfaceView.swift $SRC/GhosttyApp.swift $SRC/Ghostty+Input.swift \
  $SRC/LinkPreviewViewController.swift $SRC/Theme.swift

LINK_PREVIEW_SHOTS="$SHOTS" "$OUT/link-preview" -NSAppSleepDisabled YES
