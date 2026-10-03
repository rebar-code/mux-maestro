import XCTest
// DefaultsMigration.swift compiles into this test target.

final class DefaultsMigrationTests: XCTestCase {
    private let legacy = "test.muxmaestro.legacy.\(UUID().uuidString)"
    private let domain = "test.muxmaestro.new.\(UUID().uuidString)"
    private let defaults = UserDefaults.standard

    override func tearDown() {
        defaults.removePersistentDomain(forName: legacy)
        defaults.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    func testCopiesLegacyKeysAndKeepsNewerOnes() {
        defaults.setPersistentDomain(["a": 1, "shared": "old"], forName: legacy)
        defaults.setPersistentDomain(["shared": "new"], forName: domain)

        XCTAssertTrue(DefaultsMigration.migrate(from: legacy, into: domain, defaults: defaults))

        let result = defaults.persistentDomain(forName: domain) ?? [:]
        XCTAssertEqual(result["a"] as? Int, 1)
        XCTAssertEqual(result["shared"] as? String, "new")
        XCTAssertEqual(result[DefaultsMigration.doneKey] as? Bool, true)
    }

    func testRunsOnlyOnce() {
        defaults.setPersistentDomain(["a": 1], forName: legacy)
        DefaultsMigration.migrate(from: legacy, into: domain, defaults: defaults)
        defaults.setPersistentDomain(["a": 2], forName: legacy)

        XCTAssertFalse(DefaultsMigration.migrate(from: legacy, into: domain, defaults: defaults))
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["a"] as? Int, 1)
    }

    func testNoLegacyDomainCopiesNothing() {
        XCTAssertFalse(DefaultsMigration.migrate(from: legacy, into: domain, defaults: defaults))
    }
}
