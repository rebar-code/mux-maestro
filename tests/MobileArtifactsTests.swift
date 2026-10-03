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

    func testSecretLookingNamesAreNeverListed() throws {
        for name in [
            "server.pem", "server.key", "app.p12", "app.pfx", "login.keychain", "app.jks",
            "release.keystore", "vault.kdbx", "office.ovpn", "deploy.tfvars", "backup.asc", "backup.gpg",
            "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "id_custom", "ID_RSA",
            "credentials", "Credentials.json", "kubeconfig", "secrets.json", "secrets.yml",
            "secrets.yaml", "secret.json", "terraform.tfstate", "terraform.tfstate.backup",
            "htpasswd", "authorized_keys", "known_hosts", "shadow", "passwd", "master.key",
            "zsh_history", "psql_history", "service-account.json", "service-account-prod.json",
            "serviceaccount.json",
        ] {
            XCTAssertTrue(MobileArtifacts.isSecret("/Users/me/acme-app/config/" + name), name)
        }
        for name in [
            "PLAN.md", "env.ts", "keys.md", "id_rsa.pub", "id_ed25519.pub", "credentials.md",
            "keychain.swift", "history.md", "secrets.md", "passwd.ts", "identity.ts", "tfvars.md",
        ] {
            XCTAssertFalse(MobileArtifacts.isSecret("/Users/me/acme-app/src/" + name), name)
        }

        // In the thread's own folder, and still not offered.
        var made: [Artifact] = []
        for name in ["kubeconfig", "secrets.json", "terraform.tfstate", "deploy.tfvars", "app.jks", "PLAN.md"] {
            made.append(artifact(try write("x", to: project.appendingPathComponent(name))))
        }
        let listed = MobileArtifacts.files((made, []), cwd: project.path)
        XCTAssertEqual(listed.map(\.artifact.name), ["PLAN.md"])
        for hidden in made.dropLast() {
            let refused = MobileArtifacts.file(
                id: MobileArtifacts.id(path: hidden.path), thread: thread(cwd: project.path)
            ) { _ in (made, []) }
            XCTAssertEqual(refused.status, 404, hidden.name)
        }
    }

    func testNoDotfileAndNothingInADotFolderIsOffered() throws {
        for relative in [
            ".env", ".env.local", ".npmrc", ".git/config", "src/.secret/notes.md", "a/b/.hidden",
            ".github/workflows/ci.yml", "docs/.DS_Store",
        ] {
            XCTAssertTrue(MobileArtifacts.hidden(relative), relative)
        }
        for relative in ["PLAN.md", "src/env.ts", "a.b/c.d", "docs/v1.2/notes.md", ""] {
            XCTAssertFalse(MobileArtifacts.hidden(relative), relative)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: project.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        let made = [
            artifact(try write("TOKEN=1", to: project.appendingPathComponent(".env"))),
            artifact(try write("x", to: project.appendingPathComponent(".cache/report.html"))),
            artifact(try write("# Plan", to: project.appendingPathComponent("PLAN.md"))),
            // A dotfile that is gone is not offered as missing either.
            artifact(project.appendingPathComponent(".env.old").path, exists: false),
        ]
        XCTAssertEqual(
            MobileArtifacts.files((made, []), cwd: project.path).map(\.artifact.name), ["PLAN.md"])
        // The rule is about what lies under the thread's folder: a project
        // that itself lives in a dot-folder keeps its files.
        let nested = root.appendingPathComponent(".worktrees/acme-app")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let plan = artifact(try write("# Plan", to: nested.appendingPathComponent("PLAN.md")))
        XCTAssertEqual(MobileArtifacts.files(([plan], []), cwd: nested.path).map(\.artifact.name), ["PLAN.md"])
        XCTAssertEqual(
            MobileArtifacts.read(path: plan.path, cwd: nested.path, image: false), .data(Data("# Plan".utf8)))
        XCTAssertEqual(
            MobileArtifacts.read(path: made[0].path, cwd: project.path, image: false), .missing)
        XCTAssertEqual(
            MobileArtifacts.read(path: made[1].path, cwd: project.path, image: false), .missing)
    }

    /// The paths an agent can be made to name with an edit that never ran:
    /// credentials in the home folder. None is in the thread's folder.
    func testAFileOutsideTheThreadsFolderIsNotOfferedAndNotRead() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home")
        let sibling = home.appendingPathComponent("code/other-app")
        let cwd = home.appendingPathComponent("code/acme-app")
        for folder in [cwd, sibling, home.appendingPathComponent(".config/gh"),
                       home.appendingPathComponent(".kube"), home.appendingPathComponent(".docker")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var outsiders: [Artifact] = []
        for relative in [
            ".config/gh/hosts.yml", ".kube/config", ".docker/config.json", ".git-credentials",
            ".pgpass", ".zsh_history", "code/other-app/notes.md", "code/other-app/index.html",
            "notes.txt",
        ] {
            outsiders.append(artifact(try write("secret", to: home.appendingPathComponent(relative))))
        }
        // Named, and not there.
        outsiders.append(artifact(home.appendingPathComponent("code/other-app/gone.md").path, exists: false))
        outsiders.append(artifact("/etc/hosts"))
        let plan = artifact(try write("# Plan", to: cwd.appendingPathComponent("PLAN.md")))
        let source: MobileArtifactSource = (outsiders + [plan], [])

        XCTAssertEqual(MobileArtifacts.files(source, cwd: cwd.path).map(\.artifact.name), ["PLAN.md"])
        let body = try object(MobileArtifacts.list(thread: thread(cwd: cwd.path)) { _ in source })
        XCTAssertEqual((body["files"] as? [[String: Any]])?.map { $0["name"] as? String }, ["PLAN.md"])
        for outsider in outsiders {
            let refused = MobileArtifacts.file(
                id: MobileArtifacts.id(path: outsider.path), thread: thread(cwd: cwd.path)) { _ in source }
            XCTAssertEqual(refused.status, 404, outsider.path)
            XCTAssertEqual(
                MobileArtifacts.read(path: outsider.path, cwd: cwd.path, image: false), .missing, outsider.path)
        }
        // With no folder to be in, nothing is offered.
        for none in ["", "/"] {
            XCTAssertEqual(MobileArtifacts.files(source, cwd: none, tempRoots: []), [], none)
            XCTAssertEqual(MobileArtifacts.read(path: plan.path, cwd: none, image: false, tempRoots: []), .missing)
        }
        // A folder whose name starts like the thread's is another folder.
        let twin = home.appendingPathComponent("code/acme-app-old")
        try fm.createDirectory(at: twin, withIntermediateDirectories: true)
        let old = artifact(try write("old", to: twin.appendingPathComponent("PLAN.md")))
        XCTAssertEqual(MobileArtifacts.files(([old], []), cwd: cwd.path), [])
    }

    /// A thread started in the home folder would make everything under it
    /// (`Documents`, `Library`) the thread's own. The home folder and the
    /// folders above it are never a root.
    func testTheHomeFolderAndTheFoldersAboveItAreNeverARoot() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home")
        let cwd = home.appendingPathComponent("code/acme-app")
        for folder in [cwd, home.appendingPathComponent("Documents"),
                       home.appendingPathComponent("Library/Mail")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let papers = artifact(try write("tax", to: home.appendingPathComponent("Documents/tax.md")))
        let mail = artifact(try write("mail", to: home.appendingPathComponent("Library/Mail/inbox.txt")))
        let loose = artifact(try write("note", to: home.appendingPathComponent("notes.txt")))
        let plan = artifact(try write("# Plan", to: cwd.appendingPathComponent("PLAN.md")))
        let source: MobileArtifactSource = ([papers, mail, loose, plan], [])

        // The home folder itself, the folder above it, and the home folder
        // written with a trailing slash or through a link to it.
        let link = root.appendingPathComponent("home-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: home)
        for folder in [home.path, root.path, home.path + "/", link.path] {
            XCTAssertEqual(
                MobileArtifacts.files(source, cwd: folder, tempRoots: [], home: home.path), [], folder)
            for file in [papers, mail, loose, plan] {
                XCTAssertEqual(
                    MobileArtifacts.read(
                        path: file.path, cwd: folder, image: false, tempRoots: [], home: home.path),
                    .missing, "\(folder) \(file.path)")
            }
        }
        // A project inside the home folder is a root as before.
        XCTAssertEqual(
            MobileArtifacts.files(source, cwd: cwd.path, tempRoots: [], home: home.path)
                .map(\.artifact.name), ["PLAN.md"])
        XCTAssertEqual(
            MobileArtifacts.read(path: plan.path, cwd: cwd.path, image: false, tempRoots: [], home: home.path),
            .data(Data("# Plan".utf8)))
    }

    func testAScreenshotInATempFolderIsOfferedAndOtherTempFilesAreNot() throws {
        let temp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let shot = artifact(try write("png", to: temp.appendingPathComponent("shot.png")))
        let paper = artifact(try write("pdf", to: temp.appendingPathComponent("report.pdf")))
        let notes = artifact(try write("# Notes", to: temp.appendingPathComponent("notes.md")))
        let page = artifact(try write("<p>", to: temp.appendingPathComponent("page.html")))
        let hidden = artifact(try write("png", to: temp.appendingPathComponent(".shot.png")))
        let source: MobileArtifactSource = ([shot, paper, notes, page, hidden], [])
        let roots = [temp.path]

        XCTAssertEqual(
            MobileArtifacts.files(source, cwd: project.path, tempRoots: roots).map(\.artifact.name),
            ["shot.png"])
        // A PDF is a document, not a screenshot: the temp folders do not serve it.
        XCTAssertEqual(
            MobileArtifacts.file(
                id: MobileArtifacts.id(path: paper.path), thread: thread(cwd: project.path)) { _ in source }
                .status, 404)
        XCTAssertEqual(
            MobileArtifacts.read(path: shot.path, cwd: project.path, image: true, tempRoots: roots),
            .data(Data("png".utf8)))
        // The same file asked for as anything but an image stays closed.
        XCTAssertEqual(
            MobileArtifacts.read(path: shot.path, cwd: project.path, image: false, tempRoots: roots), .missing)
        XCTAssertEqual(
            MobileArtifacts.read(path: notes.path, cwd: project.path, image: false, tempRoots: roots), .missing)
        // An image that is in neither place is not offered.
        XCTAssertEqual(MobileArtifacts.files(source, cwd: project.path, tempRoots: []), [])
        XCTAssertEqual(
            MobileArtifacts.read(path: shot.path, cwd: project.path, image: true, tempRoots: []), .missing)
        // The system's temp folders are the ones that count.
        XCTAssertTrue(MobileArtifacts.tempRoots.contains("/private/tmp"))
        XCTAssertTrue(MobileArtifacts.tempRoots.contains("/private/var/folders"))
        XCTAssertFalse(MobileArtifacts.tempRoots.contains("/"))
        XCTAssertFalse(MobileArtifacts.tempRoots.contains(""))
    }

    func testAPathListedInAnotherLetterCaseStillReads() throws {
        let real = try write("# Report", to: project.appendingPathComponent("Report.md"))
        let listed = project.appendingPathComponent("report.md").path
        // Only where the volume ignores case is this the same file.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: listed), "case-sensitive volume")
        XCTAssertNotEqual(real, listed)
        XCTAssertEqual(
            MobileArtifacts.read(path: listed, cwd: project.path, image: false), .data(Data("# Report".utf8)))
        XCTAssertEqual(
            MobileArtifacts.read(path: listed, cwd: project.path.uppercased(), image: false),
            .data(Data("# Report".utf8)))
        let source: MobileArtifactSource = ([artifact(listed)], [])
        let served = MobileArtifacts.file(
            id: MobileArtifacts.id(path: listed), thread: thread(cwd: project.path)) { _ in source }
        XCTAssertEqual(served.status, 200)
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
        // `other` is listed by the scanner too, and lies outside the thread's folder.
        let source: MobileArtifactSource = ([artifact(plan), artifact(secret), artifact(other)], [])
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
        XCTAssertEqual(MobileArtifacts.read(path: link, cwd: cwd, image: true, tempRoots: []), .missing)
        // Also when it points at a file of the same project.
        let inner = try write("inside", to: project.appendingPathComponent("real.txt"))
        let innerLink = project.appendingPathComponent("alias.txt").path
        try fm.createSymbolicLink(atPath: innerLink, withDestinationPath: inner)
        XCTAssertEqual(MobileArtifacts.read(path: innerLink, cwd: cwd, image: false), .missing)

        // A folder of the listed path is a link that leads out of the project.
        let folder = project.appendingPathComponent("out").path
        try fm.createSymbolicLink(atPath: folder, withDestinationPath: outside.path)
        XCTAssertEqual(MobileArtifacts.read(path: folder + "/notes.txt", cwd: cwd, image: false), .missing)
        // The same outside the project, with no directory to be inside of.
        XCTAssertEqual(MobileArtifacts.read(path: folder + "/notes.txt", cwd: "", image: false), .missing)
        XCTAssertEqual(MobileArtifacts.read(path: folder + "/notes.txt", cwd: "/", image: false), .missing)

        // A linked folder that stays inside the project is the project's own.
        try fm.createDirectory(at: project.appendingPathComponent("build"), withIntermediateDirectories: true)
        _ = try write("built", to: project.appendingPathComponent("build/index.html"))
        let latest = project.appendingPathComponent("latest").path
        try fm.createSymbolicLink(atPath: latest, withDestinationPath: "build")
        XCTAssertEqual(MobileArtifacts.read(path: latest + "/index.html", cwd: cwd, image: false), .data(Data("built".utf8)))

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
        XCTAssertEqual(MobileArtifacts.read(path: plain, cwd: cwd, image: false), .data(Data("hello".utf8)))
        let empty = try write("", to: project.appendingPathComponent("empty.txt"))
        XCTAssertEqual(MobileArtifacts.read(path: empty, cwd: cwd, image: false), .data(Data()))

        XCTAssertEqual(
            MobileArtifacts.read(path: project.appendingPathComponent("gone.txt").path, cwd: cwd, image: false),
            .missing)
        XCTAssertEqual(MobileArtifacts.read(path: cwd, cwd: cwd, image: false), .missing)
        XCTAssertEqual(MobileArtifacts.read(path: "/dev/null", cwd: cwd, image: false), .missing)
        XCTAssertEqual(MobileArtifacts.read(path: "/dev/null", cwd: "/dev", image: false), .missing)

        XCTAssertEqual(
            MobileArtifacts.read(path: plain, cwd: cwd, image: false, limit: 5), .data(Data("hello".utf8)))
        XCTAssertEqual(MobileArtifacts.read(path: plain, cwd: cwd, image: false, limit: 4), .tooLarge)

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
}
