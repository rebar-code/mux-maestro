import Foundation

/// The bundle ID was `is.rebar.Sidekick` until the open-source release, and
/// settings live in the defaults domain named by the bundle ID. On the first
/// launch under the new ID, copy the old domain's keys across once. Keys already
/// set under the new ID win.
enum DefaultsMigration {
    static let legacyDomain = "is.rebar.Sidekick"
    static let doneKey = "migratedLegacyDefaults"

    /// Returns true when it copied anything.
    @discardableResult
    static func migrate(
        from legacy: String = legacyDomain,
        into domain: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let domain, domain != legacy else { return false }
        var current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[doneKey] == nil else { return false }
        let old = defaults.persistentDomain(forName: legacy) ?? [:]
        current.merge(old) { newer, _ in newer }
        current[doneKey] = true
        defaults.setPersistentDomain(current, forName: domain)
        return !old.isEmpty
    }
}
