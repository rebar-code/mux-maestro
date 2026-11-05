import Foundation

/// Finds the web URL under the pointer in one terminal row, for the ⌘-hover
/// preview. Ghostty's own link match is not exposed to the app, so the preview
/// reads the row text and matches it here.
enum LinkHover {
    /// The `http(s)` URL in `row` that covers cell `column` (0-based), or nil.
    /// Columns count terminal cells: a wide character takes two.
    static func url(inRow row: String, column: Int) -> URL? {
        guard column >= 0 else { return nil }
        let chars = Array(row)
        var cols: [Int] = []
        var col = 0
        for ch in chars {
            cols.append(col)
            col += cellWidth(ch)
        }

        var i = 0
        while i < chars.count {
            guard startsURL(chars, at: i) else {
                i += 1
                continue
            }
            var end = i
            while end < chars.count, !stops(chars[end]) { end += 1 }
            let run = trimmed(chars[i..<end])
            let last = i + run.count - 1
            if run.count > 0, column >= cols[i], column < cols[last] + cellWidth(chars[last]) {
                return webURL(String(run))
            }
            i = end
        }
        return nil
    }

    private static let schemes: [[Character]] = [Array("https://"), Array("http://")]

    private static func startsURL(_ chars: [Character], at i: Int) -> Bool {
        schemes.contains { scheme in
            i + scheme.count <= chars.count
                && zip(chars[i..<(i + scheme.count)], scheme).allSatisfy { $0.lowercased() == String($1) }
        }
    }

    /// Characters that end a URL run: whitespace, quotes and angle brackets, and
    /// box-drawing characters (tmux pane borders).
    private static func stops(_ ch: Character) -> Bool {
        if ch.isWhitespace || "\"<>`".contains(ch) { return true }
        return ch.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) || $0.value < 0x20 }
    }

    /// Drop trailing sentence punctuation and closing brackets that have no
    /// opener in the run, so `(see https://x.dev/a).` yields `https://x.dev/a`.
    private static func trimmed(_ run: ArraySlice<Character>) -> ArraySlice<Character> {
        var run = run
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = run.last {
            if ".,;:!?'".contains(last) {
                run.removeLast()
            } else if let open = pairs[last],
                      run.filter({ $0 == last }).count > run.filter({ $0 == open }).count {
                run.removeLast()
            } else {
                break
            }
        }
        return run
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Terminal cells taken by `ch`: two for East Asian wide and emoji, else one.
    static func cellWidth(_ ch: Character) -> Int {
        guard let first = ch.unicodeScalars.first else { return 1 }
        if first.properties.isEmojiPresentation { return 2 }
        if ch.unicodeScalars.contains(where: { $0.value == 0xFE0F }),
           first.properties.isEmoji { return 2 }
        switch first.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
