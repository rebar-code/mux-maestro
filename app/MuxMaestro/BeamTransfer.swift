import Foundation

/// Pure construction of the invocation for **Beam** — moving a running repo +
/// Claude Code session between this Mac and a remote SSH host, in any direction.
/// No process spawning here (that's `BeamRunner`), so the env + argv are fully
/// unit-testable against a fixed script path, exactly like `ScratchpadTransfer`.
///
/// The engine is the vendored `beam.sh` (bundled under `Resources/beam/`). Three
/// flows, all Mac-orchestrated (beam's model — the remote only runs ssh/rsync/git):
///  - **pushTakeover** — local → server. Transport repo + Claude history, stand up
///    a remote tmux running `claude --resume`, then respawn the source pane into an
///    attach to it (the seamless handoff).
///  - **pushDetach** — local → server, but stand the remote session up *detached*
///    (no pane respawn). Used as leg 2 of a server→server relay, where the app
///    reveals the destination session itself.
///  - **pull** — server → local. Bootstrap a local checkout if absent, then
///    converge repo + Claude history home (reverse path-rewrite). The app does the
///    local `claude --resume` + reveal, so there's no handoff here.
///
/// Histories are merged (idempotent hybrid-union DAG merge with path rewriting),
/// never clobbered — in either direction.
enum BeamTransfer {
    /// Which way the work moves, and how the destination session is stood up.
    enum Mode: Equatable {
        /// local → server; respawn `paneId` into the remote session on success.
        case pushTakeover(paneId: String)
        /// local → server; stand the remote session up detached (relay leg 2).
        case pushDetach
        /// server → local; transport only (the app resumes + reveals locally).
        case pull
    }

    /// A resolved beam request. `host` is always the **remote peer** — the target
    /// for a push, the source for a pull. `localDir` is the Mac-side project dir
    /// beam runs from (created by the caller for a pull bootstrap). `claudeSessionId`
    /// is nil for a non-Claude window (repo-only move).
    struct Request: Equatable {
        let mode: Mode
        let host: Host
        let localDir: String
        let claudeSessionId: String?
    }

    /// Why a request can't be beamed — surfaced up front for a precise error
    /// instead of a mid-transport failure.
    enum Rejection: Equatable {
        /// The remote peer resolved to the local host (beam needs a remote peer).
        case localPeer
        /// A remote host with no usable ssh alias (shouldn't happen in practice).
        case noSshAlias
        /// No project directory resolved for the row.
        case emptyDir
        /// Refusing to move the entire home directory (beam.sh refuses this too).
        case homeDir
    }

    /// Validate a request against `home` (`NSHomeDirectory()` in the app), or nil
    /// when it is safe to beam. Pure so the guard matrix is unit-tested.
    static func reject(_ req: Request, home: String) -> Rejection? {
        if req.host.isLocal { return .localPeer }
        if (req.host.sshAlias ?? "").isEmpty { return .noSshAlias }
        let dir = (req.localDir as NSString).expandingTildeInPath
        if dir.isEmpty { return .emptyDir }
        let normHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let normDir = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        if normDir == normHome { return .homeDir }
        return nil
    }

    /// The env overlay that drives `beam.sh` headlessly. Returned as an overlay
    /// (not a full environment) so the runner can merge it onto a PATH-corrected
    /// base — keeping this function pure and its output small enough to assert.
    static func env(for req: Request) -> [String: String] {
        var env: [String: String] = ["BEAM_CONFLICT": "skip"]  // no interactive TUI
        switch req.mode {
        case .pushTakeover(let paneId):
            env["BEAM_HANDOFF"] = "takeover"  // respawn the pane into the remote session
            env["BEAM_PANE"] = paneId
        case .pushDetach:
            env["BEAM_HANDOFF"] = "detach"    // stand up detached; app reveals it
        case .pull:
            break                             // transport only; app resumes locally
        }
        if let sid = req.claudeSessionId, !sid.isEmpty {
            env["BEAM_OPTS"] = "Claude history"  // sync the transcript...
            env["BEAM_RESUME_SID"] = sid         // ...and resume it on the far side
        } else {
            env["BEAM_OPTS"] = ""                // repo only — no Claude session here
        }
        return env
    }

    /// The invocation: `bash <scriptPath> <verb> <sshAlias>`. Run `bash` explicitly
    /// so a stripped exec bit on the bundled script can't break it. The verb is
    /// `pull` for a pull and `push` otherwise; the host is the remote peer.
    /// `cwd`/`env` are applied by the runner, not encoded here.
    static func invocation(scriptPath: String, req: Request) -> (path: String, args: [String]) {
        let verb: String
        switch req.mode {
        case .pull: verb = "pull"
        case .pushTakeover, .pushDetach: verb = "push"
        }
        return ("/bin/bash", [scriptPath, verb, req.host.sshAlias ?? req.host.name])
    }

    /// The bundled `beam.sh` inside the app (`Resources/beam/beam.sh`), or nil if
    /// missing from the build. `beam_merge.py` sits beside it (beam.sh resolves it
    /// relative to its own location), so returning this one path is enough.
    static func bundledScriptURL() -> URL? {
        Bundle.main.url(forResource: "beam", withExtension: "sh", subdirectory: "beam")
    }

    /// A user-facing message for a rejected request.
    static func rejectionMessage(_ rejection: Rejection, host: Host) -> String {
        switch rejection {
        case .localPeer:
            return "Beam moves a session between this Mac and a server — pick a remote host."
        case .noSshAlias:
            return "“\(host.name)” has no SSH alias to beam to."
        case .emptyDir:
            return "Couldn’t find a working directory for that session to beam."
        case .homeDir:
            return "That session’s directory is your home folder — refusing to beam all of it."
        }
    }
}
