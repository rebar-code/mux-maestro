import Foundation

/// A command-line tool MuxMaestro uses, as the Setup window lists it.
struct SetupTool: Equatable {
    /// How the app reaches the tool, which decides where "found" may look.
    enum Lookup: Equatable {
        /// Run by absolute path from `SetupTools.appSearchDirs`. A Finder-launched
        /// app has no user PATH, so a copy anywhere else can't be used.
        case appPaths
        /// Run inside a pane's shell, so the user's own PATH counts too.
        case loginShell
    }

    let name: String
    /// Every binary the row needs; the row reads found only when all are.
    let commands: [String]
    let required: Bool
    let lookup: Lookup
    /// What the Install button runs in the terminal. nil for tools that ship
    /// with macOS.
    let install: String?
}

/// The tools the Setup window checks, and the rules for finding and installing
/// them. The core is pure — every lookup is injected — so the rules are
/// unit-tested without depending on what this Mac has installed.
enum SetupTools {
    /// Where the app looks for the tools it runs by absolute path — the list
    /// `TmuxService`, `HerdrService` and `Ssh` each search.
    static let appSearchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// macOS stubs that exist before the Command Line Tools do. Running one only
    /// opens Apple's install prompt, so it counts as found only once
    /// `xcode-select -p` succeeds.
    static let developerToolShims: Set<String> = ["/usr/bin/git", "/usr/bin/python3"]

    static let commandLineTools = "xcode-select --install"

    /// `brew install <formula>`, installing Homebrew first when it's missing (its
    /// installer asks before it changes anything). The Homebrew prefixes go on
    /// PATH so an existing brew is found from a shell whose profile lacks it.
    static func brewInstall(_ formula: String) -> String {
        "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
            + "command -v brew >/dev/null 2>&1 || /bin/bash -c "
            + "\"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" "
            + "&& brew install \(formula)"
    }

    static let all: [SetupTool] = [
        SetupTool(name: "tmux", commands: ["tmux"], required: true, lookup: .appPaths,
                  install: brewInstall("tmux")),
        SetupTool(name: "python3", commands: ["python3"], required: false, lookup: .appPaths,
                  install: commandLineTools),
        SetupTool(name: "git", commands: ["git"], required: false, lookup: .appPaths,
                  install: commandLineTools),
        SetupTool(name: "gh", commands: ["gh"], required: false, lookup: .appPaths,
                  install: brewInstall("gh")),
        SetupTool(name: "rg", commands: ["rg"], required: false, lookup: .appPaths,
                  install: brewInstall("ripgrep")),
        SetupTool(name: "ssh / scp", commands: ["ssh", "scp"], required: false, lookup: .appPaths,
                  install: nil),
        SetupTool(name: "mosh", commands: ["mosh"], required: false, lookup: .appPaths,
                  install: brewInstall("mosh")),
        SetupTool(name: "herdr", commands: ["herdr"], required: false, lookup: .appPaths,
                  install: brewInstall("herdr")),
        SetupTool(name: "claude", commands: ["claude"], required: false, lookup: .loginShell,
                  install: "curl -fsSL https://claude.ai/install.sh | bash"),
        SetupTool(name: "codex", commands: ["codex"], required: false, lookup: .loginShell,
                  install: brewInstall("--cask codex")),
        SetupTool(name: "treehouse", commands: ["treehouse"], required: false, lookup: .loginShell,
                  install: brewInstall("treehouse")),
    ]

    struct Status: Equatable {
        let tool: SetupTool
        /// Where each of `tool.commands` was found, in order; empty when any is missing.
        let paths: [String]
        var found: Bool { !paths.isEmpty }
    }

    // MARK: Pure core (unit-tested)

    static func check(
        _ tools: [SetupTool] = all,
        isExecutable: (String) -> Bool,
        shellPaths: [String: String],
        developerToolsInstalled: Bool
    ) -> [Status] {
        var statuses: [Status] = []
        for tool in tools {
            var paths: [String] = []
            for command in tool.commands {
                guard let path = locate(
                    command, lookup: tool.lookup, isExecutable: isExecutable,
                    shellPaths: shellPaths, developerToolsInstalled: developerToolsInstalled)
                else { paths = []; break }
                paths.append(path)
            }
            statuses.append(Status(tool: tool, paths: paths))
        }
        return statuses
    }

    /// The first usable copy of `command`: the app's search dirs, then — for a
    /// login-shell tool — wherever the user's shell resolved it.
    static func locate(
        _ command: String,
        lookup: SetupTool.Lookup,
        isExecutable: (String) -> Bool,
        shellPaths: [String: String],
        developerToolsInstalled: Bool
    ) -> String? {
        var candidates = appSearchDirs.map { "\($0)/\(command)" }
        if lookup == .loginShell, let path = shellPaths[command] { candidates.append(path) }
        for path in candidates where isExecutable(path) {
            if developerToolShims.contains(path) && !developerToolsInstalled { continue }
            return path
        }
        return nil
    }

    /// The required tools the app can't find. No shell and no subprocess, so it
    /// is cheap enough to run on the main thread at launch.
    static func missingRequired(isExecutable: (String) -> Bool) -> [SetupTool] {
        check(all.filter(\.required), isExecutable: isExecutable, shellPaths: [:],
              developerToolsInstalled: true)
            .filter { !$0.found }
            .map(\.tool)
    }

    /// Prefixes each line of `shellLookupScript` output, so rc-file noise is ignored.
    static let shellMarker = "__muxmaestro__"

    /// A script for the user's shell that prints `<marker><command>=<path>` for
    /// each command it resolves. Ends in `true`: the runner treats a non-zero
    /// exit as failure, which would drop every hit when the last one is missing.
    static func shellLookupScript(_ commands: [String]) -> String {
        "for c in \(commands.joined(separator: " ")); do "
            + "p=$(command -v \"$c\" 2>/dev/null) && printf '\(shellMarker)%s=%s\\n' \"$c\" \"$p\"; "
            + "done; true"
    }

    /// Parse `shellLookupScript` output. Only absolute paths count — zsh's
    /// `command -v` prints `alias x=…` for an alias, which the app can't run.
    static func parseShellLookup(_ output: String) -> [String: String] {
        var paths: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let marker = line.range(of: shellMarker) else { continue }
            let pair = line[marker.upperBound...]
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let path = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            paths[String(pair[..<eq])] = path
        }
        return paths
    }

    /// What the terminal runs for an Install click: the recipe in a login shell
    /// (so the user's PATH resolves), then a shell left open on the output.
    static func terminalCommand(install: String) -> String {
        "exec \"$SHELL\" -lc " + Ssh.shellQuote("\(install); exec \"$SHELL\" -l")
    }

    // MARK: This Mac (blocking IO — call off the main thread)

    /// Check every tool against this Mac: one run of the user's shell for the
    /// login-shell tools, one `xcode-select -p`.
    static func checkThisMac() -> [Status] {
        let runner = ProcessCommandRunner(timeout: 10)
        let shellVar = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let shell = shellVar.isEmpty ? "/bin/zsh" : shellVar
        let commands = all.filter { $0.lookup == .loginShell }.flatMap(\.commands)
        // -i as well as -l: installers such as claude's and bun's add their bin
        // dir in the interactive rc file, which is what a pane's shell reads.
        let output = runner.run(shell, ["-ilc", shellLookupScript(commands)]) ?? ""
        return check(
            isExecutable: FileManager.default.isExecutableFile(atPath:),
            shellPaths: parseShellLookup(output),
            developerToolsInstalled: runner.run("/usr/bin/xcode-select", ["-p"]) != nil)
    }
}
