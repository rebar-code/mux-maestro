#!/usr/bin/env bash
#
# toast-click-selftest.sh — clicks the manager toast's × and body with real
# NSEvents dispatched through AppKit, against the real ManagerToastOverlay.swift.
# `make test` never compiles AppKit views, and calling a click handler directly
# proves nothing about which view AppKit hands the click to (that is how the ×
# shipped dead in PR #124). Exit 0 = every expectation held.
#
# Usage:  scripts/toast-click-selftest.sh
# Requires: Xcode (swiftc). Opens a toast on screen for about a second.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
OUT=$(mktemp -d /tmp/toast-click-selftest.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

# The toast's small dependencies are cut out of the big files they live in, so
# the harness builds against the shipping code and not a copy of it.
{
  echo 'import Cocoa'
  awk '/^enum SidebarPalette/,/^}/' $SRC/SidebarViewController.swift
  awk '/^enum SidebarAddButton/,/^}/' $SRC/SidebarViewController.swift
  awk '/^final class HoverTintButton/,/^}/' $SRC/SidebarViewController.swift
} > "$OUT/Extracted.swift"

# The pure sources the unit-test target already compiles without AppKit views
# (every Swift file listed in both Sources phases), plus the toast and its views.
PURE=$(awk '/isa = PBXSourcesBuildPhase/,/};/' MuxMaestro.xcodeproj/project.pbxproj \
  | grep -o '/\* [A-Za-z0-9+]*\.swift in' | awk '{print $2}' | sort | uniq -d \
  | sed "s|^|$SRC/|")

# shellcheck disable=SC2086
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc \
  -o "$OUT/toast-click" \
  scripts/toast-click/main.swift "$OUT/Extracted.swift" $PURE \
  $SRC/ManagerToastOverlay.swift $SRC/LinkLabel.swift $SRC/Theme.swift

"$OUT/toast-click" -NSAppSleepDisabled YES
