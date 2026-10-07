import Foundation

/// Per-host + global app settings, stored in `UserDefaults`. There is no other
/// settings framework in the app — this is the single typed seam over
/// `UserDefaults` so keys aren't stringly-typed at every call site.
///
/// Per-host settings are keyed by the host's ssh alias (`host.name` is the alias
/// for a remote, so it works for hosts from both `~/.ssh/config` and the managed
/// `~/.ssh/sidekick_hosts`). The `defaults` parameter is injectable so the logic
/// is unit-testable against a throwaway suite instead of the shared store.
enum Settings {
    /// Floor for the poll interval — below this the concurrent ssh fan-out would
    /// thrash, so a too-small (or zero/negative) stored value is clamped up.
    static let pollFloor: TimeInterval = 0.5
    /// Default poll cadence when nothing is stored (the historical 1.5s).
    static let pollDefault: TimeInterval = 1.5

    private static func watchKey(_ host: Host) -> String { "watch.\(host.name)" }
    private static func moshKey(_ host: Host) -> String { "mosh.\(host.name)" }
    private static func orderKey(_ host: Host) -> String { "order.\(host.name)" }
    private static func colorKey(_ host: Host) -> String { "color.\(host.name)" }
    private static func recentSortKey(_ host: Host) -> String { "recentSort.\(host.name)" }
    private static func expandedKey(_ host: Host) -> String { "expanded.\(host.name)" }

    /// Drop every per-host key for `host` — used when a server is renamed (its
    /// state moves to the new alias) so no dead keys accumulate. Lives here so the
    /// key format stays in one place.
    static func clearHost(_ host: Host, defaults: UserDefaults = .standard) {
        for key in [watchKey(host), moshKey(host), orderKey(host), colorKey(host), recentSortKey(host),
                    expandedKey(host)] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether a session lists its windows newest prompt first (see
    /// `TmuxWindow.byRecent`) instead of in tmux index order, the default.
    static func sortsByRecent(session: String, host: Host, defaults: UserDefaults = .standard) -> Bool {
        defaults.stringArray(forKey: recentSortKey(host))?.contains(session) ?? false
    }

    static func setSortsByRecent(
        _ on: Bool, session: String, host: Host, defaults: UserDefaults = .standard
    ) {
        var names = defaults.stringArray(forKey: recentSortKey(host)) ?? []
        names.removeAll { $0 == session }
        if on { names.append(session) }
        defaults.set(names, forKey: recentSortKey(host))
    }

    private static let pinnedDirsKey = "pinnedDirs"

    /// Directories pinned in the sidebar's `Group ▸ By Directory` mode, as
    /// absolute paths in pin order. A directory row is normally built from the
    /// live sessions sitting in it, so it vanishes when the last one is killed —
    /// pinning is what keeps a project on screen at zero sessions. Pinning is a
    /// property of the path, so it is host-agnostic.
    static func pinnedDirs(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: pinnedDirsKey) ?? []
    }

    static func isPinnedDir(_ path: String, defaults: UserDefaults = .standard) -> Bool {
        pinnedDirs(defaults: defaults).contains(path)
    }

    /// Pin (append, keeping pin order) or unpin `path`. An empty path is never
    /// pinned — that's the "(no directory)" bucket, not a project.
    static func setPinnedDir(
        _ pinned: Bool, path: String, defaults: UserDefaults = .standard
    ) {
        var dirs = pinnedDirs(defaults: defaults)
        if pinned {
            guard !path.isEmpty, !dirs.contains(path) else { return }
            dirs.append(path)
        } else {
            dirs.removeAll { $0 == path }
        }
        defaults.set(dirs, forKey: pinnedDirsKey)
    }

    private static let pollIntervalKey = "pollInterval"
    private static let rightSidebarColumnsKey = "rightSidebarColumns"
    private static let managerRailShownKey = "managerRailShown"
    private static let sessionRecoveryEnabledKey = "sessionRecoveryEnabled"
    private static let sessionRecoveryAutoResumeAgentsKey = "sessionRecoveryAutoResumeAgents"

    /// Whether the 🤖 Manager rail is open — so it comes back after a relaunch.
    /// Defaults to hidden; the manager only exists once the user first opens it.
    static func managerRailShown(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: managerRailShownKey) as? Bool ?? false
    }

    static func setManagerRailShown(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: managerRailShownKey)
    }

    private static let runningDrawerExpandedKey = "runningDrawerExpanded"

    /// Whether the Running drawer over the terminal is open. Defaults to closed:
    /// the pill's count is the signal, the list is on demand.
    static func runningDrawerExpanded(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: runningDrawerExpandedKey) as? Bool ?? false
    }

    static func setRunningDrawerExpanded(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: runningDrawerExpandedKey)
    }

    private static let managerRailSideBySideKey = "managerRailSideBySide"

    /// Whether the Manager rail puts its list and its chat side by side instead
    /// of stacking the list above the chat. Defaults to stacked.
    static func managerRailSideBySide(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: managerRailSideBySideKey) as? Bool ?? false
    }

    static func setManagerRailSideBySide(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: managerRailSideBySideKey)
    }

    private static let managerRailShowsRequestsKey = "managerRailShowsRequests"

    /// Whether the Manager rail's list card shows the request list instead of
    /// the board. Defaults to the board.
    static func managerRailShowsRequests(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: managerRailShowsRequestsKey) as? Bool ?? false
    }

    static func setManagerRailShowsRequests(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: managerRailShowsRequestsKey)
    }

    /// The size the human dragged the Manager rail's list to: its height when
    /// stacked, its width when side by side. Kept per layout, because a height
    /// means nothing as a width. nil until the divider is first dragged.
    static func managerRailListSize(sideBySide: Bool, defaults: UserDefaults = .standard) -> CGFloat? {
        (defaults.object(forKey: managerRailListSizeKey(sideBySide)) as? Double).map { CGFloat($0) }
    }

    static func setManagerRailListSize(
        _ size: CGFloat, sideBySide: Bool, defaults: UserDefaults = .standard
    ) {
        defaults.set(Double(size), forKey: managerRailListSizeKey(sideBySide))
    }

    private static func managerRailListSizeKey(_ sideBySide: Bool) -> String {
        sideBySide ? "managerRailListWidth" : "managerRailListHeight"
    }

    /// Whether automatic recovery after a reboot is on. The app always records
    /// the local tmux tree for the manual Recover Previous Sessions action;
    /// enabling this also installs the agent hooks and lets launch rebuild the
    /// saved tree automatically when tmux is empty. Defaults to **off**.
    static func sessionRecoveryEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: sessionRecoveryEnabledKey) as? Bool ?? false
    }

    static func setSessionRecoveryEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: sessionRecoveryEnabledKey)
    }

    /// Whether exact recovery should execute recorded Claude/Codex resume
    /// commands after recreating their panes. Defaults off so restored prompts
    /// are staged for review instead of starting agents in the background.
    static func sessionRecoveryAutoResumeAgents(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: sessionRecoveryAutoResumeAgentsKey) as? Bool ?? false
    }

    static func setSessionRecoveryAutoResumeAgents(
        _ on: Bool, defaults: UserDefaults = .standard
    ) {
        defaults.set(on, forKey: sessionRecoveryAutoResumeAgentsKey)
    }

    /// Whether the right sidebar lays its Tree/Diff panes out as columns (side by
    /// side) rather than rows (stacked). Defaults to rows — the rail is narrow, so
    /// stacked reads better until the user flips it. `object(forKey:)` (not `bool`)
    /// so an unset key falls through to the default instead of reading back false.
    static func rightSidebarColumns(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: rightSidebarColumnsKey) as? Bool ?? false
    }

    static func setRightSidebarColumns(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: rightSidebarColumnsKey)
    }

    /// Whether `host` is kept polling even when its sidebar row is collapsed. The
    /// local host is always watched (it always polls); remotes default to off and
    /// opt in via the row's "Watch" toggle or the add-server sheet.
    static func watch(host: Host, defaults: UserDefaults = .standard) -> Bool {
        guard !host.isLocal else { return true }
        return defaults.bool(forKey: watchKey(host))
    }

    static func setWatch(_ on: Bool, host: Host, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: watchKey(host))
    }

    /// Whether `host`'s Servers row is expanded to show its stat card — so the
    /// servers someone keeps an eye on are still open after a relaunch. Defaults
    /// to collapsed: most servers stay that way.
    static func hostExpanded(_ host: Host, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: expandedKey(host))
    }

    static func setHostExpanded(_ on: Bool, host: Host, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: expandedKey(host))
    }

    /// Whether the interactive terminal attach to `host` uses mosh (UDP, roaming)
    /// instead of `ssh -t`. Discovery polling never uses mosh. Local hosts ignore
    /// this (they attach directly, no ssh/mosh).
    static func useMosh(host: Host, defaults: UserDefaults = .standard) -> Bool {
        guard !host.isLocal else { return false }
        return defaults.bool(forKey: moshKey(host))
    }

    static func setUseMosh(_ on: Bool, host: Host, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: moshKey(host))
    }

    /// The user's custom session order for `host` (session names, in the order the
    /// rows should appear). Empty when the user hasn't reordered — the sidebar then
    /// keeps the default alphabetical order. See `TmuxModel.applyCustomOrder`.
    static func sessionOrder(host: Host, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: orderKey(host)) ?? []
    }

    static func setSessionOrder(_ names: [String], host: Host, defaults: UserDefaults = .standard) {
        defaults.set(names, forKey: orderKey(host))
    }

    /// The sidebar tint for every session running on `host`, as `#rrggbb`. The
    /// color denotes *which box the session is on*, so it's a property of the host,
    /// not of the session or its project.
    ///
    /// Unset hosts fall back to `HostColor.defaultHex(for:)`, a stable hue derived
    /// from the host name — so a freshly-added server is already distinguishable
    /// with no setup, and "Set Color…" only exists to override that choice.
    static func colorHex(host: Host, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: colorKey(host)) ?? HostColor.defaultHex(for: host.name)
    }

    /// Store an explicit `#rrggbb` for `host`; nil clears back to the derived hue.
    static func setColorHex(_ hex: String?, host: Host, defaults: UserDefaults = .standard) {
        if let hex { defaults.set(hex, forKey: colorKey(host)) }
        else { defaults.removeObject(forKey: colorKey(host)) }
    }

    /// Whether `host` has an explicit color (vs riding the derived default) — drives
    /// whether the row menu offers "Reset Color".
    static func hasCustomColor(host: Host, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: colorKey(host)) != nil
    }

    /// The global poll cadence, clamped to `pollFloor`. Defaults to `pollDefault`
    /// when unset (a missing key reads back as 0, which the floor catches too).
    static func pollInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.object(forKey: pollIntervalKey) as? TimeInterval ?? pollDefault
        return max(pollFloor, stored)
    }

    static func setPollInterval(_ value: TimeInterval, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: pollIntervalKey)
    }

    // MARK: Maestro

    private static let maestroAgentKey = "maestro.agent"

    /// The CLI the Maestro session starts. Claude until the user picks Codex.
    static func maestroAgent(defaults: UserDefaults = .standard) -> MaestroAgent {
        defaults.string(forKey: maestroAgentKey).flatMap(MaestroAgent.init) ?? .claude
    }

    static func setMaestroAgent(_ agent: MaestroAgent, defaults: UserDefaults = .standard) {
        defaults.set(agent.rawValue, forKey: maestroAgentKey)
    }

    /// The model `agent` runs as the Maestro; empty is the CLI's own default.
    /// Kept per agent, so a change of agent brings its own model back.
    static func maestroModel(_ agent: MaestroAgent, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "maestro.model.\(agent.rawValue)") ?? ""
    }

    static func setMaestroModel(
        _ model: String, agent: MaestroAgent, defaults: UserDefaults = .standard
    ) {
        defaults.set(
            model.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: "maestro.model.\(agent.rawValue)")
    }

    private static let maestroResetAfterIdleKey = "maestro.resetAfterIdleMinutes"
    private static let maestroResetAboveTokensKey = "maestro.resetAboveTokens"
    static let maestroResetAfterIdleDefault = 30
    static let maestroResetAboveTokensDefault = 80_000

    /// Minutes the Maestro may sit idle before its conversation is cleared;
    /// 0 never clears for idleness. No row in Settings:
    /// `defaults write is.rebar.MuxMaestro maestro.resetAfterIdleMinutes <n>`.
    static func maestroResetAfterIdleMinutes(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: maestroResetAfterIdleKey) == nil
            ? maestroResetAfterIdleDefault : max(0, defaults.integer(forKey: maestroResetAfterIdleKey))
    }

    static func setMaestroResetAfterIdleMinutes(_ minutes: Int, defaults: UserDefaults = .standard) {
        defaults.set(minutes, forKey: maestroResetAfterIdleKey)
    }

    /// The context size, in tokens, past which an idle Maestro's conversation
    /// is cleared; 0 never clears for size. No row in Settings:
    /// `defaults write is.rebar.MuxMaestro maestro.resetAboveTokens <n>`.
    static func maestroResetAboveTokens(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: maestroResetAboveTokensKey) == nil
            ? maestroResetAboveTokensDefault : max(0, defaults.integer(forKey: maestroResetAboveTokensKey))
    }

    static func setMaestroResetAboveTokens(_ tokens: Int, defaults: UserDefaults = .standard) {
        defaults.set(tokens, forKey: maestroResetAboveTokensKey)
    }

    // MARK: Phone

    private static let phoneEnabledKey = "phone.enabled"
    private static let phonePortKey = "phone.port"
    /// The port the phone server listens on and `tailscale serve` publishes.
    static let phonePortDefault = 7433

    /// Whether the phone server runs. Off until the user turns it on.
    static func phoneEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: phoneEnabledKey)
    }

    static func setPhoneEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: phoneEnabledKey)
    }

    static let phonePortRange = 1024...65535

    /// An unset or unusable port reads as the default.
    static func phonePort(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: phonePortKey)
        return phonePortRange.contains(stored) ? stored : phonePortDefault
    }

    static func setPhonePort(_ port: Int, defaults: UserDefaults = .standard) {
        defaults.set(port, forKey: phonePortKey)
    }

    /// What the Mac sidebar leaves out. Off until it is changed there.
    static func sidebarFilter(defaults: UserDefaults = .standard) -> SidebarFilter {
        defaults.string(forKey: "sidebar.filter").flatMap(SidebarFilter.init) ?? .off
    }

    static func setSidebarFilter(_ filter: SidebarFilter, defaults: UserDefaults = .standard) {
        defaults.set(filter.rawValue, forKey: "sidebar.filter")
    }

    /// The grouping the phone's sidebar opens with until it is changed there.
    static func phoneGrouping(defaults: UserDefaults = .standard) -> MobileGrouping {
        defaults.string(forKey: "phone.grouping").flatMap(MobileGrouping.init) ?? .recent
    }

    static func setPhoneGrouping(_ grouping: MobileGrouping, defaults: UserDefaults = .standard) {
        defaults.set(grouping.rawValue, forKey: "phone.grouping")
    }

    /// Whether the Mac is kept from idle sleep while the phone server runs.
    static func phoneKeepAwake(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "phone.keepAwake")
    }

    static func setPhoneKeepAwake(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: "phone.keepAwake")
    }

    /// Where the phone's own log is kept (`MobileLog`). There is no row for it
    /// in Settings: `defaults write is.rebar.MuxMaestro phone.logDir <dir>`
    /// moves it, and `mux phone-log` reads the same key.
    static func phoneLogDirectory(
        defaults: UserDefaults = .standard,
        support: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL? {
        if let path = defaults.string(forKey: "phone.logDir"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return support?.appendingPathComponent("MuxMaestro/logs", isDirectory: true)
    }

    /// One switch per phone feature. Each is off until turned on.
    static func phoneCapability(_ capability: MobileCapability, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "phone.capability.\(capability.rawValue)")
    }

    static func setPhoneCapability(
        _ capability: MobileCapability, _ on: Bool, defaults: UserDefaults = .standard
    ) {
        defaults.set(on, forKey: "phone.capability.\(capability.rawValue)")
    }

    /// The voice mode and speaker a phone starts with until it picks its own.
    static func phoneVoice(defaults: UserDefaults = .standard) -> MobileVoiceDefaults {
        MobileVoiceDefaults(
            mode: defaults.string(forKey: "phone.voice.mode").flatMap(MobileVoiceMode.init) ?? .manual,
            // Stored as "input only", so an unset key reads as two-way.
            speaker: !defaults.bool(forKey: "phone.voice.inputOnly"))
    }

    static func setPhoneVoice(_ voice: MobileVoiceDefaults, defaults: UserDefaults = .standard) {
        defaults.set(voice.mode.rawValue, forKey: "phone.voice.mode")
        defaults.set(!voice.speaker, forKey: "phone.voice.inputOnly")
    }

    /// The largest file the phone may upload, in bytes: one of
    /// `MobileReply.uploadLimits`.
    static func phoneUploadLimit(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: "phone.upload.maxBytes")
        return MobileReply.uploadLimits.contains(stored) ? stored : MobileReply.defaultUploadLimit
    }

    static func setPhoneUploadLimit(_ bytes: Int, defaults: UserDefaults = .standard) {
        defaults.set(bytes, forKey: "phone.upload.maxBytes")
    }

    /// Which events notify the phone, what the text says, and the VAPID
    /// contact. Both events are on and the text is generic until changed.
    static func phonePush(defaults: UserDefaults = .standard) -> MobilePushOptions {
        MobilePushOptions(
            waiting: defaults.object(forKey: "phone.push.waiting") as? Bool ?? true,
            done: defaults.object(forKey: "phone.push.done") as? Bool ?? true,
            detail: defaults.bool(forKey: "phone.push.detail"),
            subject: defaults.string(forKey: "phone.push.subject").flatMap(MobilePush.subject)
                ?? MobilePush.defaultSubject)
    }

    static func setPhonePush(_ options: MobilePushOptions, defaults: UserDefaults = .standard) {
        defaults.set(options.waiting, forKey: "phone.push.waiting")
        defaults.set(options.done, forKey: "phone.push.done")
        defaults.set(options.detail, forKey: "phone.push.detail")
        defaults.set(MobilePush.subject(options.subject) ?? MobilePush.defaultSubject,
                     forKey: "phone.push.subject")
    }

    /// The phone settings as the server enforces them.
    static func phoneConfig(defaults: UserDefaults = .standard) -> MobileConfig {
        MobileConfig(
            capabilities: Set(MobileCapability.allCases.filter { phoneCapability($0, defaults: defaults) }),
            grouping: phoneGrouping(defaults: defaults),
            voice: phoneVoice(defaults: defaults),
            uploadLimit: phoneUploadLimit(defaults: defaults))
    }
}
