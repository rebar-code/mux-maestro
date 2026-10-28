#!/usr/bin/env bash
#
# palette-selftest.sh — types into the REAL ⌘P file palette and ⌘K session
# palette with key events dispatched through AppKit. ⌘P lists a demo folder
# that is not a git repo (the real `TmuxService.repoFiles` walk) plus an
# artifact outside it; both palettes reopen with the old query selected.
# Writes PNG snapshots. `make test` never compiles AppKit views. Exit 0 =
# every expectation held.
#
# Usage:  scripts/palette-selftest.sh [out-dir]
# Requires: Xcode (swiftc). Shows two palettes for about two seconds.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/MuxMaestro
SHOTS=${1:-/tmp/palette}
mkdir -p "$SHOTS"
OUT=$(mktemp -d /tmp/palette-selftest.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

# The palettes' small dependencies are cut out of the big files they live in,
# so the harness builds against the shipping code and not a copy of it.
{
  echo 'import Cocoa'
  awk '/^enum SidebarPalette/,/^}/' $SRC/SidebarViewController.swift
  echo 'enum TreeViewController {'
  awk '/static func nsRange\(byteRange/,/^    }/' $SRC/TreeViewController.swift
  echo '}'
} > "$OUT/Extracted.swift"

# The pure sources the unit-test target already compiles without AppKit views
# (every Swift file listed in both Sources phases), plus the two palettes.
PURE=$(awk '/isa = PBXSourcesBuildPhase/,/};/' MuxMaestro.xcodeproj/project.pbxproj \
  | grep -o '/\* [A-Za-z0-9+]*\.swift in' | awk '{print $2}' | sort | uniq -d \
  | sed "s|^|$SRC/|")

# shellcheck disable=SC2086
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc \
  -o "$OUT/palette" \
  scripts/palette/main.swift "$OUT/Extracted.swift" $PURE \
  $SRC/FilePaletteViewController.swift $SRC/SessionPaletteViewController.swift $SRC/Theme.swift

PALETTE_SHOTS="$SHOTS" "$OUT/palette" -NSAppSleepDisabled YES
