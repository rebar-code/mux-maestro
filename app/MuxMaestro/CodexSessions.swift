import Foundation

/// Resolves the **codex** conversation id running in each local tmux pane — the
/// id `codex resume <uuid>` needs, and the thing you grep `~/.codex/sessions`
/// for. Claude ids come from `sessions.py` instead (see
/// `TmuxModel.parsePaneSessionIds`); `claude` does not keep its transcript open,
/// so the trick below does not work for it.
///
/// A codex TUI holds its rollout transcripts open for the life of the process,
/// so one `lsof` names every live conversation:
///
///     pane %47 → pane_pid 65439 → descendant `codex` pid 66143
///       → /usr/sbin/lsof -c codex -Fpn
///       → ~/.codex/sessions/2026/08/29/rollout-…-01a04e9e-….jsonl
///       → first line: {"type":"session_meta","payload":{"session_id":"01a04e9e-…", …}}
///
/// Every rollout one process holds — the main thread and each subagent thread —
/// records the **same** `payload.session_id` (the top-level conversation); the
/// per-file `id` / `parent_thread_id` are what distinguish subagents, and we
/// ignore them.
///
/// Cost is exactly **two** subprocesses regardless of pane count (`ps` + `lsof`),
/// plus a bounded 4 KB read per codex process. That is deliberate: a per-pane
/// subprocess is the perf regression fixed in PR #67. The result rides
/// `CachedStatusProvider`'s TTL like the rest of the snapshot.
enum CodexSessions {
    /// Absolute paths — a Finder-launched app inherits a stunted PATH, the bug
    /// fixed in PR #73.
    static let psPath = "/bin/ps"
    static let lsofPath = "/usr/sbin/lsof"

    /// How much of a rollout's first line to read. `session_id` sits at byte ~85
    /// of an ~18 KB `session_meta` line, so 4 KB is plenty and never parses the
    /// megabytes behind it.
    static let headBytes = 4 * 1024

    // MARK: Pure core (unit-tested)

    /// Parse `ps -Ao pid=,ppid=` into pid → ppid. Unparseable lines are skipped.
    static func parseProcessTable(_ ps: String) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for line in ps.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, let pid = Int(f[0]), let ppid = Int(f[1]) else { continue }
            map[pid] = ppid
        }
        return map
    }

    /// Parse `lsof -c codex -Fpn` into pid → the rollout paths that pid holds open.
    ///
    /// The `-F` output is one field per line, `p<pid>` starting a process block and
    /// `n<name>` naming a file. Everything that is not a `~/.codex/sessions/…jsonl`
    /// path is dropped, so a codex process with no open rollout (a freshly started
    /// one, a helper) simply has no entry.
    static func parseOpenRollouts(_ lsof: String) -> [Int: [String]] {
        var map: [Int: [String]] = [:]
        var current: Int?
        for line in lsof.split(separator: "\n", omittingEmptySubsequences: true) {
            let body = line.dropFirst()
            switch line.first {
            case "p":
                current = Int(body)
            case "n":
                guard let pid = current else { continue }
                let path = String(body)
                guard path.hasSuffix(".jsonl"), path.contains("/.codex/sessions/") else { continue }
                map[pid, default: []].append(path)
            default:
                continue
            }
        }
        return map
    }

    /// The `payload.session_id` in a rollout's first line — the **top-level**
    /// conversation id, which subagent rollouts carry too. Scans for the key
    /// rather than parsing an 18 KB JSON object. Nil when the key is absent
    /// (truncated head, foreign file) or its value is empty.
    static func sessionId(fromRolloutHead head: String) -> String? {
        guard let keyRange = head.range(of: "\"session_id\":\"") else { return nil }
        var value = ""
        var escaped = false
        for ch in head[keyRange.upperBound...] {
            if escaped {
                value.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return value.isEmpty ? nil : value
            } else {
                value.append(ch)
            }
        }
        return nil
    }

    // MARK: IO (call off the main thread)

    /// Every live codex conversation keyed by the codex process holding it, plus
    /// the process table needed to walk those pids back to a tmux pane, and each
    /// conversation's own rollout path (see `mainRollout`). Empty
    /// when nothing is running or `lsof` is unavailable.
    ///
    /// Where a process holds several rollouts, the **newest by mtime** wins — that
    /// is what makes a `/new` thread in a long-lived codex resolve to the current
    /// conversation instead of the first one it ever opened.
    static func scan(
        runner: CommandRunner = ProcessCommandRunner()
    ) -> (codexByPid: [Int: String], ppids: [Int: Int], rollouts: [String: String]) {
        guard FileManager.default.isExecutableFile(atPath: lsofPath) else {
            if claimFirstWarning() {
                NSLog("MuxMaestro: \(lsofPath) missing; codex session ids unavailable")
            }
            return ([:], [:], [:])
        }
        // `lsof` exits non-zero (→ nil) when no codex process matches, which is
        // simply "no codex running" — not a failure worth logging.
        guard let lsofOut = runner.run(lsofPath, ["-c", "codex", "-Fpn"]) else { return ([:], [:], [:]) }
        let ppids = runner.run(psPath, ["-Ao", "pid=,ppid="]).map(parseProcessTable) ?? [:]

        var byPid: [Int: String] = [:]
        var rollouts: [String: String] = [:]
        for (pid, paths) in parseOpenRollouts(lsofOut) {
            guard let newest = newestByModification(paths),
                  let head = readHead(ofFileAt: newest),
                  let id = sessionId(fromRolloutHead: head)
            else { continue }
            byPid[pid] = id
            rollouts[id] = mainRollout(sessionId: id, paths: paths)
        }
        return (byPid, ppids, rollouts)
    }

    /// The conversation's own rollout among the ones its process holds open: the
    /// file named for `sessionId`. Guardian subagent rollouts share the
    /// `session_id` but are named for their own id. nil when it is not open.
    static func mainRollout(sessionId: String, paths: [String]) -> String? {
        paths.first { $0.hasSuffix("-\(sessionId).jsonl") }
    }

    /// The most recently modified of `paths`. Unstattable paths (the file was
    /// rotated away mid-scan) are skipped.
    private static func newestByModification(_ paths: [String]) -> String? {
        var best: (path: String, mtime: Date)?
        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            if mtime > (best?.mtime ?? .distantPast) { best = (path, mtime) }
        }
        return best?.path
    }

    private static func readHead(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Guards the one-time "lsof missing" log. `scan` runs on the background poll
    /// queue, so the flag is flipped under a lock to stay race-free and emit the
    /// warning exactly once — mirroring `SessionsPyStatusProvider`.
    private static let warnLock = NSLock()
    private static var warnedMissing = false

    private static func claimFirstWarning() -> Bool {
        warnLock.lock()
        defer { warnLock.unlock() }
        if warnedMissing { return false }
        warnedMissing = true
        return true
    }
}
