import XCTest

final class RemoteTranscriptMirrorTests: XCTestCase {
    private var root: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var mirror: RemoteTranscriptMirror!
    /// The transcript on the far host, and what was asked of that host.
    private var far = Data()
    private var located = 0
    private var fetched: [Int] = []
    private var reachable = true

    private let session = "0f8fad5b-d9cb-469f-a165-70867728950e"

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-mirror-\(UUID().uuidString)", isDirectory: true)
        mirror = RemoteTranscriptMirror(root: root) { [unowned self] in clock }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var remote: RemoteTranscriptMirror.Remote {
        RemoteTranscriptMirror.Remote(
            locate: { [unowned self] in
                located += 1
                return reachable ? "/Users/me/.claude/projects/-Users-me-acme-app/\(session).jsonl" : nil
            },
            size: { [unowned self] _ in reachable ? far.count : nil },
            fetch: { [unowned self] _, from in
                guard reachable else { return nil }
                fetched.append(from)
                return from >= far.count ? Data() : Data(far.dropFirst(from))
            })
    }

    /// Ask for the copy a second later, so the rate limit is not in the way.
    private func mirrored(host: String = "devbox", id: String? = nil) -> String? {
        clock = clock.addingTimeInterval(1)
        return mirror.file(host: host, sessionId: id ?? session, remote: remote)
    }

    private func text(_ path: String?) -> String? {
        path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    func testTheCopyHasTheSessionsNameAndIsPrivate() throws {
        far = Data("{\"a\":1}\n".utf8)
        let path = try XCTUnwrap(mirrored())
        XCTAssertEqual(path, root.appendingPathComponent("devbox/\(session).jsonl").path)
        // The chat tells sessions apart by this name.
        XCTAssertEqual(MobileChat.session(path: path), session)
        XCTAssertEqual(text(path), "{\"a\":1}\n")
        let mode = { (path: String) in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        }
        XCTAssertEqual(mode(root.appendingPathComponent("devbox").path), 0o700)
        XCTAssertEqual(mode(root.path), 0o700)
        XCTAssertEqual(mode(path), 0o600)
    }

    func testNewLinesAreAppendedFromWhereTheCopyStopped() {
        far = Data("one\n".utf8)
        let path = mirrored()
        far.append(Data("two\nthree\n".utf8))
        XCTAssertEqual(text(mirrored()), "one\ntwo\nthree\n")
        XCTAssertEqual(text(path), "one\ntwo\nthree\n")
        XCTAssertEqual(fetched, [0, 4])
        // The transcript is looked for once.
        XCTAssertEqual(located, 1)
    }

    func testHalfALineIsHeldBackUntilItIsWhole() {
        far = Data("one\n{\"half\":".utf8)
        XCTAssertEqual(text(mirrored()), "one\n")
        far.append(Data("true}\n".utf8))
        XCTAssertEqual(text(mirrored()), "one\n{\"half\":true}\n")
        // A character cut in two is bytes like any other.
        far.append(Data([0x7B, 0xC3]))
        XCTAssertEqual(text(mirrored()), "one\n{\"half\":true}\n")
        far.append(Data([0xA9, 0x7D, 0x0A]))
        XCTAssertEqual(text(mirrored()), "one\n{\"half\":true}\n{\u{e9}}\n")
    }

    func testAFileThatBecameShorterIsCopiedAgainFromItsStart() {
        far = Data("one\ntwo\nthree\n".utf8)
        XCTAssertEqual(text(mirrored()), "one\ntwo\nthree\n")
        far = Data("new\n".utf8)
        XCTAssertEqual(text(mirrored()), "new\n")
        far.append(Data("more\n".utf8))
        XCTAssertEqual(text(mirrored()), "new\nmore\n")
    }

    func testOneSessionIsFetchedAtMostOnceASecond() {
        far = Data("one\n".utf8)
        let path = mirrored()
        far.append(Data("two\n".utf8))
        // Within the same second: the copy as it is, and no question to the host.
        XCTAssertEqual(mirror.file(host: "devbox", sessionId: session, remote: remote), path)
        clock = clock.addingTimeInterval(0.5)
        XCTAssertEqual(mirror.file(host: "devbox", sessionId: session, remote: remote), path)
        XCTAssertEqual(text(path), "one\n")
        XCTAssertEqual(fetched, [0])
        XCTAssertEqual(text(mirrored()), "one\ntwo\n")
        // Another session of the same host is not held up by this one.
        let other = "11111111-2222-3333-4444-555555555555"
        XCTAssertNotNil(mirror.file(host: "devbox", sessionId: other, remote: remote))
    }

    func testALongTranscriptIsCopiedFromItsEndStartingOnALine() throws {
        let line = String(repeating: "x", count: 1023) + "\n"
        let lines = RemoteTranscriptMirror.cap / 1024 + 10
        // An odd first line, so the cut falls inside a line.
        far = Data(("first\n" + String(repeating: line, count: lines)).utf8)
        let path = try XCTUnwrap(mirrored())
        let copied = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertLessThanOrEqual(copied.count, RemoteTranscriptMirror.cap)
        XCTAssertGreaterThanOrEqual(copied.count, RemoteTranscriptMirror.cap - 1024)
        XCTAssertEqual(copied.count % 1024, 0)
        XCTAssertEqual(copied.prefix(1024), Data(line.utf8))
        XCTAssertEqual(far.suffix(copied.count), copied)
        // What comes later lands after it, at the right place.
        far.append(Data("last\n".utf8))
        let after = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(mirrored())))
        XCTAssertEqual(after, copied + Data("last\n".utf8))
        XCTAssertEqual(fetched.last, far.count - 5)
    }

    func testANewLaunchGoesOnFromTheCopyOnDisk() {
        far = Data("one\n".utf8)
        _ = mirrored()
        far.append(Data("two\n".utf8))
        mirror = RemoteTranscriptMirror(root: root) { [unowned self] in clock }
        XCTAssertEqual(text(mirrored()), "one\ntwo\n")
        XCTAssertEqual(fetched, [0, 4])
    }

    func testAnIDThatIsNotOneIsRefusedBeforeAnythingIsAsked() {
        far = Data("one\n".utf8)
        for bad in ["", "../../etc/passwd", "a/b", "..", "a b", "a;b", "id.jsonl", "caf\u{e9}", "*",
                    String(repeating: "a", count: 129)] {
            XCTAssertNil(mirrored(id: bad), bad)
        }
        XCTAssertEqual(located, 0)
        XCTAssertEqual(fetched, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAHostsNameIsOneFolderInsideTheRoot() throws {
        far = Data("one\n".utf8)
        let path = try XCTUnwrap(mirrored(host: "up/../../there box"))
        XCTAssertTrue(path.hasPrefix(root.path + "/"))
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().path,
                       root.path)
        // A name that starts with a dot is no folder at all.
        XCTAssertNil(mirrored(host: "../../up there"))
        XCTAssertNil(RemoteTranscriptMirror.folder(host: ""))
        XCTAssertEqual(RemoteTranscriptMirror.folder(host: ".."), nil)
        XCTAssertEqual(RemoteTranscriptMirror.folder(host: "dev.box-1"), "dev.box-1")
    }

    func testAHostThatIsAwayLeavesTheCopyAsItWasAndNoCopyIsNone() {
        reachable = false
        XCTAssertNil(mirrored())
        reachable = true
        far = Data("one\n".utf8)
        let path = mirrored()
        XCTAssertNotNil(path)
        reachable = false
        far.append(Data("two\n".utf8))
        XCTAssertEqual(mirrored(), path)
        XCTAssertEqual(text(path), "one\n")
    }

    func testOldCopiesAreDeletedAndFreshOnesAreKept() throws {
        far = Data("one\n".utf8)
        let old = try XCTUnwrap(mirrored(id: "old-session"))
        let fresh = try XCTUnwrap(mirrored(id: "fresh-session"))
        let longAgo = clock.addingTimeInterval(-8 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: fresh)
        mirror.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old + ".start"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
    }
}
