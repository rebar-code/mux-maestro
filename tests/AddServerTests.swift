import XCTest

// AddServer.swift + SshConfig.swift are compiled into this test target, so the
// pure ssh_config generation, the Include-following parser, idempotent Include
// insertion, and the "never writes a secret" guarantees are asserted without
// touching the real ~/.ssh or spawning ssh. The one filesystem test (`save`)
// runs entirely inside a NSTemporaryDirectory subdir.

final class AddServerTests: XCTestCase {
    // MARK: Host-block generation per auth method

    func testHostBlock1PasswordAgent() {
        let entry = ServerEntry(
            name: "host3", hostName: "100.64.0.2", user: "dev", port: 22,
            auth: .onePasswordAgent(publicKeyPath: "~/.ssh/id_ed25519.pub"))
        let block = AddServer.hostBlock(for: entry)
        XCTAssertTrue(block.hasPrefix("Host host3\n"))
        XCTAssertTrue(block.contains("    HostName 100.64.0.2"))
        XCTAssertTrue(block.contains("    User dev"))
        // The host3 model: the 1Password agent socket + pinned identities.
        XCTAssertTrue(block.contains(
            "    IdentityAgent \"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\""))
        XCTAssertTrue(block.contains("    IdentitiesOnly yes"))
        XCTAssertTrue(block.contains("    IdentityFile ~/.ssh/id_ed25519.pub"))
        // Default port 22 is omitted.
        XCTAssertFalse(block.contains("Port"))
    }

    func testHostBlock1PasswordAgentWithoutPublicKey() {
        let entry = ServerEntry(
            name: "h", hostName: "x", user: "u", port: 22,
            auth: .onePasswordAgent(publicKeyPath: nil))
        let block = AddServer.hostBlock(for: entry)
        XCTAssertTrue(block.contains("IdentityAgent"))
        XCTAssertTrue(block.contains("IdentitiesOnly yes"))
        // No IdentityFile line when no public key path was supplied.
        XCTAssertFalse(block.contains("IdentityFile"))
    }

    func testHostBlockKeyFile() {
        let entry = ServerEntry(
            name: "nas", hostName: "nas.example.com", user: "dev", port: 2222,
            auth: .keyFile(path: "~/.ssh/nas_key"))
        let block = AddServer.hostBlock(for: entry)
        XCTAssertTrue(block.contains("    HostName nas.example.com"))
        XCTAssertTrue(block.contains("    Port 2222"))  // non-default port emitted
        XCTAssertTrue(block.contains("    IdentityFile ~/.ssh/nas_key"))
        XCTAssertTrue(block.contains("    IdentitiesOnly yes"))
        // No 1Password agent socket for a plain key file.
        XCTAssertFalse(block.contains("IdentityAgent"))
    }

    func testHostBlockDefaultAgentHasNoIdentityDirectives() {
        let entry = ServerEntry(
            name: "buildbox", hostName: "100.64.0.1", user: "dev", port: 22,
            auth: .defaultAgent)
        let block = AddServer.hostBlock(for: entry)
        XCTAssertTrue(block.contains("    HostName 100.64.0.1"))
        XCTAssertFalse(block.contains("Identity"))  // no IdentityFile / IdentityAgent
    }

    // MARK: No secret material is ever written

    func testHostBlockNeverContainsSecretMaterial() {
        // Even if a caller mislabeled a path, the generator only ever emits the
        // path text — never key contents. Assert no PEM/private-key markers and
        // no "passphrase"/"password" leak into the generated config for any method.
        let entries: [ServerEntry] = [
            ServerEntry(name: "a", hostName: "h", user: "u", port: 22,
                auth: .onePasswordAgent(publicKeyPath: "~/.ssh/k.pub")),
            ServerEntry(name: "b", hostName: "h", user: "u", port: 22,
                auth: .keyFile(path: "~/.ssh/id_rsa")),
            ServerEntry(name: "c", hostName: "h", user: "u", port: 22, auth: .defaultAgent),
        ]
        for e in entries {
            let block = AddServer.hostBlock(for: e).lowercased()
            XCTAssertFalse(block.contains("begin openssh private key"))
            XCTAssertFalse(block.contains("begin rsa private key"))
            XCTAssertFalse(block.contains("-----begin"))
            XCTAssertFalse(block.contains("passphrase"))
            // No password directive/value. (We can't blanket-ban the substring
            // "password": the legitimate 1Password agent socket path contains
            // it — that's an agent reference, not a secret.) Assert instead that
            // no line carries an actual password keyword.
            for line in block.split(separator: "\n") {
                let kw = line.trimmingCharacters(in: .whitespaces).lowercased()
                XCTAssertFalse(kw.hasPrefix("password "))
                XCTAssertFalse(kw.contains("passwd"))
            }
        }
    }

    // MARK: Idempotent Include-line insertion (at the very top)

    func testEnsuringIncludeAddsAtTopWhenAbsent() {
        let config = "Host *\n    ForwardAgent yes\n"
        let out = AddServer.ensuringManagedInclude(in: config)
        XCTAssertTrue(out.hasPrefix("Include ~/.ssh/sidekick_hosts\n"))
        // The Include must precede the Host * block to take effect.
        let includeIdx = out.range(of: "Include ~/.ssh/sidekick_hosts")!.lowerBound
        let hostStarIdx = out.range(of: "Host *")!.lowerBound
        XCTAssertTrue(includeIdx < hostStarIdx)
    }

    func testEnsuringIncludeIsIdempotent() {
        let config = "Include ~/.ssh/sidekick_hosts\n\nHost *\n"
        XCTAssertEqual(AddServer.ensuringManagedInclude(in: config), config)
        // hasManagedInclude detects it regardless of surrounding whitespace.
        XCTAssertTrue(AddServer.hasManagedInclude(in: "  Include   ~/.ssh/sidekick_hosts  \n"))
        XCTAssertTrue(AddServer.hasManagedInclude(in: config))
    }

    func testEnsuringIncludeIntoEmptyConfig() {
        XCTAssertEqual(
            AddServer.ensuringManagedInclude(in: ""),
            "Include ~/.ssh/sidekick_hosts\n")
    }

    func testHasManagedIncludeIgnoresCommentedInclude() {
        XCTAssertFalse(
            AddServer.hasManagedInclude(in: "# Include ~/.ssh/sidekick_hosts\n"))
    }

    func testHasManagedIncludeDetectsIncludeInCRLFConfig() {
        // SHOULD-FIX: on a CRLF config a trailing `\r` clung to the Include path
        // token, so the detector missed an existing managed Include and the save
        // path duplicated it (plus a fresh backup) on every add. After
        // normalizing line endings the existing Include is detected — no dup.
        let crlf = "Include ~/.ssh/sidekick_hosts\r\n\r\nHost a\r\n    HostName 1.1.1.1\r\n"
        XCTAssertTrue(AddServer.hasManagedInclude(in: crlf))
        // ensuringManagedInclude is therefore a no-op (returns config unchanged).
        XCTAssertEqual(AddServer.ensuringManagedInclude(in: crlf), crlf)
    }

    // MARK: Upsert / remove a host block in the managed file

    func testUpsertAppendsThenReplacesByAlias() {
        let first = AddServer.hostBlock(
            for: ServerEntry(name: "a", hostName: "1.1.1.1", user: "u", port: 22, auth: .defaultAgent))
        let c1 = AddServer.upserting(block: first, alias: "a", into: "")
        XCTAssertTrue(c1.contains("HostName 1.1.1.1"))

        // Re-add `a` with a new HostName → the old block is replaced, not dupd.
        let second = AddServer.hostBlock(
            for: ServerEntry(name: "a", hostName: "2.2.2.2", user: "u", port: 22, auth: .defaultAgent))
        let c2 = AddServer.upserting(block: second, alias: "a", into: c1)
        XCTAssertTrue(c2.contains("HostName 2.2.2.2"))
        XCTAssertFalse(c2.contains("1.1.1.1"))
        // Exactly one `Host a` line.
        let count = c2.components(separatedBy: "Host a").count - 1
        XCTAssertEqual(count, 1)
    }

    func testRemoveHostBlockLeavesOtherHosts() {
        let content = """
        Host a
            HostName 1.1.1.1
            User u

        Host b
            HostName 2.2.2.2
        """
        let out = AddServer.removingHostBlock(alias: "a", from: content)
        XCTAssertFalse(out.contains("1.1.1.1"))
        XCTAssertTrue(out.contains("Host b"))
        XCTAssertTrue(out.contains("2.2.2.2"))
    }

    // MARK: Test-on-save argv

    func testTestConnectionArgsBatchModeAndTimeout() {
        let args = AddServer.testConnectionArgs(name: "host3")
        XCTAssertEqual(args, ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "host3", "true"])
    }

    // MARK: Include-following parser (tmp fixture filesystem)

    func testParserFollowsIncludeUsingInjectedReader() {
        // In-memory fixture: a main config that Includes a hosts file. The reader
        // + glob are injected so NO real filesystem is touched.
        let files: [String: String] = [
            "/cfg/config": """
            Include /cfg/sidekick_hosts
            Host inline
                HostName 9.9.9.9
            """,
            "/cfg/sidekick_hosts": """
            Host included1
                HostName 1.1.1.1
            Host included2
                HostName 2.2.2.2
            """,
        ]
        let hosts = SshConfig.parseHostsFollowingIncludes(
            path: "/cfg/config",
            reader: { files[$0] },
            glob: { files[$0] != nil ? [$0] : [] })
        // Include is expanded in place (before the inline host, file order).
        XCTAssertEqual(hosts.map(\.name), ["included1", "included2", "inline"])
    }

    func testParserDeduplicatesAcrossIncludedFiles() {
        let files: [String: String] = [
            "/cfg/config": "Include /cfg/more\nHost dup\n",
            "/cfg/more": "Host dup\nHost only\n",
        ]
        let hosts = SshConfig.parseHostsFollowingIncludes(
            path: "/cfg/config", reader: { files[$0] }, glob: { files[$0] != nil ? [$0] : [] })
        // `dup` appears in both files; collapsed to the first occurrence.
        XCTAssertEqual(hosts.map(\.name), ["dup", "only"])
    }

    func testParserHandlesMissingIncludeGracefully() {
        let files = ["/cfg/config": "Include /cfg/does-not-exist\nHost real\n"]
        let hosts = SshConfig.parseHostsFollowingIncludes(
            path: "/cfg/config", reader: { files[$0] }, glob: { _ in [] })
        XCTAssertEqual(hosts.map(\.name), ["real"])
    }

    func testParserToleratesIncludeCycle() {
        // Two files Include each other; the visited-set guard prevents infinite
        // recursion and each host is still seen once.
        let files: [String: String] = [
            "/cfg/a": "Include /cfg/b\nHost ha\n",
            "/cfg/b": "Include /cfg/a\nHost hb\n",
        ]
        let hosts = SshConfig.parseHostsFollowingIncludes(
            path: "/cfg/a", reader: { files[$0] }, glob: { files[$0] != nil ? [$0] : [] })
        XCTAssertEqual(Set(hosts.map(\.name)), ["ha", "hb"])
    }

    // MARK: End-to-end save into a temp dir (NEVER the real ~/.ssh)

    func testSaveWritesManagedFile600AndIncludesIt() throws {
        let tmp = NSTemporaryDirectory() + "sidekick-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        let managed = tmp + "/sidekick_hosts"
        let config = tmp + "/config"
        // Seed an existing config with a Host * block so we can prove the Include
        // lands ABOVE it and the original is backed up.
        try "Host *\n    ForwardAgent yes\n".write(
            toFile: config, atomically: true, encoding: .utf8)

        let entry = ServerEntry(
            name: "host3", hostName: "1.2.3.4", user: "dev", port: 22,
            auth: .onePasswordAgent(publicKeyPath: nil))
        let result = try AddServer.save(
            entry: entry, managedHostsPath: managed, configPath: config)

        // Managed file written with the host block and perms 600.
        let managedText = try String(contentsOfFile: managed, encoding: .utf8)
        XCTAssertTrue(managedText.contains("Host host3"))
        XCTAssertTrue(managedText.contains("IdentityAgent"))
        let attrs = try FileManager.default.attributesOfItem(atPath: managed)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Config now Includes the managed file, AT THE TOP, backed up first.
        let configText = try String(contentsOfFile: config, encoding: .utf8)
        XCTAssertTrue(configText.hasPrefix("Include ~/.ssh/sidekick_hosts\n"))
        XCTAssertTrue(result.insertedInclude)
        XCTAssertNotNil(result.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupPath!))
        // The backup preserves the original (no Include line in it).
        let backupText = try String(contentsOfFile: result.backupPath!, encoding: .utf8)
        XCTAssertFalse(backupText.contains("sidekick_hosts"))
    }

    func testSaveIsIdempotentForIncludeLine() throws {
        let tmp = NSTemporaryDirectory() + "sidekick-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        let managed = tmp + "/sidekick_hosts"
        let config = tmp + "/config"
        let entry = ServerEntry(
            name: "a", hostName: "h", user: "u", port: 22, auth: .defaultAgent)

        let r1 = try AddServer.save(entry: entry, managedHostsPath: managed, configPath: config)
        XCTAssertTrue(r1.insertedInclude)
        // Second save: Include already present → not inserted again, no backup.
        let entry2 = ServerEntry(
            name: "b", hostName: "h2", user: "u", port: 22, auth: .defaultAgent)
        let r2 = try AddServer.save(entry: entry2, managedHostsPath: managed, configPath: config)
        XCTAssertFalse(r2.insertedInclude)
        XCTAssertNil(r2.backupPath)
        // Exactly one Include line in the config.
        let configText = try String(contentsOfFile: config, encoding: .utf8)
        XCTAssertEqual(
            configText.components(separatedBy: "Include ~/.ssh/sidekick_hosts").count - 1, 1)
        // Both hosts present in the managed file.
        let managedText = try String(contentsOfFile: managed, encoding: .utf8)
        XCTAssertTrue(managedText.contains("Host a"))
        XCTAssertTrue(managedText.contains("Host b"))
    }

    func testSaveNeverWritesSecretsToDisk() throws {
        let tmp = NSTemporaryDirectory() + "sidekick-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        let managed = tmp + "/sidekick_hosts"
        let config = tmp + "/config"
        let entry = ServerEntry(
            name: "k", hostName: "h", user: "u", port: 22,
            auth: .keyFile(path: "~/.ssh/id_ed25519"))
        try AddServer.save(entry: entry, managedHostsPath: managed, configPath: config)
        let managedText = try String(contentsOfFile: managed, encoding: .utf8).lowercased()
        // Only the PATH is stored; never key contents or a passphrase.
        XCTAssertTrue(managedText.contains("identityfile ~/.ssh/id_ed25519"))
        XCTAssertFalse(managedText.contains("-----begin"))
        XCTAssertFalse(managedText.contains("private key"))
        XCTAssertFalse(managedText.contains("passphrase"))
    }

    // MARK: applyConnectionSettings — mosh/watch persisted keyed by alias

    func testApplyConnectionSettingsPersistsKeyedByAlias() {
        let suite = "AddServerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        AddServer.applyConnectionSettings(
            alias: "box", useMosh: true, watch: false, defaults: defaults)
        let host = Host(name: "box", sshAlias: "box")
        XCTAssertTrue(Settings.useMosh(host: host, defaults: defaults))
        XCTAssertFalse(Settings.watch(host: host, defaults: defaults))
        // A different alias is unaffected (per-host keying).
        let other = Host(name: "other", sshAlias: "other")
        XCTAssertFalse(Settings.useMosh(host: other, defaults: defaults))
    }

    // MARK: entry(forAlias:) — reading a block back for the Edit sheet

    /// Every auth case must survive render → parse unchanged, or the Edit sheet
    /// would silently downgrade a host's auth the moment you opened and saved it.
    func testEntryRoundTripsEveryAuthMethod() {
        let cases: [ServerEntry] = [
            ServerEntry(
                name: "host3", hostName: "10.0.0.5", user: "dev", port: 22,
                auth: .onePasswordAgent(publicKeyPath: "~/.ssh/id_ed25519.pub")),
            ServerEntry(
                name: "host3", hostName: "10.0.0.5", user: "dev", port: 22,
                auth: .onePasswordAgent(publicKeyPath: nil)),
            ServerEntry(
                name: "box", hostName: "example.com", user: "root", port: 2222,
                auth: .keyFile(path: "~/.ssh/id_rsa")),
            ServerEntry(
                name: "plain", hostName: "h.example.com", user: "u", port: 22,
                auth: .defaultAgent),
        ]
        for entry in cases {
            let rendered = AddServer.hostBlock(for: entry)
            let parsed = AddServer.entry(forAlias: entry.name, in: rendered)
            XCTAssertEqual(parsed, entry, "round-trip failed for \(entry)")
        }
    }

    func testEntryReadsTheRightBlockAmongMany() {
        let content = """
            Host alpha
                HostName 1.1.1.1
                User alice

            Host beta
                HostName 2.2.2.2
                User bob
                Port 2200

            Host gamma
                HostName 3.3.3.3
            """
        let beta = AddServer.entry(forAlias: "beta", in: content)
        XCTAssertEqual(beta?.hostName, "2.2.2.2")
        XCTAssertEqual(beta?.user, "bob")
        XCTAssertEqual(beta?.port, 2200)
        // Neighbours must not bleed in.
        XCTAssertEqual(AddServer.entry(forAlias: "alpha", in: content)?.port, 22)
        XCTAssertEqual(AddServer.entry(forAlias: "gamma", in: content)?.user, "")
    }

    func testEntryReturnsNilForUnknownAlias() {
        XCTAssertNil(AddServer.entry(forAlias: "nope", in: "Host alpha\n    User a\n"))
    }

    func testEntryToleratesEqualsAndQuotedValues() {
        let content = """
            Host box
                HostName=example.com
                Port = 2222
                User "dev"
            """
        let e = AddServer.entry(forAlias: "box", in: content)
        XCTAssertEqual(e?.hostName, "example.com")
        XCTAssertEqual(e?.port, 2222)
        XCTAssertEqual(e?.user, "dev")
    }

    func testEntryIgnoresCommentsAndBlankLines() {
        let content = """
            Host box
                # a comment
                HostName example.com

                User dev
            """
        let e = AddServer.entry(forAlias: "box", in: content)
        XCTAssertEqual(e?.hostName, "example.com")
        XCTAssertEqual(e?.user, "dev")
    }

    // MARK: managedAliases — which hosts the Edit item is offered for

    func testManagedAliasesListsHostsSkippingPatterns() {
        let content = """
            Host alpha
                HostName 1.1.1.1
            Host beta gamma
                HostName 2.2.2.2
            Host *
                ForwardAgent yes
            """
        XCTAssertEqual(
            AddServer.managedAliases(in: content), ["alpha", "beta", "gamma"])
    }

    // MARK: preservedDirectives — hand-added lines survive a save

    /// A save re-renders the block from the sheet's fields. Anything the user
    /// hand-added that the sheet has no field for must be carried across, or
    /// editing a host would quietly delete their `ProxyJump`.
    func testPreservedDirectivesKeepsUnknownLinesOnly() {
        let content = """
            Host box
                HostName example.com
                User dev
                IdentityFile ~/.ssh/id_rsa
                IdentitiesOnly yes
                ProxyJump bastion
                ForwardAgent yes
            """
        XCTAssertEqual(
            AddServer.preservedDirectives(forAlias: "box", in: content),
            ["    ProxyJump bastion", "    ForwardAgent yes"])
    }

    // MARK: save — rename + preservation

    /// Renaming must remove the old block. Leaving it behind would keep
    /// `ssh <old>` resolving and show a phantom host in the sidebar.
    func testSaveWithRenameRemovesTheOldBlock() throws {
        let dir = NSTemporaryDirectory() + "/edit-\(UUID().uuidString)"
        let hosts = dir + "/sidekick_hosts"
        let config = dir + "/config"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try AddServer.save(
            entry: ServerEntry(
                name: "old-box", hostName: "1.1.1.1", user: "a", port: 22,
                auth: .defaultAgent),
            managedHostsPath: hosts, configPath: config)
        try AddServer.save(
            entry: ServerEntry(
                name: "new-box", hostName: "1.1.1.1", user: "a", port: 22,
                auth: .defaultAgent),
            managedHostsPath: hosts, configPath: config, replacingAlias: "old-box")

        let content = try String(contentsOfFile: hosts, encoding: .utf8)
        XCTAssertNil(AddServer.entry(forAlias: "old-box", in: content))
        XCTAssertEqual(AddServer.entry(forAlias: "new-box", in: content)?.hostName, "1.1.1.1")
        XCTAssertEqual(AddServer.managedAliases(in: content), ["new-box"])
    }

    /// Editing a host re-renders its block from the sheet's fields. Hand-added
    /// directives the sheet has no field for must survive, or opening and saving
    /// a host would quietly break its ProxyJump.
    func testSavePreservesHandAddedDirectives() throws {
        let dir = NSTemporaryDirectory() + "/edit-\(UUID().uuidString)"
        let hosts = dir + "/sidekick_hosts"
        let config = dir + "/config"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let entry = ServerEntry(
            name: "box", hostName: "h", user: "u", port: 22, auth: .defaultAgent)
        try AddServer.save(
            entry: entry, managedHostsPath: hosts, configPath: config,
            preserving: ["    ProxyJump bastion"])

        var content = try String(contentsOfFile: hosts, encoding: .utf8)
        XCTAssertTrue(content.contains("ProxyJump bastion"))

        // Round-trip: read the extras back and save again — still there, once.
        let extras = AddServer.preservedDirectives(forAlias: "box", in: content)
        XCTAssertEqual(extras, ["    ProxyJump bastion"])
        try AddServer.save(
            entry: ServerEntry(
                name: "box", hostName: "h2", user: "u", port: 22, auth: .defaultAgent),
            managedHostsPath: hosts, configPath: config, preserving: extras)
        content = try String(contentsOfFile: hosts, encoding: .utf8)
        XCTAssertEqual(
            content.components(separatedBy: "ProxyJump bastion").count - 1, 1,
            "ProxyJump should appear exactly once, not duplicate per save")
        XCTAssertEqual(AddServer.entry(forAlias: "box", in: content)?.hostName, "h2")
    }

    func testMigrateConnectionSettingsMovesStateAndClearsOld() {
        let suite = "AddServerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        AddServer.applyConnectionSettings(
            alias: "old", useMosh: true, watch: true, defaults: defaults)
        AddServer.migrateConnectionSettings(from: "old", to: "new", defaults: defaults)

        let newHost = Host(name: "new", sshAlias: "new")
        XCTAssertTrue(Settings.useMosh(host: newHost, defaults: defaults))
        XCTAssertTrue(Settings.watch(host: newHost, defaults: defaults))
        // Old keys are gone, so a future host reusing the name starts clean.
        XCTAssertNil(defaults.object(forKey: "mosh.old"))
        XCTAssertNil(defaults.object(forKey: "watch.old"))
    }

    func testPreservedDirectivesEmptyForFullyGeneratedBlock() {
        let entry = ServerEntry(
            name: "box", hostName: "h", user: "u", port: 22,
            auth: .keyFile(path: "~/.ssh/id_rsa"))
        let rendered = AddServer.hostBlock(for: entry)
        XCTAssertEqual(AddServer.preservedDirectives(forAlias: "box", in: rendered), [])
    }

    // MARK: Key-path validation
    //
    // Regression coverage for the incident that prompted this check: the Add
    // Server sheet accepted `~/.ssh` (a directory) as a key-file path with no
    // validation, so ssh only failed on it much later — deep inside a
    // connection probe, as an opaque "Is a directory" — instead of at the
    // moment the bad path was entered.

    func testInvalidKeyPathReasonCatchesADirectory() throws {
        // A real directory, not a mock — mirrors the actual ~/.ssh mistake.
        let dir = NSTemporaryDirectory() + "addserver-dir-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let reason = AddServer.invalidKeyPathReason(for: .keyFile(path: dir))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("directory"))
    }

    func testInvalidKeyPathReasonAcceptsARealFile() throws {
        let file = NSTemporaryDirectory() + "addserver-file-\(UUID().uuidString)"
        try "not a real key".write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }

        XCTAssertNil(AddServer.invalidKeyPathReason(for: .keyFile(path: file)))
    }

    func testInvalidKeyPathReasonCatchesAMissingFile() {
        let reason = AddServer.invalidKeyPathReason(
            for: .keyFile(path: "/nonexistent/\(UUID().uuidString)"))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("doesn’t exist"))
    }

    func testInvalidKeyPathReasonRequiresNonEmptyForKeyFile() {
        let reason = AddServer.invalidKeyPathReason(for: .keyFile(path: ""))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("required"))
    }

    func testInvalidKeyPathReasonSkipsCheckWhenNoPathGiven() {
        // defaultAgent never carries a path; a 1Password entry's public-key path
        // is optional, so an omitted one shouldn't block saving.
        XCTAssertNil(AddServer.invalidKeyPathReason(for: .defaultAgent))
        XCTAssertNil(AddServer.invalidKeyPathReason(for: .onePasswordAgent(publicKeyPath: nil)))
        XCTAssertNil(AddServer.invalidKeyPathReason(for: .onePasswordAgent(publicKeyPath: "")))
    }

    func testInvalidKeyPathReasonChecksTheOnePasswordPublicKeyPathToo() throws {
        let dir = NSTemporaryDirectory() + "addserver-dir-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let reason = AddServer.invalidKeyPathReason(
            for: .onePasswordAgent(publicKeyPath: dir))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("Public key path"))
    }

    func testInvalidKeyPathReasonExpandsTilde() {
        // ~/.ssh always exists for a real user — proves tilde-expansion happens
        // before the directory check, not just literal-path matching.
        let reason = AddServer.invalidKeyPathReason(for: .keyFile(path: "~/.ssh"))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("directory"))
    }

    // MARK: ssh-copy-id command generation

    func testSshCopyIdCommandForKeyFile() {
        let entry = ServerEntry(
            name: "box", hostName: "10.1.1.11", user: "sredden", port: 22,
            auth: .keyFile(path: "~/.ssh/id_ed25519"))
        let cmd = AddServer.sshCopyIdCommand(for: entry)
        XCTAssertEqual(cmd, "ssh-copy-id -i ~/'.ssh/id_ed25519' 'sredden@10.1.1.11'")
    }

    func testSshCopyIdCommandIncludesNonDefaultPort() {
        let entry = ServerEntry(
            name: "box", hostName: "h", user: "u", port: 2222,
            auth: .keyFile(path: "~/.ssh/id_ed25519"))
        XCTAssertTrue(AddServer.sshCopyIdCommand(for: entry)!.contains(" -p 2222 "))
    }

    func testSshCopyIdCommandOmitsUserWhenEmpty() {
        let entry = ServerEntry(
            name: "box", hostName: "h", user: "", port: 22,
            auth: .keyFile(path: "~/.ssh/id_ed25519"))
        XCTAssertEqual(
            AddServer.sshCopyIdCommand(for: entry), "ssh-copy-id -i ~/'.ssh/id_ed25519' 'h'")
    }

    func testSshCopyIdCommandUsesThePublicKeyPathFor1Password() {
        let entry = ServerEntry(
            name: "box", hostName: "h", user: "u", port: 22,
            auth: .onePasswordAgent(publicKeyPath: "~/.ssh/id_ed25519.pub"))
        XCTAssertEqual(
            AddServer.sshCopyIdCommand(for: entry),
            "ssh-copy-id -i ~/'.ssh/id_ed25519.pub' 'u@h'")
    }

    func testSshCopyIdCommandNilWhenNoPathAvailable() {
        let defaultAgent = ServerEntry(
            name: "box", hostName: "h", user: "u", port: 22, auth: .defaultAgent)
        XCTAssertNil(AddServer.sshCopyIdCommand(for: defaultAgent))

        let noPubKey = ServerEntry(
            name: "box", hostName: "h", user: "u", port: 22,
            auth: .onePasswordAgent(publicKeyPath: nil))
        XCTAssertNil(AddServer.sshCopyIdCommand(for: noPubKey))
    }

    func testSshCopyIdCommandNilWhenNoHostName() {
        let entry = ServerEntry(
            name: "box", hostName: "", user: "u", port: 22,
            auth: .keyFile(path: "~/.ssh/id_ed25519"))
        XCTAssertNil(AddServer.sshCopyIdCommand(for: entry))
    }
}
