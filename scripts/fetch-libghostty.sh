#!/usr/bin/env bash
#
# fetch-libghostty.sh — download the prebuilt GhosttyKit.xcframework from this
# repo's GitHub release, check its pinned SHA-256, and link it to the repo root.
# No Zig needed. The release is built from pinned Ghostty source by
# .github/workflows/ghosttykit-release.yml. To build from source instead, run
# `make libghostty-source` (scripts/build-libghostty.sh).
#
# Usage:  scripts/fetch-libghostty.sh
# Requires: macOS arm64, curl, tar, shasum.

set -euo pipefail

# --- Pinned release --------------------------------------------------------
# Ghostty v1.3.1 @ 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28 (as in build-libghostty.sh)
RELEASE_TAG="ghosttykit-v1.3.1"
ASSET="GhosttyKit-macos-arm64.tar.gz"
ASSET_SHA256="__PENDING__"
URL="https://github.com/rebar-code/mux-maestro/releases/download/${RELEASE_TAG}/${ASSET}"

# --- Paths -----------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_PARENT="$ROOT/vendor/ghostty/macos"
XCFRAMEWORK_SRC="$DEST_PARENT/GhosttyKit.xcframework"
XCFRAMEWORK_DST="$ROOT/GhosttyKit.xcframework"

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "error: this script targets macOS arm64 (got: $ARCH)" >&2
  exit 1
fi

# --- 1. Download and verify ------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "==> Downloading prebuilt GhosttyKit (${RELEASE_TAG})"
echo "    $URL"
curl -fL --retry 3 --progress-bar -o "$TMP/$ASSET" "$URL"
ACTUAL_SHA256="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$ASSET_SHA256" ]]; then
  echo "error: SHA-256 mismatch for $ASSET: got $ACTUAL_SHA256, want $ASSET_SHA256" >&2
  exit 1
fi

# --- 2. Unpack and link to repo root ---------------------------------------
mkdir -p "$DEST_PARENT"
rm -rf "$XCFRAMEWORK_SRC"
tar -xzf "$TMP/$ASSET" -C "$DEST_PARENT"
rm -rf "$XCFRAMEWORK_DST"
ln -s "vendor/ghostty/macos/GhosttyKit.xcframework" "$XCFRAMEWORK_DST"

# --- 3. Verify -------------------------------------------------------------
HEADER="$XCFRAMEWORK_DST/macos-arm64/Headers/ghostty.h"
LIB="$XCFRAMEWORK_DST/macos-arm64/libghostty-fat.a"
[[ -f "$HEADER" ]] || { echo "error: missing ghostty.h" >&2; exit 1; }
[[ -f "$LIB" ]] || { echo "error: missing libghostty-fat.a" >&2; exit 1; }
lipo -info "$LIB"
echo "GhosttyKit.xcframework linked at $XCFRAMEWORK_DST"
