import XCTest

/// BundledTools.swift is compiled into this target. The install is tested against
/// the repo's real `Resources/tools`, so a missing vendored file fails here.
final class BundledToolsTests: XCTestCase {
    private let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("app/MuxMaestro/Resources/tools", isDirectory: true)

    private var root: URL!
    private var destination: URL { root.appendingPathComponent("tools", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledToolsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEveryToolIsVendored() {
        for tool in BundledTool.allCases {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: source.appendingPathComponent(tool.rawValue).path),
                "\(tool.rawValue) is missing from Resources/tools")
        }
    }

    func testInstallCopiesEveryToolVerbatim() throws {
        try BundledTools.install(from: source, to: destination)
        for tool in BundledTool.allCases {
            XCTAssertEqual(
                try Data(contentsOf: destination.appendingPathComponent(tool.rawValue)),
                try Data(contentsOf: source.appendingPathComponent(tool.rawValue)),
                tool.rawValue)
        }
    }

    func testReinstallReplacesStaleCopiesAndLeavesNoStagedFiles() throws {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: destination.appendingPathComponent("sessions.py"))

        try BundledTools.install(from: source, to: destination)
        try BundledTools.install(from: source, to: destination)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("sessions.py")),
            try Data(contentsOf: source.appendingPathComponent("sessions.py")))
        let staged = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { $0.contains(".staging-") }
        XCTAssertEqual(staged, [])
    }

    func testRemotePath() {
        XCTAssertEqual(BundledTools.remotePath(.sessions), "~/.muxmaestro/tools/sessions.py")
    }
}
