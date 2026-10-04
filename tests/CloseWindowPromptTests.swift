import XCTest

// CloseWindowPrompt.swift is Foundation-only and compiled into this test target,
// so the ⌘W confirmation copy is asserted here without standing up AppKit.

final class CloseWindowPromptTests: XCTestCase {

    // MARK: title

    func testTitleNamesWindowIndexNameAndSession() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "watch PR #393 #394 CI")
        XCTAssertEqual(
            CloseWindowPrompt.title(t, .window),
            "Archive window 17 “watch PR #393 #394 CI” in “dev”?")
    }

    func testTitleDropsQuotedNameWhenWindowIsUnnamed() {
        let t = CloseWindowPrompt.Target(session: "dev", index: 3, name: "")
        XCTAssertEqual(CloseWindowPrompt.title(t, .window), "Archive window 3 in “dev”?")
    }

    func testTitleTreatsWhitespaceOnlyNameAsUnnamed() {
        let t = CloseWindowPrompt.Target(session: "pulso", index: 0, name: "   ")
        XCTAssertEqual(CloseWindowPrompt.title(t, .window), "Archive window 0 in “pulso”?")
    }

    func testTitleFallsBackToActiveWindowWhenIndexIsUnknown() {
        let t = CloseWindowPrompt.Target(session: "dev", index: nil, name: "")
        XCTAssertEqual(
            CloseWindowPrompt.title(t, .window), "Archive the active window in “dev”?")
    }

    func testTitleKeepsSessionNamesWithSpaces() {
        let t = CloseWindowPrompt.Target(
            session: "Front Range Windows", index: 2, name: "zsh")
        XCTAssertEqual(
            CloseWindowPrompt.title(t, .window),
            "Archive window 2 “zsh” in “Front Range Windows”?")
    }

    // MARK: info

    func testInfoForIdleWindowIsJustTheConsequence() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 1, name: "zsh", attention: .idle)
        XCTAssertEqual(
            CloseWindowPrompt.info(t, .window),
            "This ends the tmux window and every process in it.")
    }

    func testInfoForUnknownAttentionMatchesIdle() {
        let idle = CloseWindowPrompt.Target(
            session: "s", index: 1, name: "w", attention: .idle)
        let unknown = CloseWindowPrompt.Target(
            session: "s", index: 1, name: "w", attention: .unknown)
        XCTAssertEqual(
            CloseWindowPrompt.info(idle, .window),
            CloseWindowPrompt.info(unknown, .window))
    }

    func testInfoWarnsWhenAnAgentIsRunning() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 4, name: "claude", attention: .busy)
        XCTAssertTrue(CloseWindowPrompt.info(t, .window).contains("An agent is running here"))
        XCTAssertFalse(CloseWindowPrompt.info(t, .window).contains("waiting on you"))
    }

    func testInfoWarnsWhenAnAgentIsWaitingOnYou() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 4, name: "claude", attention: .waiting)
        XCTAssertTrue(CloseWindowPrompt.info(t, .window).contains("waiting on you"))
        XCTAssertFalse(CloseWindowPrompt.info(t, .window).contains("An agent is running here"))
    }

    func testInfoSaysTheSessionEndsOnTheLastWindow() {
        let t = CloseWindowPrompt.Target(
            session: "cdgh", index: 0, name: "zsh", isLastWindow: true)
        XCTAssertTrue(
            CloseWindowPrompt.info(t, .window).contains("the session “cdgh” ends too"))
    }

    func testInfoOmitsSessionEndsWhenOtherWindowsRemain() {
        let t = CloseWindowPrompt.Target(
            session: "cdgh", index: 0, name: "zsh", isLastWindow: false)
        XCTAssertFalse(CloseWindowPrompt.info(t, .window).contains("ends too"))
    }

    func testInfoStacksAgentWarningAndSessionEnd() {
        let t = CloseWindowPrompt.Target(
            session: "pulso", index: 0, name: "claude",
            attention: .busy, isLastWindow: true)
        let info = CloseWindowPrompt.info(t, .window)
        XCTAssertEqual(
            info,
            "This ends the tmux window and every process in it. "
                + "An agent is running here — archiving the window stops that work. "
                + "It is the last window, so the session “pulso” ends too.")
    }

    // MARK: needsConfirm — who asked for the close

    /// Picking Kill/Close from the sidebar's right-click menu is already the
    /// deliberate second step, so a sheet after it is a double confirm.
    func testContextMenuCloseNeverConfirms() {
        XCTAssertFalse(CloseWindowPrompt.needsConfirm(.contextMenu))
    }

    /// The trash on a window whose PR merged: the work landed, so no sheet.
    func testMergedTrashNeverConfirms() {
        XCTAssertFalse(CloseWindowPrompt.needsConfirm(.mergedTrash))
    }

    /// ⌘W is one keystroke away from typing, so it keeps the sheet (Return confirms).
    func testKeyboardCloseConfirms() {
        XCTAssertTrue(CloseWindowPrompt.needsConfirm(.keyboard))
    }

    // MARK: button

    func testConfirmButtonTitleIsTheAction() {
        XCTAssertEqual(CloseWindowPrompt.confirmTitle(.window), "Archive Window")
    }

    // MARK: action — ⌘W closes the pane, not the whole window

    /// The reported bug: ⌘W inside one pane of a multi-pane window killed the
    /// window and every pane in it.
    func testActionClosesTheFocusedPaneWhenTheWindowHasSeveral() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents",
            panes: [
                CloseWindowPrompt.Pane(id: "%12", active: false),
                CloseWindowPrompt.Pane(id: "%13", active: true),
                CloseWindowPrompt.Pane(id: "%14", active: false),
            ])
        XCTAssertEqual(CloseWindowPrompt.action(for: t), .pane(id: "%13"))
    }

    func testActionClosesTheWindowWhenItHasASinglePane() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents",
            panes: [CloseWindowPrompt.Pane(id: "%12", active: true)])
        XCTAssertEqual(CloseWindowPrompt.action(for: t), .window)
    }

    /// No panes means the sidebar tree hasn't loaded the session, so there is no
    /// pane id to target — fall back to the window rather than guessing.
    func testActionClosesTheWindowWhenPanesArentLoaded() {
        let t = CloseWindowPrompt.Target(session: "dev", index: nil, name: "")
        XCTAssertEqual(CloseWindowPrompt.action(for: t), .window)
    }

    /// tmux always marks one pane active; if a poll ever reports none, close the
    /// first rather than escalating to the whole window.
    func testActionFallsBackToTheFirstPaneWhenNoneIsMarkedActive() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents",
            panes: [
                CloseWindowPrompt.Pane(id: "%12", active: false),
                CloseWindowPrompt.Pane(id: "%13", active: false),
            ])
        XCTAssertEqual(CloseWindowPrompt.action(for: t), .pane(id: "%12"))
    }

    // MARK: pane copy

    func testPaneTitleNamesThePaneItsWindowAndSession() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents",
            panes: [
                CloseWindowPrompt.Pane(id: "%12", active: false),
                CloseWindowPrompt.Pane(id: "%13", active: true),
            ])
        XCTAssertEqual(
            CloseWindowPrompt.title(t, .pane(id: "%13")),
            "Close pane %13 of window 17 “agents” in “dev”?")
    }

    func testPaneTitleDropsQuotedNameWhenWindowIsUnnamed() {
        let t = CloseWindowPrompt.Target(session: "dev", index: 3, name: "  ")
        XCTAssertEqual(
            CloseWindowPrompt.title(t, .pane(id: "%9")),
            "Close pane %9 of window 3 in “dev”?")
    }

    func testPaneInfoSaysTheRestOfTheWindowSurvives() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents",
            panes: [
                CloseWindowPrompt.Pane(id: "%12", active: false),
                CloseWindowPrompt.Pane(id: "%13", active: true),
                CloseWindowPrompt.Pane(id: "%14", active: false),
            ])
        XCTAssertEqual(
            CloseWindowPrompt.info(t, .pane(id: "%13")),
            "This kills the pane and the process running in it. "
                + "The window’s other 2 panes keep running.")
    }

    func testPaneInfoSingularizesTheSurvivingPane() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents",
            panes: [
                CloseWindowPrompt.Pane(id: "%12", active: false),
                CloseWindowPrompt.Pane(id: "%13", active: true),
            ])
        XCTAssertTrue(
            CloseWindowPrompt.info(t, .pane(id: "%13"))
                .contains("The window’s other pane keeps running."))
    }

    /// The warning follows the pane being closed, not the window's rollup — the
    /// busy pane next door must not make a quiet pane read as busy.
    func testPaneInfoWarnsOnlyAboutThePaneBeingClosed() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents", attention: .busy,
            panes: [
                CloseWindowPrompt.Pane(id: "%12", active: false, attention: .busy),
                CloseWindowPrompt.Pane(id: "%13", active: true, attention: .idle),
            ])
        XCTAssertFalse(
            CloseWindowPrompt.info(t, .pane(id: "%13")).contains("An agent is running"))
        XCTAssertTrue(
            CloseWindowPrompt.info(t, .pane(id: "%12")).contains("An agent is running here"))
    }

    func testPaneInfoWarnsWhenThePaneIsWaitingOnYou() {
        let t = CloseWindowPrompt.Target(
            session: "dev", index: 17, name: "agents",
            panes: [
                CloseWindowPrompt.Pane(id: "%12", active: false),
                CloseWindowPrompt.Pane(id: "%13", active: true, attention: .waiting),
            ])
        XCTAssertTrue(
            CloseWindowPrompt.info(t, .pane(id: "%13")).contains("waiting on you"))
    }

    /// A pane close never ends the session, so the window/session escalation must
    /// not leak into it even on a session's last window.
    func testPaneInfoNeverSaysTheSessionEnds() {
        let t = CloseWindowPrompt.Target(
            session: "cdgh", index: 0, name: "zsh", isLastWindow: true,
            panes: [
                CloseWindowPrompt.Pane(id: "%1", active: true),
                CloseWindowPrompt.Pane(id: "%2", active: false),
            ])
        XCTAssertFalse(CloseWindowPrompt.info(t, .pane(id: "%1")).contains("ends too"))
    }

    func testPaneConfirmButtonTitleIsTheAction() {
        XCTAssertEqual(CloseWindowPrompt.confirmTitle(.pane(id: "%13")), "Close Pane")
    }
}
