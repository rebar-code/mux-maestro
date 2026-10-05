import XCTest

// ManagerHome.swift compiles into this test target. The seed runs against a
// throwaway home and a throwaway resource folder, never Application Support.
final class ManagerHomeTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var resources: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ManagerHomeTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("manager")
        resources = root.appendingPathComponent("bundle")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try write("reference 1", "AGENT.md")
        try write("#!/bin/sh", "mux")
        try write("default instructions", "CLAUDE.default.md")
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, _ name: String) throws {
        try text.write(to: resources.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func seed() throws {
        let resources = self.resources!
        try ManagerHome.seed(home: home) { name, ext in
            resources.appendingPathComponent(ext.map { "\(name).\($0)" } ?? name)
        }
    }

    private func text(_ name: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
    }

    private func isLink(_ name: String) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(name).path)) != nil
    }

    func testANewHomeGetsTheReferenceTheInstructionsAndTheCodexLink() throws {
        try seed()
        XCTAssertEqual(text("AGENT.md"), "reference 1")
        XCTAssertEqual(text("CLAUDE.md"), "default instructions")
        XCTAssertFalse(isLink("CLAUDE.md"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("AGENTS.md").path), "CLAUDE.md")
        XCTAssertEqual(text("AGENTS.md"), "default instructions")
        XCTAssertTrue(fm.isExecutableFile(atPath: home.appendingPathComponent("bin/mux").path))
    }

    func testEditedInstructionsOutliveTheNextStartAndTheReferenceDoesNot() throws {
        try seed()
        try ManagerHome.writeContext("mine", home: home)
        try "scribble".write(to: home.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)
        try write("reference 2", "AGENT.md")
        try write("new default", "CLAUDE.default.md")
        try seed()
        XCTAssertEqual(ManagerHome.readContext(home: home), "mine")
        XCTAssertEqual(text("AGENTS.md"), "mine")
        XCTAssertEqual(text("AGENT.md"), "reference 2")
    }

    /// The home of every build before the split: CLAUDE.md links to AGENT.md.
    func testTheOldLinkToTheReferenceBecomesTheInstructions() throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let agent = home.appendingPathComponent("AGENT.md")
        try "old".write(to: agent, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: home.appendingPathComponent("CLAUDE.md"), withDestinationURL: agent)
        try seed()
        XCTAssertFalse(isLink("CLAUDE.md"))
        XCTAssertEqual(text("CLAUDE.md"), "default instructions")
        // Writing the instructions must not reach the reference through a link.
        try ManagerHome.writeContext("mine", home: home)
        XCTAssertEqual(text("AGENT.md"), "reference 1")
    }

    func testALinkTheUserMadeIsKeptAndWrittenThrough() throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let own = root.appendingPathComponent("dotfiles-maestro.md")
        try "theirs".write(to: own, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: home.appendingPathComponent("CLAUDE.md"), withDestinationURL: own)
        try seed()
        XCTAssertEqual(ManagerHome.readContext(home: home), "theirs")
        try ManagerHome.writeContext("edited", home: home)
        XCTAssertTrue(isLink("CLAUDE.md"))
        XCTAssertEqual(try String(contentsOf: own, encoding: .utf8), "edited")
    }

    func testAnAgentsFileTheUserMadeIsKept() throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try "codex only".write(to: home.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try seed()
        XCTAssertEqual(text("AGENTS.md"), "codex only")
    }

    func testTheDefaultIsWhatTheSeedWrites() throws {
        let resources = self.resources!
        XCTAssertEqual(
            ManagerHome.defaultContext { name, ext in resources.appendingPathComponent("\(name).\(ext ?? "")") },
            "default instructions")
    }
}
