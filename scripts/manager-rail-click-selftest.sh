#!/usr/bin/env bash
#
# manager-rail-click-selftest.sh — clicks a Needs-you row's dismiss checkbox and
# body with real NSEvents dispatched through AppKit, against the real
# ManagerRailViewController.swift, then resizes the pane as the right sidebar
# does and checks how the two cards lay out at each width and height.
# `make test` never compiles AppKit views, and calling a click handler directly
# proves nothing about which view AppKit hands the click to (that is how the
# checkbox shipped dead). Exit 0 = every expectation held.
#
# Usage:  scripts/manager-rail-click-selftest.sh
#         RAIL_SHOT=/tmp/shots scripts/manager-rail-click-selftest.sh   (also PNGs)
# Requires: Xcode (swiftc). Opens a window on screen for a few seconds. The
# real terminal is stubbed out here; scripts/manager-tab-selftest.sh covers it.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
OUT=$(mktemp -d /tmp/manager-rail-click-selftest.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

# The rail's small dependencies are cut out of the big files they live in, so
# the harness builds against the shipping code and not a copy of it.
{
  echo 'import Cocoa'
  awk '/^enum SidebarPalette/,/^}/' $SRC/SidebarViewController.swift
  awk '/^enum SidebarAddButton/,/^}/' $SRC/SidebarViewController.swift
  awk '/^final class HoverTintButton/,/^}/' $SRC/SidebarViewController.swift
} > "$OUT/Extracted.swift"

# The pure sources the unit-test target already compiles without AppKit views
# (every Swift file listed in both Sources phases), plus the rail and its views.
PURE=$(awk '/isa = PBXSourcesBuildPhase/,/};/' MuxMaestro.xcodeproj/project.pbxproj \
  | grep -o '/\* [A-Za-z0-9+]*\.swift in' | awk '{print $2}' | sort | uniq -d \
  | sed "s|^|$SRC/|")

# The terminal is never shown here; a stub keeps Ghostty out of the build.
echo 'import Cocoa; class TerminalViewController: NSViewController {}' > "$OUT/Stubs.swift"

# shellcheck disable=SC2086
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc \
  -o "$OUT/rail-click" \
  scripts/manager-rail-click/main.swift "$OUT/Extracted.swift" "$OUT/Stubs.swift" $PURE \
  $SRC/ManagerRailViewController.swift $SRC/ManagerController.swift \
  $SRC/LinkLabel.swift $SRC/Theme.swift

"$OUT/rail-click" -NSAppSleepDisabled YES
