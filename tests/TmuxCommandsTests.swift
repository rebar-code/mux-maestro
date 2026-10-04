import XCTest

// TmuxCommands.swift (pure argv construction, no AppKit / no process spawning)
// is compiled directly into this test target.

final class TmuxCommandsTests: XCTestCase {

    // MARK: new-session

    func testNewSessionArgv() {
        let argv = TmuxCommands.newSession(name: "api", dir: "/Users/me/code/api")
        XCTAssertEqual(argv, ["new-session", "-d", "-s", "api", "-c", "/Users/me/code/api"])
    }

    func testNewSessionPreservesSpacesInDirAndName() {
        let argv = TmuxCommands.newSession(name: "my proj", dir: "/Users/me/My Code/proj")
        XCTAssertEqual(argv[3], "my proj")
        XCTAssertEqual(argv[5], "/Users/me/My Code/proj")
    }

    func testNewSessionOmitsDirWhenAbsent() {
        // The move-to-new-session paths derive the directory from a live pane; when
        // that read fails, `-c` must be dropped rather than passed empty (tmux would
        // chdir to "" and fail the whole move).
        XCTAssertEqual(
            TmuxCommands.newSession(name: "api", dir: nil), ["new-session", "-d", "-s", "api"])
        XCTAssertEqual(
            TmuxCommands.newSession(name: "api", dir: ""), ["new-session", "-d", "-s", "api"])
    }

    func testSendKeysLineArgv() {
        let argv = TmuxCommands.sendKeysLine(session: "api", line: "claude")
        XCTAssertEqual(argv, ["send-keys", "-t", "api", "claude", "Enter"])
    }

    // MARK: kill / rename

    func testKillSessionArgv() {
        // Exact-match (`=`) so a session name that's a prefix of another can't misfire.
        XCTAssertEqual(TmuxCommands.killSession(name: "api"), ["kill-session", "-t", "=api"])
    }

    func testKillReachedGoalDespiteError() {
        // "Target already gone" outputs mean the close succeeded in effect.
        XCTAssertTrue(TmuxCommands.killReachedGoalDespiteError("can't find session: ghost"))
        XCTAssertTrue(TmuxCommands.killReachedGoalDespiteError("can't find window: 99"))
        XCTAssertTrue(TmuxCommands.killReachedGoalDespiteError("can't find pane: %999"))
        XCTAssertTrue(TmuxCommands.killReachedGoalDespiteError(
            "no server running on /private/tmp/tmux-501/default"))
        XCTAssertTrue(TmuxCommands.killReachedGoalDespiteError("CAN'T FIND WINDOW: 3")) // case-insensitive
        // A genuine error must NOT be treated as success.
        XCTAssertFalse(TmuxCommands.killReachedGoalDespiteError("permission denied"))
        XCTAssertFalse(TmuxCommands.killReachedGoalDespiteError(""))
    }

    func testRenameSessionArgv() {
        let argv = TmuxCommands.renameSession(from: "old name", to: "new name")
        XCTAssertEqual(argv, ["rename-session", "-t", "old name", "new name"])
    }

    // MARK: zoom

    func testToggleZoomArgv() {
        XCTAssertEqual(TmuxCommands.toggleZoom(target: "%12"), ["resize-pane", "-Z", "-t", "%12"])
        XCTAssertEqual(
            TmuxCommands.toggleZoom(target: "web:1"), ["resize-pane", "-Z", "-t", "web:1"])
    }

    func testZoomFlagArgv() {
        XCTAssertEqual(
            TmuxCommands.zoomFlag(target: "web"),
            ["display-message", "-p", "-t", "web", "#{window_zoomed_flag}"])
    }

    // MARK: zoom target resolution (M6 fix a)

    func testZoomTargetForSelectedPaneUsesPaneId() {
        // A selected pane must zoom by its id so the toggle hits the exact pane
        // that selectPane(zoom:) zoomed — not the session's active window.
        XCTAssertEqual(TmuxCommands.zoomTarget(for: .pane(id: "%12")), "%12")
    }

    func testZoomTargetForSelectedWindowUsesSessionWindow() {
        XCTAssertEqual(
            TmuxCommands.zoomTarget(for: .window(session: "web", window: 1)), "web:1")
    }

    func testZoomTargetForSessionUsesActiveWindow() {
        // A whole-session selection shows the active window, so zoom that window.
        XCTAssertEqual(
            TmuxCommands.zoomTarget(for: .session(name: "web", activeWindow: 2)), "web:2")
    }

    func testZoomTargetForSessionWithoutWindowsFallsBackToName() {
        XCTAssertEqual(
            TmuxCommands.zoomTarget(for: .session(name: "web", activeWindow: nil)), "web")
    }

    // MARK: copyable identifier ("Copy tmux ID")

    func testCopyableIdentifierForSessionIsTheName() {
        XCTAssertEqual(
            TmuxCommands.copyableIdentifier(for: .session(name: "web")), "web")
    }

    func testCopyableIdentifierForWindowIsSessionColonIndex() {
        XCTAssertEqual(
            TmuxCommands.copyableIdentifier(for: .window(session: "web", window: 1)), "web:1")
    }

    func testCopyableIdentifierForPaneIsThePaneId() {
        XCTAssertEqual(TmuxCommands.copyableIdentifier(for: .pane(id: "%12")), "%12")
    }

    // MARK: abbreviated agent session id (menu titles)

    func testAbbreviatedSessionIdShortensAUUID() {
        XCTAssertEqual(
            TmuxCommands.abbreviatedSessionId("6c4f3c09-1d2e-4a5b-8c7d-0099aaef189d"),
            "6c4f3c09…ef189d")
    }

    func testAbbreviatedSessionIdLeavesShortIdsAlone() {
        // Never render something no shorter than the original.
        XCTAssertEqual(TmuxCommands.abbreviatedSessionId("abc123"), "abc123")
        XCTAssertEqual(TmuxCommands.abbreviatedSessionId("123456789012345"), "123456789012345")
    }

    func testCopyableIdentifierHasNoExactMatchPrefix() {
        // The copied string is retyped by a human/agent, so it stays plain — the
        // `=` exact-match prefix belongs to argv construction, not the clipboard.
        XCTAssertFalse(
            TmuxCommands.copyableIdentifier(for: .window(session: "web", window: 1))
                .hasPrefix("="))
    }

    // MARK: context-menu target resolution (M6 fix b)

    func testContextMenuRowPrefersClickedRow() {
        // Right-clicking an unselected row must target the clicked row, never
        // fall back to the selection (which could Kill a different session).
        XCTAssertEqual(TmuxCommands.contextMenuRow(clickedRow: 3, selectedRow: 0), 3)
    }

    func testContextMenuRowFallsBackToSelectionOnlyWhenClickMissed() {
        XCTAssertEqual(TmuxCommands.contextMenuRow(clickedRow: -1, selectedRow: 2), 2)
    }

    func testContextMenuRowNilWhenNoTarget() {
        XCTAssertNil(TmuxCommands.contextMenuRow(clickedRow: -1, selectedRow: -1))
    }

    // MARK: ⌥-hover preview

    func testHoverPreviewRowIsTheHoveredRowWhileOptionIsHeld() {
        XCTAssertEqual(
            TmuxCommands.hoverPreviewRow(optionOnly: true, hoveredRow: 4, selectedRow: 1), 4)
    }

    func testHoverPreviewRowNilWithoutOption() {
        // A plain hover, or ⌥ with another modifier (⌥⌘ shortcuts), previews nothing.
        XCTAssertNil(TmuxCommands.hoverPreviewRow(optionOnly: false, hoveredRow: 4, selectedRow: 1))
    }

    func testHoverPreviewRowNilOffARowOrOnTheShownRow() {
        XCTAssertNil(TmuxCommands.hoverPreviewRow(optionOnly: true, hoveredRow: -1, selectedRow: 1))
        // Moving within the row already shown must not re-select it.
        XCTAssertNil(TmuxCommands.hoverPreviewRow(optionOnly: true, hoveredRow: 1, selectedRow: 1))
    }

    // MARK: target id construction (M9)

    func testWindowTarget() {
        // Exact-match session (`=`) so a prefix name can't resolve the wrong window.
        XCTAssertEqual(TmuxCommands.windowTarget(session: "web", window: 1), "=web:1")
        // No shell, so a space in the session name stays embedded verbatim.
        XCTAssertEqual(TmuxCommands.windowTarget(session: "my app", window: 0), "=my app:0")
    }

    func testPaneTarget() {
        XCTAssertEqual(
            TmuxCommands.paneTarget(session: "web", window: 1, pane: "%12"), "=web:1.%12")
    }

    func testSessionSlotTarget() {
        // Trailing colon with an empty window part = "next free index"; the `=`
        // stops a merge into "web" from landing in "web-2".
        XCTAssertEqual(TmuxCommands.sessionSlotTarget(session: "web"), "=web:")
        XCTAssertEqual(TmuxCommands.sessionSlotTarget(session: "my app"), "=my app:")
    }

    // MARK: move / merge (sidebar reorganisation)

    func testMoveWindowArgvAppendsByDefault() {
        XCTAssertEqual(
            TmuxCommands.moveWindow(source: "=web:1", target: "=api:"),
            ["move-window", "-s", "=web:1", "-t", "=api:"])
    }

    func testMoveWindowArgvWithKillReplacesDestination() {
        // Only the move-to-new-session path sets `-k`, to overwrite the placeholder
        // window `new-session` had to create.
        XCTAssertEqual(
            TmuxCommands.moveWindow(source: "=web:1", target: "=fresh:0", kill: true),
            ["move-window", "-s", "=web:1", "-t", "=fresh:0", "-k"])
    }

    func testBreakPaneArgv() {
        XCTAssertEqual(
            TmuxCommands.breakPane(source: "=web:1.%12", target: "=api:"),
            ["break-pane", "-s", "=web:1.%12", "-t", "=api:"])
    }

    // MARK: window actions (M9)

    func testKillWindowArgv() {
        XCTAssertEqual(TmuxCommands.killWindow(target: "web:1"), ["kill-window", "-t", "web:1"])
    }

    func testRenameWindowArgv() {
        XCTAssertEqual(
            TmuxCommands.renameWindow(target: "web:1", to: "editor"),
            ["rename-window", "-t", "web:1", "--", "editor"])
        // Spaces in the new name stay a single argv element (no shell).
        XCTAssertEqual(
            TmuxCommands.renameWindow(target: "web:1", to: "my window")[4], "my window")
    }

    func testRestoreWindowLayoutAndSelectionArgv() {
        let layout = "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        XCTAssertEqual(
            TmuxCommands.newWindow(session: "web", cwd: "/repo", atIndex: 4),
            ["new-window", "-d", "-t", "=web:4", "-c", "/repo"])
        XCTAssertEqual(
            TmuxCommands.selectLayout(target: "=web:4", layout: layout),
            ["select-layout", "-t", "=web:4", layout])
        XCTAssertEqual(
            TmuxCommands.selectWindow(target: "=web:4"),
            ["select-window", "-t", "=web:4"])
        XCTAssertEqual(
            TmuxCommands.selectPane(target: "=web:4.1"),
            ["select-pane", "-t", "=web:4.1"])
    }

    func testSetWindowUserOptionArgv() {
        XCTAssertEqual(
            TmuxCommands.setWindowUserOption(target: "web:1", key: "@mm_prs", value: "1082 1085"),
            ["set-window-option", "-t", "web:1", "@mm_prs", "1082 1085"])
    }

    func testSetPaneTitleArgv() {
        XCTAssertEqual(
            TmuxCommands.setPaneTitle(paneId: "%12", to: "build"),
            ["select-pane", "-t", "%12", "-T", "build"])
        // Spaces in the title stay a single argv element (no shell).
        XCTAssertEqual(
            TmuxCommands.setPaneTitle(paneId: "%12", to: "dev server")[4], "dev server")
    }

    func testNewWindowArgvWithCwd() {
        XCTAssertEqual(
            TmuxCommands.newWindow(session: "web", cwd: "/Users/me/code/api"),
            ["new-window", "-a", "-t", "web:", "-c", "/Users/me/code/api"])
    }

    func testNewWindowArgvOmitsCwdWhenNil() {
        XCTAssertEqual(
            TmuxCommands.newWindow(session: "web", cwd: nil), ["new-window", "-a", "-t", "web:"])
        // An empty cwd is treated the same as nil — no dangling -c.
        XCTAssertEqual(
            TmuxCommands.newWindow(session: "web", cwd: ""), ["new-window", "-a", "-t", "web:"])
    }

    // MARK: pane actions (M9)

    func testKillPaneArgv() {
        XCTAssertEqual(
            TmuxCommands.killPane(target: "web:1.%12"), ["kill-pane", "-t", "web:1.%12"])
    }

    func testSplitWindowHorizontalArgv() {
        // Horizontal split = side by side = tmux `-h`.
        XCTAssertEqual(
            TmuxCommands.splitWindow(target: "web:1.%12", vertical: false),
            ["split-window", "-h", "-t", "web:1.%12"])
    }

    func testSplitWindowVerticalArgv() {
        // Vertical split = stacked = tmux `-v`.
        XCTAssertEqual(
            TmuxCommands.splitWindow(target: "web:1.%12", vertical: true),
            ["split-window", "-v", "-t", "web:1.%12"])
    }

    func testSplitWindowWithCwdAppendsDashC() {
        // A cwd opens the new pane beside the split pane, not in the session's
        // (often ~) start dir.
        XCTAssertEqual(
            TmuxCommands.splitWindow(target: "web:1.%12", vertical: false, cwd: "/Users/me/code/api"),
            ["split-window", "-h", "-t", "web:1.%12", "-c", "/Users/me/code/api"])
    }

    func testSplitWindowEmptyCwdOmitsDashC() {
        XCTAssertEqual(
            TmuxCommands.splitWindow(target: "web:1.%12", vertical: true, cwd: ""),
            ["split-window", "-v", "-t", "web:1.%12"])
    }

    // MARK: Drag-to-rearrange (swap-pane / join-pane)

    func testSwapPaneArgv() {
        XCTAssertEqual(
            TmuxCommands.swapPane(source: "%12", target: "%13"),
            ["swap-pane", "-s", "%12", "-t", "%13"])
    }

    func testJoinPaneArgvForEachEdge() {
        // right: -h, no -b (trailing side).
        XCTAssertEqual(
            TmuxCommands.joinPane(source: "%12", target: "%13", horizontal: true, before: false),
            ["join-pane", "-s", "%12", "-t", "%13", "-h"])
        // left: -h -b (leading side).
        XCTAssertEqual(
            TmuxCommands.joinPane(source: "%12", target: "%13", horizontal: true, before: true),
            ["join-pane", "-s", "%12", "-t", "%13", "-h", "-b"])
        // bottom: -v, no -b.
        XCTAssertEqual(
            TmuxCommands.joinPane(source: "%12", target: "%13", horizontal: false, before: false),
            ["join-pane", "-s", "%12", "-t", "%13", "-v"])
        // top: -v -b.
        XCTAssertEqual(
            TmuxCommands.joinPane(source: "%12", target: "%13", horizontal: false, before: true),
            ["join-pane", "-s", "%12", "-t", "%13", "-v", "-b"])
    }

    // MARK: name sanitation

    func testSanitizedSessionNameTrims() {
        XCTAssertEqual(TmuxCommands.sanitizedSessionName("  api  "), "api")
    }

    func testSanitizedSessionNameRejectsEmpty() {
        XCTAssertNil(TmuxCommands.sanitizedSessionName(""))
        XCTAssertNil(TmuxCommands.sanitizedSessionName("   "))
        XCTAssertNil(TmuxCommands.sanitizedSessionName("\n\t"))
    }

    func testSanitizedSessionNameReplacesTargetSeparators() {
        // `.` and `:` are tmux target separators; they must be neutralized so
        // they don't break `session:window.pane` addressing.
        XCTAssertEqual(TmuxCommands.sanitizedSessionName("a.b:c"), "a_b_c")
    }

    func testSanitizedSessionNameKeepsSpaces() {
        // Spaces are fine in tmux names (we never word-split), so keep them.
        XCTAssertEqual(TmuxCommands.sanitizedSessionName("my project"), "my project")
    }

    func testUniqueSessionNamePassesThroughWhenFree() {
        XCTAssertEqual(TmuxCommands.uniqueSessionName("api", existing: ["web", "db"]), "api")
        XCTAssertEqual(TmuxCommands.uniqueSessionName("api", existing: []), "api")
    }

    func testUniqueSessionNameSuffixesOnCollision() {
        XCTAssertEqual(TmuxCommands.uniqueSessionName("api", existing: ["api"]), "api-2")
        XCTAssertEqual(
            TmuxCommands.uniqueSessionName("api", existing: ["api", "api-2", "api-3"]), "api-4")
    }

    // MARK: Find in Session (⌘F — copy-mode search)

    func testCopyModeArgv() {
        XCTAssertEqual(TmuxCommands.copyMode(target: "api"), ["copy-mode", "-t", "api"])
    }

    func testExitCopyModeArgv() {
        XCTAssertEqual(
            TmuxCommands.exitCopyMode(target: "api"),
            ["send-keys", "-t", "api", "-X", "cancel"])
    }

    func testSearchBackwardIsLiteralTextVariant() {
        // `-text` keeps the search literal, and the needle rides as its own argv
        // element — regex/shell metacharacters must arrive untouched.
        XCTAssertEqual(
            TmuxCommands.searchBackward(target: "api", text: "err.*[foo] $HOME"),
            ["send-keys", "-t", "api", "-X", "search-backward-text", "err.*[foo] $HOME"])
    }

    func testSearchStepUpIsAgainDownIsReverse() {
        // The find bar only ever starts with search-backward, so tmux's stored
        // direction is always up: again == older, reverse == newer.
        XCTAssertEqual(
            TmuxCommands.searchStep(target: "api", up: true),
            ["send-keys", "-t", "api", "-X", "search-again"])
        XCTAssertEqual(
            TmuxCommands.searchStep(target: "api", up: false),
            ["send-keys", "-t", "api", "-X", "search-reverse"])
    }

    func testSearchCountArgv() {
        XCTAssertEqual(
            TmuxCommands.searchCount(target: "api"),
            ["display-message", "-p", "-t", "api", "#{search_count}\t#{search_count_partial}"])
    }

    func testSearchCountLabelFormats() {
        XCTAssertEqual(TmuxCommands.searchCountLabel("14\t0\n"), "14 matches")
        XCTAssertEqual(TmuxCommands.searchCountLabel("1\t0"), "1 match")
        XCTAssertEqual(TmuxCommands.searchCountLabel("0\t0"), "no matches")
        // A partial count means tmux stopped counting early — surface the "+".
        XCTAssertEqual(TmuxCommands.searchCountLabel("100\t1"), "100+ matches")
    }

    func testSearchCountLabelNilOnFailureOrNoSearch() {
        XCTAssertNil(TmuxCommands.searchCountLabel(nil))
        XCTAssertNil(TmuxCommands.searchCountLabel(""))
        XCTAssertNil(TmuxCommands.searchCountLabel("\t"))
    }
    // MARK: - Reporting what a creation made (⌘N / + buttons focus the new thing)

    func testNewWindowPrintsItsIndexOnlyWhenAsked() {
        XCTAssertEqual(
            TmuxCommands.newWindow(session: "web", cwd: nil, printIndex: true),
            ["new-window", "-a", "-t", "web:", "-P", "-F", "#{window_index}"])
        XCTAssertFalse(TmuxCommands.newWindow(session: "web", cwd: nil).contains("-P"),
                       "the bulk session-recovery rebuild has no use for the echo")
    }

    func testNewWindowPrintsWindowAndPaneForHandoff() {
        XCTAssertEqual(
            TmuxCommands.newWindow(session: "web", cwd: "/repo", printTarget: true),
            ["new-window", "-a", "-t", "web:", "-P", "-F", "#{window_index}\t#{pane_id}",
             "-c", "/repo"])
    }

    func testStartAgentTypesTheLaunchCommand() {
        XCTAssertEqual(
            TmuxCommands.startAgent(target: "%7", command: AgentHandoff.Agent.claude.launchCommand),
            ["send-keys", "-t", "%7", "claude", "Enter"])
        XCTAssertEqual(AgentHandoff.Agent.codex.launchCommand, "codex")
    }

    func testHandoffPasteIsBracketedSoNewlinesDoNotSubmit() {
        XCTAssertEqual(
            TmuxCommands.pasteHandoff(target: "%7", buffer: "b").paste,
            ["paste-buffer", "-p", "-d", "-b", "b", "-t", "%7"])
    }

    func testPromptPasteIsBracketedAndKeepsNewlines() {
        let paste = TmuxCommands.pastePrompt(session: "mux-manager")
        XCTAssertEqual(paste.load, ["load-buffer", "-b", "sidekick", "-"])
        // -p: one bracketed paste, so no byte is a key press. -r: a newline
        // stays a newline and is not turned into Enter.
        XCTAssertEqual(
            paste.paste, ["paste-buffer", "-p", "-r", "-d", "-b", "sidekick", "-t", "mux-manager"])
        // A dropped file's path is pasted as before.
        XCTAssertEqual(
            TmuxCommands.pastePath(session: "web").paste,
            ["paste-buffer", "-d", "-b", "sidekick", "-t", "web"])
    }

    func testClearInputDeletesEachLineAndPressesNoEnter() {
        XCTAssertEqual(
            TmuxCommands.clearInput(target: "mux-manager", lines: 1),
            ["send-keys", "-t", "mux-manager", "C-u"])
        XCTAssertEqual(
            TmuxCommands.clearInput(target: "mux-manager", lines: 3),
            ["send-keys", "-t", "mux-manager", "C-u", "C-u", "C-u"])
        XCTAssertEqual(TmuxCommands.clearInput(target: "t", lines: 0).count, 4)
        XCTAssertEqual(TmuxCommands.clearInput(target: "t", lines: 5000).count, 3 + 64)
        XCTAssertFalse(TmuxCommands.clearInput(target: "t", lines: 3).contains("Enter"))
    }

    func testAgentStartedOnceThePaneLeavesItsShell() {
        XCTAssertFalse(AgentHandoff.agentStarted(command: "zsh", shell: "zsh"))
        XCTAssertFalse(AgentHandoff.agentStarted(command: "", shell: "zsh"))
        XCTAssertTrue(AgentHandoff.agentStarted(command: "claude", shell: "zsh"))
        XCTAssertTrue(AgentHandoff.agentStarted(command: "node", shell: "zsh"))
    }

    func testSplitWindowPrintsWindowAndPaneOnlyWhenAsked() {
        XCTAssertEqual(
            TmuxCommands.splitWindow(target: "web:1.%12", vertical: false, printTarget: true),
            ["split-window", "-h", "-t", "web:1.%12", "-P", "-F", "#{window_index}\t#{pane_id}"])
        XCTAssertFalse(
            TmuxCommands.splitWindow(target: "web:1.%12", vertical: false).contains("-P"))
    }

    func testParseCreatedWindow() {
        XCTAssertEqual(TmuxCommands.parseCreatedWindow("3\n"), 3)
        XCTAssertNil(TmuxCommands.parseCreatedWindow(nil))
        XCTAssertNil(TmuxCommands.parseCreatedWindow(""))
        XCTAssertNil(TmuxCommands.parseCreatedWindow("no such session"))
    }

    func testParseCreatedPane() {
        XCTAssertEqual(
            TmuxCommands.parseCreatedPane("2\t%40\n"),
            TmuxCommands.CreatedPane(window: 2, pane: "%40"))
        XCTAssertNil(TmuxCommands.parseCreatedPane(nil))
        XCTAssertNil(TmuxCommands.parseCreatedPane("%40"), "half an answer is not an answer")
        XCTAssertNil(TmuxCommands.parseCreatedPane("x\t%40"))
    }

}
