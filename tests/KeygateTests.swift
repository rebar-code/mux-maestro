import XCTest

// Keygate.swift compiles directly into this test target. Nothing here runs a
// real keygate: the binary check takes its file facts from the test.
final class KeygateTests: XCTestCase {
    // MARK: Ids

    func testAValidIDIsOneToSixtyFourLowercaseHexCharacters() {
        for id in ["0", "a", "ab12", "0123456789abcdef", String(repeating: "f", count: 64)] {
            XCTAssertTrue(Keygate.isValidID(id), id)
        }
    }

    func testAnythingElseIsNotAnID() {
        let bad = [
            "", "AB12", "ab-1", "g", "ab 12", "ab12\n", "\nab12", "ab\u{0}12", "ab12/../x",
            "ab12&next=1", "ab12#x", "%61", "ａｂ", "аb12", String(repeating: "a", count: 65),
        ]
        for id in bad {
            XCTAssertFalse(Keygate.isValidID(id), id.debugDescription)
            XCTAssertNil(Keygate.validID(id), id.debugDescription)
            XCTAssertNil(Keygate.approveArguments(id: id), id.debugDescription)
        }
        XCTAssertNil(Keygate.validID(nil))
    }

    // MARK: The command

    func testApproveIsTheFixedBinaryWithTwoArguments() {
        XCTAssertEqual(Keygate.binaryPath, "/usr/local/bin/keygate")
        XCTAssertEqual(Keygate.approveArguments(id: "ab12"), ["approve", "ab12"])
        XCTAssertEqual(Keygate.infoArguments, ["info", "--json"])
    }

    func testTheChildGetsAFixedPathAndNoKeygateVariables() {
        let env = Keygate.environment(from: [
            "HOME": "/Users/me", "USER": "me", "PATH": "/tmp/evil:/usr/bin",
            "KEYGATE_SOCKET": "/tmp/fake.sock", "KEYGATE_APPROVER": "/tmp/fake", "KEYGATE_URL": "x",
            "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
        ])
        XCTAssertEqual(env, ["HOME": "/Users/me", "USER": "me", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    // MARK: The binary check

    private let rootFile = Keygate.FileFacts(kind: .file, owner: 0, mode: 0o100755)
    private let rootDir = Keygate.FileFacts(kind: .directory, owner: 0, mode: 0o040755)

    private func trusted(file: Keygate.FileFacts?, dir: Keygate.FileFacts?, path: String = Keygate.binaryPath) -> Bool {
        Keygate.binaryIsTrusted(path: path) { asked in
            asked == path ? file : asked == (path as NSString).deletingLastPathComponent ? dir : nil
        }
    }

    func testARootOwnedBinaryInARootOwnedFolderIsTrusted() {
        XCTAssertTrue(trusted(file: rootFile, dir: rootDir))
        XCTAssertTrue(trusted(file: .init(kind: .file, owner: 0, mode: 0o100555), dir: rootDir))
    }

    func testABinaryThatIsMissingOrNotRootsIsNotTrusted() {
        XCTAssertFalse(trusted(file: nil, dir: rootDir))
        XCTAssertFalse(trusted(file: rootFile, dir: nil))
        XCTAssertFalse(trusted(file: .init(kind: .file, owner: 501, mode: 0o100755), dir: rootDir))
        XCTAssertFalse(trusted(file: .init(kind: .other, owner: 0, mode: 0o120755), dir: rootDir), "a link")
        XCTAssertFalse(trusted(file: .init(kind: .directory, owner: 0, mode: 0o040755), dir: rootDir))
        XCTAssertFalse(trusted(file: .init(kind: .file, owner: 0, mode: 0o100644), dir: rootDir), "not executable")
    }

    func testABinaryOthersCanWriteIsNotTrusted() {
        XCTAssertFalse(trusted(file: .init(kind: .file, owner: 0, mode: 0o100775), dir: rootDir))
        XCTAssertFalse(trusted(file: .init(kind: .file, owner: 0, mode: 0o100757), dir: rootDir))
    }

    func testAFolderThisUserOrOthersCanWriteIsNotTrusted() {
        XCTAssertFalse(trusted(file: rootFile, dir: .init(kind: .directory, owner: 501, mode: 0o040755)))
        XCTAssertFalse(trusted(file: rootFile, dir: .init(kind: .directory, owner: 0, mode: 0o040775)))
        XCTAssertFalse(trusted(file: rootFile, dir: .init(kind: .directory, owner: 0, mode: 0o041777)))
    }

    func testARelativePathIsNotTrusted() {
        XCTAssertFalse(trusted(file: rootFile, dir: rootDir, path: "keygate"))
    }

    func testTheRealCheckReadsTheFileSystem() throws {
        // /bin/ls is root's, in a folder root owns: the same rules pass it.
        XCTAssertTrue(Keygate.binaryIsTrusted(path: "/bin/ls"))
        // A file this user made is not root's.
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("keygate-\(UUID())")
        try Data("#!/bin/sh\n".utf8).write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.path)
        XCTAssertFalse(Keygate.binaryIsTrusted(path: mine.path))
        XCTAssertFalse(Keygate.binaryIsTrusted(path: "/usr/local/bin/no-such-keygate-\(UUID())"))
    }

    // MARK: Running it

    /// /bin/echo is root's, in a folder root owns, and prints its argv: what it
    /// prints is what the process was given, with no shell between.
    func testArgumentsReachTheProcessAsTheyAreWithNoShell() throws {
        let words = ["approve", "ab12; touch /tmp/x", "$(id)", "*"]
        let out = try XCTUnwrap(Keygate.run(words, timeout: 3, path: "/bin/echo"))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), words.joined(separator: " ") + "\n")
    }

    func testApproveStartsATrustedBinaryAndReportsItsExit() {
        let exited = expectation(description: "exited")
        XCTAssertTrue(Keygate.approve(id: "ab12", path: "/usr/bin/true") { exited.fulfill() })
        wait(for: [exited], timeout: 3)
    }

    func testApproveRunsNothingForABadIDOrAnUntrustedBinary() throws {
        XCTAssertFalse(Keygate.approve(id: "AB12", path: "/usr/bin/true") { XCTFail("ran") })
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("keygate-\(UUID())")
        let marker = mine.path + ".ran"
        try Data("#!/bin/sh\ntouch '\(marker)'\n".utf8).write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.path)
        XCTAssertFalse(Keygate.approve(id: "ab12", path: mine.path) { XCTFail("ran") })
        XCTAssertNil(Keygate.run(["info"], timeout: 3, path: mine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        XCTAssertNil(Keygate.run(["info"], timeout: 3, path: "/usr/bin/false"), "a failed run is nil")
    }

    // MARK: The phone origin

    private func origin(_ json: String) -> String? {
        Keygate.origin(fromInfo: Data(json.utf8))
    }

    func testTheOriginIsReadFromKeygateInfo() {
        XCTAssertEqual(origin(#"{"web_origin": "https://devbox.example.ts.net"}"#), "https://devbox.example.ts.net")
        XCTAssertEqual(origin(#"{"web_origin": "https://devbox.example.ts.net/"}"#), "https://devbox.example.ts.net")
        XCTAssertEqual(origin(#"{"web_origin": "HTTPS://DevBox.Example.ts.net:8443"}"#), "https://devbox.example.ts.net:8443")
    }

    func testNoOriginWhenKeygateHasNone() {
        XCTAssertNil(origin(#"{"web_origin": null}"#))
        XCTAssertNil(origin(#"{}"#))
        XCTAssertNil(origin(#"not json"#))
        XCTAssertNil(origin(#"["https://devbox.example.ts.net"]"#))
        XCTAssertNil(origin(#"{"web_origin": 7}"#))
    }

    func testOnlyABareHttpsOriginIsTaken() {
        let bad = [
            "http://devbox.example.ts.net", "javascript:alert(1)", "data:text/html,x", "file:///etc/passwd",
            "https://", "https:///x", "//devbox.example.ts.net", "devbox.example.ts.net",
            "https://user:pw@devbox.example.ts.net", "https://user@devbox.example.ts.net",
            "https://devbox.example.ts.net/approve", "https://devbox.example.ts.net/?id=1",
            "https://devbox.example.ts.net#x", "https://devbox.example.ts.net\n", " https://devbox.example.ts.net",
            "https://dev box.example.ts.net", "https://devbox.éxample.ts.net",
            "https://" + String(repeating: "a", count: Keygate.maxOriginLength),
        ]
        for raw in bad {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["web_origin": raw]), as: UTF8.self)
            XCTAssertNil(origin(json), raw.debugDescription)
        }
    }

    func testThePhoneLinkIsTheOriginWithTheID() {
        XCTAssertEqual(
            Keygate.phoneLink(origin: "https://devbox.example.ts.net", id: "ab12")?.absoluteString,
            "https://devbox.example.ts.net/?id=ab12")
        XCTAssertNil(Keygate.phoneLink(origin: "https://devbox.example.ts.net", id: "AB12"))
        XCTAssertNil(Keygate.phoneLink(origin: "https://devbox.example.ts.net", id: "ab12&x=1"))
        XCTAssertNil(Keygate.phoneLink(origin: "http://devbox.example.ts.net", id: "ab12"))
    }
}

final class KeygateOriginTests: XCTestCase {
    func testItFetchesOnceUntilTheAnswerIsStale() {
        var calls = 0
        let origin = KeygateOrigin(fetch: {
            calls += 1
            return "https://devbox.example.ts.net"
        }, queue: .main)
        let changed = expectation(description: "changed")
        origin.onChange = { changed.fulfill() }
        origin.refreshIfStale()
        origin.refreshIfStale()
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(origin.value, "https://devbox.example.ts.net")
        XCTAssertEqual(calls, 1)
        origin.refreshIfStale()
        XCTAssertEqual(calls, 1, "a fresh answer is kept")

        let again = expectation(description: "fetched again")
        origin.onChange = nil
        origin.refreshIfStale(now: Date().addingTimeInterval(KeygateOrigin.maxAge + 1))
        DispatchQueue.main.async { DispatchQueue.main.async { again.fulfill() } }
        wait(for: [again], timeout: 2)
        XCTAssertEqual(calls, 2)
    }
}
