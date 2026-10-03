import Foundation

/// A Claude Code session that was live when the tmux server last died and can
/// be revived with `claude --resume <id>` in a fresh tmux session.
struct RecoverableSession: Equatable {
    /// The Claude session UUID — the transcript's `.jsonl` basename.
    let id: String
    /// The working directory recorded in the transcript.
    let cwd: String
    /// When the transcript was last written (≈ when the session last did work).
    let lastActive: Date
    /// The same project has transcript activity NEWER than the cutoff — the user
    /// may already have picked that work up in a fresh session, so the picker
    /// flags it rather than hiding it.
    let hasNewerActivity: Bool

    var suggestedSessionName: String {
        ClaudeSessionRecovery.suggestedSessionName(forDirectory: cwd)
    }
}

/// Finds Claude Code sessions lost to a reboot / OS update / tmux-server death.
///
/// Every Claude Code conversation persists as
/// `~/.claude/projects/<path-slug>/<uuid>.jsonl` regardless of what happens to
/// the terminal it ran in. So "the sessions that were open last night" are
/// exactly: per project, the newest transcript whose mtime falls shortly before
/// the moment tmux died — for which the last boot time is the reliable proxy.
enum ClaudeSessionRecovery {
    /// How far before the cutoff a transcript still counts as "was open".
    /// 12h covers an evening of work without dredging up the whole week.
    static let defaultWindow: TimeInterval = 12 * 3600

    /// One transcript file's identity, IO-free for testability.
    struct Transcript: Equatable {
        let id: String
        let mtime: Date
    }

    // MARK: Pure core (unit-tested)

    /// The newest transcript within `(cutoff - window, cutoff]`, plus whether the
    /// project also has activity after the cutoff. Nil when nothing in the window
    /// (project was idle, or all its activity is post-cutoff).
    static func newestInWindow(
        _ transcripts: [Transcript], cutoff: Date, window: TimeInterval
    ) -> (transcript: Transcript, hasNewerActivity: Bool)? {
        let start = cutoff.addingTimeInterval(-window)
        var best: Transcript?
        var newer = false
        for t in transcripts {
            if t.mtime > cutoff {
                newer = true
            } else if t.mtime > start, t.mtime > (best?.mtime ?? .distantPast) {
                best = t
            }
        }
        guard let best else { return nil }
        return (best, newer)
    }

    /// The first `"cwd":"…"` value in a transcript's head, JSON-unescaped enough
    /// for filesystem paths (\" \\ \/). Nil when absent (empty/foreign file).
    static func extractCwd(fromTranscriptHead head: String) -> String? {
        guard let keyRange = head.range(of: "\"cwd\":\"") else { return nil }
        var value = ""
        var escaped = false
        for ch in head[keyRange.upperBound...] {
            if escaped {
                value.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return value
            } else {
                value.append(ch)
            }
        }
        return nil
    }

    /// A tmux session name for a recovered session's directory. Mirrors how the
    /// sidebar's own sessions are named (folder basename), with two refinements:
    /// `~/.claude` itself becomes `_claude`, a repo worktree under
    /// `<repo>/.claude/worktrees/<name>` becomes `<repo>-<name>`, and a generic
    /// or hidden basename (`data`, `src`, …) gets its parent prefixed so the row
    /// still says which project it is. tmux-invalid characters are handled later
    /// by `TmuxCommands.sanitizedSessionName`.
    static func suggestedSessionName(
        forDirectory dir: String, home: String = NSHomeDirectory()
    ) -> String {
        if dir == home + "/.claude" { return "_claude" }
        let path = dir as NSString
        let base = path.lastPathComponent
        if let repoPart = dir.range(of: "/.claude/worktrees/") {
            let repo = (String(dir[..<repoPart.lowerBound]) as NSString).lastPathComponent
            return "\(repo)-\(base)"
        }
        let generic: Set<String> = ["data", "src", "app", "dist", "build"]
        if generic.contains(base) || base.hasPrefix(".") {
            let parent = (path.deletingLastPathComponent as NSString).lastPathComponent
            return "\(parent)-\(base)"
        }
        return base
    }

    // MARK: Discovery (filesystem)

    /// Scan `projectsDir` and return the lost sessions, newest first. Sessions
    /// whose recorded cwd no longer exists are dropped (the directory moved or
    /// was deleted — `claude --resume` needs somewhere to run). Call off the
    /// main thread; it stats every transcript and reads the head of the winners.
    static func findLostSessions(
        projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects"),
        cutoff: Date? = bootTime(),
        window: TimeInterval = defaultWindow
    ) -> [RecoverableSession] {
        guard let cutoff else { return [] }
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)
        else { return [] }

        var found: [RecoverableSession] = []
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            let transcripts: [Transcript] = files.compactMap { file in
                guard file.pathExtension == "jsonl",
                      isSessionId(file.deletingPathExtension().lastPathComponent),
                      let mtime = (try? file.resourceValues(
                        forKeys: [.contentModificationDateKey]))?.contentModificationDate
                else { return nil }
                return Transcript(id: file.deletingPathExtension().lastPathComponent, mtime: mtime)
            }
            guard let (best, newer) = newestInWindow(
                transcripts, cutoff: cutoff, window: window) else { continue }

            let transcript = project.appendingPathComponent("\(best.id).jsonl")
            guard let head = readHead(of: transcript),
                  let cwd = extractCwd(fromTranscriptHead: head),
                  fm.fileExists(atPath: cwd)
            else { continue }
            found.append(RecoverableSession(
                id: best.id, cwd: cwd, lastActive: best.mtime, hasNewerActivity: newer))
        }
        return found.sorted { $0.lastActive > $1.lastActive }
    }

    /// Session transcripts are named `<uuid>.jsonl`; anything else in a project
    /// dir (indexes, agent transcripts) is not resumable.
    static func isSessionId(_ s: String) -> Bool {
        s.count == 36 && s.range(
            of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
            options: .regularExpression) != nil
    }

    /// The first 256 KB of the transcript — the cwd appears on the first record,
    /// but transcripts can be many MB, so never read the whole file.
    private static func readHead(of url: URL, bytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// When the machine last booted — the proxy for "when tmux died". Nil only if
    /// the sysctl fails (never expected on macOS).
    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    // MARK: Cached lookup (for the sidebar's empty-state row)

    /// The lost-session list is stable for the whole app run (its inputs — boot
    /// time and pre-boot transcript mtimes — can't change), so compute it once.
    /// First access does disk IO; the sidebar prewarms this off-main before it
    /// builds the empty-state row on the main thread.
    static var lostSessions: [RecoverableSession] {
        cacheQueue.sync {
            if let cached { return cached }
            let found = findLostSessions()
            cached = found
            return found
        }
    }

    private static let cacheQueue = DispatchQueue(label: "is.rebar.muxmaestro.claude-recovery")
    private static var cached: [RecoverableSession]?
}
