import XCTest

/// SetupTools.swift is compiled into this target; the Setup window
/// (SettingsWindowController.swift) is app-only.
final class SetupToolsTests: XCTestCase {
    private func tool(_ name: String) -> SetupTool {
        SetupTools.all.first { $0.name == name }!
    }

    func testListsEveryToolWithTmuxTheOnlyRequiredOne() {
        XCTAssertEqual(SetupTools.all.map(\.name), [
            "tmux", "python3", "git", "gh", "rg", "ssh / scp", "mosh", "herdr",
            "claude", "codex", "treehouse",
        ])
        XCTAssertEqual(SetupTools.all.filter(\.required).map(\.name), ["tmux"])
    }

    func testAppPathToolIgnoresTheLoginShell() {
        // The app runs tmux by absolute path, so a copy only the shell can see is no use.
        let statuses = SetupTools.check(
            [tool("tmux")],
            isExecutable: { _ in true },
            shellPaths: ["tmux": "/Users/x/.nix-profile/bin/tmux"],
            developerToolsInstalled: true)
        XCTAssertEqual(statuses[0].paths, ["/opt/homebrew/bin/tmux"])

        let missing = SetupTools.check(
            [tool("tmux")],
            isExecutable: { $0 == "/Users/x/.nix-profile/bin/tmux" },
            shellPaths: ["tmux": "/Users/x/.nix-profile/bin/tmux"],
            developerToolsInstalled: true)
        XCTAssertFalse(missing[0].found)
    }

    func testLoginShellToolIsFoundOnTheUsersPath() {
        let statuses = SetupTools.check(
            [tool("claude")],
            isExecutable: { $0 == "/Users/x/.local/bin/claude" },
            shellPaths: ["claude": "/Users/x/.local/bin/claude"],
            developerToolsInstalled: true)
        XCTAssertEqual(statuses[0].paths, ["/Users/x/.local/bin/claude"])
    }

    func testAShellPathThatIsNotExecutableIsMissing() {
        let statuses = SetupTools.check(
            [tool("claude")],
            isExecutable: { _ in false },
            shellPaths: ["claude": "/Users/x/.local/bin/claude"],
            developerToolsInstalled: true)
        XCTAssertFalse(statuses[0].found)
    }

    func testDeveloperToolStubsCountOnlyWithTheCommandLineTools() {
        let stubs: (String) -> Bool = { SetupTools.developerToolShims.contains($0) }
        let without = SetupTools.check(
            [tool("git"), tool("python3")], isExecutable: stubs, shellPaths: [:],
            developerToolsInstalled: false)
        XCTAssertEqual(without.map(\.found), [false, false])
        let with = SetupTools.check(
            [tool("git"), tool("python3")], isExecutable: stubs, shellPaths: [:],
            developerToolsInstalled: true)
        XCTAssertEqual(with.map(\.paths), [["/usr/bin/git"], ["/usr/bin/python3"]])
    }

    func testHomebrewPythonNeedsNoCommandLineTools() {
        let statuses = SetupTools.check(
            [tool("python3")], isExecutable: { $0 == "/opt/homebrew/bin/python3" },
            shellPaths: [:], developerToolsInstalled: false)
        XCTAssertEqual(statuses[0].paths, ["/opt/homebrew/bin/python3"])
    }

    func testEveryCommandInARowMustBeFound() {
        let sshOnly = SetupTools.check(
            [tool("ssh / scp")], isExecutable: { $0 == "/usr/bin/ssh" }, shellPaths: [:],
            developerToolsInstalled: true)
        XCTAssertFalse(sshOnly[0].found)
        let both = SetupTools.check(
            [tool("ssh / scp")], isExecutable: { ["/usr/bin/ssh", "/usr/bin/scp"].contains($0) },
            shellPaths: [:], developerToolsInstalled: true)
        XCTAssertEqual(both[0].paths, ["/usr/bin/ssh", "/usr/bin/scp"])
    }

    func testMissingRequired() {
        XCTAssertEqual(SetupTools.missingRequired(isExecutable: { _ in false }).map(\.name), ["tmux"])
        XCTAssertEqual(SetupTools.missingRequired(isExecutable: { $0 == "/usr/local/bin/tmux" }), [])
    }

    func testParseShellLookupKeepsOnlyMarkedAbsolutePaths() {
        let output = """
            Last login: Thu Sep 10 09:00:00
            __muxmaestro__claude=/Users/x/.local/bin/claude
            __muxmaestro__codex=alias codex='npx codex'
            unmarked=/usr/bin/true
            __muxmaestro__treehouse=/Users/x/go/bin/treehouse
            """
        XCTAssertEqual(SetupTools.parseShellLookup(output), [
            "claude": "/Users/x/.local/bin/claude",
            "treehouse": "/Users/x/go/bin/treehouse",
        ])
    }

    func testShellLookupScriptResolvesAndExitsZeroWhenTheLastCommandIsMissing() {
        let script = SetupTools.shellLookupScript(["sh", "muxmaestro-no-such-command"])
        let output = ProcessCommandRunner().run("/bin/sh", ["-c", script])
        XCTAssertNotNil(output, "a missing last command must not fail the whole lookup")
        let paths = SetupTools.parseShellLookup(output ?? "")
        XCTAssertEqual(paths["sh"], "/bin/sh")
        XCTAssertNil(paths["muxmaestro-no-such-command"])
    }

    func testInstallRecipes() {
        XCTAssertNil(tool("ssh / scp").install, "ssh and scp ship with macOS")
        XCTAssertEqual(tool("git").install, "xcode-select --install")
        XCTAssertEqual(tool("python3").install, "xcode-select --install")
        XCTAssertEqual(tool("claude").install, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(tool("rg").install.map { $0.hasSuffix("&& brew install ripgrep") }, true)
        XCTAssertEqual(tool("codex").install.map { $0.hasSuffix("&& brew install --cask codex") }, true)
        for name in ["tmux", "python3", "git", "gh", "rg", "mosh", "herdr", "claude", "codex", "treehouse"] {
            XCTAssertNotNil(tool(name).install, name)
        }
    }

    func testBrewInstallBootstrapsHomebrewOnlyWhenBrewIsMissing() {
        XCTAssertEqual(
            SetupTools.brewInstall("gh"),
            "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
                + "command -v brew >/dev/null 2>&1 || /bin/bash -c "
                + "\"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" "
                + "&& brew install gh")
    }

    func testTerminalCommandRunsTheRecipeInALoginShellThenStaysOpen() {
        XCTAssertEqual(
            SetupTools.terminalCommand(install: "brew install gh"),
            "exec \"$SHELL\" -lc 'brew install gh; exec \"$SHELL\" -l'")
    }
}
