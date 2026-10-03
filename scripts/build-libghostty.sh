#!/usr/bin/env bash
#
# build-libghostty.sh — reproducibly build GhosttyKit.xcframework from pinned
# Ghostty source using a project-local, pinned Zig toolchain (no brew/global
# install). Output is symlinked to the repo root as GhosttyKit.xcframework.
#
# Pinned versions (Milestone 1):
#   Ghostty: v1.3.1 @ 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
#   Zig:     0.15.2 (build.zig.zon minimum_zig_version; matches Ghostty's nix pin)
#
# Usage:  scripts/build-libghostty.sh
# Requires: macOS arm64, Xcode (xcodebuild/libtool on PATH), curl, tar, git.

set -euo pipefail

# --- Pinned versions -------------------------------------------------------
GHOSTTY_TAG="v1.3.1"
GHOSTTY_SHA="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
ZIG_VERSION="0.15.2"

# --- Paths -----------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor/ghostty"
TOOLCHAIN_DIR="$ROOT/.toolchain"
ZIG_DIR="$TOOLCHAIN_DIR/zig-aarch64-macos-${ZIG_VERSION}"
ZIG="$ZIG_DIR/zig"
XCFRAMEWORK_SRC="$VENDOR_DIR/macos/GhosttyKit.xcframework"
XCFRAMEWORK_DST="$ROOT/GhosttyKit.xcframework"

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "error: this script targets macOS arm64 (got: $ARCH)" >&2
  exit 1
fi

# --- 1. Pinned Zig toolchain (download official tarball if missing) --------
if [[ ! -x "$ZIG" ]]; then
  echo "==> Installing Zig ${ZIG_VERSION} (project-local, no global install)"
  mkdir -p "$TOOLCHAIN_DIR"
  ZIG_TARBALL_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
  echo "    downloading $ZIG_TARBALL_URL"
  curl -fsSL -o "$TOOLCHAIN_DIR/zig.tar.xz" "$ZIG_TARBALL_URL"
  tar -xf "$TOOLCHAIN_DIR/zig.tar.xz" -C "$TOOLCHAIN_DIR"
  rm -f "$TOOLCHAIN_DIR/zig.tar.xz"
fi
echo "==> Using Zig: $("$ZIG" version) at $ZIG"

# --- 2. Pinned Ghostty checkout --------------------------------------------
if [[ ! -d "$VENDOR_DIR/.git" ]]; then
  echo "==> Cloning Ghostty ${GHOSTTY_TAG}"
  git clone --quiet "$GHOSTTY_REPO" "$VENDOR_DIR"
fi
echo "==> Checking out Ghostty ${GHOSTTY_TAG} (${GHOSTTY_SHA})"
git -C "$VENDOR_DIR" fetch --quiet --tags
git -C "$VENDOR_DIR" checkout --quiet "$GHOSTTY_SHA"
ACTUAL_SHA="$(git -C "$VENDOR_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_SHA" != "$GHOSTTY_SHA" ]]; then
  echo "error: Ghostty SHA mismatch: got $ACTUAL_SHA, want $GHOSTTY_SHA" >&2
  exit 1
fi

# --- 3. Build the xcframework only (no macOS app) --------------------------
# emit-macos-app=false avoids building Ghostty.app (DockTilePlugin etc.), which
# we do not need and which can fail on Swift-version drift. xcframework-target
# native = arm64 only (this machine); use universal to also emit x86_64.
echo "==> Building GhosttyKit.xcframework (native arm64, ReleaseFast)"
( cd "$VENDOR_DIR" && "$ZIG" build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast )

if [[ ! -d "$XCFRAMEWORK_SRC" ]]; then
  echo "error: build did not produce $XCFRAMEWORK_SRC" >&2
  exit 1
fi

# --- 4. Symlink to repo root -----------------------------------------------
rm -rf "$XCFRAMEWORK_DST"
ln -s "vendor/ghostty/macos/GhosttyKit.xcframework" "$XCFRAMEWORK_DST"

# --- 5. Verify -------------------------------------------------------------
echo "==> Verifying xcframework"
HEADER="$XCFRAMEWORK_DST/macos-arm64/Headers/ghostty.h"
LIB="$XCFRAMEWORK_DST/macos-arm64/libghostty-fat.a"
[[ -f "$HEADER" ]] || { echo "error: missing ghostty.h" >&2; exit 1; }
[[ -f "$LIB" ]] || { echo "error: missing libghostty-fat.a" >&2; exit 1; }
lipo -info "$LIB"
echo ""
echo "GhosttyKit.xcframework built and linked at:"
echo "  $XCFRAMEWORK_DST -> vendor/ghostty/macos/GhosttyKit.xcframework"
echo "  header: $HEADER"
echo "Done."
