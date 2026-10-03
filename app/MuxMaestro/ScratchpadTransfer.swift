import Foundation

/// Pure construction of the argument vectors and invocations for the Milestone-11
/// scratchpad artifact conduit. No process spawning here so every piece is fully
/// unit-testable against a `FakeRunner`: each function returns the exact `argv`
/// (or invocation tuple) that `TmuxService` runs.
///
/// Two directions:
///  - **GRAB** (server/session → scratchpad): pull a file (scp remote / cp local)
///    or capture a pane's visible output, then feed it to the local scratchpad
///    (`scratchpad.py add <file>` for a file, `push --kind text` for captured
///    text) so it shows on the phone-pinned `/latest` view.
///  - **DROP** (file → server session): copy a file to the session's cwd
///    (scp remote / cp local), then PASTE the resulting path into the pane (the
///    M11 decision: paste the path, do not auto-run).
///
/// These go straight to `scp`/`cp`/`ssh`/`python3` as argv, so spaces and
/// metacharacters in local paths/titles are safe by construction. The one
/// exception is the scp **remote** operand: scp expands the remote path through
/// the remote login shell, so that path portion is shell-quoted (via
/// `Ssh.shellQuoteAllowingTilde`) before the `alias:` prefix — see `copyArgv`.
/// The remote scratchpad title in a pane-output capture is handled by the caller
/// piping bytes, not by argv.
enum ScratchpadTransfer {
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

    /// Copy a file FROM a host (grab) or TO a host (drop). For the local host
    /// it's a plain `cp <src> <dst>`; for a remote host it's
    /// `scp <opts> <remote-operand> <local-operand>` where exactly one side
    /// carries the `host:` prefix (the `remoteIsSource` side). Local paths are
    /// passed as argv elements (no quoting needed); the remote path portion is
    /// shell-quoted because scp expands it through the remote login shell.
    ///
    /// - Parameters:
    ///   - host: the host the remote operand lives on (nil/local ⇒ plain cp).
    ///   - localPath: the path on the local machine.
    ///   - remotePath: the path on `host` (only meaningful for a remote host).
    ///   - remoteIsSource: true for a GRAB (remote → local), false for a DROP
    ///     (local → remote). For the local host this just orders src/dst.
    static func copyArgv(
        host: Host, localPath: String, remotePath: String, remoteIsSource: Bool
    ) -> (path: String, args: [String]) {
        if host.isLocal {
            let src = remoteIsSource ? remotePath : localPath
            let dst = remoteIsSource ? localPath : remotePath
            return ("/bin/cp", [src, dst])
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
        let args: [String]
        if remoteIsSource {
            args = scpOpts() + [remoteOperand, localPath]
        } else {
            args = scpOpts() + [localPath, remoteOperand]
        }
        return (Ssh.scpPath, args)
    }

    /// The tmux argv that captures a pane's full visible output as plain text.
    /// `target` is a tmux target (a `session:window.pane`, `session:window`, or a
    /// bare pane id). Routed through the transport by the caller, so the same argv
    /// works local (`tmux capture-pane …`) or remote (ssh-wrapped automatically).
    static func capturePaneArgv(target: String) -> [String] {
        ["capture-pane", "-p", "-t", target]
    }

    /// The invocation that pushes a *file* to the local scratchpad:
    /// `python3 <scriptPath> add <file> --title <title>`. The scratchpad infers
    /// the kind from the file extension.
    static func addInvocation(
        python: String, scriptPath: String, file: String, title: String
    ) -> (path: String, args: [String]) {
        (python, [scriptPath, "add", file, "--title", title])
    }

    /// The invocation that pushes *content on stdin* to the local scratchpad:
    /// `python3 <scriptPath> push --kind <kind> --title <title>` (the caller pipes
    /// the bytes into stdin). Used for captured pane text (`--kind text`).
    static func pushInvocation(
        python: String, scriptPath: String, kind: String, title: String
    ) -> (path: String, args: [String]) {
        (python, [scriptPath, "push", "--kind", kind, "--title", title])
    }

    // MARK: Title helpers

    /// Title for a grabbed file: `<basename> @ <host>` (e.g. `report.html @ buildbox`).
    static func fileTitle(path: String, host: Host) -> String {
        let base = (path as NSString).lastPathComponent
        return "\(base) @ \(host.name)"
    }

    /// Title for grabbed pane output: `<session>:<win> @ <host>`.
    static func paneTitle(session: String, window: Int, host: Host) -> String {
        "\(session):\(window) @ \(host.name)"
    }

    // MARK: Drop destination

    /// The destination path a dropped file lands at on the target session: the
    /// session's cwd joined with the file's basename. `cwd` has any trailing slash
    /// normalized so we never produce a doubled separator.
    static func dropDestination(cwd: String, fileName: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return "\(trimmed)/\(fileName)"
    }

    // MARK: Environment resolution (filesystem-dependent — not exercised by the
    // pure-argv tests; the AppDelegate uses these to fill in `python` /
    // `scratchpadScript` / a staging path before calling the service.)

    /// Candidate python3 paths (a Finder-launched app has a minimal PATH), same
    /// list the status provider uses. First executable wins; nil if none found.
    static var python3Path: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Absolute path to the app's bundled `scratchpad.py` (see `BundledTools`).
    static var scriptPath: String { BundledTools.path(.scratchpad) }

    /// True when the scratchpad script + a python3 are both present locally.
    static var isAvailable: Bool {
        python3Path != nil && FileManager.default.fileExists(atPath: scriptPath)
    }

    /// A unique local staging path for a grabbed remote file, keeping the source
    /// extension so the scratchpad infers the right kind.
    static func stagingPath(for remotePath: String) -> String {
        let ext = (remotePath as NSString).pathExtension
        let base = (remotePath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let unique = "\(stem)-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...9999))"
        let name = ext.isEmpty ? unique : "\(unique).\(ext)"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }
}
