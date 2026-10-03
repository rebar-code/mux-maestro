import Foundation

/// Pure construction of the argument vectors for dropping a file onto a
/// session. No process spawning here so every piece is fully unit-testable
/// against a `FakeRunner`: each function returns the exact `argv` that
/// `TmuxService` runs.
///
/// **DROP** (file → server session): copy a file to the session's cwd (scp
/// remote / cp local), then PASTE the resulting path into the pane (the M11
/// decision: paste the path, do not auto-run).
///
/// These go straight to `scp`/`cp`/`ssh` as argv, so spaces and metacharacters
/// in local paths are safe by construction. The one exception is the scp
/// **remote** operand: scp expands the remote path through the remote login
/// shell, so that path portion is shell-quoted (via
/// `Ssh.shellQuoteAllowingTilde`) before the `alias:` prefix — see `copyArgv`.
enum FileTransfer {
    /// The control-master options scp shares with ssh so a file pull/push to a
    /// host reuses the same multiplexed connection the tree loads use, instead of
    /// re-handshaking. Mirrors `Ssh.opts` but WITHOUT the trailing host token —
    /// scp takes the host inside the `host:path` operand, not as a bare arg.
    static func scpOpts() -> [String] {
        let controlPath = "\(Ssh.controlDir)/ssh-%r@%h:%p"
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=60s",
            "-o", "ConnectTimeout=4",
            "-o", "BatchMode=yes",
        ]
    }

    /// Copy a local file TO a host. For the local host it's a plain
    /// `cp <src> <dst>`; for a remote host it's
    /// `scp <opts> <local-operand> <remote-operand>` where the remote side
    /// carries the `host:` prefix. The local path is passed as an argv element
    /// (no quoting needed); the remote path portion is shell-quoted because scp
    /// expands it through the remote login shell.
    ///
    /// - Parameters:
    ///   - host: the host the destination lives on (local ⇒ plain cp).
    ///   - localPath: the source path on the local machine.
    ///   - remotePath: the destination path on `host`.
    static func copyArgv(
        host: Host, localPath: String, remotePath: String
    ) -> (path: String, args: [String]) {
        if host.isLocal {
            return ("/bin/cp", [localPath, remotePath])
        }
        let alias = host.sshAlias ?? host.name
        // SECURITY: scp expands the remote path through the remote LOGIN SHELL
        // (`<remote-shell> -c 'scp -t <remotePath>'`), so spaces/`;`/`$()`/
        // backticks/`&&` in `remotePath` would execute on the host. Quote the
        // path portion before prefixing `alias:`. `shellQuoteAllowingTilde` (not
        // plain `shellQuote`) keeps a user-typed `~/report.html` tilde-expanding
        // to remote $HOME like the rest of the app; a malicious leading `~…`
        // (e.g. `~;rm`) fails that helper's tilde-segment validation and falls
        // back to full single-quoting automatically. The local `cp` branch above
        // needs no quoting — it passes operands as argv with no shell.
        let remoteOperand = "\(alias):" + Ssh.shellQuoteAllowingTilde(remotePath)
        return (Ssh.scpPath, scpOpts() + [localPath, remoteOperand])
    }

    /// The tmux argv that captures a pane's full visible output as plain text.
    /// `target` is a tmux target (a `session:window.pane`, `session:window`, or a
    /// bare pane id). Routed through the transport by the caller, so the same argv
    /// works local (`tmux capture-pane …`) or remote (ssh-wrapped automatically).
    static func capturePaneArgv(target: String) -> [String] {
        ["capture-pane", "-p", "-t", target]
    }

    // MARK: Drop destination

    /// The destination path a dropped file lands at on the target session: the
    /// session's cwd joined with the file's basename. `cwd` has any trailing slash
    /// normalized so we never produce a doubled separator.
    static func dropDestination(cwd: String, fileName: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return "\(trimmed)/\(fileName)"
    }

    // MARK: Environment resolution

    /// Candidate python3 paths (a Finder-launched app has a minimal PATH), same
    /// list the status provider uses. First executable wins; nil if none found.
    static var python3Path: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
