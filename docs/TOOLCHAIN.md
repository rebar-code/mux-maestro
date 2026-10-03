# Toolchain — building GhosttyKit.xcframework

Milestone 1 builds **`GhosttyKit.xcframework`** from Ghostty's source. This is
the embedded terminal engine (libghostty) the native Swift app links against.
It is built locally / in CI from a *pinned* Ghostty tag with a *pinned*,
project-local Zig toolchain (no Homebrew / global install).

## Pinned versions

| Component | Value |
|-----------|-------|
| Ghostty tag | `v1.3.1` |
| Ghostty commit SHA | `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` |
| Ghostty repo | https://github.com/ghostty-org/ghostty |
| Zig version | `0.15.2` |
| Zig download URL | https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz |

`v1.3.1` is the latest stable Ghostty release tag. The Zig version is taken from
Ghostty's `build.zig.zon` (`minimum_zig_version = "0.15.2"`) and confirmed by
its nix flake, which pins `zig ... "0.15.2"`.

## How to build

```sh
make libghostty
# or directly:
scripts/build-libghostty.sh
```

The script:
1. Downloads the pinned Zig tarball into `./.toolchain/` (skipped if present)
   and uses that `zig` binary by absolute path — no global/brew install.
2. Clones Ghostty into `./vendor/ghostty/` (skipped if present) and checks out
   the pinned SHA, asserting it matches.
3. Builds **only** the xcframework with:
   ```sh
   zig build -Demit-xcframework=true -Demit-macos-app=false \
             -Dxcframework-target=native -Doptimize=ReleaseFast
   ```
   - `-Demit-macos-app=false` skips building `Ghostty.app` (DockTilePlugin and
     other app-only Swift targets). We only need the library; building the full
     app is unnecessary and can fail on Swift-version drift.
   - `-Dxcframework-target=native` emits **arm64 only** (this machine). Use
     `universal` to also emit an x86_64 slice.
4. Symlinks the result to the repo root as `./GhosttyKit.xcframework`.
5. Verifies `ghostty.h` and `libghostty-fat.a` (arm64) exist.

Build inputs/outputs are gitignored (`vendor/ghostty/`, `.toolchain/` via
`zig-out`/caches, `GhosttyKit.xcframework/`) — they persist locally across
milestones and are rebuilt by this script.

## Where the xcframework lands

- Built by Ghostty's build at: `vendor/ghostty/macos/GhosttyKit.xcframework`
- Symlinked for the app at:     `./GhosttyKit.xcframework` (repo root)

Structure (arm64, static lib):

```
GhosttyKit.xcframework/
├── Info.plist
└── macos-arm64/
    ├── libghostty-fat.a          # static lib, arch: arm64
    └── Headers/
        ├── ghostty.h             # main libghostty C API
        ├── module.modulemap      # GhosttyKit module map (import GhosttyKit)
        └── ghostty/vt/...        # terminal/VT headers
```

## How to verify

```sh
ls -R GhosttyKit.xcframework
cat GhosttyKit.xcframework/Info.plist          # XFWK, SupportedArchitectures: arm64
lipo -info GhosttyKit.xcframework/macos-arm64/libghostty-fat.a   # arm64
test -f GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h && echo OK
```

## libghostty C API usage — for the next milestone (Skeleton)

libghostty's embedding C API is the surface defined in
`macos-arm64/Headers/ghostty.h`. Ghostty's own macOS app is the reference for
correct usage. The Swift↔C bridge lives in:

- `vendor/ghostty/macos/Sources/Ghostty/` — the bridge layer:
  - `Ghostty.App.swift` — `ghostty_app_new` / init / tick / lifecycle
  - `Ghostty.Surface.swift` + `Surface View/` — surface create, draw, resize,
    key/mouse input, PTY wiring (the core of what M2 needs)
  - `Ghostty.Config.swift`, `Ghostty.Input.swift`, `Ghostty.Action.swift`,
    `Ghostty.Event.swift` — config, input encoding, callbacks
- `vendor/ghostty/macos/Sources/Features/Terminal/` — higher-level usage:
  `TerminalView.swift`, `TerminalController.swift`, `BaseTerminalController.swift`
- `vendor/ghostty/macos/Sources/App/macOS/AppDelegate.swift` /
  `main.swift` — app-level wiring.

Files that `import GhosttyKit` / call the `ghostty_*` C API are the ones to
study when embedding a single libghostty surface pointed at a `tmux attach` PTY.

### Gotcha (M2): `window-vsync` must be off when embedding

`ghostty_surface_new` fails with `error.OutOfMemory` (and returns NULL) on this
embedding path **unless `window-vsync = false` is set in the libghostty config.**

Root cause (traced via a Debug build of libghostty): with vsync on (the
default), the Metal renderer calls the legacy
`CVDisplayLinkCreateWithActiveCGDisplays()`
(`pkg/macos/video/display_link.zig`), which fails in the embedded host context;
the wrapper maps *any* failure from that call to `error.OutOfMemory`, which
unwinds the whole surface init. The error message is misleading — it is not an
actual allocation failure.

With vsync off, libghostty does not create a CVDisplayLink and instead relies on
the host to drive draws. MuxMaestro already does this: a ~60 Hz app-tick timer
calls `ghostty_app_tick`, and the runtime `action_cb` handles `GHOSTTY_ACTION_RENDER`
by calling `ghostty_surface_draw`. MuxMaestro writes a tiny override config
(`window-vsync = false`) and loads it *after* the user's config so user settings
are still respected (see `app/MuxMaestro/GhosttyApp.swift`).
