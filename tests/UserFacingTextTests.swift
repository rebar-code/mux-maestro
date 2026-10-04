import XCTest

/// The agent that watches the other sessions is "the Maestro" in every text a
/// person reads. Its old name stays in wire names only. This scans the string
/// literals of the app's Swift sources, so a new string with the old name
/// fails here.
final class UserFacingTextTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("app/MuxMaestro", isDirectory: true)

    /// Wire names, stored names and developer logs: the literals that keep the
    /// old name. The last two are about a host's package manager.
    private static let allowed: Set<String> = [
        "manager",
        "manager-delta",
        "mux-manager",
        "manager.db",
        "MuxMaestro/manager",
        "ghostty-manager.conf",
        "is.rebar.muxmaestro.manager",
        "is.rebar.muxmaestro.manager.driver",
        "manager: start failed — \\(error)",
        "MuxMaestro: manager ghostty_config_new failed",
        "MuxMaestro: failed to write manager theme: \\(error)",
        "Runs the host's package manager over ssh (it may prompt ",
        "manager over ssh (it may prompt for your sudo password in the terminal). ",
        "else echo 'No supported package manager found.'; fi;",
    ]

    /// The string literals of `source` that use the old name, comments left out.
    static func oldNames(in source: String) -> [String] {
        let code = source.replacingOccurrences(
            of: #"(?m)(^|\s)//.*$"#, with: "$1", options: .regularExpression)
        var literals: [String] = []
        var rest = code
        for pattern in [#""""([\s\S]*?)""""#, #""((?:[^"\\\n]|\\.)*)""#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(rest.startIndex..., in: rest)
            literals += regex.matches(in: rest, range: range).compactMap {
                Range($0.range(at: 1), in: rest).map { String(rest[$0]) }
            }
            rest = regex.stringByReplacingMatches(in: rest, range: range, withTemplate: "")
        }
        return literals.filter {
            !allowed.contains($0)
                && $0.range(of: #"\bmanagers?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    func testTheOldNameIsFoundInAStringLiteral() {
        XCTAssertEqual(Self.oldNames(in: #"let title = "Toggle Manager""#), ["Toggle Manager"])
        XCTAssertEqual(
            Self.oldNames(in: "let text = \"\"\"\n    Ask the manager\n    \"\"\""),
            ["\n    Ask the manager\n    "])
    }

    func testWireNamesIdentifiersAndCommentsPass() {
        XCTAssertEqual(Self.oldNames(in: #"case "manager": return .manager"#), [])
        XCTAssertEqual(Self.oldNames(in: #"let key = "managerRailShown" // the manager rail"#), [])
        XCTAssertEqual(Self.oldNames(in: #"FileManager.default.fileExists(atPath: "a")"#), [])
    }

    func testTheAppCallsTheAgentTheMaestro() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        let found = try files.flatMap { file in
            Self.oldNames(in: try String(contentsOf: file, encoding: .utf8))
                .map { "\(file.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(found.sorted(), [])
    }
}
