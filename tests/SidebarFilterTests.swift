import XCTest

// TmuxModel.swift and Settings.swift are compiled directly into this test target.

final class SidebarFilterTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-01-02 15:00:00 UTC. Midnight of that day is `now - 15 h`.
    private let now = 1_767_366_000
    private var midnight: Int { now - 15 * 3600 }

    private func window(
        _ index: Int, stage: IdleStage = .dozing, activity: Int? = nil
    ) -> TmuxWindow {
        var pane = TmuxPane(id: "%\(index)", index: 0, command: "claude", title: "", active: true)
        pane.attention = .idle
        pane.idleStage = stage
        pane.lastActivityAt = activity
        return TmuxWindow(index: index, name: "w\(index)", active: false, panes: [pane])
    }

    private func session(_ name: String, _ windows: [TmuxWindow]) -> TmuxSession {
        TmuxSession(name: name, attached: false, windows: windows)
    }

    private func shown(_ filter: SidebarFilter, _ window: TmuxWindow) -> Bool {
        window.shows(under: filter, now: now, calendar: utc)
    }

    func testOffShowsASleepingWindow() {
        XCTAssertTrue(shown(.off, window(1)))
    }

    func testEveryModeShowsAWindowThatIsNotAsleep() {
        for filter in SidebarFilter.modes {
            XCTAssertTrue(shown(filter, window(1, stage: .awake)), filter.rawValue)
            XCTAssertTrue(shown(filter, window(1, stage: .yawning)), filter.rawValue)
        }
    }

    func testAWindowWithNoAgentIsNotAsleep() {
        let shell = TmuxWindow(index: 1, name: "zsh", active: true, panes: [
            TmuxPane(id: "%1", index: 0, command: "zsh", title: "", active: true)])
        XCTAssertTrue(shown(.sleepy, shell))
    }

    func testSleepyHidesASleepingWindowHoweverRecent() {
        XCTAssertFalse(shown(.sleepy, window(1, activity: now - 60)))
    }

    func testTwoHoursKeepsASleepingWindowWrittenInTheLastTwoHours() {
        XCTAssertTrue(shown(.twoHours, window(1, activity: now - 7200)))
        XCTAssertFalse(shown(.twoHours, window(1, activity: now - 7201)))
    }

    func testTodayKeepsASleepingWindowWrittenSinceMidnight() {
        XCTAssertTrue(shown(.today, window(1, activity: midnight)))
        XCTAssertFalse(shown(.today, window(1, activity: midnight - 1)))
    }

    func testASleepingWindowWithNoActivityTimeIsHiddenInEveryMode() {
        for filter in SidebarFilter.modes {
            XCTAssertFalse(shown(filter, window(1)), filter.rawValue)
        }
    }

    func testApplyDropsTheHiddenWindowsAndTheSessionsLeftEmpty() {
        let sessions = [
            session("mixed", [window(1, stage: .awake), window(2)]),
            session("asleep", [window(3), window(4)]),
        ]
        let kept = SidebarFilter.sleepy.apply(to: sessions, now: now, calendar: utc)
        XCTAssertEqual(kept.map(\.name), ["mixed"])
        XCTAssertEqual(kept[0].windows.map(\.index), [1])
        XCTAssertEqual(SidebarFilter.off.apply(to: sessions, now: now, calendar: utc), sessions)
    }

    func testApplyKeepsTheWindowItIsToldToKeep() {
        let sessions = [session("asleep", [window(3), window(4)])]
        let kept = SidebarFilter.sleepy.apply(to: sessions, now: now, calendar: utc) {
            $0.name == "asleep" && $1.index == 4
        }
        XCTAssertEqual(kept.map { $0.windows.map(\.index) }, [[4]])
    }

    func testOneClickGivesSleepyFromOffAndOffFromAnyMode() {
        XCTAssertEqual(SidebarFilter.off.toggled, .sleepy)
        for filter in SidebarFilter.modes { XCTAssertEqual(filter.toggled, .off) }
    }

    func testTheSettingIsOffUntilItIsSet() {
        let defaults = UserDefaults(suiteName: "SidebarFilterTests")!
        defaults.removePersistentDomain(forName: "SidebarFilterTests")
        XCTAssertEqual(Settings.sidebarFilter(defaults: defaults), .off)
        Settings.setSidebarFilter(.today, defaults: defaults)
        XCTAssertEqual(Settings.sidebarFilter(defaults: defaults), .today)
        defaults.removePersistentDomain(forName: "SidebarFilterTests")
    }
}
