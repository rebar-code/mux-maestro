import XCTest

// HostStats.swift compiles into this test target. Fixtures are real output of
// `HostStats.script`, captured from a Linux server (devbox) and this Mac.
final class HostStatsTests: XCTestCase {
    private let linux = """
        @os
        Linux
        @cores
        6
        @loadavg
        3.02 3.86 3.76 1/6888 486617
        @cpu
        cpu  190198395 35248 71758638 1835528884 35161645 0 1913588 0 0 0
        cpu  190198495 35248 71758672 1835529309 35161676 0 1913589 0 0 0
        @meminfo
        MemTotal:       32180324 kB
        MemAvailable:   13880688 kB
        @uptime
        3572677.08 18176369.87
        @df
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        /dev/sda2        959218776 116648484 793770960      13% /
        """

    private let mac = """
        @os
        Darwin
        @cores
        10
        @loadavg
        { 2.07 3.70 1.09 }
        @cpu
         39  33  29  105.58 184.81 158.19
        @memsize
        68719476736
        @vmstat
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                     3702.
        Pages active:                                1012544.
        Pages inactive:                               997487.
        Pages speculative:                             14383.
        Pages wired down:                             466625.
        Pages purgeable:                                1000.
        "Translation faults":                   107491254574.
        File-backed pages:                            468516.
        Anonymous pages:                             1555898.
        Pages occupied by compressor:                1642708.
        @boottime
        { sec = 1787933000, usec = 257221 } Fri Aug 28 11:03:20 2026
        @now
        1790215919
        @df
        Filesystem     1024-blocks      Used Available Capacity  Mounted on
        /dev/disk3s1s1   971350180  15829280 104461248    14%    /
        """

    func testLinux() throws {
        let s = try XCTUnwrap(HostStats.parse(linux))
        XCTAssertEqual(s.cores, 6)
        XCTAssertEqual(s.load1, 3.02)
        XCTAssertEqual(s.memTotalBytes, 32_180_324 * 1024)
        XCTAssertEqual(s.memUsedBytes, (32_180_324 - 13_880_688) * 1024)
        XCTAssertEqual(s.diskFreeBytes, 793_770_960 * 1024)
        XCTAssertEqual(s.diskTotalBytes, 959_218_776 * 1024)
        XCTAssertEqual(s.uptimeSeconds, 3_572_677.08)
        XCTAssertEqual(s.labels, ["CPU 23%", "RAM 17/31G", "Disk 757G free", "up 41d"])
        XCTAssertEqual(s.diskTooltip, "757G free of 915G on /")
    }

    func testMac() throws {
        let s = try XCTUnwrap(HostStats.parse(mac))
        XCTAssertEqual(s.cores, 10)
        XCTAssertEqual(s.load1, 2.07)
        XCTAssertEqual(s.memTotalBytes, 68_719_476_736)
        // (anonymous − purgeable) + wired + compressor, in 16 KiB pages.
        XCTAssertEqual(s.memUsedBytes, (1_555_898 - 1000 + 466_625 + 1_642_708) * 16384)
        XCTAssertEqual(s.diskFreeBytes, 104_461_248 * 1024)
        XCTAssertEqual(s.uptimeSeconds, 1_790_215_919 - 1_787_933_000)
        XCTAssertEqual(s.labels, ["CPU 71%", "RAM 56/64G", "Disk 100G free", "up 26d"])
    }

    func testOlderMacWithoutAnonymousPagesFallsBackToActive() throws {
        let old = mac.replacingOccurrences(of: "Anonymous pages:", with: "Something else:")
        let s = try XCTUnwrap(HostStats.parse(old))
        XCTAssertEqual(s.memUsedBytes, (1_012_544 + 466_625 + 1_642_708) * 16384)
    }

    func testCPUPercentBothOSes() throws {
        XCTAssertEqual(try XCTUnwrap(HostStats.parse(linux)).cpuPercent ?? 0, 100.0 * 135 / 591, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(HostStats.parse(mac)).cpuPercent ?? 0, 71, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(HostStats.parse(mac)).cpuTooltip, "load 2.1 · 10 cores")
    }

    func testCPUPercentNeedsTwoGoodSamples() {
        // One /proc/stat line, no elapsed time, or a counter that went backwards
        // is no reading, never a made-up 0% or 100%.
        let one = "@cpu\ncpu  100 0 100 900 0 0 0 0\n@uptime\n5\n"
        let same = "@cpu\ncpu  100 0 100 900 0 0 0 0\ncpu  100 0 100 900 0 0 0 0\n@uptime\n5\n"
        let back = "@cpu\ncpu  100 0 100 900 0 0 0 0\ncpu  100 0 100 800 0 0 0 0\n@uptime\n5\n"
        for out in [one, same, back] {
            XCTAssertNil(HostStats.parse(out)?.cpuPercent)
        }
        XCTAssertNil(HostStats.parse("@cpu\nnonsense\n@uptime\n5\n")?.cpuPercent)
    }

    func testGarbageIsNil() {
        XCTAssertNil(HostStats.parse(""))
        XCTAssertNil(HostStats.parse("bash: sh: command not found\n"))
        XCTAssertNil(HostStats.parse("@cores\nnope\n@loadavg\nx y z\n@df\nwhat\n"))
        XCTAssertNil(HostStats.parse("@cores\n-4\n@uptime\n-1\n"), "negative numbers are not stats")
    }

    func testPartialKeepsWhatItCouldRead() throws {
        // The ssh dropped after the CPU sample.
        let cut = String(linux.prefix(while: { $0 != "M" }))
        let s = try XCTUnwrap(HostStats.parse(cut))
        XCTAssertEqual(s.cpuLabel, "CPU 23%")
        XCTAssertEqual(s.ramLabel, "RAM —")
        XCTAssertEqual(s.diskLabel, "Disk —")
        XCTAssertEqual(s.uptimeLabel, "up —")
        XCTAssertNil(s.diskTooltip)
    }

    func testMemAvailableAboveTotalIsNotTrusted() throws {
        let s = try XCTUnwrap(HostStats.parse("@meminfo\nMemTotal: 100 kB\nMemAvailable: 200 kB\n"))
        XCTAssertEqual(s.memTotalBytes, 102_400)
        XCTAssertNil(s.memUsedBytes)
        XCTAssertEqual(s.ramLabel, "RAM —")
    }

    func testDfWithSpaceInFilesystemName() throws {
        let s = try XCTUnwrap(HostStats.parse(
            "@df\nFilesystem 1024-blocks Used Available Capacity Mounted on\n"
            + "map auto home 2000 1000 1000 50% /\n"))
        XCTAssertEqual(s.diskFreeBytes, 1_024_000)
    }

    func testUnknownIsADashNotZero() {
        XCTAssertEqual(HostStats().labels, ["CPU —", "RAM —", "Disk —", "up —"])
    }

    func testLabelFormats() {
        var s = HostStats()
        s.cpuPercent = 53.6
        XCTAssertEqual(s.cpuLabel, "CPU 54%")
        XCTAssertNil(s.cpuTooltip, "no load reading, no tooltip")
        s.load1 = 12.4
        XCTAssertEqual(s.cpuTooltip, "load 12")
        s.cores = 64
        XCTAssertEqual(s.cpuTooltip, "load 12 · 64 cores")
        s.diskFreeBytes = 2 * 1024 * 1_073_741_824
        XCTAssertEqual(s.diskLabel, "Disk 2.0T free")
        s.memUsedBytes = 3 * 1_073_741_824 / 2
        s.memTotalBytes = 8 * 1_073_741_824
        XCTAssertEqual(s.ramLabel, "RAM 1.5/8.0G")
        s.uptimeSeconds = 5 * 3600 + 59
        XCTAssertEqual(s.uptimeLabel, "up 5h")
        s.uptimeSeconds = 125
        XCTAssertEqual(s.uptimeLabel, "up 2m")
    }
}
