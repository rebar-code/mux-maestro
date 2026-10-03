import Foundation

/// One thing a pane's agent made, as the Artifacts panel lists it.
struct Artifact: Equatable {
    enum Kind: Equatable { case image, file }
    let kind: Kind
    /// Absolute and standardized.
    let path: String
    /// Timestamp of the newest transcript record that mentions the path.
    let at: Date
    /// False for a made file that is gone. It stays listed, marked missing.
    let exists: Bool

    var name: String { (path as NSString).lastPathComponent }
    var parentDir: String { (path as NSString).deletingLastPathComponent }

    /// The panel renders these instead of showing their source.
    var isMarkdown: Bool {
        ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The panel shows these with syntax highlighting. HTML is left out: Quick
    /// Look draws the page, which says more than its source.
    var isCode: Bool {
        let base = name.lowercased()
        return Self.codeNames.contains(base)
            || Self.codeExtensions.contains((base as NSString).pathExtension)
    }

    /// The languages `Resources/preview/index.html` maps to a grammar.
    private static let codeExtensions: Set<String> = [
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "svelte", "vue", "xml",
        "css", "scss", "sass", "less", "json",
        "py", "rb", "go", "rs", "swift", "sh", "bash", "zsh", "fish",
        "yml", "yaml", "toml", "ini", "conf",
        "c", "h", "cpp", "cc", "cxx", "hpp",
        "java", "kt", "kts", "php", "sql", "lua", "pl", "r", "dart", "scala",
    ]
    private static let codeNames: Set<String> = ["makefile", "dockerfile"]
}

/// A markdown artifact's text, made ready for the renderer.
enum ArtifactMarkdown {
    /// Larger markdown and code files keep the Quick Look preview.
    static let maxBytes = 1_000_000

    /// `text` with `\n` line endings and its YAML front matter as a fenced
    /// block. Left as is, markdown reads the closing `---` as a heading
    /// underline and draws the keys as one big title.
    static func source(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let close = lines.dropFirst().firstIndex(of: "---"), close > 1
        else { return normalized }
        lines[0] = "```"
        lines[close] = "```"
        return lines.joined(separator: "\n")
    }
}

/// What a transcript says, before any disk check. `made` holds the paths an
/// edit tool wrote; `imageCandidates` holds image paths that appeared anywhere
/// the agent acted (tool input, tool result, its own text). A candidate only
/// counts once the disk shows it was written during the thread.
struct ArtifactMentions: Equatable {
    var threadStart: Date?
    var made: [String: Date] = [:]
    var imageCandidates: [String: Date] = [:]
    /// `http(s)` URLs from the agent's own text (never tool input or results:
    /// those are full of URLs the agent only read). URL → newest mention.
    var urls: [String: Date] = [:]
    /// The cwd of the newest record that carried one. Relative paths resolve
    /// against it.
    var cwd = ""

    /// Fold one JSONL record (Claude Code transcript or Codex rollout) in.
    mutating func ingest(line: Substring) {
        guard let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        let at = (record["timestamp"] as? String).flatMap(ArtifactScanner.parseTimestamp)
        if let at, threadStart == nil { threadStart = at }
        if let c = record["cwd"] as? String, !c.isEmpty { cwd = c }
        let when = at ?? threadStart ?? .distantPast
        switch record["type"] as? String {
        case "assistant", "user":
            ingestClaude(record, at: when)
        case "session_meta", "turn_context":
            if let c = (record["payload"] as? [String: Any])?["cwd"] as? String, !c.isEmpty { cwd = c }
        case "response_item":
            ingestCodex(record["payload"] as? [String: Any] ?? [:], at: when)
        default:
            break
        }
    }

    private static let editTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    private mutating func ingestClaude(_ record: [String: Any], at: Date) {
        let message = record["message"] as? [String: Any]
        guard let blocks = message?["content"] as? [[String: Any]] else { return }
        let assistant = record["type"] as? String == "assistant"
        for block in blocks {
            switch block["type"] as? String {
            case "tool_use" where assistant:
                let input = block["input"] as? [String: Any] ?? [:]
                if let name = block["name"] as? String, Self.editTools.contains(name),
                   let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                    note(made: path, at: at)
                }
                noteImages(in: ArtifactScanner.strings(in: input), at: at)
            case "tool_result" where !assistant:
                noteImages(in: ArtifactScanner.strings(in: block["content"] ?? ""), at: at)
            case "text" where assistant:
                let text = block["text"] as? String ?? ""
                noteImages(in: [text], at: at)
                noteURLs(in: [text], at: at)
            default:
                break
            }
        }
    }

    private mutating func ingestCodex(_ payload: [String: Any], at: Date) {
        switch payload["type"] as? String {
        case "function_call", "custom_tool_call", "local_shell_call":
            let texts = ArtifactScanner.strings(in: payload)
            for text in texts { ArtifactScanner.patchPaths(in: text).forEach { note(made: $0, at: at) } }
            noteImages(in: texts, at: at)
        case "function_call_output", "custom_tool_call_output":
            noteImages(in: ArtifactScanner.strings(in: payload["output"] ?? ""), at: at)
        case "message" where payload["role"] as? String == "assistant":
            let texts = ArtifactScanner.strings(in: payload["content"] ?? "")
            noteImages(in: texts, at: at)
            noteURLs(in: texts, at: at)
        default:
            break
        }
    }

    private mutating func note(made path: String, at: Date) {
        let abs = ArtifactScanner.absolute(path, cwd: cwd)
        made[abs] = max(made[abs] ?? at, at)
    }

    private mutating func noteURLs(in texts: [String], at: Date) {
        for text in texts {
            for url in ArtifactScanner.urls(in: text) { urls[url] = max(urls[url] ?? at, at) }
        }
    }

    private mutating func noteImages(in texts: [String], at: Date) {
        for text in texts {
            for path in ArtifactScanner.imagePaths(in: text) {
                let abs = ArtifactScanner.absolute(path, cwd: cwd)
                imageCandidates[abs] = max(imageCandidates[abs] ?? at, at)
            }
        }
    }
}

/// Turns transcript lines into the Artifacts panel's list. Pure: the disk is
/// reached only through the injected `fileExists` / `mtime`.
enum ArtifactScanner {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf"]

    static func scan(
        lines: [String], cwd: String, threadStart: Date?,
        fileExists: (String) -> Bool, mtime: (String) -> Date?
    ) -> [Artifact] {
        var mentions = ArtifactMentions(cwd: cwd)
        for line in lines { mentions.ingest(line: Substring(line)) }
        if let threadStart { mentions.threadStart = threadStart }
        return resolve(mentions, fileExists: fileExists, mtime: mtime)
    }

    /// Made paths always list (missing ones marked). An image candidate lists
    /// only when it exists and was modified at or after the thread's start:
    /// that is what separates a screenshot the agent took from an old asset it
    /// merely mentioned. Newest first; ties by path.
    static func resolve(
        _ mentions: ArtifactMentions,
        fileExists: (String) -> Bool, mtime: (String) -> Date?
    ) -> [Artifact] {
        var out: [Artifact] = mentions.made.map { path, at in
            Artifact(kind: kind(of: path), path: path, at: at, exists: fileExists(path))
        }
        for (path, at) in mentions.imageCandidates where mentions.made[path] == nil {
            guard fileExists(path), let modified = mtime(path),
                  modified >= (mentions.threadStart ?? .distantPast) else { continue }
            out.append(Artifact(kind: .image, path: path, at: at, exists: true))
        }
        return out.sorted { $0.at != $1.at ? $0.at > $1.at : $0.path < $1.path }
    }

    static func kind(of path: String) -> Artifact.Kind {
        imageExtensions.contains((path as NSString).pathExtension.lowercased()) ? .image : .file
    }

    /// Image-looking paths in free text. Not part of a URL (nothing glued on
    /// before), and the extension must end the path (`a.png.bak` is not an image).
    static func imagePaths(in text: String) -> [String] {
        guard text.count < 2_000_000 else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return imageRegex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static let imageRegex = try! NSRegularExpression(
        pattern: #"(?<![\w/.~:@%+=,-])((?:~|\.{1,2})?/?(?:[\w@%+=,.~-]+/)*[\w@%+=,~-][\w@%+=,.~-]*\.(?:png|jpe?g|gif|webp|svg|pdf))(?![\w/-]|\.\w)"#,
        options: [.caseInsensitive])

    /// Paths a Codex `apply_patch` adds or updates, in order. A `Move to:` line
    /// replaces the `Update File:` before it. Deletes are not artifacts. The
    /// patch often sits JSON- or JS-escaped inside a tool input, so a path also
    /// ends at a backslash or quote.
    static func patchPaths(in text: String) -> [String] {
        guard text.contains("*** ") else { return [] }
        var out: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in patchRegex.matches(in: text, range: range) {
            guard let op = Range(match.range(at: 1), in: text),
                  let p = Range(match.range(at: 2), in: text) else { continue }
            let path = text[p].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            switch text[op] {
            case "Move to":
                if !out.isEmpty { out.removeLast() }
                out.append(path)
            case "Delete File":
                continue
            default:
                out.append(path)
            }
        }
        return out
    }

    private static let patchRegex = try! NSRegularExpression(
        pattern: #"\*\*\* (Add File|Update File|Move to|Delete File): ([^\n\\"]+)"#)

    /// Every string inside a JSON value, depth first. Tool inputs and results
    /// nest their text at varying depths; this reads them all.
    static func strings(in value: Any) -> [String] {
        switch value {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(strings(in:))
        case let d as [String: Any]: return d.values.flatMap(strings(in:))
        default: return []
        }
    }

    static func absolute(_ path: String, cwd: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        if !p.hasPrefix("/"), !cwd.isEmpty { p = (cwd as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let isoLock = NSLock()

    static func parseTimestamp(_ s: String) -> Date? {
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }
}

/// A server this pane's process tree is listening on, as Running reports it.
struct ArtifactRunningServer: Equatable {
    let port: Int
    let url: String?
}

/// A Servers or Links row.
struct ArtifactWebItem: Equatable {
    let url: String
    let host: String
    /// Path plus query, "" for a bare origin.
    let path: String
    /// Newest mention in the agent's text; nil for a server it never named.
    let at: Date?
    /// Servers: whether something listens on the port. nil when Running does
    /// not know yet (never shown as dead), and always nil for links.
    let live: Bool?
}

extension ArtifactScanner {
    /// `http(s)` URLs in free text. A URL ends at whitespace, a quote, `<>`, a
    /// backtick, or a `)`/`]` that closes Markdown; trailing sentence
    /// punctuation and Markdown emphasis are not part of it. The brackets of
    /// an IPv6 host (`http://[::1]:3000`) do not end it.
    static func urls(in text: String) -> [String] {
        guard text.contains("http") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return urlRegex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            var url = String(text[r])
            while let last = url.last, ".,;:!?'*".contains(last) { url.removeLast() }
            // A wildcard host (`https://*.example.com`) is a pattern, not a link.
            guard let host = URLComponents(string: url)?.host, !host.isEmpty,
                  !host.contains("*") else { return nil }
            return url
        }
    }

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://(?:\[[0-9a-f:.]+\])?[^\s<>"'`)\]]*"#, options: [.caseInsensitive])

    /// Loopback, the unspecified address, and mDNS / `.localhost` names.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(h)
            || h.hasSuffix(".local") || h.hasSuffix(".localhost")
    }

    /// Split the agent's URLs into local servers and links. One server row per
    /// port: it opens the page the agent named most recently on that port, or
    /// Running's URL when the agent never named it. When Running saw the
    /// server speak https, the named page opens over https too. Live first,
    /// then by port. Links: every other URL, newest first.
    static func web(
        urls: [String: Date], running: [ArtifactRunningServer], runningKnown: Bool
    ) -> (servers: [ArtifactWebItem], links: [ArtifactWebItem]) {
        var links: [ArtifactWebItem] = []
        var named: [Int: (url: String, at: Date)] = [:]
        for (url, at) in urls {
            guard let c = URLComponents(string: url), let host = c.host else { continue }
            if isLocalHost(host) {
                let port = c.port ?? (c.scheme?.lowercased() == "https" ? 443 : 80)
                if let seen = named[port], seen.at > at || (seen.at == at && seen.url < url) { continue }
                named[port] = (url, at)
            } else {
                links.append(ArtifactWebItem(
                    url: url, host: host, path: pathAndQuery(c), at: at, live: nil))
            }
        }
        let livePorts = Set(running.map(\.port))
        var servers: [(port: Int, item: ArtifactWebItem)] = []
        for server in running {
            var url = named[server.port]?.url ?? server.url ?? "http://localhost:\(server.port)/"
            if server.url?.lowercased().hasPrefix("https://") == true,
               var c = URLComponents(string: url), c.scheme?.lowercased() == "http" {
                c.scheme = "https"
                url = c.string ?? url
            }
            servers.append((server.port, item(url, at: named[server.port]?.at, live: true)))
        }
        for (port, mention) in named where !livePorts.contains(port) {
            servers.append((port, item(mention.url, at: mention.at, live: runningKnown ? false : nil)))
        }
        servers.sort { a, b in
            let la = a.item.live == true, lb = b.item.live == true
            return la != lb ? la : a.port < b.port
        }
        links.sort { ($0.at ?? .distantPast, $1.url) > ($1.at ?? .distantPast, $0.url) }
        return (servers.map(\.item), links)
    }

    private static func item(_ url: String, at: Date?, live: Bool?) -> ArtifactWebItem {
        let c = URLComponents(string: url)
        let port = c?.port.map { ":\($0)" } ?? ""
        return ArtifactWebItem(
            url: url, host: (c?.host ?? url) + port, path: c.map(pathAndQuery) ?? "", at: at, live: live)
    }

    private static func pathAndQuery(_ c: URLComponents) -> String {
        let path = c.percentEncodedPath == "/" ? "" : c.percentEncodedPath
        return path + (c.percentEncodedQuery.map { "?\($0)" } ?? "")
    }
}

/// Reads agent transcripts for the Artifacts panel incrementally: each
/// transcript keeps a byte offset, and a read parses only the whole lines
/// appended since. Safe to call from any queue.
final class ArtifactTranscriptReader {
    private struct Entry {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var mentions = ArtifactMentions()
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var located: [String: String] = [:]
    /// Lines parsed so far. For tests.
    private(set) var linesParsed = 0

    /// The mentions in `path` so far, or nil when it cannot be read. Unchanged
    /// size ⇒ no read. A shorter file was rewritten, so it starts over.
    func mentions(transcript path: String) -> ArtifactMentions? {
        lock.lock()
        defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return nil }
        var entry = entries[path] ?? Entry()
        if size < entry.size { entry = Entry() }
        if size != entry.size || entries[path] == nil {
            entry.size = size
            read(path, into: &entry)
        }
        entries[path] = entry
        return entry.mentions
    }

    private func read(_ path: String, into entry: inout Entry) {
        guard entry.size > entry.offset,
              let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: entry.offset)) != nil,
              let data = try? handle.read(upToCount: Int(entry.size - entry.offset)),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        else { return }
        let whole = data[data.startIndex...lastNewline]
        entry.offset += UInt64(whole.count)
        for line in whole.split(separator: UInt8(ascii: "\n")) {
            guard let text = String(data: Data(line), encoding: .utf8) else { continue }
            entry.mentions.ingest(line: Substring(text))
            linesParsed += 1
        }
    }

    /// The transcript path for a pane's agent thread, cached per session id.
    func transcript(claudeSessionId: String?, codexSessionId: String?) -> String? {
        let key = claudeSessionId ?? codexSessionId ?? ""
        guard !key.isEmpty else { return nil }
        lock.lock()
        if let hit = located[key], FileManager.default.fileExists(atPath: hit) {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found = Self.locate(
            claudeSessionId: claudeSessionId, codexSessionId: codexSessionId,
            claudeProjects: home.appendingPathComponent(".claude/projects"),
            codexSessions: home.appendingPathComponent(".codex/sessions"))
        lock.lock()
        located[key] = found
        lock.unlock()
        return found
    }

    /// Claude: `<projects>/<any folder>/<id>.jsonl`. Codex: the rollout under
    /// `<sessions>/YYYY/MM/DD/` whose name ends in `-<id>.jsonl`, newest day first.
    static func locate(
        claudeSessionId: String?, codexSessionId: String?,
        claudeProjects: URL, codexSessions: URL
    ) -> String? {
        let fm = FileManager.default
        if let id = claudeSessionId, !id.isEmpty {
            let folders = (try? fm.contentsOfDirectory(atPath: claudeProjects.path)) ?? []
            for folder in folders.sorted() {
                let path = claudeProjects.appendingPathComponent(folder)
                    .appendingPathComponent("\(id).jsonl").path
                if fm.fileExists(atPath: path) { return path }
            }
        }
        if let id = codexSessionId, !id.isEmpty {
            func children(_ url: URL) -> [URL] {
                ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                    .sorted(by: >).map { url.appendingPathComponent($0) }
            }
            let suffix = "-\(id).jsonl"
            for year in children(codexSessions) {
                for month in children(year) {
                    for day in children(month) {
                        if let hit = children(day).first(where: { $0.lastPathComponent.hasSuffix(suffix) }) {
                            return hit.path
                        }
                    }
                }
            }
        }
        return nil
    }
}

