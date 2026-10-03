import Cocoa

/// Semantic color tokens for the app's native chrome — the left session sidebar
/// and the right Tree panel both read their colors from here, never hardcoding a
/// hex. Centralized so a future theme switch is just assigning `Theme.current`
/// (and refreshing the views): every surface re-themes together. The values
/// mirror the MuxMaestro web companion's refined dark theme.
struct Theme {
    /// Window/list background.
    let bg: NSColor
    /// Raised fill for panels and text areas.
    let surface: NSColor
    /// Session card fill in the sidebar: one flat gray, lighter than `bg`.
    let card: NSColor
    /// Hairline borders and dividers.
    let border: NSColor
    /// Secondary text and quiet icons.
    let muted: NSColor
    /// Primary text.
    let text: NSColor
    /// Secondary foreground for a session on a *remote* host — one step back from
    /// the bright local `text`, so local vs. remote reads at a glance.
    let textRemote: NSColor
    /// Interactive accent (links, hover, selection tint, folders).
    let accent: NSColor
    /// Status: busy / ok.
    let green: NSColor
    /// Status: attention / search-match highlight.
    let amber: NSColor
    /// Status: waiting / destructive.
    let red: NSColor
    /// Status: merged — GitHub's own signal for "this landed", and the one hue
    /// that must not read as `green` (open) or `red` (closed).
    let purple: NSColor
    /// The ambient Manager rail's own surface — a cool-tinted charcoal, distinct
    /// from the main terminal's theme so the agent zone reads as its own card.
    /// Used for the rail card fill AND injected as the manager terminal's Ghostty
    /// `background` (see `GhosttyApp.managerConfig`).
    let managerSurface: NSColor

    /// The active theme. Swap this (then refresh the views) to re-theme; today
    /// there is a single dark theme. A stored property — not a `let` — so it's the
    /// single switch point when more themes land.
    static var current: Theme = .dark

    /// Geist-inspired dark theme (Vercel's design system): near-black surfaces,
    /// neutral hairline borders, high-contrast foreground, one blue accent, and
    /// crisp status hues — all tuned for legibility on the #0a0a0a background.
    static let dark = Theme(
        bg: hex(0x0a0a0a),
        surface: hex(0x171717),
        card: hex(0x161616),
        border: hex(0x2a2a2a),
        muted: hex(0x8f8f8f),
        text: hex(0xededed),
        textRemote: hex(0xa1a1a1),
        accent: hex(0x3291ff),
        green: hex(0x45d483),
        amber: hex(0xf5a623),
        red: hex(0xf85149),
        purple: hex(0xa371f7),
        managerSurface: hex(0x15151f))

    static func hex(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255,
                green: CGFloat((h >> 8) & 0xff) / 255,
                blue: CGFloat(h & 0xff) / 255, alpha: 1)
    }

    /// A `rrggbb` hex string for a color (sRGB, no `#`) — the format Ghostty's
    /// `background`/`foreground` config keys expect.
    static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }
}
