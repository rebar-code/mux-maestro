import Foundation

/// Env-gated diagnostics for the poll/refresh hot path: `MUXMAESTRO_DIAG=1` prints
/// timing + structural lines to stderr. Off (the default), every entry point is a
/// no-op guarded by a `static let` the optimizer folds away, so shipping builds pay
/// nothing.
///
/// Exists because the two bugs it was written for are both *intermittent and
/// invisible*: a sidebar that silently drops rows, and a poll whose cost is spread
/// across ~20 subprocesses. Neither shows up in a debugger you have to catch in the
/// act — but both show up immediately in a log you can leave running.
enum Diag {
    static let on = ProcessInfo.processInfo.environment["MUXMAESTRO_DIAG"] == "1"

    private static let start = Date()

    static func log(_ tag: String, _ message: @autoclosure () -> String) {
        guard on else { return }
        let elapsed = Date().timeIntervalSince(start)
        fputs("[diag \(String(format: "%8.3f", elapsed))] \(tag.padding(toLength: 12, withPad: " ", startingAt: 0)) \(message())\n", stderr)
    }

    /// Run `body`, returning its value, and log how long it took.
    static func time<T>(_ tag: String, _ detail: String = "", _ body: () -> T) -> T {
        guard on else { return body() }
        let t0 = Date()
        let value = body()
        let ms = Date().timeIntervalSince(t0) * 1000
        log(tag, "\(String(format: "%7.1fms", ms)) \(detail)")
        return value
    }

    /// Milliseconds `body` took, alongside its value — for callers that fold the
    /// duration into a larger line instead of emitting one of their own.
    static func measure<T>(_ body: () -> T) -> (value: T, ms: Double) {
        let t0 = Date()
        let value = body()
        return (value, Date().timeIntervalSince(t0) * 1000)
    }

    // MARK: Subprocess accounting

    /// Every `ProcessCommandRunner.run` bumps these so a refresh can report how many
    /// processes it spawned and how long they cost in aggregate — the difference
    /// between "the poll is slow" and "the poll spawns python three times".
    private static let lock = NSLock()
    private static var spawnCount = 0
    private static var spawnMillis = 0.0
    /// argv[0] basename → (count, ms), so the worst offender names itself.
    private static var spawnByTool: [String: (n: Int, ms: Double)] = [:]

    static func recordSpawn(_ tool: String, ms: Double) {
        guard on else { return }
        lock.lock()
        defer { lock.unlock() }
        spawnCount += 1
        spawnMillis += ms
        var entry = spawnByTool[tool] ?? (0, 0)
        entry.n += 1
        entry.ms += ms
        spawnByTool[tool] = entry
    }

    /// Snapshot of the counters, for diffing across a refresh cycle.
    struct SpawnStats {
        var count = 0
        var millis = 0.0
        var byTool: [String: (n: Int, ms: Double)] = [:]

        /// What happened between `self` and a later snapshot.
        func delta(since earlier: SpawnStats) -> String {
            let tools = byTool.map { tool, v -> String in
                let before = earlier.byTool[tool] ?? (0, 0)
                return "\(tool)×\(v.n - before.n) \(String(format: "%.0fms", v.ms - before.ms))"
            }.sorted()
            return "\(count - earlier.count) procs, "
                + "\(String(format: "%.0fms", millis - earlier.millis)) in-proc [\(tools.joined(separator: " "))]"
        }
    }

    static func spawnStats() -> SpawnStats {
        guard on else { return SpawnStats() }
        lock.lock()
        defer { lock.unlock() }
        return SpawnStats(count: spawnCount, millis: spawnMillis, byTool: spawnByTool)
    }
}
