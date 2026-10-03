import Foundation

/// Attributing running Docker containers — and the host ports they publish — to a
/// directory on this Mac. Pure: argv builders, output parsers and the join rule,
/// no process spawning, no AppKit.
///
/// Written directory-first rather than worktree-first on purpose. The same join
/// answers "what is this orphaned worktree still running?" and "does this tmux
/// window have a dev server on :5173?" — only the directory changes.
///
/// **Docker blocks.** At nine concurrent Supabase stacks on this machine a single
/// `docker ps` took over five minutes. Every caller must run this off the sidebar
/// poll, under an explicit timeout, and treat a nil result as
/// `DockerSnapshot.unavailable` — "unknown", never "0 containers".

/// One running container, reduced to the facts that let a directory claim it.
struct DockerContainer: Equatable {
    let name: String
    /// `com.supabase.cli.project` — the Supabase CLI's project id, **truncated to
    /// 40 characters** by the CLI (same cap as the container name). Empty when the
    /// label is absent.
    let supabaseProject: String
    /// `com.docker.compose.project.working_dir` — the absolute directory
    /// `docker compose` was invoked from. Empty when the label is absent.
    let composeWorkingDir: String
    /// Published host ports, ascending and deduped. Container-only ports (no
    /// `->` in `docker ps`'s Ports column) are not published and are dropped.
    let ports: [Int]
    /// `{{.RunningFor}}` — docker's own human phrasing ("2 days ago"), shown as
    /// the idle age in the Running popover's Stop confirm so a human can judge
    /// whether an unclaimed stack is abandoned or a live database. Empty when the
    /// column is absent (a snapshot taken by an older template).
    let runningFor: String

    init(name: String, supabaseProject: String, composeWorkingDir: String,
         ports: [Int], runningFor: String = "") {
        self.name = name
        self.supabaseProject = supabaseProject
        self.composeWorkingDir = composeWorkingDir
        self.ports = ports
        self.runningFor = runningFor
    }
}

/// The result of asking Docker what is running.
///
/// `unavailable` is a first-class case, not an empty list: Docker missing, the
/// daemon down, or `docker ps` exceeding its timeout must all read as "we don't
/// know", because "0 containers" is the answer that makes a stale worktree look
/// idle.
enum DockerSnapshot: Equatable {
    case unavailable
    case containers([DockerContainer])
}

/// What one directory owns in Docker right now.
struct DockerAttribution: Equatable {
    /// False when the snapshot was `unavailable`. `containers` / `ports` are then
    /// meaningless and the row says so.
    let known: Bool
    let containers: Int
    /// Published host ports across those containers, ascending and deduped.
    let ports: [Int]

    static let unknown = DockerAttribution(known: false, containers: 0, ports: [])
}

enum Docker {
    // MARK: argv

    /// Tab-separated `docker ps` template. Tabs (not spaces) because the Ports
    /// column itself contains ", " separators, and `.Names` never contains a tab.
    static let psTemplate =
        #"{{.Names}}\#t{{.Label "com.supabase.cli.project"}}\#t"#
        + #"{{.Label "com.docker.compose.project.working_dir"}}\#t{{.Ports}}\#t{{.RunningFor}}"#

    /// `docker ps --no-trunc --format <template>` — running containers only
    /// (`ps` without `-a`). `--no-trunc` so a long container name isn't elided;
    /// it does **not** un-truncate the Supabase label, which the CLI writes
    /// already capped at 40 characters.
    static func psArgv() -> [String] { ["ps", "--no-trunc", "--format", psTemplate] }

    /// The Supabase CLI config inside a checkout, which carries `project_id`.
    static func configTomlPath(root: String) -> String {
        Worktrees.normalize(root) + "/supabase/config.toml"
    }

    // MARK: parsers

    /// Parse the tab-separated `docker ps` output produced by `psTemplate`.
    /// Malformed lines (fewer than four fields) are skipped rather than guessed at.
    static func parsePS(_ output: String) -> [DockerContainer] {
        output.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let f = line.components(separatedBy: "\t")
            guard f.count >= 4, !f[0].isEmpty else { return nil }
            return DockerContainer(
                name: f[0],
                supabaseProject: f[1].trimmingCharacters(in: .whitespaces),
                composeWorkingDir: Worktrees.normalize(f[2]),
                ports: parsePorts(f[3]),
                runningFor: f.count >= 5 ? f[4].trimmingCharacters(in: .whitespaces) : "")
        }
    }

    /// Published **host** ports out of `docker ps`'s Ports column.
    ///
    /// Two shapes appear there: `3000/tcp` (exposed inside the container network
    /// only — invisible from this Mac, so dropped) and
    /// `0.0.0.0:54473->3000/tcp` / `[::]:54473->3000/tcp` (published — the host
    /// port is what a browser would hit). IPv4 and IPv6 publish the same port, so
    /// the result is deduped.
    static func parsePorts(_ column: String) -> [Int] {
        var found = Set<Int>()
        for raw in column.components(separatedBy: ",") {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard let arrow = entry.range(of: "->") else { continue }
            let hostSide = entry[entry.startIndex..<arrow.lowerBound]
            // `0.0.0.0:54473` / `[::1]:54473` — the host port is after the last colon.
            guard let colon = hostSide.lastIndex(of: ":"),
                  let port = Int(hostSide[hostSide.index(after: colon)...]) else { continue }
            found.insert(port)
        }
        return found.sorted()
    }

    /// The `project_id` out of a `supabase/config.toml` — the key that ties a
    /// checkout to its own local stack. Returns nil when the file has no `project_id`.
    ///
    /// Commented-out lines are ignored: `worktree-supabase.sh` rewrites this file
    /// per worktree and leaves the original id behind as a comment.
    static func supabaseProjectID(configToml: String) -> String? {
        for raw in configToml.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix("project_id") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: the join

    /// Whether a container's `com.supabase.cli.project` label names the stack of a
    /// checkout whose config.toml says `project_id`.
    ///
    /// The label is **truncated to 40 characters** by the Supabase CLI, so plain
    /// equality misses most spin-created stacks: label
    /// `acme-app-portal-spin-feat-rate-auditor-f` (40) against project_id
    /// `acme-app-portal-spin-feat-rate-auditor-field-capture` (51).
    ///
    /// A plain `hasPrefix` is the wrong repair and was shipped once as a bug: the
    /// main repo's own stack `acme-app-portal` prefixes every
    /// `acme-app-portal-spin-*` id, so one live stack made every orphan look busy.
    /// The prefix rule therefore only applies when the label is *exactly* at the
    /// truncation limit, which is the only case where information was lost.
    static let supabaseLabelLimit = 40

    static func supabaseStackMatches(label: String, projectID: String) -> Bool {
        guard !label.isEmpty, !projectID.isEmpty else { return false }
        if label == projectID { return true }
        return label.count == supabaseLabelLimit && projectID.hasPrefix(label)
    }

    /// Everything running for `path`: its Supabase stack (joined by project id) plus
    /// any compose project whose working dir is that directory or inside it.
    ///
    /// `projectID` is the value read from that checkout's own `supabase/config.toml`;
    /// pass nil when the checkout has none (or could not be read) and only the
    /// compose join applies.
    static func attribute(
        snapshot: DockerSnapshot, path: String, supabaseProjectID projectID: String?
    ) -> DockerAttribution {
        guard case .containers(let all) = snapshot else { return .unknown }
        let root = Worktrees.normalize(path)
        let mine = all.filter { c in
            if let projectID, supabaseStackMatches(label: c.supabaseProject, projectID: projectID) {
                return true
            }
            return !c.composeWorkingDir.isEmpty
                && Worktrees.isInside(path: c.composeWorkingDir, root: root)
        }
        var ports = Set<Int>()
        for c in mine { ports.formUnion(c.ports) }
        return DockerAttribution(known: true, containers: mine.count, ports: ports.sorted())
    }
}
