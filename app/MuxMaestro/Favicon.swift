import AppKit
import Foundation

/// Resolves a web favicon for a project directory so a session row can show the
/// project's own icon instead of the generic host glyph. The candidate logic is
/// pure (Foundation-only, injectable `exists`) and unit-tested; `load` does the
/// disk read + NSImage decode and is called off the main thread.
enum Favicon {
    /// Favicon locations relative to a project dir, ordered by framework
    /// convention — the first existing file wins. Covers SvelteKit (`static/`),
    /// Vite/Next/CRA (`public/`), the Next app router (`app/favicon.ico`), and a
    /// bare repo-root favicon.
    static let candidates: [String] = [
        "static/favicon.png",   // SvelteKit
        "static/favicon.svg",
        "static/favicon.ico",
        "public/favicon.ico",   // Vite / Next / CRA
        "public/favicon.png",
        "public/favicon.svg",
        "app/favicon.ico",      // Next app router
        "src/favicon.ico",
        "favicon.ico",          // repo root
        "favicon.png",
        "favicon.svg",
    ]

    /// The first candidate that exists under `dir`, or nil. `exists` is injected
    /// so this stays pure and testable; `load` passes the real filesystem check.
    static func candidatePath(in dir: String, exists: (String) -> Bool) -> String? {
        guard !dir.isEmpty else { return nil }
        for rel in candidates {
            let path = (dir as NSString).appendingPathComponent(rel)
            if exists(path) { return path }
        }
        return nil
    }

    /// Resolve + load the favicon under `dir` as a ~15pt color image, or nil on
    /// miss / decode failure. Does disk I/O — call off the main thread.
    static func load(dir: String) -> NSImage? {
        guard let path = candidatePath(
                in: dir, exists: { FileManager.default.fileExists(atPath: $0) }),
              let image = NSImage(contentsOfFile: path)
        else { return nil }
        image.size = NSSize(width: 15, height: 15)
        // Favicons are already colored artwork — render them as-is, not tinted as
        // a monochrome template symbol.
        image.isTemplate = false
        return image
    }
}
