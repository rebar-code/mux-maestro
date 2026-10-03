import XCTest

// MobileArtifacts.swift compiles into this test target. The file rules are
// asserted against real files, links and folders in a temporary directory.
final class MobileArtifactsTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("acme-app") }
    private var outside: URL { root.appendingPathComponent("outside") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-artifacts-\(UUID().uuidString)")
        for folder in [project, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws -> String {
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func artifact(_ path: String, exists: Bool = true) -> Artifact {
        Artifact(
            kind: ArtifactScanner.kind(of: path), path: path,
            at: Date(timeIntervalSince1970: 1_700_000_000), exists: exists)
    }

    private func thread(host: Host = .local, cwd: String) -> MobileThread {
        MobileThread(
            id: "\(host.name):12", host: host, hostColor: "#3291ff", session: "acme-app", window: 1,
            name: "checkout-fix", pane: "%12", command: "claude", cwd: cwd, status: .busy,
            since: nil, idleStage: .awake, lastPrompt: nil, lastActivityAt: nil, sessionActivity: 0,
            claudeSessionId: "c1", codexSessionId: nil)
    }

    private func object(_ response: MobileResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testAnIdIs32HexCharactersAndSaysNothingOfThePath() {
        let id = MobileArtifacts.id(path: "/Users/me/acme-app/PLAN.md")
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(id, MobileArtifacts.id(path: "/Users/me/acme-app/PLAN.md"))
        XCTAssertNotEqual(id, MobileArtifacts.id(path: "/Users/me/acme-app/plan.md"))
    }

    func testSecretLookingFilesAreNeverListed() {
        for path in [
            "/Users/me/acme-app/.env", "/Users/me/acme-app/.env.local", "/Users/me/acme-app/.ENV.production",
            "/Users/me/acme-app/certs/server.pem", "/Users/me/acme-app/certs/server.key",
            "/Users/me/acme-app/dist/app.p12", "/Users/me/acme-app/dist/app.pfx",
            "/Users/me/Library/Keychains/login.keychain", "/Users/me/.ssh/config",
            "/Users/me/.ssh/id_ed25519.pub", "/Users/me/keys/id_rsa", "/Users/me/keys/id_ed25519",
            "/Users/me/keys/id_ecdsa", "/Users/me/keys/id_dsa", "/Users/me/.aws/config",
            "/Users/me/.gnupg/pubring.kbx", "/Users/me/.netrc", "/Users/me/acme-app/.npmrc",
            "/Users/me/.aws/credentials", "/Users/me/acme-app/credentials",
        ] {
            XCTAssertTrue(MobileArtifacts.isSecret(path), path)
        }
        for path in [
            "/Users/me/acme-app/PLAN.md", "/Users/me/acme-app/src/env.ts", "/Users/me/acme-app/keys.md",
            "/Users/me/acme-app/id_rsa.pub", "/Users/me/acme-app/docs/credentials.md",
            "/Users/me/acme-app/src/keychain.swift",
        ] {
            XCTAssertFalse(MobileArtifacts.isSecret(path), path)
        }
        let listed = MobileArtifacts.files(
            ([artifact("/Users/me/acme-app/.env"), artifact("/Users/me/acme-app/PLAN.md")], []),
            size: { _ in 12 })
        XCTAssertEqual(listed.map(\.artifact.name), ["PLAN.md"])
    }

    func testTheKindAndTheContentTypeComeFromAFixedMap() {
        let expected: [(String, MobileArtifactKind, String)] = [
            ("a.png", .image, "image/png"), ("a.JPG", .image, "image/jpeg"),
            ("a.jpeg", .image, "image/jpeg"), ("a.gif", .image, "image/gif"),
            ("a.webp", .image, "image/webp"), ("a.svg", .image, "image/svg+xml"),
            ("a.pdf", .pdf, "application/pdf"), ("a.html", .html, "text/html; charset=utf-8"),
            ("a.htm", .html, "text/html; charset=utf-8"),
            ("PLAN.md", .markdown, "text/plain; charset=utf-8"),
            ("a.ts", .code, "text/plain; charset=utf-8"), ("Makefile", .code, "text/plain; charset=utf-8"),
            ("a.log", .text, "text/plain; charset=utf-8"), ("a.csv", .text, "text/plain; charset=utf-8"),
            ("a.zip", .other, "application/octet-stream"), ("a", .other, "application/octet-stream"),
            // The last extension decides: a page is never served as an image.
            ("a.png.html", .html, "text/html; charset=utf-8"),
        ]
        for (name, kind, type) in expected {
            let made = artifact("/Users/me/acme-app/" + name)
            XCTAssertEqual(MobileArtifacts.kind(of: made), kind, name)
            XCTAssertEqual(MobileArtifacts.contentType(for: made), type, name)
        }
    }

    func testListsFilesAndLinksAndNothingForARemoteThread() throws {
        let plan = try write("# Plan", to: project.appendingPathComponent("PLAN.md"))
        let gone = project.appendingPathComponent("gone.ts").path
        let link = ArtifactWebItem(
            url: "https://example.com/docs", host: "example.com", path: "/docs",
            at: Date(timeIntervalSince1970: 1_700_000_100), live: nil)
        let source: MobileArtifactSource = ([artifact(plan), artifact(gone, exists: false)], [link])

        let body = try object(MobileArtifacts.list(thread: thread(cwd: project.path)) { _ in source })
        XCTAssertEqual(body["remote"] as? Bool, false)
        let files = try XCTUnwrap(body["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0]["id"] as? String, MobileArtifacts.id(path: plan))
        XCTAssertEqual(files[0]["name"] as? String, "PLAN.md")
        XCTAssertEqual(files[0]["dir"] as? String, project.path)
        XCTAssertEqual(files[0]["kind"] as? String, "markdown")
        XCTAssertEqual(files[0]["mime"] as? String, "text/plain; charset=utf-8")
        XCTAssertEqual(files[0]["size"] as? Int, 6)
        XCTAssertEqual(files[0]["at"] as? Int, 1_700_000_000)
        XCTAssertEqual(files[0]["exists"] as? Bool, true)
        XCTAssertEqual(files[1]["exists"] as? Bool, false)
        XCTAssertTrue(files[1]["size"] is NSNull)
        let links = try XCTUnwrap(body["links"] as? [[String: Any]])
        XCTAssertEqual(links.first?["url"] as? String, "https://example.com/docs")
        XCTAssertEqual(links.first?["at"] as? Int, 1_700_000_100)

        // No transcript: empty lists, not an error.
        let empty = try object(MobileArtifacts.list(thread: thread(cwd: project.path)) { _ in nil })
        XCTAssertEqual((empty["files"] as? [Any])?.count, 0)

        // Another host: the source is not asked at all.
        let devbox = Host(name: "devbox", sshAlias: "devbox")
        var asked = 0
        let remote = try object(MobileArtifacts.list(thread: thread(host: devbox, cwd: "/home/me")) { _ in
            asked += 1
            return source
        })
        XCTAssertEqual(remote["remote"] as? Bool, true)
        XCTAssertEqual((remote["files"] as? [Any])?.count, 0)
        XCTAssertEqual(
            MobileArtifacts.file(
                id: MobileArtifacts.id(path: plan), thread: thread(host: devbox, cwd: project.path)
            ) { _ in
                asked += 1
                return source
            }.status, 404)
        XCTAssertEqual(asked, 0)
    }

    func testAFileIsServedByItsIdWithTheHeadersOfAnUntrustedFile() throws {
        let page = try write("<script>alert(1)</script>", to: project.appendingPathComponent("report.html"))
        let source: MobileArtifactSource = ([artifact(page)], [])
        let served = MobileArtifacts.file(
            id: MobileArtifacts.id(path: page), thread: thread(cwd: project.path)) { _ in source }
        XCTAssertEqual(served.status, 200)
        XCTAssertEqual(String(decoding: served.body, as: UTF8.self), "<script>alert(1)</script>")
        XCTAssertEqual(served.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(served.headers["Cache-Control"], "no-store")
        XCTAssertEqual(
            served.headers["Content-Security-Policy"],
            "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:")
        XCTAssertEqual(served.headers["Content-Disposition"], "attachment")
        XCTAssertEqual(served.headers["Cross-Origin-Resource-Policy"], "same-origin")
        XCTAssertTrue(
            String(decoding: served.serialized(), as: UTF8.self)
                .contains("X-Content-Type-Options: nosniff\r\n"))
    }

    func testAnIdThatIsNotInTheListIsA404WhateverItLooksLike() throws {
        let plan = try write("# Plan", to: project.appendingPathComponent("PLAN.md"))
        let secret = try write("TOKEN=1", to: project.appendingPathComponent(".env"))
        let other = try write("other", to: outside.appendingPathComponent("notes.txt"))
        let source: MobileArtifactSource = ([artifact(plan), artifact(secret)], [])
        for id in [
            "", "PLAN.md", plan, other, "../PLAN.md", "../../outside/notes.txt", "..", "/etc/passwd",
            "%2e%2e%2fPLAN.md", "..%2f..%2fetc%2fpasswd", "file://" + plan,
            MobileArtifacts.id(path: other), MobileArtifacts.id(path: plan).uppercased(),
            MobileArtifacts.id(path: plan) + "/../" + MobileArtifacts.id(path: other),
            // Listed by the scanner, kept from the phone.
            MobileArtifacts.id(path: secret),
        ] {
            let refused = MobileArtifacts.file(id: id, thread: thread(cwd: project.path)) { _ in source }
            XCTAssertEqual(refused.status, 404, id)
            XCTAssertEqual(String(decoding: refused.body, as: UTF8.self), #"{"error":"not_found"}"#, id)
        }
    }

    func testASymlinkIsNeverFollowedOutOfTheListedPath() throws {
        let fm = FileManager.default
        let target = try write("outside the project", to: outside.appendingPathComponent("notes.txt"))
        let cwd = project.path

        // The listed file is itself a link.
        let link = project.appendingPathComponent("shot.png").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertEqual(MobileArtifacts.read(path: link, cwd: cwd), .missing)
        // Also when it points at a file of the same project.
        let inner = try write("inside", to: project.appendingPathComponent("real.txt"))
        let innerLink = project.appendingPathComponent("alias.txt").path
        try fm.createSymbolicLink(atPath: innerLink, withDestinationPath: inner)
        XCTAssertEqual(MobileArtifacts.read(path: innerLink, cwd: cwd), .missing)

        // A folder of the listed path is a link that leads out of the project.
        let folder = project.appendingPathComponent("out").path
        try fm.createSymbolicLink(atPath: folder, withDestinationPath: outside.path)
        XCTAssertEqual(MobileArtifacts.read(path: folder + "/notes.txt", cwd: cwd), .missing)
        // The same outside the project, with no directory to be inside of.
        XCTAssertEqual(MobileArtifacts.read(path: folder + "/notes.txt", cwd: ""), .missing)
        XCTAssertEqual(MobileArtifacts.read(path: folder + "/notes.txt", cwd: "/"), .missing)

        // A linked folder that stays inside the project is the project's own.
        try fm.createDirectory(at: project.appendingPathComponent("build"), withIntermediateDirectories: true)
        _ = try write("built", to: project.appendingPathComponent("build/index.html"))
        let latest = project.appendingPathComponent("latest").path
        try fm.createSymbolicLink(atPath: latest, withDestinationPath: "build")
        XCTAssertEqual(MobileArtifacts.read(path: latest + "/index.html", cwd: cwd), .data(Data("built".utf8)))

        // The route answers 404 for each.
        let source: MobileArtifactSource = ([artifact(link), artifact(folder + "/notes.txt")], [])
        for path in [link, folder + "/notes.txt"] {
            let refused = MobileArtifacts.file(
                id: MobileArtifacts.id(path: path), thread: thread(cwd: cwd)) { _ in source }
            XCTAssertEqual(refused.status, 404, path)
        }
    }

    func testOnlyAPlainFileUnderTheSizeCapIsRead() throws {
        let cwd = project.path
        let plain = try write("hello", to: project.appendingPathComponent("a.txt"))
        XCTAssertEqual(MobileArtifacts.read(path: plain, cwd: cwd), .data(Data("hello".utf8)))
        // A file outside the project is read when it is the listed path itself.
        let shot = try write("png", to: outside.appendingPathComponent("shot.png"))
        XCTAssertEqual(MobileArtifacts.read(path: shot, cwd: cwd), .data(Data("png".utf8)))
        let empty = try write("", to: project.appendingPathComponent("empty.txt"))
        XCTAssertEqual(MobileArtifacts.read(path: empty, cwd: cwd), .data(Data()))

        XCTAssertEqual(MobileArtifacts.read(path: project.appendingPathComponent("gone.txt").path, cwd: cwd), .missing)
        XCTAssertEqual(MobileArtifacts.read(path: cwd, cwd: cwd), .missing)
        XCTAssertEqual(MobileArtifacts.read(path: "/dev/null", cwd: cwd), .missing)

        XCTAssertEqual(MobileArtifacts.read(path: plain, cwd: cwd, limit: 5), .data(Data("hello".utf8)))
        XCTAssertEqual(MobileArtifacts.read(path: plain, cwd: cwd, limit: 4), .tooLarge)

        // One byte over the real cap: 413, and nothing of the file.
        let big = project.appendingPathComponent("big.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(MobileArtifacts.maxFileBytes) + 1)
        try handle.close()
        XCTAssertEqual(MobileArtifacts.maxFileBytes, 10 * 1_048_576)
        let source: MobileArtifactSource = ([artifact(big.path)], [])
        let refused = MobileArtifacts.file(
            id: MobileArtifacts.id(path: big.path), thread: thread(cwd: cwd)) { _ in source }
        XCTAssertEqual(refused.status, 413)
        XCTAssertEqual(String(decoding: refused.body, as: UTF8.self), #"{"error":"too_large"}"#)
    }

    func testTheSystemsOwnPrivateLinksAreNotAnEscape() {
        XCTAssertEqual(MobileArtifacts.unaliased("/private/tmp/shot.png"), "/tmp/shot.png")
        XCTAssertEqual(MobileArtifacts.unaliased("/private/var/folders/x/shot.png"), "/var/folders/x/shot.png")
        XCTAssertEqual(MobileArtifacts.unaliased("/private/etc"), "/etc")
        XCTAssertEqual(MobileArtifacts.unaliased("/tmp/shot.png"), "/tmp/shot.png")
        XCTAssertEqual(MobileArtifacts.unaliased("/private/tmpfile"), "/private/tmpfile")
        XCTAssertEqual(MobileArtifacts.unaliased("/private/secret/a"), "/private/secret/a")
    }
}
