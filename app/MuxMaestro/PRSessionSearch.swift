import Foundation

/// One agent conversation that worked on a pull request, found in its transcript
/// on disk — live or long gone from tmux.
struct PRSessionHit: Equatable {
    let agent: RecoveryAgent
    /// The id `claude --resume` / `codex resume` takes.
    let sessionId: String
    /// The directory the conversation ran in. May no longer exist.
    let cwd: String
    /// The repo whose PR it touched.
    let slug: String
    /// When the transcript was last written.
    let lastActive: Date
}

/// Finds every Claude and Codex conversation that touched a PR number, by
/// grepping the transcripts both agents keep on disk:
///
///   • Claude writes a `pr-link` record when a session creates or links a PR:
///     `{"type":"pr-link",…,"prNumber":784,"prUrl":"https://github.com/o/r/pull/784",…}`.
///     Only that record counts, so a session that merely mentioned the URL (or
///     searched for it, like this code does) does not match.
///   • Codex has no such record, so a rollout matches on a PR URL anywhere in it.
///
/// One `rg` per agent, never a Swift read of the ~9 GB of transcripts. Local
/// only: the transcripts live on this Mac. `/usr/bin/grep` is the fallback when
/// ripgrep is missing, but it is ~100× slower (40 s vs 0.3 s on 9 GB).
enum PRSessionSearch {
    static let grepPath = "/usr/bin/grep"
    /// Absolute, like every tool path here: a Finder-launched app has a stunted PATH.
    static var rgPath: String? {
        ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    // MARK: Pure core (unit-tested)

    /// The PR number in what the user typed: `784`, `#784`, `pr 784`, or a PR URL.
    static func number(fromQuery raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:.*/pull/|pr\s*|#)?(\d+)/?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s),
              let n = Int(s[r]), n > 0
        else { return nil }
        return n
    }

    /// `grep -o` pattern for Claude's `pr-link` record of PR `number`.
    static func claudePattern(number: Int) -> String {
        #""prNumber":\#(number)[,}][^}]*"#
    }

    /// `grep -o` pattern for a GitHub URL of PR `number` in a Codex rollout. The
    /// trailing class stops `784` from matching `7840`.
    static func codexPattern(number: Int) -> String {
        #"github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\#(number)([^0-9]|$)"#
    }

    /// The argv that prints `<path>:<match>` for every `pattern` match under
    /// `dir`, skipping subagent transcripts (not resumable). `--no-ignore
    /// --hidden` because `~/.claude` is a git repo that may ignore its transcripts.
    static func matchCommand(pattern: String, dir: String, rg: String?) -> (path: String, args: [String]) {
        if let rg {
            return (rg, ["-o", "--with-filename", "--no-heading", "--no-line-number",
                         "--no-ignore", "--hidden", "--glob", "*.jsonl", "--glob", "!subagents",
                         pattern, dir])
        }
        return (grepPath, ["-rEo", "--include=*.jsonl", "--exclude-dir=subagents", pattern, dir])
    }

    /// Parse `grep -rEo` / `rg -o` output (`<path>:<match>` per line) into path → repo slug.
    /// A path matching several repos keeps the first. Lines without a GitHub PR
    /// URL are dropped.
    static func parseMatches(_ out: String) -> [(path: String, slug: String)] {
        var seen = Set<String>()
        var result: [(path: String, slug: String)] = []
        for line in out.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let path = String(line[..<colon])
            let match = String(line[line.index(after: colon)...])
            guard !seen.contains(path), let slug = slug(inPRURL: match) else { continue }
            seen.insert(path)
            result.append((path, slug))
        }
        return result
    }

    /// `owner/repo` from the first `github.com/owner/repo/pull/` in `text`.
    static func slug(inPRURL text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"github\.com/([^/"\s]+/[^/"\s]+)/pull/"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    /// Keep the newest transcript per conversation (Codex subagent rollouts share
    /// their parent's `session_id`), newest first.
    static func dedupe(_ hits: [PRSessionHit]) -> [PRSessionHit] {
        var best: [String: PRSessionHit] = [:]
        for h in hits {
            let key = "\(h.agent.rawValue):\(h.sessionId)"
            if let cur = best[key], cur.lastActive >= h.lastActive { continue }
            best[key] = h
        }
        return best.values.sorted { $0.lastActive > $1.lastActive }
    }

    // MARK: Search (filesystem + grep)

    /// Every conversation that touched PR `number`, newest first. Call off the
    /// main thread: the scan takes up to a second with rg, far longer with grep.
    static func search(
        number: Int,
        claudeDir: String = NSHomeDirectory() + "/.claude/projects",
        codexDir: String = NSHomeDirectory() + "/.codex/sessions",
        rg: String? = rgPath,
        runner: CommandRunner = ProcessCommandRunner(timeout: 120)
    ) -> [PRSessionHit] {
        // rg and grep exit 1 on no match, which the runner reports as nil: no hits.
        func grep(_ pattern: String, _ dir: String) -> [(path: String, slug: String)] {
            guard FileManager.default.fileExists(atPath: dir) else { return [] }
            let cmd = matchCommand(pattern: pattern, dir: dir, rg: rg)
            return parseMatches(runner.run(cmd.path, cmd.args) ?? "")
        }

        var hits: [PRSessionHit] = []
        for (path, slug) in grep(claudePattern(number: number), claudeDir) {
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard ClaudeSessionRecovery.isSessionId(id),
                  let head = readHead(path, bytes: 256 * 1024),
                  let cwd = ClaudeSessionRecovery.extractCwd(fromTranscriptHead: head)
            else { continue }
            hits.append(PRSessionHit(agent: .claude, sessionId: id, cwd: cwd, slug: slug,
                                     lastActive: mtime(path)))
        }
        for (path, slug) in grep(codexPattern(number: number), codexDir) {
            guard let head = readHead(path, bytes: CodexSessions.headBytes),
                  let id = CodexSessions.sessionId(fromRolloutHead: head),
                  let cwd = ClaudeSessionRecovery.extractCwd(fromTranscriptHead: head)
            else { continue }
            hits.append(PRSessionHit(agent: .codex, sessionId: id, cwd: cwd, slug: slug,
                                     lastActive: mtime(path)))
        }
        return dedupe(hits)
    }

    /// `dir` if it exists, else its nearest existing ancestor: a deleted
    /// worktree still resumes from the repo it lived in.
    static func existingDirectory(_ dir: String) -> String {
        var d = dir
        while !d.isEmpty, d != "/", !FileManager.default.fileExists(atPath: d) {
            d = (d as NSString).deletingLastPathComponent
        }
        return d.isEmpty ? NSHomeDirectory() : d
    }

    private static func readHead(_ path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            ?? .distantPast
    }
}
