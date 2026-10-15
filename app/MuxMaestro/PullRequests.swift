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
        return arr.compactMap(pullRequest(from:)).sorted { $0.number < $1.number }
    }

    /// One PR row, in `gh --json` or GraphQL node shape (they agree on these
    /// fields). nil when it lacks what a chip needs.
    private static func pullRequest(from obj: [String: Any]) -> PullRequest? {
        guard let number = obj["number"] as? Int,
              let url = obj["url"] as? String, !url.isEmpty else { return nil }
        return PullRequest(
            number: number,
            title: obj["title"] as? String ?? "",
            url: url,
            isDraft: obj["isDraft"] as? Bool ?? false,
            state: state(obj["state"]))
    }

    /// Decode the single-object payload of `gh pr view --json`. nil when the
    /// JSON is missing/unparseable or lacks the fields a chip needs.
    static func parseOne(json: String) -> PullRequest? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return pullRequest(from: obj)
    }

    /// gh spells state `OPEN`/`CLOSED`/`MERGED`; anything else reads as open.
    private static func state(_ raw: Any?) -> PRState {
        (raw as? String).flatMap(PRState.init(rawValue:)) ?? .open
    }

    /// `git -C <cwd> rev-parse --abbrev-ref HEAD` — the session's current branch.
    static func branchArgv(cwd: String) -> [String] {
        ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
    }
    /// `git -C <cwd> rev-parse --verify --quiet refs/remotes/origin/<branch>` —
    /// the branch's last-pushed commit. It moves on every push from this Mac, which
    /// is when a PR can appear, so the sidebar re-asks GitHub only then. Exits
    /// non-zero for an unpushed branch.
    static func originRefArgv(cwd: String, branch: String) -> [String] {
        ["-C", cwd, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"]
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

// MARK: - Batched head lookups

/// GitHub's GraphQL budget as one answer reported it.
struct RateReading: Equatable {
    let remaining: Int
    let resetAt: Date
}

extension GitHubPR {
    /// Branches per GraphQL document. GitHub prices a document by the connections
    /// it may return, a hundred per point, so fifty aliased lookups cost one point
    /// — the same as ONE `gh pr list --head`. T3 Code batches the same way.
    static let headsPerQuery = 50

    /// One document asking for the open PRs of `count` heads, aliased `h0…`, with
    /// the budget alongside. Branch names travel as variables, never inlined, so no
    /// branch name can break the document.
    static func headsQuery(count: Int) -> String {
        let vars = (0..<count).map { ", $h\($0): String!" }.joined()
        let fields = (0..<count).map {
            "h\($0): pullRequests(headRefName: $h\($0), states: OPEN, first: 20) "
                + "{ nodes { number title url isDraft state } }"
        }.joined(separator: " ")
        return "query($owner: String!, $name: String!\(vars)) "
            + "{ rateLimit { remaining resetAt } "
            + "repository(owner: $owner, name: $name) { \(fields) } }"
    }

    /// `gh api graphql` argv for one batch. nil for a malformed slug or no branches.
    static func headsArgv(slug: String, branches: [String]) -> [String]? {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !branches.isEmpty
        else { return nil }
        var argv = ["api", "graphql", "-f", "query=\(headsQuery(count: branches.count))",
                    "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])"]
        for (i, branch) in branches.enumerated() { argv += ["-f", "h\(i)=\(branch)"] }
        return argv
    }

    /// Decode a `headsQuery` answer back onto `branches` (the order the argv used).
    /// nil unless every alias came back: a partial answer would blank real chips.
    static func parseHeads(json: String, branches: [String])
        -> (prsByBranch: [String: [PullRequest]], rate: RateReading?)?
    {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = obj["data"] as? [String: Any],
              let repo = body["repository"] as? [String: Any]
        else { return nil }
        var out: [String: [PullRequest]] = [:]
        for (i, branch) in branches.enumerated() {
            guard let conn = repo["h\(i)"] as? [String: Any],
                  let nodes = conn["nodes"] as? [[String: Any]] else { return nil }
            out[branch] = nodes.compactMap(pullRequest(from:)).sorted { $0.number < $1.number }
        }
        var rate: RateReading?
        if let r = body["rateLimit"] as? [String: Any],
           let remaining = r["remaining"] as? Int,
           let reset = (r["resetAt"] as? String).flatMap(ISO8601DateFormatter().date(from:)) {
            rate = RateReading(remaining: remaining, resetAt: reset)
        }
        return (out, rate)
    }
}

/// The sidebar's branch-PR answers per repo, and the rule for when to re-ask.
///
/// GitHub's GraphQL budget (5,000 points an hour) is shared by every gh, agent
/// and app signed in as the user. Asking once per window cwd every 20s spent
/// ~5,400 an hour on its own. So a repo is asked only when:
/// - a window sits on a branch it has not asked about (asked once), or a push
///   moved a known branch's origin ref (then it stays hot for `hotWindow`,
///   because `gh pr create` lands seconds after the push);
/// - or `refreshInterval` has passed, to catch merges and PRs opened elsewhere.
/// A host whose budget drops below `reserve` pauses until GitHub's reset.
final class BranchPRCache {
    static let refreshInterval: TimeInterval = 300
    static let hotWindow: TimeInterval = 120
    static let reserve = 250

    private struct Repo {
        /// branch -> origin ref at the last ask.
        var signatures: [String: String] = [:]
        var prs: [String: [PullRequest]] = [:]
        var asked: Date?
        var hotUntil: Date = .distantPast
    }

    private let lock = NSLock()
    private var repos: [String: Repo] = [:]
    private var pausedUntil: [String: Date] = [:]

    private static func key(host: String, slug: String) -> String { "\(host)\n\(slug)" }

    /// Whether to ask GitHub about this repo now. `signatures` maps every branch an
    /// open window sits on to its origin ref ("" when unpushed).
    func isDue(host: String, slug: String, signatures: [String: String],
               now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = pausedUntil[host], now < until { return false }
        let key = Self.key(host: host, slug: slug)
        var repo = repos[key] ?? Repo()
        // A branch never asked about: ask once. A known branch whose origin ref
        // moved was just pushed: ask, and stay hot for the PR that follows.
        if signatures.contains(where: { repo.signatures[$0.key] == nil }) { return true }
        if signatures.contains(where: { repo.signatures[$0.key] != $0.value }) {
            repo.hotUntil = now + Self.hotWindow
            repos[key] = repo
            return true
        }
        guard let asked = repo.asked else { return true }
        return now < repo.hotUntil || now.timeIntervalSince(asked) >= Self.refreshInterval
    }

    /// Store an answer. A low budget pauses every repo on `host` until reset.
    func record(host: String, slug: String, signatures: [String: String],
                prs: [String: [PullRequest]], rate: RateReading?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(host: host, slug: slug)
        var repo = repos[key] ?? Repo()
        repo.signatures.merge(signatures) { _, new in new }
        repo.prs.merge(prs) { _, new in new }
        repo.asked = now
        repos[key] = repo
        if let rate, rate.remaining < Self.reserve { pausedUntil[host] = rate.resetAt }
    }

    /// A failed ask keeps the last answer and waits a full interval, so a repo
    /// that can't be read (no access, budget gone) isn't retried every scan.
    func recordFailure(host: String, slug: String, signatures: [String: String],
                       now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(host: host, slug: slug)
        var repo = repos[key] ?? Repo()
        repo.signatures.merge(signatures) { _, new in new }
        repo.asked = now
        repo.hotUntil = .distantPast
        repos[key] = repo
    }

    /// The last answer for a branch; [] before the first.
    func prs(host: String, slug: String, branch: String) -> [PullRequest] {
        lock.lock(); defer { lock.unlock() }
        return repos[Self.key(host: host, slug: slug)]?.prs[branch] ?? []
    }
}
