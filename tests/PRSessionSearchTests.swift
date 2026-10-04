import XCTest

// PRSessionSearch.swift is compiled directly into this test target. The search
// runs the real /usr/bin/grep over fixture transcripts in a temp directory.
final class PRSessionSearchTests: XCTestCase {
    // MARK: number(fromQuery:)

    func testQueryForms() {
        XCTAssertEqual(PRSessionSearch.number(fromQuery: "784"), 784)
        XCTAssertEqual(PRSessionSearch.number(fromQuery: " #784 "), 784)
        XCTAssertEqual(PRSessionSearch.number(fromQuery: "PR 784"), 784)
        XCTAssertEqual(PRSessionSearch.number(fromQuery: "pr784"), 784)
        XCTAssertEqual(PRSessionSearch.number(fromQuery: "https://github.com/o/r/pull/784"), 784)
        XCTAssertNil(PRSessionSearch.number(fromQuery: "abc"))
        XCTAssertNil(PRSessionSearch.number(fromQuery: "0"))
        XCTAssertNil(PRSessionSearch.number(fromQuery: ""))
    }

    // MARK: parseMatches

    func testParseMatchesKeepsFirstSlugPerPath() {
        let out = """
        /a/1.jsonl:"prNumber":784,"prUrl":"https://github.com/o/acme-app/pull/784","prRepository":"o/acme-app"
        /a/1.jsonl:"prNumber":784,"prUrl":"https://github.com/o/other/pull/784"
        /b/2.jsonl:github.com/o/widget-shop/pull/784"
        /c/3.jsonl:no url here
        """
        let parsed = PRSessionSearch.parseMatches(out)
        XCTAssertEqual(parsed.map(\.path), ["/a/1.jsonl", "/b/2.jsonl"])
        XCTAssertEqual(parsed.map(\.slug), ["o/acme-app", "o/widget-shop"])
    }

    func testDedupeKeepsNewestPerConversation() {
        let old = PRSessionHit(agent: .codex, sessionId: "x", cwd: "/a", slug: "o/r",
                               lastActive: Date(timeIntervalSince1970: 1))
        let new = PRSessionHit(agent: .codex, sessionId: "x", cwd: "/a", slug: "o/r",
                               lastActive: Date(timeIntervalSince1970: 5))
        let other = PRSessionHit(agent: .claude, sessionId: "x", cwd: "/b", slug: "o/r",
                                 lastActive: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(PRSessionSearch.dedupe([old, other, new]), [new, other])
    }

    // MARK: search over fixture transcripts

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prsearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, _ lines: [String]) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testSearchFindsClaudePrLinkAndCodexUrlWithGrep() throws {
        try searchFindsClaudePrLinkAndCodexUrl(rg: nil)
    }

    func testSearchFindsClaudePrLinkAndCodexUrlWithRipgrep() throws {
        guard let rg = PRSessionSearch.rgPath else { throw XCTSkip("ripgrep is not installed") }
        try searchFindsClaudePrLinkAndCodexUrl(rg: rg)
    }

    private func searchFindsClaudePrLinkAndCodexUrl(rg: String?) throws {
        let linked = "20b68ff0-9b00-4afc-adb2-520e0aff2baa"
        let mentioned = "8cc97900-469b-4e49-80b5-acf718a51478"
        let other = "ae96433b-a04c-4391-b332-9c3edc6d54c6"
        try write("claude/-proj/\(linked).jsonl", [
            #"{"type":"user","cwd":"/Users/j/code/acme-app","sessionId":"\#(linked)"}"#,
            #"{"type":"pr-link","sessionId":"\#(linked)","prNumber":784,"prUrl":"https://github.com/o/acme-app/pull/784","prRepository":"o/acme-app"}"#,
        ])
        // Only mentions the URL (e.g. a grep for it): not a pr-link, no match.
        try write("claude/-proj/\(mentioned).jsonl", [
            #"{"type":"user","cwd":"/Users/j/code/mux"}"#,
            #"{"type":"user","message":"see https://github.com/o/acme-app/pull/784 and \"prNumber\":784"}"#,
        ])
        // A different PR whose number starts with 784.
        try write("claude/-proj/\(other).jsonl", [
            #"{"type":"user","cwd":"/Users/j/code/widget-shop"}"#,
            #"{"type":"pr-link","prNumber":7840,"prUrl":"https://github.com/o/widget-shop/pull/7840"}"#,
        ])
        // Subagent transcripts are not resumable.
        try write("claude/-proj/\(linked)/subagents/agent-a1.jsonl", [
            #"{"cwd":"/x","type":"pr-link","prNumber":784,"prUrl":"https://github.com/o/acme-app/pull/784"}"#,
        ])
        try write("codex/2026/09/29/rollout-a.jsonl", [
            #"{"type":"session_meta","payload":{"session_id":"01a0dd8e-98fb-7902-9924-bf7c90dfc4fb","cwd":"/Users/j/code/widget-shop"}}"#,
            #"{"type":"event","text":"opened https://github.com/o/widget-shop/pull/784."}"#,
        ])
        try write("codex/2026/09/29/rollout-b.jsonl", [
            #"{"type":"session_meta","payload":{"session_id":"02","cwd":"/Users/j/code/widget-shop"}}"#,
            #"{"type":"event","text":"https://github.com/o/widget-shop/pull/7841"}"#,
        ])

        let hits = PRSessionSearch.search(
            number: 784,
            claudeDir: root.appendingPathComponent("claude").path,
            codexDir: root.appendingPathComponent("codex").path, rg: rg)
        let summary = hits.map { "\($0.agent.rawValue) \($0.sessionId) \($0.slug) \($0.cwd)" }.sorted()
        XCTAssertEqual(summary, [
            "claude \(linked) o/acme-app /Users/j/code/acme-app",
            "codex 01a0dd8e-98fb-7902-9924-bf7c90dfc4fb o/widget-shop /Users/j/code/widget-shop",
        ])
    }

    func testSearchWithMissingDirsFindsNothing() {
        XCTAssertEqual(PRSessionSearch.search(
            number: 1, claudeDir: root.appendingPathComponent("nope").path,
            codexDir: root.appendingPathComponent("nope2").path), [])
    }

    func testExistingDirectoryWalksUpToAnAncestor() {
        let gone = root.appendingPathComponent("worktree/deleted/deeper").path
        XCTAssertEqual(PRSessionSearch.existingDirectory(gone), root.path)
        XCTAssertEqual(PRSessionSearch.existingDirectory(root.path), root.path)
    }
}
