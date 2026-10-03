import Foundation

/// Text clean-up and chunking for speech, ported from an earlier voice prototype
/// (`chat/voice.py` `_speechify` + `_FenceFilter`, `chat/speech.py` `_drain` +
/// `_chunk_for_speech`). Pure string functions, no AppKit, compiled into the
/// test target. Kokoro reads leftover markdown literally — an unstripped `**`
/// comes out as "asterisk asterisk" — so everything the synthesizer sees goes
/// through `Speechify.clean` first.
enum Speechify {
    static let codeOmitted = " — code omitted — "

    private static let codeFence = regex("```.*?```", [.dotMatchesLineSeparators])
    private static let link = regex("\\[([^\\]]+)\\]\\([^)]*\\)")
    private static let heading = regex("^\\s*#+\\s*", [.anchorsMatchLines])
    private static let bullet = regex("^\\s*[-*+]\\s+", [.anchorsMatchLines])
    private static let quote = regex("^\\s*>\\s?", [.anchorsMatchLines])
    /// Emphasis, code ticks, strikethrough, inline hashes.
    private static let drop = regex("[*`~#]+")
    /// snake_case and table pipes read better as a gap.
    private static let space = regex("[_|]+")

    /// Markdown cleanup so a coding-session reply reads okay aloud.
    ///
    /// Sentence chunking splits emphasis pairs across chunks ("**Deploy.** PR"
    /// becomes "**Deploy." plus "** PR"), so the structural rules run first and
    /// a final sweep drops whatever markers are left rather than requiring
    /// matched pairs.
    static func clean(_ text: String) -> String {
        var s = text
        s = codeFence.replace(s, with: codeOmitted)
        s = link.replace(s, with: "$1")
        s = heading.replace(s, with: "")
        s = bullet.replace(s, with: "")
        s = quote.replace(s, with: "")
        s = drop.replace(s, with: "")
        s = space.replace(s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Every pattern here is a literal in this file, so a failure is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// `text` split at every match, separators dropped; like Python's `re.split`
    /// without groups. Always at least one element.
    static func split(_ text: String, by re: NSRegularExpression) -> [String] {
        var parts: [String] = []
        var last = text.startIndex
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(match.range, in: text) else { continue }
            parts.append(String(text[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(text[last...]))
        return parts
    }
}

extension NSRegularExpression {
    func replace(_ text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// The capture groups of the first match, `nil` when there is none.
    func groups(in text: String) -> [String]? {
        guard let match = firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// Drops fenced code out of a delta stream before it reaches the speech buffer.
///
/// `Speechify.clean` only sees one drained chunk at a time, and a ``` block
/// routinely spans several deltas, so the open/closed state lives across them.
/// A trailing partial run of backticks is held back until the next delta in
/// case the marker itself was split.
///
/// One deliberate difference from the Python: a run that completes a marker
/// (`"```\n"` at the end of a delta) is not held back. the prototype cut the
/// last two ticks off it, so a fence closed at a delta boundary never closed
/// and the rest of the reply went unspoken.
final class FenceFilter {
    private static let tail = Speechify.regex("(?<!`)`{1,2}$")
    private static let marker = "```"

    private var open = false
    private var pending = ""

    init() {}

    func feed(_ delta: String) -> String {
        var text = pending + delta
        pending = ""
        if let match = Self.tail.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(match.range, in: text) {
            pending = String(text[r])
            text = String(text[..<r.lowerBound])
        }
        var out = ""
        for (i, part) in text.components(separatedBy: Self.marker).enumerated() {
            if i > 0 {
                open.toggle()
                if open { out += Speechify.codeOmitted }
            }
            if !open { out += part }
        }
        return out
    }

    /// Whatever was held back, once the stream ends.
    func flush() -> String {
        let held = pending
        pending = ""
        return open ? "" : held
    }
}

/// Sentence chunking so the first audio starts before the reply is complete.
enum SpeechChunker {
    private static let sentenceEnd = Speechify.regex("(?<=[.!?])\\s+")
    private static let openingClause = Speechify.regex("^(.{20,}?[,;:])\\s+(.*)", [.dotMatchesLineSeparators])
    private static let firstClause = Speechify.regex("^(.{15,60}?[,;:])\\s+(.+)")

    /// Slice speakable chunks off a growing buffer, keeping the trailing partial.
    ///
    /// Emits whole sentences once a terminator is followed by whitespace.
    /// Before the first chunk, peels an opening clause on a comma so audio can
    /// start a beat sooner.
    static func drain(_ buffer: String, started: Bool) -> (chunks: [String], remainder: String) {
        let parts = Speechify.split(buffer, by: sentenceEnd)
        if parts.count > 1 {
            let complete = parts.dropLast().filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return (Array(complete), parts[parts.count - 1])
        }
        if !started, let groups = openingClause.groups(in: buffer) {
            return ([groups[1]], groups[2])
        }
        return ([], buffer)
    }

    /// Split a complete text into synthesis chunks: whole sentences, except
    /// the first — if it is long, its opening clause is peeled off so audio can
    /// start sooner.
    static func chunks(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = Speechify.split(trimmed, by: sentenceEnd).filter { !$0.isEmpty }
        guard let first = sentences.first else { return [] }
        if first.count > 60, let groups = firstClause.groups(in: first) {
            return [groups[1], groups[2]] + sentences.dropFirst()
        }
        return sentences
    }
}
