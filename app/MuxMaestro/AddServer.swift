import Foundation

/// How a new remote host authenticates over SSH. Drives which `Identity*`
/// directives the generated `Host` block contains. CRITICAL: none of these store
/// a secret — only a *path* (a public/private key file) or a *reference* (the
/// 1Password agent socket). Private keys, passphrases, and any secret material
/// are NEVER written by MuxMaestro.
enum SshAuthMethod: Equatable {
    /// 1Password SSH agent + Touch ID (the `host3` model): point ssh at the
    /// 1Password agent socket and pin it (`IdentitiesOnly yes`). The optional
    /// `.pub` path lets `IdentitiesOnly` select exactly one key; it is a public
    /// key path only — never the private key.
    case onePasswordAgent(publicKeyPath: String?)
    /// A key file on disk: `IdentityFile <path>`. Stores only the PATH to the
    /// private key, never its contents.
    case keyFile(path: String)
    /// Default ssh agent / config — no Identity directives, ssh decides.
    case defaultAgent
}

/// The data captured by the Add Server sheet. Pure value type so the generated
/// ssh_config block can be asserted without any UI.
struct ServerEntry: Equatable {
    /// The `Host` alias (what `ssh <name>` uses; also the sidebar display name).
    var name: String
    var hostName: String
    var user: String
    var port: Int
    var auth: SshAuthMethod
}

/// Generates ssh_config text + manages MuxMaestro's own hosts file and the
/// `Include` line in `~/.ssh/config`. Everything that touches the filesystem
/// takes explicit paths so tests run entirely in a temp dir — the real `~/.ssh`
/// is never touched by tests.
enum AddServer {
    /// The canonical 1Password SSH agent socket (the `host3` model uses this).
    static let onePasswordAgentSocket =
        "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    /// MuxMaestro-managed hosts file (kept out of the user's hand-maintained
    /// `~/.ssh/config`; perms 600). `~/.ssh/config` Includes it.
    static var managedHostsPath: String {
        NSString(string: "~/.ssh/sidekick_hosts").expandingTildeInPath
    }

    static var sshConfigPath: String {
        NSString(string: "~/.ssh/config").expandingTildeInPath
    }

    /// The exact `Include` line we ensure is present at the top of `~/.ssh/config`
    /// so the managed hosts are visible to ssh. Uses the literal `~/.ssh/...`
    /// form (ssh expands it) so the line is stable + recognizable.
    static let includeLine = "Include ~/.ssh/sidekick_hosts"

    // MARK: ssh_config block generation (pure — unit-tested per auth method)

    /// Render the `Host` block for `entry`. Indented bodies, one directive per
    /// line. NEVER emits a private key, passphrase, or any secret — only the
    /// HostName/User/Port metadata and the chosen auth's path/agent references.
    static func hostBlock(for entry: ServerEntry) -> String {
        var lines = ["Host \(entry.name)"]
        if !entry.hostName.isEmpty { lines.append("    HostName \(entry.hostName)") }
        if !entry.user.isEmpty { lines.append("    User \(entry.user)") }
        if entry.port != 22 { lines.append("    Port \(entry.port)") }

        switch entry.auth {
        case .onePasswordAgent(let publicKeyPath):
            // The host3 model: 1Password agent socket + pin identities to it.
            lines.append("    IdentityAgent \"\(onePasswordAgentSocket)\"")
            lines.append("    IdentitiesOnly yes")
            if let pub = publicKeyPath, !pub.isEmpty {
                // A PUBLIC key path only — lets IdentitiesOnly pick one key.
                lines.append("    IdentityFile \(pub)")
            }
        case .keyFile(let path):
            // Store only the PATH to the private key — never its contents.
            lines.append("    IdentityFile \(path)")
            lines.append("    IdentitiesOnly yes")
        case .defaultAgent:
            break  // no Identity directives — ssh defaults apply.
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Include-line insertion (idempotent — unit-tested)

    /// Whether `config` already contains an active `Include` of the managed hosts
    /// file (ignoring comments + whitespace, tolerating quoting/`=`).
    static func hasManagedInclude(in config: String) -> Bool {
        // Normalize CRLF → LF first: `\r` is not in `.whitespaces`, so on a CRLF
        // config a trailing `\r` would cling to the Include path token and the
        // match would miss an existing Include — duplicating it (and triggering a
        // fresh backup) on every add.
        for raw in SshConfig.normalizeNewlines(config)
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let tokens = line
                .replacingOccurrences(of: "=", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            guard tokens.first?.lowercased() == "include" else { continue }
            // Match either the tilde form or the expanded absolute form.
            let expanded = managedHostsPath
            for t in tokens.dropFirst() {
                let normalized = NSString(string: t).expandingTildeInPath
                if normalized == expanded || t == "~/.ssh/sidekick_hosts" { return true }
            }
        }
        return false
    }

    /// Insert the managed `Include` line at the **very top** of `config` if it
    /// isn't already present — Include must precede `Host *` blocks to take
    /// effect. Idempotent: returns `config` unchanged when already present.
    static func ensuringManagedInclude(in config: String) -> String {
        guard !hasManagedInclude(in: config) else { return config }
        // Prepend; keep a blank line between our line and the user's content.
        if config.isEmpty { return includeLine + "\n" }
        return includeLine + "\n\n" + config
    }

    // MARK: Managed-hosts-file content (append a block idempotently by alias)

    /// Append `block` to the managed file's existing `content`, replacing any
    /// existing block for the same `Host` alias (so re-adding a server updates it
    /// rather than duplicating). Pure string transform.
    static func upserting(block: String, alias: String, into content: String) -> String {
        let withoutOld = removingHostBlock(alias: alias, from: content)
        let trimmed = withoutOld.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? block : trimmed + "\n\n" + block
        return body + "\n"
    }

    /// Remove an existing `Host <alias>` block (the Host line + its indented
    /// body, up to the next `Host`/`Include` at column 0 or EOF) from `content`.
    static func removingHostBlock(alias: String, from content: String) -> String {
        // Normalize CRLF → LF so a `\r` doesn't cling to the Host alias token and
        // defeat the alias match / block-boundary detection on a CRLF file.
        let lines = SshConfig.normalizeNewlines(content)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            let isHostLine = lower.hasPrefix("host ") || lower == "host"
            let isIncludeLine = lower.hasPrefix("include ") || lower == "include"
            if skipping {
                // A new top-level Host/Include ends the block we're skipping.
                if isHostLine || isIncludeLine {
                    skipping = false
                } else {
                    continue  // still inside the old block
                }
            }
            if isHostLine {
                let aliases = trimmed
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .dropFirst()
                    .map(String.init)
                if aliases.contains(alias) {
                    skipping = true
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Reading a block back (pure — inverse of `hostBlock`)

    /// The `Host` aliases MuxMaestro manages, in file order. Only these are
    /// editable — a host defined in the user's hand-maintained `~/.ssh/config` is
    /// never rewritten by the app, so the sidebar hides Edit for it.
    static func managedAliases(in content: String) -> [String] {
        var out: [String] = []
        for line in SshConfig.normalizeNewlines(content)
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("host ") else { continue }
            for alias in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst() {
                // Patterns (`*`, `?`) aren't real hosts and can't be round-tripped
                // through the sheet — skip them rather than offer a broken edit.
                let a = String(alias)
                if !a.contains("*"), !a.contains("?") { out.append(a) }
            }
        }
        return out
    }

    /// Parse the `Host <alias>` block out of `content` back into a `ServerEntry`,
    /// so the sheet can be prefilled for editing. The inverse of `hostBlock`;
    /// round-trip is unit-tested for every auth case.
    ///
    /// Returns nil when the alias has no block. Unrecognized directives inside the
    /// block are ignored — see `preservedDirectives` for how they survive a save.
    static func entry(forAlias alias: String, in content: String) -> ServerEntry? {
        guard let body = blockBody(forAlias: alias, in: content) else { return nil }
        var hostName = ""
        var user = ""
        var port = 22
        var identityFile: String?
        var identityAgent: String?
        for line in body {
            switch line.key {
            case "hostname": hostName = line.value
            case "user": user = line.value
            case "port": port = Int(line.value) ?? 22
            case "identityfile": identityFile = line.value
            case "identityagent": identityAgent = line.value
            default: break
            }
        }
        // Auth is inferred the same way `hostBlock` writes it: the 1Password agent
        // socket is the discriminator, and its IdentityFile (when present) is a
        // PUBLIC key path. Anything else with an IdentityFile is a key file.
        let auth: SshAuthMethod
        if let agent = identityAgent, agent.contains("1password") {
            auth = .onePasswordAgent(publicKeyPath: identityFile)
        } else if let key = identityFile {
            auth = .keyFile(path: key)
        } else {
            auth = .defaultAgent
        }
        return ServerEntry(
            name: alias, hostName: hostName, user: user, port: port, auth: auth)
    }

    /// Directives inside the alias's block that `hostBlock` does not generate.
    /// A save re-renders the block from the sheet's fields, which would silently
    /// drop anything the user hand-added (`ProxyJump`, `ForwardAgent`, …), so the
    /// caller re-appends these. Returned as raw lines, original order preserved.
    static func preservedDirectives(forAlias alias: String, in content: String) -> [String] {
        let generated: Set<String> = [
            "hostname", "user", "port", "identityfile", "identityagent", "identitiesonly",
        ]
        guard let body = blockBody(forAlias: alias, in: content) else { return [] }
        return body
            .filter { !generated.contains($0.key) }
            .map { "    \($0.raw)" }
    }

    /// Key/value/raw triples for the body lines of `alias`'s block (comments and
    /// blank lines dropped). Shares `removingHostBlock`'s boundary rules: a block
    /// runs to the next `Host`/`Include` at column 0, or EOF.
    private static func blockBody(
        forAlias alias: String, in content: String
    ) -> [(key: String, value: String, raw: String)]? {
        let lines = SshConfig.normalizeNewlines(content)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body: [(key: String, value: String, raw: String)] = []
        var inBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            let isHostLine = lower.hasPrefix("host ") || lower == "host"
            let isIncludeLine = lower.hasPrefix("include ") || lower == "include"
            if inBlock, isHostLine || isIncludeLine { break }  // block ended
            if isHostLine {
                let aliases = trimmed
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .dropFirst()
                    .map(String.init)
                inBlock = aliases.contains(alias)
                continue
            }
            guard inBlock, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // `Key value`, `Key=value`, and quoted values are all legal ssh_config.
            let parts = trimmed.split(
                separator: trimmed.contains("=") && !trimmed.contains(" ") ? "=" : " ",
                maxSplits: 1, omittingEmptySubsequences: true)
            guard let key = parts.first else { continue }
            var value = parts.count > 1 ? String(parts[1]) : ""
            // `Key = value` (spaces around the separator) leaves a stray `=`.
            value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("=") { value = String(value.dropFirst()) }
            value = value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            body.append((key: key.lowercased(), value: value, raw: trimmed))
        }
        return inBlock ? body : nil
    }

    // MARK: Test-on-save command (pure argv — runner injected)

    /// The `ssh` argv that verifies a host resolves + auths without an
    /// interactive password prompt: `ssh -o ConnectTimeout=5 -o BatchMode=yes
    /// <name> true`. BatchMode still lets the agent / Touch ID satisfy auth (for
    /// a 1Password-agent host this triggers Touch ID); it only blocks a password
    /// prompt that would otherwise hang.
    static func testConnectionArgs(name: String) -> [String] {
        ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", name, "true"]
    }

    /// Run the test-on-save probe through `runner` (defaults to a real ssh with a
    /// short ceiling). Returns true when ssh exits 0 (resolves + auths). For a
    /// 1Password-agent host this can trigger Touch ID. The host must already be
    /// written to the managed file (which `~/.ssh/config` Includes) so ssh can
    /// resolve the alias.
    static func testConnection(
        name: String, runner: CommandRunner = ProcessCommandRunner(timeout: 8.0)
    ) -> Bool {
        runner.run(Ssh.sshPath, testConnectionArgs(name: name)) != nil
    }

    // MARK: Key-path validation (pure logic, filesystem check — unit-tested)

    /// Checks the path carried by `auth` (the `keyFile` path, or the optional
    /// `onePasswordAgent` public-key path) before it's ever written to
    /// `~/.ssh/sidekick_hosts`. Returns a user-facing reason when the path is
    /// missing, doesn't exist, or — the bug this exists to catch — points at a
    /// directory instead of the key file inside it (e.g. a stray `~/.ssh` typed
    /// into the sheet's key-path field, which ssh only rejects much later, deep
    /// in a connection probe, as an opaque "Is a directory"). nil when there's
    /// nothing to check (`defaultAgent`, or an omitted optional 1Password public
    /// key) or the path checks out.
    static func invalidKeyPathReason(
        for auth: SshAuthMethod, fileManager: FileManager = .default
    ) -> String? {
        let path: String
        let label: String
        switch auth {
        case .keyFile(let p):
            path = p
            label = "Key path"
        case .onePasswordAgent(let pub):
            guard let pub, !pub.isEmpty else { return nil }
            path = pub
            label = "Public key path"
        case .defaultAgent:
            return nil
        }
        guard !path.isEmpty else {
            return "\(label) is required for this auth method."
        }
        let expanded = NSString(string: path).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return "\(label) “\(path)” doesn’t exist."
        }
        if isDir.boolValue {
            return "\(label) “\(path)” is a directory, not a key file. Point this at "
                + "the actual key file inside it (e.g. ~/.ssh/id_ed25519)."
        }
        return nil
    }

    // MARK: Copy-key-to-server command (pure — unit-tested)

    /// The `ssh-copy-id` command that installs `entry`'s public key on its
    /// remote, or nil when the entry's auth method carries no local key-file
    /// path to copy (`defaultAgent`, or a 1Password-agent entry with no public
    /// key path saved) or no HostName to target. `ssh-copy-id -i` accepts either
    /// the private key path or the `.pub` path — it derives the public key
    /// itself — so the `keyFile` case's stored (private) path works as-is.
    /// Surfaced by the failed-test-on-save alert so the user can install the key
    /// themselves; MuxMaestro never runs this itself (that would mean piping a
    /// password through the app — see `openInTerminal` in AppDelegate).
    static func sshCopyIdCommand(for entry: ServerEntry) -> String? {
        let path: String?
        switch entry.auth {
        case .keyFile(let p): path = p.isEmpty ? nil : p
        case .onePasswordAgent(let pub): path = (pub?.isEmpty == false) ? pub : nil
        case .defaultAgent: path = nil
        }
        guard let path, !entry.hostName.isEmpty else { return nil }
        let target = entry.user.isEmpty ? entry.hostName : "\(entry.user)@\(entry.hostName)"
        // Stored paths are typically `~/.ssh/...` (that's what the sheet's Browse
        // panel and hand-typed entries both produce). This runs inside a bash
        // script (see `openInTerminal`), so a plain single-quoted `'~/...'` would
        // NOT tilde-expand — bash only expands a leading ~ outside quotes. Use
        // the tilde-preserving quoter (same one `SshTmuxTransport` uses for the
        // same reason) so `~` still resolves to $HOME while the rest of the path
        // stays safely quoted.
        var argv = "ssh-copy-id -i \(Ssh.shellQuoteAllowingTilde(path))"
        if entry.port != 22 { argv += " -p \(entry.port)" }
        argv += " \(Ssh.shellQuote(target))"
        return argv
    }

    // MARK: Persistence (filesystem — paths injected so tests use a temp dir)

    /// Result of persisting a server entry.
    struct SaveResult: Equatable {
        var managedHostsPath: String
        var backupPath: String?
        var insertedInclude: Bool
    }

    /// Persist `entry`: write its block into the managed hosts file (perms 600,
    /// created if absent), back up `~/.ssh/config` (timestamped) before editing,
    /// and idempotently add the `Include` line at the top of `~/.ssh/config`.
    /// Paths are injected so tests operate entirely inside a temp dir. Returns
    /// what changed; throws on a filesystem error.
    ///
    /// `replacingAlias` supports the Edit sheet's rename: the old block is removed
    /// before the new one is written, so a rename can't leave an orphan behind.
    /// `preserving` re-appends directives the sheet has no field for (`ProxyJump`,
    /// …) — without it, re-rendering the block from the sheet would delete them.
    @discardableResult
    static func save(
        entry: ServerEntry,
        managedHostsPath: String,
        configPath: String,
        replacingAlias: String? = nil,
        preserving: [String] = [],
        now: Date = Date()
    ) throws -> SaveResult {
        let fm = FileManager.default
        let sshDir = (managedHostsPath as NSString).deletingLastPathComponent
        try fm.createDirectory(
            atPath: sshDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // 1. Upsert the host block into the managed file (perms 600).
        var existing = (try? String(contentsOfFile: managedHostsPath, encoding: .utf8)) ?? ""
        // A rename writes under the new alias, so drop the old block first —
        // otherwise the stale one lingers and `ssh <old>` still resolves.
        if let old = replacingAlias, old != entry.name {
            existing = removingHostBlock(alias: old, from: existing)
        }
        var block = hostBlock(for: entry)
        if !preserving.isEmpty {
            block += "\n" + preserving.joined(separator: "\n")
        }
        let newContent = upserting(block: block, alias: entry.name, into: existing)
        try newContent.write(toFile: managedHostsPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: managedHostsPath)

        // 2. Ensure ~/.ssh/config Includes the managed file — backing it up first.
        let config = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        var backupPath: String?
        var inserted = false
        if !hasManagedInclude(in: config) {
            // Back up the existing config (only if it exists) before editing.
            if fm.fileExists(atPath: configPath) {
                let stamp = backupTimestamp(now)
                let bp = "\(configPath).sidekick-backup-\(stamp)"
                try fm.copyItem(atPath: configPath, toPath: bp)
                backupPath = bp
            }
            let updated = ensuringManagedInclude(in: config)
            try updated.write(toFile: configPath, atomically: true, encoding: .utf8)
            inserted = true
        }

        return SaveResult(
            managedHostsPath: managedHostsPath, backupPath: backupPath,
            insertedInclude: inserted)
    }

    /// Map the add-server sheet's per-connection choices into the `Settings`
    /// store, keyed by the saved ssh alias. mosh/watch are app settings, not
    /// ssh_config directives, so they live here rather than in the host block.
    /// `defaults` is injected so the mapping is unit-testable.
    static func applyConnectionSettings(
        alias: String, useMosh: Bool, watch: Bool,
        defaults: UserDefaults = .standard
    ) {
        let host = Host(name: alias, sshAlias: alias)
        Settings.setUseMosh(useMosh, host: host, defaults: defaults)
        Settings.setWatch(watch, host: host, defaults: defaults)
    }

    /// Carry a renamed server's per-alias state (mosh/watch/session order) over to
    /// its new alias and drop the old keys. Settings are keyed by host name, so
    /// without this a rename silently resets the host to defaults and leaves dead
    /// keys behind.
    static func migrateConnectionSettings(
        from old: String, to new: String, defaults: UserDefaults = .standard
    ) {
        guard old != new else { return }
        let oldHost = Host(name: old, sshAlias: old)
        let newHost = Host(name: new, sshAlias: new)
        Settings.setUseMosh(
            Settings.useMosh(host: oldHost, defaults: defaults), host: newHost,
            defaults: defaults)
        Settings.setWatch(
            Settings.watch(host: oldHost, defaults: defaults), host: newHost,
            defaults: defaults)
        let order = Settings.sessionOrder(host: oldHost, defaults: defaults)
        if !order.isEmpty {
            Settings.setSessionOrder(order, host: newHost, defaults: defaults)
        }
        Settings.clearHost(oldHost, defaults: defaults)
    }

    /// Timestamp for the config backup filename (sortable, filesystem-safe).
    static func backupTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
