import Foundation

/// Where a pull request is in its life, from `gh --json state`. Draft is a
/// separate flag on GitHub's side, so it stays a separate field. The sidebar
/// chip colors by this: a merged PR must not read as an open one.
enum PRState: String, Equatable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

/// A pull request surfaced as a clickable chip on a sidebar row and in the
/// toolbar "PRs" dropdown. `url` opens on GitHub.
struct PullRequest: Equatable {
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    /// Defaults to `.open` because the branch query is `gh pr list --state open`
    /// and can return nothing else; the by-number lookup fills in the real state.
    var state: PRState = .open
}

/// Pure GitHub helpers: parse a repo slug from a git remote URL, decode the
/// `gh pr list --json` payload, and build the git/gh argv. No process spawning
/// here so it's fully unit-testable (see PullRequestsTests).
enum GitHubPR {
    /// Extract "owner/repo" from a git remote URL. Handles the common forms:
    ///   git@github.com:owner/repo.git
    ///   https://github.com/owner/repo.git
    ///   ssh://git@github.com/owner/repo
    /// Returns nil for a non-GitHub or unparseable remote.
    static func slug(fromRemoteURL raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        // Only GitHub remotes (github.com, or an SSH host alias won't match — the
        // slug still comes from the path after the host, but we gate on the host
        // to avoid mis-parsing GitLab/Bitbucket URLs).
        guard let host = s.range(of: "github.com") else { return nil }
        var tail = String(s[host.upperBound...])
        while let f = tail.first, f == "/" || f == ":" { tail.removeFirst() }
        let parts = tail.split(separator: "/")
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Decode `gh pr list --json number,title,url,isDraft` output. Returns [] on
    /// empty/invalid JSON (gh missing, not a repo, or no matching PRs), sorted by
    /// number ascending for a stable display order.
    static func parse(json: String) -> [PullRequest] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { obj -> PullRequest? in
            guard let number = obj["number"] as? Int,
                  let url = obj["url"] as? String, !url.isEmpty else { return nil }
            return PullRequest(
                number: number,
                title: obj["title"] as? String ?? "",
                url: url,
                isDraft: obj["isDraft"] as? Bool ?? false,
                state: state(obj["state"]))
        }.sorted { $0.number < $1.number }
    }

    /// Decode the single-object payload of `gh pr view --json`. nil when the
    /// JSON is missing/unparseable or lacks the fields a chip needs.
    static func parseOne(json: String) -> PullRequest? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = obj["number"] as? Int,
              let url = obj["url"] as? String, !url.isEmpty
        else { return nil }
        return PullRequest(
            number: number,
            title: obj["title"] as? String ?? "",
            url: url,
            isDraft: obj["isDraft"] as? Bool ?? false,
            state: state(obj["state"]))
    }

    /// gh spells state `OPEN`/`CLOSED`/`MERGED`; anything else reads as open.
    private static func state(_ raw: Any?) -> PRState {
        (raw as? String).flatMap(PRState.init(rawValue:)) ?? .open
    }

    /// `git -C <cwd> rev-parse --abbrev-ref HEAD` — the session's current branch.
    static func branchArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
    }
    /// `git -C <cwd> remote get-url origin` — to derive the repo slug.
    static func remoteArgv(cwd: String) -> [String] {
        ["-C", cwd, "remote", "get-url", "origin"]
    }
    /// `gh pr list -R <slug> --head <branch> --state open --json …`. Scoped by
    /// `-R` so gh needs no working directory (works local + over ssh).
    static func prListArgv(slug: String, branch: String) -> [String] {
        ["pr", "list", "-R", slug, "--head", branch, "--state", "open",
         "--json", "number,title,url,isDraft", "--limit", "20"]
    }
    /// `gh pr view <number> -R <slug> --json …` — resolve ONE PR **by number**,
    /// in any state. This is how a PR number declared in a tmux window's name
    /// gets validated: such a PR usually has nothing to do with the window's own
    /// branch, and is often already merged. gh exits non-zero when the number
    /// doesn't exist, which the runner surfaces as nil.
    static func prViewArgv(slug: String, number: Int) -> [String] {
        ["pr", "view", String(number), "-R", slug,
         "--json", "number,title,url,isDraft,state"]
    }
    /// `gh pr create -R <slug> --head <branch> --title … --body …`. The branch must
    /// already be pushed to the remote. Prints the new PR's URL on success.
    static func prCreateArgv(slug: String, branch: String, title: String, body: String) -> [String] {
        ["pr", "create", "-R", slug, "--head", branch, "--title", title, "--body", body]
    }
}
