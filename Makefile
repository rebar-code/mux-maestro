# MuxMaestro — native macOS tmux orchestrator
#
# Milestone 1: build the embedded terminal engine (GhosttyKit.xcframework).
# Milestone 2: build/run the native AppKit app (MuxMaestro.app).

# Per-developer settings, never committed (see .gitignore). Read before the
# defaults below, so a `SIGN_IDENTITY = ...` line here wins over them. The file
# is optional: the build works without it.
-include local.mk

.PHONY: libghostty clean-libghostty app run install signing-identity signing-selftest test clean-app diff-bundle mobile vendor-beam beam-selftest vendor-tools tools-selftest

# Xcode to build with. Overridable so CI can point at its Xcode_16.2.app; the
# Swift packages need tools version 6.0, which the runner's default Xcode lacks.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# xcodebuild drops products into ./build/Release with SYMROOT=./build. The
# path is passed absolute: a relative SYMROOT is resolved per project, so the
# Swift packages would build into their own checkouts and the app link fails.
BUILD_DIR := build
APP := $(BUILD_DIR)/Release/MuxMaestro.app

# Code signing. `make app` uses a stable, self-signed identity when one exists —
# create it once with `make signing-identity`. Without it the build falls back to
# ad-hoc signing, whose designated requirement is a bare cdhash: macOS then reads
# every rebuild as a NEW app and asks again for every permission already granted
# (App Data, Automation, Documents…), leaving one more MuxMaestro row in System
# Settings each time. The identity keeps the requirement stable across rebuilds.
#
# SIGN_IDENTITY is a name or the identity's SHA-1 hash, as `security
# find-identity -v -p codesigning` lists them. An Apple identity's name has
# spaces, a colon and parentheses ("Apple Development: Your Name (TEAMID)"), so
# every use below goes through `shq`: one single-quoted shell word, with any
# quote inside it escaped. `grep -F` matches it as text, not as a pattern.
# `make signing-selftest` checks this.
SIGN_IDENTITY ?= MuxMaestro-Local
shq = '$(subst ','\'',$(1))'
HAVE_IDENTITY = security find-identity -v -p codesigning 2>/dev/null | grep -qF -- $(call shq,$(SIGN_IDENTITY))
#
# The identity reaches only the app target, through MM_CODE_SIGN_IDENTITY (the
# target's CODE_SIGN_IDENTITY is "$(MM_CODE_SIGN_IDENTITY)"). A CODE_SIGN_IDENTITY
# on the command line would apply to every project in the build, and xcodebuild
# then tries to sign the Swift packages' object files, which codesign refuses.
SIGN_FLAGS = $(if $(shell $(HAVE_IDENTITY) && echo yes),\
	MM_CODE_SIGN_IDENTITY=$(call shq,$(SIGN_IDENTITY)) OTHER_CODE_SIGN_FLAGS=--timestamp=none,\
	MM_CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)

# Create the stable local signing identity. Run once per Mac; see the script
# header for what it makes and why.
signing-identity:
	scripts/create-signing-identity.sh $(call shq,$(SIGN_IDENTITY))

# Check that a signing identity with spaces, parentheses or quotes in its name
# reaches xcodebuild as one argument. Uses stub tools: builds nothing and never
# reads the keychain.
signing-selftest:
	bash scripts/signing-selftest.sh

# Build GhosttyKit.xcframework from pinned Ghostty source with a pinned,
# project-local Zig toolchain. Output is symlinked to ./GhosttyKit.xcframework.
libghostty:
	scripts/build-libghostty.sh

# Remove the built xcframework symlink and Zig build artifacts (keeps the
# downloaded Zig toolchain and the Ghostty clone).
clean-libghostty:
	rm -rf GhosttyKit.xcframework vendor/ghostty/macos/GhosttyKit.xcframework
	rm -rf vendor/ghostty/zig-out vendor/ghostty/.zig-cache

# Build MuxMaestro.app. Requires GhosttyKit.xcframework at the repo root
# (run `make libghostty` first). Builds with the full Xcode toolchain.
# ARCHS is pinned on the command line so the Swift packages (FluidAudio,
# WhisperKit) build arm64 only: the project-level setting does not reach
# them, and FluidAudio uses Float16, which x86_64 macOS lacks.
app:
	@test -e GhosttyKit.xcframework || { echo "GhosttyKit.xcframework missing — run 'make libghostty'"; exit 1; }
	@$(HAVE_IDENTITY) || echo "warning: no signing identity named" $(call shq,$(SIGN_IDENTITY)) "— ad-hoc signing, so macOS re-asks for every permission after this build. Fix once with 'make signing-identity'."
	DEVELOPER_DIR=$(DEVELOPER_DIR) \
	xcodebuild \
		-project MuxMaestro.xcodeproj \
		-target MuxMaestro \
		-configuration Release \
		-sdk macosx \
		SYMROOT=$(CURDIR)/$(BUILD_DIR) OBJROOT=$(CURDIR)/$(BUILD_DIR)/obj \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		$(SIGN_FLAGS) \
		build
	@echo "Built $(APP)"

# Launch the built app.
run: app
	open $(APP)

# Install the fresh build over /Applications/MuxMaestro.app — the copy the Dock,
# Spotlight and a plain relaunch actually open.
#
# This target exists because the two copies drift and the running one is usually
# the older: on 2026-08-21 /Applications was a three-day-old build with none of
# the current work in it, and "the app doesn't show the feature" was really "the
# feature was never installed". Copying by hand is what let that happen.
#
# Quits a running instance first (replacing a live bundle in place corrupts it),
# then relaunches. tmux sessions are unaffected — the app is only a client.
install: app
	@pkill -x MuxMaestro 2>/dev/null; true
	@for i in $$(seq 1 20); do pgrep -x MuxMaestro >/dev/null || break; sleep 0.5; done
	@if pgrep -x MuxMaestro >/dev/null; then echo "MuxMaestro won't quit — install aborted"; exit 1; fi
	rm -rf /Applications/MuxMaestro.app
	ditto $(APP) /Applications/MuxMaestro.app
	@echo "Installed /Applications/MuxMaestro.app ($$(date -r /Applications/MuxMaestro.app/Contents/MacOS/MuxMaestro '+%Y-%m-%d %H:%M'))"
	open /Applications/MuxMaestro.app

# Run the unit tests (pure tmux parsing + attention/sort logic). This is a
# logic-test bundle with no app host, so it does not require GhosttyKit.
test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) \
	xcodebuild test \
		-project MuxMaestro.xcodeproj \
		-scheme MuxMaestroTests \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		SYMROOT=$(CURDIR)/$(BUILD_DIR) OBJROOT=$(CURDIR)/$(BUILD_DIR)/obj \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Rebuild the vendored, offline Diff-pane web bundle (@pierre/diffs + Shiki) and
# refresh the committed output under app/MuxMaestro/Resources/diff/. Only needed
# when changing the renderer — the built bundle is committed, so `make app`
# never runs this and end users never rebuild. Requires pnpm + node.
diff-bundle:
	pnpm -C web/diff install
	pnpm -C web/diff build
	@echo "Rebuilt web/diff → app/MuxMaestro/Resources/diff/ (commit the output)"

# Rebuild the phone web app (Svelte, source in mobile/) and refresh the
# committed output under app/MuxMaestro/Resources/mobile/. Only needed when
# changing mobile/: the built bundle is committed, so `make app` and CI need
# no Node. The same sources build the same files. Requires pnpm + node.
MOBILE_OUT := app/MuxMaestro/Resources/mobile
mobile:
	pnpm -C mobile install --frozen-lockfile
	rm -rf $(CURDIR)/$(MOBILE_OUT)
	pnpm -C mobile build
	@echo "Rebuilt mobile → $(MOBILE_OUT)/ (commit the output)"

clean-app:
	rm -rf $(BUILD_DIR)

# Maintainer-only: refreshes vendored copies from upstream. Not part of the
# default build; `make app` and `make test` use the committed copies.
# Usage: make vendor-beam BEAM_SRC=/path/to/dir/with/beam.sh
BEAM_SRC ?=
BEAM_DST := app/MuxMaestro/Resources/beam
vendor-beam:
	@test -n "$(BEAM_SRC)" || { echo "vendor-beam: set BEAM_SRC to the upstream directory holding beam.sh (maintainer-only target)"; exit 1; }
	cp $(BEAM_SRC)/beam.sh $(BEAM_SRC)/beam_merge.py $(BEAM_SRC)/beam-selftest.sh $(BEAM_DST)/
	chmod +x $(BEAM_DST)/beam.sh $(BEAM_DST)/beam-selftest.sh
	@echo "Re-synced beam scripts → $(BEAM_DST)/ (commit the output)"

# End-to-end test of the VENDORED beam engine against a no-SSH fake remote
# (repo + git + Claude/Codex history merge with path rewriting). Proves the
# bundled scripts are self-consistent without touching a real server.
beam-selftest:
	bash $(BEAM_DST)/beam-selftest.sh

# Maintainer-only: refreshes vendored copies from upstream. Not part of the
# default build. TOOLS_SRC is a directory holding sessions.py,
# spindown.py and spin.py. See Resources/tools/README.md.
TOOLS_SRC ?=
TOOLS_DST := app/MuxMaestro/Resources/tools
vendor-tools:
	@test -n "$(TOOLS_SRC)" || { echo "vendor-tools: set TOOLS_SRC to the upstream directory holding the tool scripts (maintainer-only target)"; exit 1; }
	cp $(TOOLS_SRC)/sessions.py $(TOOLS_SRC)/spindown.py $(TOOLS_SRC)/spin.py $(TOOLS_DST)/
	@echo "Re-synced helper scripts → $(TOOLS_DST)/ (commit the output)"

# Run the VENDORED helper scripts with an empty temp HOME and PATH=/usr/bin:/bin,
# the way they run on a Mac that isn't the author's.
tools-selftest:
	bash scripts/tools-selftest.sh
