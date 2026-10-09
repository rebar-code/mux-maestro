import XCTest

// Settings.swift compiles into this test target; the get/set/default/clamp logic
// is asserted against a throwaway UserDefaults suite so nothing touches the
// shared store.
final class SettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func host(_ name: String) -> Host { Host(name: name, sshAlias: name) }

    func testPhoneArtifactFoldersStartEmptyAndRoundTrip() {
        XCTAssertEqual(Settings.phoneArtifactFolders(defaults: defaults), [])
        Settings.setPhoneArtifactFolders(" ~/reports, /srv/notes ", defaults: defaults)
        XCTAssertEqual(
            Settings.phoneArtifactFolders(defaults: defaults), [NSHomeDirectory() + "/reports", "/srv/notes"])
        Settings.setPhoneArtifactFolders("not a path", defaults: defaults)
        XCTAssertEqual(Settings.phoneArtifactFolders(defaults: defaults), [])
    }

    // MARK: watch

    func testSortByRecentIsPerSessionAndClearedWithTheHost() {
        let a = host("a")
        XCTAssertFalse(Settings.sortsByRecent(session: "work", host: a, defaults: defaults))
        Settings.setSortsByRecent(true, session: "work", host: a, defaults: defaults)
        XCTAssertTrue(Settings.sortsByRecent(session: "work", host: a, defaults: defaults))
        XCTAssertFalse(Settings.sortsByRecent(session: "play", host: a, defaults: defaults))
        XCTAssertFalse(Settings.sortsByRecent(session: "work", host: host("b"), defaults: defaults))
        Settings.setSortsByRecent(false, session: "work", host: a, defaults: defaults)
        XCTAssertFalse(Settings.sortsByRecent(session: "work", host: a, defaults: defaults))
        Settings.setSortsByRecent(true, session: "work", host: a, defaults: defaults)
        Settings.clearHost(a, defaults: defaults)
        XCTAssertFalse(Settings.sortsByRecent(session: "work", host: a, defaults: defaults))
    }

    func testManagerRailLayoutDefaultsToStacked() {
        XCTAssertFalse(Settings.managerRailSideBySide(defaults: defaults))
        Settings.setManagerRailSideBySide(true, defaults: defaults)
        XCTAssertTrue(Settings.managerRailSideBySide(defaults: defaults))
    }

    func testManagerRailListDefaultsToTheBoard() {
        XCTAssertFalse(Settings.managerRailShowsRequests(defaults: defaults))
        Settings.setManagerRailShowsRequests(true, defaults: defaults)
        XCTAssertTrue(Settings.managerRailShowsRequests(defaults: defaults))
    }

    func testManagerRailListSizeIsKeptPerLayout() {
        XCTAssertNil(Settings.managerRailListSize(sideBySide: false, defaults: defaults))
        Settings.setManagerRailListSize(420, sideBySide: false, defaults: defaults)
        XCTAssertEqual(Settings.managerRailListSize(sideBySide: false, defaults: defaults), 420)
        XCTAssertNil(Settings.managerRailListSize(sideBySide: true, defaults: defaults),
                     "a stacked height is not a side-by-side width")
    }

    func testRecoveryAutoResumeDefaultsOffAndRoundTrips() {
        XCTAssertFalse(Settings.sessionRecoveryAutoResumeAgents(defaults: defaults))
        Settings.setSessionRecoveryAutoResumeAgents(true, defaults: defaults)
        XCTAssertTrue(Settings.sessionRecoveryAutoResumeAgents(defaults: defaults))
        Settings.setSessionRecoveryAutoResumeAgents(false, defaults: defaults)
        XCTAssertFalse(Settings.sessionRecoveryAutoResumeAgents(defaults: defaults))
    }

    func testHostExpandedDefaultsCollapsedRoundTripsAndClearsWithTheHost() {
        let a = host("a")
        XCTAssertFalse(Settings.hostExpanded(a, defaults: defaults))
        XCTAssertFalse(Settings.hostExpanded(.local, defaults: defaults))
        Settings.setHostExpanded(true, host: a, defaults: defaults)
        XCTAssertTrue(Settings.hostExpanded(a, defaults: defaults))
        XCTAssertFalse(Settings.hostExpanded(host("b"), defaults: defaults), "keyed per host")
        Settings.setHostExpanded(false, host: a, defaults: defaults)
        XCTAssertFalse(Settings.hostExpanded(a, defaults: defaults))
        Settings.setHostExpanded(true, host: a, defaults: defaults)
        Settings.clearHost(a, defaults: defaults)
        XCTAssertFalse(Settings.hostExpanded(a, defaults: defaults))
    }

    func testWatchDefaultsOffForRemote() {
        XCTAssertFalse(Settings.watch(host: host("box"), defaults: defaults))
    }

    func testWatchRoundTrips() {
        Settings.setWatch(true, host: host("box"), defaults: defaults)
        XCTAssertTrue(Settings.watch(host: host("box"), defaults: defaults))
        Settings.setWatch(false, host: host("box"), defaults: defaults)
        XCTAssertFalse(Settings.watch(host: host("box"), defaults: defaults))
    }

    func testWatchIsKeyedPerHost() {
        Settings.setWatch(true, host: host("a"), defaults: defaults)
        XCTAssertTrue(Settings.watch(host: host("a"), defaults: defaults))
        XCTAssertFalse(Settings.watch(host: host("b"), defaults: defaults))
    }

    func testLocalHostIsAlwaysWatched() {
        // Local always polls regardless of any stored value.
        XCTAssertTrue(Settings.watch(host: .local, defaults: defaults))
        Settings.setWatch(false, host: .local, defaults: defaults)
        XCTAssertTrue(Settings.watch(host: .local, defaults: defaults))
    }

    // MARK: useMosh

    func testUseMoshDefaultsOffForRemote() {
        XCTAssertFalse(Settings.useMosh(host: host("box"), defaults: defaults))
    }

    func testUseMoshRoundTrips() {
        Settings.setUseMosh(true, host: host("box"), defaults: defaults)
        XCTAssertTrue(Settings.useMosh(host: host("box"), defaults: defaults))
    }

    func testLocalHostNeverUsesMosh() {
        Settings.setUseMosh(true, host: .local, defaults: defaults)
        XCTAssertFalse(Settings.useMosh(host: .local, defaults: defaults))
    }

    // MARK: sessionOrder

    func testSessionOrderDefaultsEmpty() {
        XCTAssertEqual(Settings.sessionOrder(host: host("box"), defaults: defaults), [])
    }

    func testSessionOrderRoundTrips() {
        Settings.setSessionOrder(["b", "a", "c"], host: host("box"), defaults: defaults)
        XCTAssertEqual(
            Settings.sessionOrder(host: host("box"), defaults: defaults), ["b", "a", "c"])
    }

    func testSessionOrderIsKeyedPerHost() {
        Settings.setSessionOrder(["x"], host: host("a"), defaults: defaults)
        XCTAssertEqual(Settings.sessionOrder(host: host("a"), defaults: defaults), ["x"])
        XCTAssertEqual(Settings.sessionOrder(host: host("b"), defaults: defaults), [])
    }

    // MARK: pinnedDirs

    func testPinnedDirsDefaultsEmpty() {
        XCTAssertEqual(Settings.pinnedDirs(defaults: defaults), [])
        XCTAssertFalse(Settings.isPinnedDir("/a", defaults: defaults))
    }

    func testPinAppendsInPinOrder() {
        Settings.setPinnedDir(true, path: "/b", defaults: defaults)
        Settings.setPinnedDir(true, path: "/a", defaults: defaults)
        XCTAssertEqual(Settings.pinnedDirs(defaults: defaults), ["/b", "/a"])
        XCTAssertTrue(Settings.isPinnedDir("/a", defaults: defaults))
    }

    func testPinIsIdempotentAndKeepsPosition() {
        Settings.setPinnedDir(true, path: "/a", defaults: defaults)
        Settings.setPinnedDir(true, path: "/b", defaults: defaults)
        Settings.setPinnedDir(true, path: "/a", defaults: defaults)
        XCTAssertEqual(Settings.pinnedDirs(defaults: defaults), ["/a", "/b"])
    }

    func testUnpinRemovesOnlyThatPath() {
        Settings.setPinnedDir(true, path: "/a", defaults: defaults)
        Settings.setPinnedDir(true, path: "/b", defaults: defaults)
        Settings.setPinnedDir(false, path: "/a", defaults: defaults)
        XCTAssertEqual(Settings.pinnedDirs(defaults: defaults), ["/b"])
        XCTAssertFalse(Settings.isPinnedDir("/a", defaults: defaults))
    }

    func testUnpinUnknownPathIsHarmless() {
        Settings.setPinnedDir(true, path: "/a", defaults: defaults)
        Settings.setPinnedDir(false, path: "/nope", defaults: defaults)
        XCTAssertEqual(Settings.pinnedDirs(defaults: defaults), ["/a"])
    }

    func testEmptyPathIsNeverPinned() {
        // The "(no directory)" bucket is not a project.
        Settings.setPinnedDir(true, path: "", defaults: defaults)
        XCTAssertEqual(Settings.pinnedDirs(defaults: defaults), [])
    }

    // MARK: pollInterval

    func testPollIntervalDefault() {
        XCTAssertEqual(Settings.pollInterval(defaults: defaults), Settings.pollDefault, accuracy: 0.0001)
    }

    func testPollIntervalRoundTrips() {
        Settings.setPollInterval(3.0, defaults: defaults)
        XCTAssertEqual(Settings.pollInterval(defaults: defaults), 3.0, accuracy: 0.0001)
    }

    func testPollIntervalClampsToFloor() {
        Settings.setPollInterval(0.0, defaults: defaults)
        XCTAssertEqual(Settings.pollInterval(defaults: defaults), Settings.pollFloor, accuracy: 0.0001)
        Settings.setPollInterval(-5.0, defaults: defaults)
        XCTAssertEqual(Settings.pollInterval(defaults: defaults), Settings.pollFloor, accuracy: 0.0001)
    }

    // MARK: per-host color

    func testColorDefaultsToDerivedHueWhenUnset() {
        // No stored value → the name-derived palette pick, so a freshly added
        // server is already distinguishable with zero setup.
        let h = host("buildbox1")
        XCTAssertEqual(Settings.colorHex(host: h, defaults: defaults),
                       HostColor.defaultHex(for: "buildbox1"))
        XCTAssertFalse(Settings.hasCustomColor(host: h, defaults: defaults))
    }

    func testSetColorOverridesDerivedDefault() {
        let h = host("devbox1")
        Settings.setColorHex("#123456", host: h, defaults: defaults)
        XCTAssertEqual(Settings.colorHex(host: h, defaults: defaults), "#123456")
        XCTAssertTrue(Settings.hasCustomColor(host: h, defaults: defaults))
    }

    func testResetColorFallsBackToDerivedDefault() {
        let h = host("host3")
        Settings.setColorHex("#123456", host: h, defaults: defaults)
        Settings.setColorHex(nil, host: h, defaults: defaults)
        XCTAssertEqual(Settings.colorHex(host: h, defaults: defaults),
                       HostColor.defaultHex(for: "host3"))
        XCTAssertFalse(Settings.hasCustomColor(host: h, defaults: defaults))
    }

    func testColorIsPerHostNotShared() {
        Settings.setColorHex("#aaaaaa", host: host("a"), defaults: defaults)
        Settings.setColorHex("#bbbbbb", host: host("b"), defaults: defaults)
        XCTAssertEqual(Settings.colorHex(host: host("a"), defaults: defaults), "#aaaaaa")
        XCTAssertEqual(Settings.colorHex(host: host("b"), defaults: defaults), "#bbbbbb")
    }

    func testRunningDrawerDefaultsClosedAndRoundTrips() {
        XCTAssertFalse(Settings.runningDrawerExpanded(defaults: defaults))
        Settings.setRunningDrawerExpanded(true, defaults: defaults)
        XCTAssertTrue(Settings.runningDrawerExpanded(defaults: defaults))
    }

    // MARK: phone

    func testPhoneIsOffWithEveryFeatureOffByDefault() {
        XCTAssertFalse(Settings.phoneEnabled(defaults: defaults))
        XCTAssertFalse(Settings.phoneKeepAwake(defaults: defaults))
        XCTAssertEqual(Settings.phonePort(defaults: defaults), Settings.phonePortDefault)
        XCTAssertEqual(Settings.phoneGrouping(defaults: defaults), .recent)
        XCTAssertEqual(Settings.phoneConfig(defaults: defaults), MobileConfig())
        for capability in MobileCapability.allCases {
            XCTAssertFalse(Settings.phoneCapability(capability, defaults: defaults))
        }
    }

    func testPhoneSettingsRoundTripIntoTheServerConfig() {
        Settings.setPhoneEnabled(true, defaults: defaults)
        Settings.setPhoneKeepAwake(true, defaults: defaults)
        Settings.setPhonePort(8123, defaults: defaults)
        Settings.setPhoneGrouping(.directory, defaults: defaults)
        Settings.setPhoneCapability(.replies, true, defaults: defaults)
        XCTAssertTrue(Settings.phoneEnabled(defaults: defaults))
        XCTAssertTrue(Settings.phoneKeepAwake(defaults: defaults))
        XCTAssertEqual(Settings.phonePort(defaults: defaults), 8123)
        XCTAssertEqual(
            Settings.phoneConfig(defaults: defaults),
            MobileConfig(capabilities: [.replies], grouping: .directory))
        Settings.setPhoneCapability(.replies, false, defaults: defaults)
        XCTAssertEqual(Settings.phoneConfig(defaults: defaults).capabilities, [])
    }

    func testAnUnusablePhonePortReadsAsTheDefault() {
        for port in [0, 80, 70000] {
            Settings.setPhonePort(port, defaults: defaults)
            XCTAssertEqual(Settings.phonePort(defaults: defaults), Settings.phonePortDefault)
        }
    }

    func testTheMaestroIsClaudeWithTheDefaultModelUntilSet() {
        XCTAssertEqual(Settings.maestroAgent(defaults: defaults), .claude)
        XCTAssertEqual(Settings.maestroModel(.claude, defaults: defaults), "")
        defaults.set("gemini", forKey: "maestro.agent")
        XCTAssertEqual(Settings.maestroAgent(defaults: defaults), .claude)
    }

    func testTheMaestroIsNeverClearedUntilAThresholdIsSet() {
        XCTAssertEqual(Settings.maestroResetAfterIdleMinutes(defaults: defaults), 0)
        XCTAssertEqual(Settings.maestroResetAboveTokens(defaults: defaults), 0)
        XCTAssertEqual(
            ManagerResetPolicy(
                idleSeconds: Settings.maestroResetAfterIdleMinutes(defaults: defaults) * 60,
                contextTokens: Settings.maestroResetAboveTokens(defaults: defaults)),
            ManagerResetPolicy(idleSeconds: 0, contextTokens: 0))
    }

    func testTheMaestroResetThresholdsReadZeroAsOff() {
        Settings.setMaestroResetAfterIdleMinutes(5, defaults: defaults)
        Settings.setMaestroResetAboveTokens(120_000, defaults: defaults)
        XCTAssertEqual(Settings.maestroResetAfterIdleMinutes(defaults: defaults), 5)
        XCTAssertEqual(Settings.maestroResetAboveTokens(defaults: defaults), 120_000)
        // 0 is a value, not "unset": it turns the rule off.
        Settings.setMaestroResetAfterIdleMinutes(0, defaults: defaults)
        Settings.setMaestroResetAboveTokens(0, defaults: defaults)
        XCTAssertEqual(Settings.maestroResetAfterIdleMinutes(defaults: defaults), 0)
        XCTAssertEqual(Settings.maestroResetAboveTokens(defaults: defaults), 0)
        Settings.setMaestroResetAfterIdleMinutes(-3, defaults: defaults)
        XCTAssertEqual(Settings.maestroResetAfterIdleMinutes(defaults: defaults), 0)
    }

    func testEachMaestroAgentKeepsItsOwnModel() {
        Settings.setMaestroAgent(.codex, defaults: defaults)
        Settings.setMaestroModel(" gpt-5.5 ", agent: .codex, defaults: defaults)
        Settings.setMaestroModel("opus", agent: .claude, defaults: defaults)
        XCTAssertEqual(Settings.maestroAgent(defaults: defaults), .codex)
        XCTAssertEqual(Settings.maestroModel(.codex, defaults: defaults), "gpt-5.5")
        XCTAssertEqual(Settings.maestroModel(.claude, defaults: defaults), "opus")
    }
}
