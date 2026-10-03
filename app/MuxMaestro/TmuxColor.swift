import AppKit

/// Parse a color string (`Settings.colorHex`, or a tmux-style name) into an NSColor, or nil for
/// "default"/empty/unrecognized. Handles `#rrggbb` hex, xterm `colourN`/`colorN`
/// palette indices, and the named ANSI colors tmux uses. Lives outside TmuxModel
/// so that file stays AppKit-free; kept small and dependency-light so it compiles
/// into the logic test target.
enum TmuxColor {
    static func parse(_ s: String) -> NSColor? {
        let v = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !v.isEmpty, v != "default" else { return nil }
        if v.hasPrefix("#") { return hex(v) }
        if v.hasPrefix("colour") { return xterm(String(v.dropFirst(6))) }
        if v.hasPrefix("color") { return xterm(String(v.dropFirst(5))) }
        return named(v)
    }

    private static func hex(_ s: String) -> NSColor? {
        let h = s.dropFirst()
        guard h.count == 6, let n = Int(h, radix: 16) else { return nil }
        return rgb((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
    }

    private static func xterm(_ s: String) -> NSColor? {
        guard let n = Int(s), (0...255).contains(n) else { return nil }
        if n < 16 { return base16[n] }
        if n < 232 {
            // 6×6×6 color cube: each channel indexes [0,95,135,175,215,255].
            let steps = [0, 95, 135, 175, 215, 255]
            let i = n - 16
            return rgb(steps[i / 36], steps[(i / 6) % 6], steps[i % 6])
        }
        let g = 8 + 10 * (n - 232)  // 24-step grayscale ramp
        return rgb(g, g, g)
    }

    private static func named(_ s: String) -> NSColor? {
        let table: [String: Int] = [
            "black": 0, "red": 1, "green": 2, "yellow": 3,
            "blue": 4, "magenta": 5, "cyan": 6, "white": 7,
            "brightblack": 8, "brightred": 9, "brightgreen": 10, "brightyellow": 11,
            "brightblue": 12, "brightmagenta": 13, "brightcyan": 14, "brightwhite": 15,
        ]
        return table[s].map { base16[$0] }
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// The standard xterm-256 base table (0–7 normal, 8–15 bright).
    private static let base16: [NSColor] = [
        rgb(0, 0, 0), rgb(128, 0, 0), rgb(0, 128, 0), rgb(128, 128, 0),
        rgb(0, 0, 128), rgb(128, 0, 128), rgb(0, 128, 128), rgb(192, 192, 192),
        rgb(128, 128, 128), rgb(255, 0, 0), rgb(0, 255, 0), rgb(255, 255, 0),
        rgb(0, 0, 255), rgb(255, 0, 255), rgb(0, 255, 255), rgb(255, 255, 255),
    ]
}

/// The default sidebar tint for a host that the user hasn't explicitly colored:
/// a stable pick from a curated palette, keyed by host name. Pure Foundation (hex
/// strings in, hex strings out) so `Settings` doesn't need AppKit.
enum HostColor {
    /// Dark-sidebar-friendly hues, all distinct at the ~50% alpha the card gradient
    /// draws them at. Deliberately no red — the attention state already owns red
    /// (the `.card.attn` stroke), and a red *tint* would read as a false alarm.
    static let palette = [
        "#7c3aed",  // violet
        "#0ea5e9",  // sky
        "#f59e0b",  // amber
        "#10b981",  // emerald
        "#ec4899",  // pink
        "#14b8a6",  // teal
        "#8b5cf6",  // purple
        "#f97316",  // orange
        "#22c55e",  // green
        "#3b82f6",  // blue
        "#eab308",  // yellow
    ]

    /// A stable palette index for `name`.
    ///
    /// Uses FNV-1a rather than `String.hashValue`: Swift seeds its hasher per
    /// process, so `hashValue` would hand a host a different color on every
    /// relaunch. This must be deterministic across runs and machines.
    static func defaultHex(for name: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return palette[Int(h % UInt64(palette.count))]
    }
}
