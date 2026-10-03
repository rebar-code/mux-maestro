import Foundation

/// A host the sidebar can show tmux sessions for: either the local machine or a
/// remote machine reached over SSH. The local host always exists and sorts
/// first; remote hosts come from the user's `~/.ssh/config` Host aliases.
struct Host: Equatable {
    /// Display + identity name. "localhost" for local; the ssh alias otherwise.
    let name: String
    /// nil for the local host; the ssh alias (`ssh <alias>`) for a remote host.
    let sshAlias: String?

    /// The always-present local host.
    static let local = Host(name: "localhost", sshAlias: nil)

    var isLocal: Bool { sshAlias == nil }

    /// Identity used to diff host rows across refreshes.
    var identity: String { "H:\(name)" }
}

/// Whether a host's ssh probe currently succeeds. Drives the greyed
/// "unreachable" treatment without blocking other hosts or the local tree.
enum HostReachability: Equatable {
    /// Local host, or a remote whose probe succeeded.
    case reachable
    /// Remote host whose ssh probe failed/timed out.
    case unreachable
    /// Reachable over ssh, but tmux isn't installed on it (so no sessions; we
    /// offer a plain shell / install instead).
    case tmuxMissing
    /// Not yet probed.
    case unknown
}

/// Pure parsing of `~/.ssh/config` into the list of remote hosts. Mirrors the
/// zsh `server()` helper exactly:
///
///   awk 'tolower($1)=="host"{for(i=2;i<=NF;i++)if($i!~/[*?]/)print $i}'
///
/// i.e. every token after `Host` on a `Host` line that is not a `*`/`?`
/// wildcard pattern becomes an alias. A line may list several aliases
/// (`Host host3 host3-server`); each becomes its own host. Duplicate aliases
/// (the same name appearing twice) are collapsed to the first occurrence,
/// preserving file order. No process spawning here so it is fully unit-tested.
enum SshConfig {
    /// Default config location.
    static var defaultPath: String {
        NSString(string: "~/.ssh/config").expandingTildeInPath
    }

    /// Normalize line endings so a CRLF (`\r\n`) config parses identically to an
    /// LF one. `\r` is NOT in `.whitespaces`, so without this a trailing `\r`
    /// clings to the last token on every line — breaking Include detection
    /// (duplicate Include + a fresh backup on every add) and host-block parsing.
    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Parse the aliases out of ssh-config text into ordered, de-duplicated
    /// remote `Host`s (the local host is added by the caller, not here).
    static func parseHosts(_ text: String) -> [Host] {
        var seen = Set<String>()
        var hosts: [Host] = []
        for rawLine in normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip inline comments and surrounding whitespace.
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            // ssh_config keywords may be separated from values by whitespace or
            // `=`; `Host` never uses `=` in practice but tolerate both.
            let tokens = line
                .replacingOccurrences(of: "=", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard let keyword = tokens.first, keyword.lowercased() == "host" else { continue }
            for alias in tokens.dropFirst() {
                // Skip wildcard patterns, exactly like the awk filter.
                if alias.contains("*") || alias.contains("?") { continue }
                if seen.insert(alias).inserted {
                    hosts.append(Host(name: alias, sshAlias: alias))
                }
            }
        }
        return hosts
    }

    /// Read + parse the config at `path` (defaults to `~/.ssh/config`),
    /// **following `Include` directives** so hosts defined in included files
    /// (notably MuxMaestro's own `~/.ssh/sidekick_hosts`) also appear. Returns the
    /// local host first, followed by the parsed remote hosts in file order with
    /// includes expanded in place. A missing or unreadable config yields just the
    /// local host.
    static func loadHosts(path: String? = nil) -> [Host] {
        let p = path ?? defaultPath
        let remotes = parseHostsFollowingIncludes(
            path: p, reader: { try? String(contentsOfFile: $0, encoding: .utf8) },
            glob: Self.globMatches)
        return [.local] + remotes
    }

    /// Parse aliases out of the config at `path`, recursively expanding `Include`
    /// directives. `reader` reads a file's text (nil if missing); `glob` expands a
    /// possibly-glob path into concrete file paths. Both are injected so the whole
    /// include-following walk is unit-testable against an in-memory fixture
    /// filesystem with no real `~/.ssh` access. De-duplicates aliases across all
    /// files (first occurrence wins), preserving order.
    static func parseHostsFollowingIncludes(
        path: String,
        reader: (String) -> String?,
        glob: (String) -> [String]
    ) -> [Host] {
        var seen = Set<String>()
        var hosts: [Host] = []
        var visited = Set<String>()  // guard against include cycles

        func walk(_ filePath: String, baseDir: String) {
            let resolved = expandTilde(filePath, baseDir: baseDir)
            guard visited.insert(resolved).inserted else { return }
            guard let text = reader(resolved) else { return }
            let dir = (resolved as NSString).deletingLastPathComponent
            for rawLine in normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !line.isEmpty else { continue }
                let tokens = line
                    .replacingOccurrences(of: "=", with: " ")
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                guard let keyword = tokens.first?.lowercased() else { continue }
                if keyword == "include" {
                    // Each token after `Include` is a path/glob, resolved relative
                    // to the including file's directory when not absolute/tilde.
                    for pattern in tokens.dropFirst() {
                        let abs = expandTilde(pattern, baseDir: dir)
                        let matches = glob(abs)
                        // No glob match (e.g. a plain not-yet-globbed path): still
                        // try the literal path so a simple `Include file` works.
                        for m in (matches.isEmpty ? [abs] : matches) {
                            walk(m, baseDir: dir)
                        }
                    }
                    continue
                }
                guard keyword == "host" else { continue }
                for alias in tokens.dropFirst() {
                    if alias.contains("*") || alias.contains("?") { continue }
                    if seen.insert(alias).inserted {
                        hosts.append(Host(name: alias, sshAlias: alias))
                    }
                }
            }
        }

        let baseDir = (path as NSString).deletingLastPathComponent
        walk(path, baseDir: baseDir)
        return hosts
    }

    /// Expand a leading `~`/`~/` to the home directory; resolve a relative path
    /// against `baseDir` (ssh resolves a relative Include against the directory of
    /// the file containing it). Absolute paths pass through.
    static func expandTilde(_ path: String, baseDir: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        if path.hasPrefix("/") { return path }
        return (baseDir as NSString).appendingPathComponent(path)
    }

    /// Glob a path into concrete file paths (used to expand `Include` globs like
    /// `~/.ssh/conf.d/*`). Returns the literal path when it isn't a glob.
    static func globMatches(_ pattern: String) -> [String] {
        guard pattern.contains("*") || pattern.contains("?") || pattern.contains("[") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, 0, nil, &g) == 0 else { return [] }
        var results: [String] = []
        for i in 0..<Int(g.gl_pathc) {
            if let c = g.gl_pathv[i] { results.append(String(cString: c)) }
        }
        return results
    }
}

/// Turns a tmux argument vector into the concrete `(executable, argv)` to run —
/// locally it's `tmux <args>`; remotely it's `ssh <opts> <host> tmux <args>`.
/// This is the seam that makes a remote host behave exactly like the local one:
/// `TmuxService` builds tmux argv as before and the transport decides how it's
/// dispatched. Pure (no spawning) so the ssh-prefixing + ControlMaster opts are
/// unit-testable against the FakeRunner.
protocol TmuxTransport {
    /// The wall-clock timeout a single command should be bounded by on this
    /// transport (remote wants a longer ceiling than local).
    var timeout: TimeInterval { get }
    /// Map a tmux argv into the executable + argv to actually run.
    func command(forTmux args: [String]) -> (path: String, args: [String])?
    /// The shell command string the libghostty surface runs to attach-or-create
    /// `session` on this host (a full command line, since the surface spawns a
    /// shell). nil if the transport can't be resolved (e.g. no local tmux).
    func attachCommand(session: String) -> String?
}

/// Local transport: runs the host's `tmux` binary directly (the M1–M7 path).
struct LocalTmuxTransport: TmuxTransport {
    let tmuxPath: String?
    var timeout: TimeInterval = 4.0

    func command(forTmux args: [String]) -> (path: String, args: [String])? {
        guard let tmuxPath else { return nil }
        return (tmuxPath, args)
    }

    func attachCommand(session: String) -> String? {
        guard let tmuxPath else { return nil }
        return "\(tmuxPath) attach -t \(Ssh.shellQuote(session))"
    }
}

/// Remote transport: every tmux invocation becomes
/// `ssh <controlmaster opts> <host> tmux <args>`. Connection reuse
/// (ControlMaster=auto + a per-host ControlPath + ControlPersist) means the
/// 1.5s poll reuses one multiplexed connection per host instead of
/// re-handshaking every command — the difference between a responsive remote
/// tree and one that blocks the UI.
struct SshTmuxTransport: TmuxTransport {
    let host: String
    /// Remote tmux is invoked by bare name (resolved on the remote's PATH); the
    /// remote may install tmux anywhere, so we don't hardcode an absolute path.
    var remoteTmux: String = "tmux"
    var sshPath: String = Ssh.sshPath
    /// Local mosh client path (nil ⇒ not installed ⇒ mosh attach unavailable,
    /// caller falls back to ssh). Injectable so the mosh argv is unit-testable.
    var moshPath: String? = Ssh.moshPath
    /// Longer than local: a slow/offline host shouldn't freeze the UI, but the
    /// ConnectTimeout below caps the truly-offline case; this bounds a sluggish
    /// but reachable host.
    var timeout: TimeInterval = 8.0

    func command(forTmux args: [String]) -> (path: String, args: [String])? {
        // CRITICAL: ssh does NOT preserve argv boundaries — it joins the remote
        // command tokens with spaces and re-parses them through the remote login
        // shell. So tmux args containing `#` (every `-F #{…}` format string),
        // spaces, `$`, etc. would be mangled (a `#` even starts a remote-shell
        // comment, eating the rest of the line). Single-quote every tmux token
        // so the remote shell receives it verbatim — making a remote tmux call
        // behave exactly like a local one.
        //
        // The one exception (PR#9 carry-over fix): a leading `~` / `~/` in a
        // token (the new-session `-c ~` default dir) must reach the remote shell
        // UNquoted so it tilde-expands to the remote `$HOME`; single-quoting it
        // sent a literal `~` and tmux created the session under a directory
        // named `~`. `shellQuoteAllowingTilde` leaves only the leading tilde
        // segment unquoted and quotes the rest of the token — preserving the
        // uniform per-token quoting invariant for everything else.
        let quoted = ([remoteTmux] + args).map(Ssh.shellQuoteAllowingTilde)
        return (sshPath, Ssh.opts(host: host) + quoted)
    }

    /// The mosh form of the attach command — UDP, roaming, survives network
    /// changes — for a mosh-enabled remote. Discovery polling never uses this
    /// (mosh is wrong for scripted one-shots); only the interactive surface does.
    /// Returns nil when the local `mosh` client isn't installed, so the caller
    /// falls back to the ssh attach.
    ///
    ///   mosh --ssh='ssh <controlmaster flags>' <host> -- env TERM=… tmux new -A -s <session>
    ///
    /// Quoting: ghostty runs the whole string through a local `bash -c`, which
    /// tokenizes the line — so the `--ssh` value and the session name are each
    /// single-quoted for THAT shell. mosh then execs the post-`--` argv on the
    /// remote directly (no remote login-shell re-parse, unlike ssh), so the
    /// session keeps just its one local quote. `Ssh.opts` appends the host, but
    /// mosh adds the host itself (the positional arg), so the `--ssh` value uses
    /// the host-less `controlFlags`; reusing them lets mosh's bootstrap ssh ride
    /// the warm ControlMaster socket even though the live session is mosh-UDP.
    func moshAttachCommand(session: String) -> String? {
        guard let moshPath else { return nil }
        let sshCmd = ([sshPath] + Ssh.controlFlags).joined(separator: " ")
        let remote = "env TERM=xterm-256color "
            + "\(remoteTmux) new-session -A -s \(Ssh.shellQuote(session))"
        return "\(moshPath) --ssh=\(Ssh.shellQuote(sshCmd)) \(host) -- \(remote)"
    }

    func attachCommand(session: String) -> String? {
        // -t forces a PTY so the remote tmux is interactive; new-session -A
        // attaches if it exists, else creates it (attach-or-create).
        //
        // Force a portable TERM: the embedded surface advertises `xterm-ghostty`,
        // whose terminfo entry the remote host almost never has, so the remote
        // tmux/login bails with "missing or unsuitable terminal: xterm-ghostty".
        // `xterm-256color` is present essentially everywhere.
        //
        // TWO shells parse this: ghostty runs the whole string through a local
        // `bash -c`, then ssh re-parses the trailing tokens through the REMOTE
        // shell. So the session needs TWO levels of quoting — quote it for the
        // remote, build the full remote command, then quote THAT for the local
        // shell as a single argument. With only one level a name like
        // `buildbox serv` split remotely into `-s buildbox` + a stray `serv` command.
        // `Ssh.opts` already ends with the host, so the remote command follows it
        // directly — do NOT repeat the host (that made ssh run `<host>` as the
        // remote command: "command not found: <host>").
        let opts = Ssh.opts(host: host).joined(separator: " ")
        let remote = "env TERM=xterm-256color "
            + "\(remoteTmux) new-session -A -s \(Ssh.shellQuote(session))"
        return "\(sshPath) -t \(opts) \(Ssh.shellQuote(remote))"
    }
}

/// SSH option construction shared by the transports — the ControlMaster reuse
/// settings + connect/batch timeouts. Pure so the exact opts are unit-tested.
enum Ssh {
    /// Path to the ssh client binary.
    static let sshPath = "/usr/bin/ssh"

    /// Path to the scp binary (used by the M11 file drop).
    static let scpPath = "/usr/bin/scp"

    /// Path to the local `mosh` client binary, or nil if not installed locally.
    /// mosh runs locally as the client; the remote needs `mosh-server`, which is
    /// detected + auto-provisioned separately. Mirrors the tmux/herdr discovery.
    static var moshPath: String? {
        ["/opt/homebrew/bin/mosh", "/usr/local/bin/mosh", "/usr/bin/mosh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Directory holding the per-host control sockets. Created lazily.
    static var controlDir: String {
        NSString(string: "~/.sidekick").expandingTildeInPath
    }

    /// The `-o` options every ssh invocation to a host uses. ControlMaster=auto
    /// + a per-host ControlPath + ControlPersist=60s multiplex all commands to a
    /// host over one connection (the poll reuses it instead of re-handshaking);
    /// ConnectTimeout bounds the offline case and BatchMode prevents any
    /// interactive password/passphrase prompt from hanging the subprocess.
    /// The `-o` ControlMaster/timeout flags shared by every ssh invocation,
    /// WITHOUT the trailing host. ControlPath uses ssh's own %r@%h:%p tokens so
    /// it's host-independent (expanded at connect time) — which is why mosh's
    /// `--ssh` can reuse these flags directly (mosh appends the host itself).
    static var controlFlags: [String] {
        let controlPath = "\(controlDir)/ssh-%r@%h:%p"
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=60s",
            "-o", "ConnectTimeout=4",
            // ConnectTimeout only bounds the initial handshake. A host that
            // connects fine but then goes sluggish (or its link wedges) would hang
            // each command near the 8s per-command ceiling — and a remote loadTree
            // issues several serially, so one slow box stalled a whole poll cycle
            // for 15-18s, blocking the LOCAL sidebar (which waits on group.wait()).
            // Keepalives tear a wedged connection down in ~5s; the command then
            // returns nil, which preserves the last-known tree and retries next
            // poll — strictly better than hanging the cycle.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "BatchMode=yes",
        ]
    }

    static func opts(host: String) -> [String] {
        controlFlags + [host]
    }

    /// Ensure the control-socket directory exists (0700) before the first ssh
    /// command so ControlMaster can create its socket there.
    static func ensureControlDir() {
        try? FileManager.default.createDirectory(
            atPath: controlDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// `ssh -O exit` argv to tear down a host's multiplexed ControlMaster
    /// connection on app terminate.
    static func sshExitArgv(host: String) -> [String] {
        ["-O", "exit"] + opts(host: host)
    }

    /// Single-quote a string for safe embedding in a shell command line (used
    /// only for the attach command the libghostty surface runs through a shell).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Like `shellQuote`, but lets a LEADING tilde (`~` or `~/…`) reach the
    /// remote shell unquoted so it expands to `$HOME` — every other character
    /// (including the rest of the path) is still single-quoted verbatim. This is
    /// what lets the remote new-session default dir `~` become an absolute home
    /// path instead of a literal `~` directory, without weakening quoting for any
    /// other token. Bare `~` → `~`; `~/code/my proj` → `~/'code/my proj'`.
    /// `~user` and `~user/…` likewise keep `~user` literal, quoting the rest.
    ///
    /// SECURITY (shell-injection fix): leaving the tilde segment bare is only
    /// safe when that segment is a real tilde-expansion token — `~` or `~user`
    /// with a username drawn from `[A-Za-z0-9._-]`. A free-text field (the remote
    /// new-session dir defaults to `~`) could otherwise carry a payload like
    /// `~; rm -rf ~/data`, ``~`id` ``, `~$(touch /x)`, `~&&id`, `~|id`, `~ ; ls`,
    /// or `~user; id` — emitting the segment before the first `/` unquoted would
    /// inject those metacharacters straight into the remote login shell. So we
    /// validate the tilde segment against `^~[A-Za-z0-9._-]*$` and, if it doesn't
    /// match, fall back to fully single-quoting the whole token. The legit cases
    /// (`~`, `~/code/x`, `~deploy/app`, `/abs/path`, `a~b`) are unaffected.
    static func shellQuoteAllowingTilde(_ s: String) -> String {
        guard s.hasPrefix("~") else { return shellQuote(s) }
        if let slash = s.firstIndex(of: "/") {
            let tildePart = String(s[..<slash])               // "~" or "~user"
            let rest = String(s[s.index(after: slash)...])    // after the slash
            // Only leave the tilde segment bare if it's a safe expansion token;
            // otherwise the whole token is fully quoted (no injection vector).
            guard isSafeTildeSegment(tildePart) else { return shellQuote(s) }
            return rest.isEmpty ? "\(tildePart)/" : "\(tildePart)/" + shellQuote(rest)
        }
        // No slash: bare "~" or "~user". Leave unquoted only when safe.
        guard isSafeTildeSegment(s) else { return shellQuote(s) }
        return s
    }

    /// True iff `segment` is a bare tilde-expansion token safe to leave unquoted:
    /// a leading `~` optionally followed by a username made only of
    /// `[A-Za-z0-9._-]`. Anything carrying a shell metacharacter (`;` `` ` `` `$`
    /// `&` `|`, whitespace, …) fails and forces full quoting.
    private static func isSafeTildeSegment(_ segment: String) -> Bool {
        guard segment.hasPrefix("~") else { return false }
        let user = segment.dropFirst()
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return user.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Canonicalizes an ssh alias to the machine it actually reaches.
///
/// `~/.ssh/config` is an alias table, not a server list: `Host buildbox buildbox1`
/// declares two names for one box, and two separate blocks can share a `HostName`.
/// Rendering both aliases' tmux sessions in the sidebar lists every session twice —
/// and polling both doubles the ssh traffic to one machine.
///
/// `ssh -G <alias>` resolves the config the same way `ssh` itself does (following
/// `Match`/`Include`/wildcards), and prints the effective settings. It performs no
/// network I/O, so it's safe and fast. Results are cached for the process lifetime;
/// an ssh-config edit mid-session needs a relaunch to re-canonicalize, matching how
/// the rest of the app treats that file.
enum SshIdentity {
    /// The local machine's identity — never collapses with a remote.
    static let localIdentity = "local"

    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// Pull `user@hostname:port` out of `ssh -G` output. Takes the FIRST occurrence
    /// of each key (ssh prints the effective value first). Returns nil when the
    /// output is missing `hostname`, which is the only field we can't synthesize.
    static func parse(sshDashG output: String) -> String? {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            guard ["user", "hostname", "port"].contains(key), fields[key] == nil else { continue }
            fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let hostname = fields["hostname"], !hostname.isEmpty else { return nil }
        let user = fields["user"] ?? ""
        let port = fields["port"] ?? "22"
        return "\(user)@\(hostname):\(port)"
    }

    /// Resolve `host` to its canonical machine identity, blocking on `ssh -G` for a
    /// cache miss. Call OFF the main thread. Falls back to the alias itself when ssh
    /// can't resolve it — a unique fallback, so an unresolvable alias never collapses
    /// with another host.
    static func canonical(_ host: Host, runner: CommandRunner = ProcessCommandRunner(timeout: 4.0))
        -> String
    {
        guard let alias = host.sshAlias else { return localIdentity }
        lock.lock()
        if let hit = cache[alias] { lock.unlock(); return hit }
        lock.unlock()

        let out = runner.run(Ssh.sshPath, ["-G", alias])
        let resolved = out.flatMap(parse) ?? alias

        lock.lock()
        cache[alias] = resolved
        lock.unlock()
        return resolved
    }

    /// Non-blocking read for the main thread: the cached identity, or nil if this
    /// alias hasn't been resolved yet. Callers treat nil as "not yet known" and fall
    /// back to the alias, so a pre-warm miss degrades to today's behaviour for one
    /// refresh rather than spawning a subprocess during layout.
    static func cached(_ host: Host) -> String? {
        guard let alias = host.sshAlias else { return localIdentity }
        lock.lock()
        defer { lock.unlock() }
        return cache[alias]
    }

    /// Resolve every host off-main so `cached(_:)` hits on the next render.
    static func prewarm(_ hosts: [Host], runner: CommandRunner = ProcessCommandRunner(timeout: 4.0)) {
        for host in hosts { _ = canonical(host, runner: runner) }
    }

    /// Collapse entries that resolve to the same machine, keeping the first — the
    /// order `~/.ssh/config` declares them, so `buildbox` wins over `buildbox1`.
    /// `identity` returns nil when unknown; those entries are always kept (an
    /// unresolved alias is never assumed to be a duplicate).
    static func dedupe<T>(_ items: [T], identity: (T) -> String?) -> [T] {
        var seen = Set<String>()
        return items.filter { item in
            guard let id = identity(item) else { return true }
            return seen.insert(id).inserted
        }
    }

    /// Test seam: drop the memoized resolutions.
    static func resetCacheForTesting() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
