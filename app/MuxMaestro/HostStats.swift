import Foundation

/// A server's CPU use, memory, disk and uptime, for the stat card under an expanded
/// Servers row. Every field is optional: a host that answers only part of the
/// script still shows what it did answer, and a missing field renders as "—",
/// never as zero.
struct HostStats: Equatable {
    /// Share of CPU time in use over the script's one-second sample, 0–100.
    var cpuPercent: Double?
    /// 1-minute load average and core count, for the CPU tooltip.
    var load1: Double?
    var cores: Int?
    var memUsedBytes: Int64?
    var memTotalBytes: Int64?
    /// Free and total space on `/`, as `df` reports them.
    var diskFreeBytes: Int64?
    var diskTotalBytes: Int64?
    var uptimeSeconds: TimeInterval?

    /// One `sh -c` script for both OSes. Each tool's raw output sits under an
    /// `@name` marker so `parse` can pick the pieces apart; a tool that fails
    /// leaves its section empty rather than failing the whole fetch. `/usr/sbin`
    /// is added for `sysctl`, which a non-login ssh PATH can miss. CPU use needs
    /// two readings, so the script takes about a second: Linux reads `/proc/stat`
    /// twice; macOS reads `iostat`'s second row (`top` needs 5 s on a busy Mac).
    static let script = """
        PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"
        echo @os; uname -s
        case "$(uname -s)" in
        Linux)
          echo @cores; nproc 2>/dev/null || getconf _NPROCESSORS_ONLN
          echo @loadavg; cat /proc/loadavg
          cpu1=$(grep '^cpu ' /proc/stat); sleep 1; cpu2=$(grep '^cpu ' /proc/stat)
          echo @cpu; echo "$cpu1"; echo "$cpu2"
          echo @meminfo; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo
          echo @uptime; cat /proc/uptime ;;
        Darwin)
          echo @cores; sysctl -n hw.ncpu
          echo @loadavg; sysctl -n vm.loadavg
          echo @cpu; iostat -n 0 -c 2 -w 1 | tail -1
          echo @memsize; sysctl -n hw.memsize
          echo @vmstat; vm_stat
          echo @boottime; sysctl -n kern.boottime
          echo @now; date +%s ;;
        esac
        echo @df; df -Pk /
        exit 0
        """

    /// Parse the script's output. nil when nothing at all could be read — the
    /// caller keeps the last value then, so garbage never blanks a good card.
    static func parse(_ output: String) -> HostStats? {
        var sections: [String: [String]] = [:]
        var current: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@") {
                current = String(line.dropFirst())
                sections[current!] = []
            } else if let current {
                sections[current, default: []].append(line)
            }
        }

        var stats = HostStats()
        stats.cores = sections["cores"]?.first.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        stats.load1 = sections["loadavg"]?.first.flatMap(parseLoad)
        stats.cpuPercent = sections["cpu"].flatMap(parseCPU)

        if let meminfo = sections["meminfo"] {
            // Linux: used is total less MemAvailable, the kernel's own estimate of
            // what a new process could get without swapping.
            let total = meminfoKB(meminfo, "MemTotal")
            let available = meminfoKB(meminfo, "MemAvailable")
            if let total { stats.memTotalBytes = total * 1024 }
            if let total, let available, available <= total {
                stats.memUsedBytes = (total - available) * 1024
            }
        }
        if let memsize = sections["memsize"]?.first.flatMap({ Int64($0) }), memsize > 0 {
            stats.memTotalBytes = memsize
        }
        if let vmstat = sections["vmstat"], let used = vmStatUsedBytes(vmstat) {
            stats.memUsedBytes = used
        }

        if let up = sections["uptime"]?.first?.split(separator: " ").first.flatMap({ Double($0) }),
           up >= 0 {
            stats.uptimeSeconds = up
        } else if let boot = sections["boottime"]?.first.flatMap(parseBootTime),
                  let now = sections["now"]?.first.flatMap({ Double($0) }), now >= boot {
            stats.uptimeSeconds = now - boot
        }

        if let df = sections["df"] { parseDF(df, into: &stats) }

        return stats == HostStats() ? nil : stats
    }

    /// First number of `/proc/loadavg` ("0.52 0.58 …") or `vm.loadavg` ("{ 2.10 … }").
    private static func parseLoad(_ line: String) -> Double? {
        line.split(separator: " ").lazy
            .filter { $0 != "{" }
            .first.flatMap { Double($0) }
            .flatMap { $0 >= 0 ? $0 : nil }
    }

    /// CPU use from the `@cpu` section. Linux: two `/proc/stat` "cpu" lines, the
    /// busy share of the time between them (idle and iowait count as idle).
    /// macOS: `iostat`'s last row, "us sy id 1m 5m 15m", busy = 100 − id.
    private static func parseCPU(_ lines: [String]) -> Double? {
        let percent: Double
        if !lines.contains(where: { $0.hasPrefix("cpu") }) {
            let f = (lines.last ?? "").split(separator: " ").compactMap { Double($0) }
            guard f.count >= 3, (0...100).contains(f[2]) else { return nil }
            percent = 100 - f[2]
        } else {
            let samples = lines.filter { $0.hasPrefix("cpu") }.map {
                $0.split(separator: " ").dropFirst().prefix(8).compactMap { Double($0) }
            }
            guard samples.count == 2, samples.allSatisfy({ $0.count >= 5 }) else { return nil }
            let total = zip(samples[1], samples[0]).map { $0 - $1 }.reduce(0, +)
            let idle = (samples[1][3] + samples[1][4]) - (samples[0][3] + samples[0][4])
            guard total > 0, idle >= 0, idle <= total else { return nil }
            percent = (total - idle) / total * 100
        }
        return min(100, max(0, percent))
    }

    /// A `/proc/meminfo` value in kB ("MemTotal:  32180324 kB").
    private static func meminfoKB(_ lines: [String], _ key: String) -> Int64? {
        guard let line = lines.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
        return line.dropFirst(key.count + 1).split(separator: " ").first.flatMap { Int64($0) }
    }

    /// macOS memory in use, counted the way Activity Monitor's "Memory Used" is:
    /// app memory (anonymous less purgeable) plus wired plus compressed. File
    /// cache is excluded, as `MemAvailable` excludes it on Linux. Older macOS has
    /// no "Anonymous pages" line; active pages stand in for app memory there.
    private static func vmStatUsedBytes(_ lines: [String]) -> Int64? {
        guard let header = lines.first(where: { $0.contains("page size of") }),
              let size = header.components(separatedBy: "page size of ").last?
                .split(separator: " ").first.flatMap({ Int64($0) }), size > 0
        else { return nil }
        var pages: [String: Int64] = [:]
        for line in lines {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if let n = Int64(value) { pages[key] = n }
        }
        guard let wired = pages["Pages wired down"],
              let compressed = pages["Pages occupied by compressor"] else { return nil }
        let app: Int64
        if let anonymous = pages["Anonymous pages"] {
            app = max(0, anonymous - (pages["Pages purgeable"] ?? 0))
        } else if let active = pages["Pages active"] {
            app = active
        } else { return nil }
        return (app + wired + compressed) * size
    }

    /// `kern.boottime`: "{ sec = 1787933000, usec = 257221 } Fri Aug 28 …".
    private static func parseBootTime(_ line: String) -> Double? {
        guard let range = line.range(of: "sec = ") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Double(digits)
    }

    /// The last line of `df -Pk /`. Read from the right, so a filesystem name
    /// with a space in it cannot shift the columns: … blocks used avail cap% mount.
    private static func parseDF(_ lines: [String], into stats: inout HostStats) {
        guard let line = lines.last(where: { !$0.hasPrefix("Filesystem") }) else { return }
        let f = line.split(separator: " ")
        guard f.count >= 6, f[f.count - 2].hasSuffix("%"),
              let blocks = Int64(f[f.count - 5]), let avail = Int64(f[f.count - 3]),
              blocks > 0, avail >= 0 else { return }
        stats.diskTotalBytes = blocks * 1024
        stats.diskFreeBytes = avail * 1024
    }

    // MARK: labels

    /// Shown for any value not known yet.
    static let dash = "—"

    /// "CPU 54%".
    var cpuLabel: String {
        guard let cpuPercent else { return "CPU \(Self.dash)" }
        return "CPU \(Int(cpuPercent.rounded()))%"
    }

    /// "load 2.1 · 8 cores", for the CPU value's tooltip.
    var cpuTooltip: String? {
        guard let load1 else { return nil }
        let load = load1 < 10 ? String(format: "%.1f", load1) : String(Int(load1.rounded()))
        return cores.map { "load \(load) · \($0) cores" } ?? "load \(load)"
    }

    /// "RAM 12/32G".
    var ramLabel: String {
        guard let memUsedBytes, let memTotalBytes else { return "RAM \(Self.dash)" }
        return "RAM \(Self.gib(memUsedBytes))/\(Self.gib(memTotalBytes))G"
    }

    /// "Disk 120G free" — free space is what decides where new work goes. The
    /// total is in `diskTooltip`.
    var diskLabel: String {
        guard let diskFreeBytes else { return "Disk \(Self.dash)" }
        return "Disk \(Self.size(diskFreeBytes)) free"
    }

    var diskTooltip: String? {
        guard let diskFreeBytes, let diskTotalBytes else { return nil }
        return "\(Self.size(diskFreeBytes)) free of \(Self.size(diskTotalBytes)) on /"
    }

    /// "up 3d", "up 5h", "up 12m".
    var uptimeLabel: String {
        guard let s = uptimeSeconds else { return "up \(Self.dash)" }
        if s >= 86_400 { return "up \(Int(s / 86_400))d" }
        if s >= 3_600 { return "up \(Int(s / 3_600))h" }
        return "up \(Int(s / 60))m"
    }

    /// Every label, for the sidebar diff: a changed number reloads the row.
    var labels: [String] { [cpuLabel, ramLabel, diskLabel, uptimeLabel] }

    private static let gibibyte = 1_073_741_824.0

    /// Bytes as GiB with no unit: one decimal under 10, whole above.
    private static func gib(_ bytes: Int64) -> String {
        let g = Double(bytes) / gibibyte
        return g < 10 ? String(format: "%.1f", g) : String(Int(g.rounded()))
    }

    /// Bytes as "120G" or, from 1000G up, "1.2T".
    private static func size(_ bytes: Int64) -> String {
        let g = Double(bytes) / gibibyte
        if g >= 1000 { return String(format: "%.1fT", g / 1024) }
        return "\(gib(bytes))G"
    }
}
