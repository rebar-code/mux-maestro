import Foundation

/// Which pull requests a sidebar **window row** is about.
///
/// Before this, a window's chip was purely "the open PR for the branch checked
/// out in the window's cwd". That is right for a normal work window and wrong
/// for every watcher window: `watch PR #393 #394 CI` sitting in the monorepo
/// showed `#411` (the cwd's branch), and `pr1026-review-fixes` showed `#1025`.
///
/// A window's PRs are now the union of
///   (a) the PR numbers **declared** for the window — first those an agent set in
///       the `@mm_prs` window option, then those in the window's name — and
///   (b) the open PR for the window cwd's branch (the old behavior).
///
/// Everything here is Foundation-only and pure so it compiles into the test
/// target; the `gh` calls live in `TmuxService`.
enum WindowPRs {

    // MARK: - Name parsing

    /// A PR number is only read out of a window name behind an **explicit
    /// marker**. A bare number is never a PR reference — `2.1.238` is a version,
    /// `data-17-19-3-pms-vendors` is a dataset name. The two markers are:
    ///
    /// 1. `#` immediately followed by digits — `#411`, `PR #393 #394`.
    /// 2. The token `pr` (case-insensitive) followed by digits, with an optional
    ///    separator of spaces and/or one of `# - _ :` between them — `PR 410`,
    ///    `PR#411`, `pr-405`, `pr1026`.
    ///
    /// The `pr` token must start on a **word boundary** (start of string, or a
    /// non-alphanumeric before it), which is what keeps `expression-42`,
    /// `sprint-3` and `approve-12` from matching. The digit run must not be
    /// followed by a letter (`#3rd`, `pr12ab` are not references), must not lead
    /// with `0`, and is capped at 6 digits.
    ///
    /// Each marker yields at most ONE number, so `PR 393 394` reads as [393] —
    /// the second bare number has no marker of its own. Write `PR #393 #394`.
    /// Results are deduped, in order of appearance.
    ///
    /// Parsing a name is a guess; every number it returns is checked against the
    /// real repo before a chip is drawn (see `TmuxService.pullRequest(slug:number:)`).
    static func numbers(inName name: String) -> [Int] {
        let chars = Array(name)
        var out: [Int] = []
        var seen = Set<Int>()
        var i = 0

        /// Read a digit run starting at `j`, or nil if it isn't a plausible PR number.
        func readNumber(from j: Int) -> (value: Int, next: Int)? {
            var k = j
            var digits = ""
            while k < chars.count, chars[k].isASCII, chars[k].isNumber {
                digits.append(chars[k])
                k += 1
            }
            guard !digits.isEmpty, digits.count <= maxDigits, digits.first != "0",
                  let value = Int(digits) else { return nil }
            // A number glued to letters is part of a word, not a reference.
            if k < chars.count, chars[k].isLetter { return nil }
            return (value, k)
        }

        func take(_ found: (value: Int, next: Int)) {
            if seen.insert(found.value).inserted { out.append(found.value) }
            i = found.next
        }

        while i < chars.count {
            let c = chars[i]
            if c == "#" {
                if let found = readNumber(from: i + 1) { take(found); continue }
                i += 1
                continue
            }
            if (c == "p" || c == "P"), i + 1 < chars.count,
               chars[i + 1] == "r" || chars[i + 1] == "R",
               i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber) {
                var j = i + 2
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, separators.contains(chars[j]) { j += 1 }
                while j < chars.count, chars[j] == " " { j += 1 }
                if let found = readNumber(from: j) { take(found); continue }
            }
            i += 1
        }
        return out
    }

    /// Longest plausible PR number. GitHub's biggest repos are in the six digits.
    static let maxDigits = 6
    private static let separators: Set<Character> = ["#", "-", "_", ":"]

    /// The tmux window user option an agent sets to declare the window's PRs:
    /// space-separated numbers, e.g. `1082 1085`.
    static let prsOptionKey = "@mm_prs"
    /// The tmux window user option naming the `owner/repo` those PRs live in.
    static let repoOptionKey = "@mm_repo"

    /// All PR numbers declared for a window: the `@mm_prs` metadata an agent set
    /// first (an explicit statement beats a guess from the name), then the numbers
    /// in `name` that aren't already listed. With no metadata this is exactly
    /// `numbers(inName:)`.
    static func declaredNumbers(metadata: [Int], name: String) -> [Int] {
        var seen = Set<Int>()
        return (metadata + numbers(inName: name)).filter { seen.insert($0).inserted }
    }

    // MARK: - Which repo a declared number belongs to

    /// The repo slug to resolve a window's declared PR numbers against.
    ///
    /// A non-empty `declaredRepo` (the `@mm_repo` window option) wins outright: the
    /// agent said which repo it means. Otherwise the window's own cwd. But watcher
    /// windows often sit somewhere that isn't a checkout at all — `monitor-pr-405`
    /// runs in `~/code/github/acme-app`, a plain directory holding several clones — so
    /// fall back to the slug the **session's other windows agree on**. A tmux
    /// session is one project by convention, so a single distinct slug across its
    /// windows is a safe answer; zero or two-plus is not, and yields nil (no
    /// chip) rather than a guess against the wrong repo.
    static func slugForDeclared(
        declaredRepo: String = "", windowSlug: String?, sessionSlugs: [String?]
    ) -> String? {
        let repo = declaredRepo.trimmingCharacters(in: .whitespaces)
        if !repo.isEmpty { return repo }
        if let windowSlug, !windowSlug.isEmpty { return windowSlug }
        let distinct = Set(sessionSlugs.compactMap { $0 }.filter { !$0.isEmpty })
        return distinct.count == 1 ? distinct.first : nil
    }

    // MARK: - Union

    /// Open PRs first, then merged/closed ones. Within each group, declared PRs
    /// come first (they are what the window is *about*), then the cwd-branch PRs
    /// that aren't already listed. Deduped by number.
    ///
    /// Open-first because declared numbers are sticky — an agent's `@mm_prs` keeps
    /// a PR after it merges — and a row shows only `maxChips` (one) chip, so a
    /// stale merged PR must not take that chip from the window's current open one.
    static func merge(declared: [PullRequest], branch: [PullRequest]) -> [PullRequest] {
        var seen = Set<Int>()
        var out: [PullRequest] = []
        for pr in declared + branch where seen.insert(pr.number).inserted {
            out.append(pr)
        }
        return out.filter { $0.state == .open } + out.filter { $0.state != .open }
    }

    /// Whether the window's work has landed: at least one PR merged and none
    /// still open. A closed PR counts for nothing either way. The row then shows
    /// its trash without hover and closes without the confirm.
    static func allMerged(_ prs: [PullRequest]) -> Bool {
        prs.contains { $0.state == .merged } && !prs.contains { $0.state == .open }
    }

    // MARK: - Write-back

    /// The new `@mm_prs` value for a window after detection, or nil when there is
    /// nothing to write: `declared` followed by every OPEN `found` PR it doesn't
    /// already list, in found order.
    ///
    /// Additive only — it never drops a declared number. Dropping would erase an
    /// agent's declaration the moment its PR merges, and the declaration is what
    /// keeps a merged PR tied to the window that still sits on it.
    ///
    /// Only PRs in `readSlug` qualify: the repo the window's `@mm_prs` numbers are
    /// resolved against on the next scan (see `slugForDeclared`). A branch PR from
    /// the cwd's repo, written under an `@mm_repo` naming another repo, would come
    /// back as a different PR or none. A nil `readSlug` writes nothing.
    static func backfill(declared: [Int], found: [PullRequest], readSlug: String?) -> [Int]? {
        guard let readSlug else { return nil }
        var seen = Set(declared)
        let added = found.filter {
            $0.state == .open
                && GitHubPR.slug(fromRemoteURL: $0.url)?.lowercased() == readSlug.lowercased()
                && seen.insert($0.number).inserted
        }
        return added.isEmpty ? nil : declared + added.map(\.number)
    }

    // MARK: - PRs screen

    /// Invert window → PRs into PR → windows, for the PRs screen. A PR is keyed
    /// by URL, since numbers repeat across repos. Every state is kept: a merged
    /// PR that windows still sit on is what the screen is for.
    ///
    /// Ordered by repo slug, then open PRs before merged/closed, then newest
    /// number first. Each PR's windows keep their input order.
    static func index<W>(_ windows: [(window: W, prs: [PullRequest])])
        -> [(slug: String, pr: PullRequest, windows: [W])] {
        var order: [String] = []
        var byURL: [String: (slug: String, pr: PullRequest, windows: [W])] = [:]
        for (window, prs) in windows {
            for pr in prs {
                if byURL[pr.url] == nil {
                    order.append(pr.url)
                    byURL[pr.url] = (GitHubPR.slug(fromRemoteURL: pr.url) ?? "", pr, [])
                }
                byURL[pr.url]?.windows.append(window)
            }
        }
        return order.compactMap { byURL[$0] }.sorted { a, b in
            if a.slug != b.slug { return a.slug < b.slug }
            let aOpen = a.pr.state == .open, bOpen = b.pr.state == .open
            if aOpen != bOpen { return aOpen }
            return a.pr.number > b.pr.number
        }
    }

    // MARK: - Row display

    /// How many PR numbers a window row spells out before the rest collapse into
    /// a `+N` overflow pill.
    ///
    /// One. This is measured, not a taste call: the sidebar is 220pt, window rows
    /// are indented, and two numeric chips plus the row's own name did not fit —
    /// the second chip rendered as `#102` with its last digit cut off and the name
    /// shrank to `6: pr1…`. One chip plus a `+N` pill costs ~65pt and leaves the
    /// name its share. The hidden PRs stay one click away in the overflow menu.
    static let maxChips = 1

    /// Split a window's PRs into the chips to draw and the count hidden behind
    /// the overflow pill (0 = no overflow).
    static func chipLayout(_ prs: [PullRequest]) -> (visible: [PullRequest], overflow: Int) {
        let visible = Array(prs.prefix(maxChips))
        return (visible, prs.count - visible.count)
    }
}

/// Lifecycle words for the chip tooltip, shared by the row and the overflow menu.
extension PullRequest {
    /// "Open" / "Draft" / "Merged" / "Closed".
    var stateWord: String {
        switch state {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .open: return isDraft ? "Draft" : "Open"
        }
    }

    /// `"Merged PR #393 · feat(competitors): …"` — the chip's tooltip.
    var chipTooltip: String {
        "\(stateWord) PR #\(number)" + (title.isEmpty ? "" : " · \(title)")
    }
}

/// Resolved pull requests keyed by (repo slug, number).
///
/// A PR number's *identity* — title, url — never changes, and merged/closed are
/// terminal, so those are cached for the life of the process; so are misses (a
/// number that doesn't exist never will). Only an **open** PR is re-checked, and
/// only after `openTTL`, so a merge eventually repaints the chip. This keeps the
/// name-declared lookups off the 1.5s poll's subprocess budget (see PR #67).
///
/// Thread-safe: the sidebar reads/writes it from the off-main scan workers.
final class PRIdentityCache {
    /// How long a PR that is still open may be trusted before re-asking `gh`.
    static let openTTL: TimeInterval = 300

    private struct Entry {
        let pr: PullRequest?
        let fetched: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    static func key(slug: String, number: Int) -> String { "\(slug)#\(number)" }

    /// The cached PR, or nil when absent or known not to exist.
    func pr(slug: String, number: Int) -> PullRequest? {
        lock.lock(); defer { lock.unlock() }
        return entries[Self.key(slug: slug, number: number)]?.pr
    }

    /// Whether `gh` must be asked about this (slug, number) right now.
    func needsFetch(slug: String, number: Int, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[Self.key(slug: slug, number: number)] else { return true }
        guard let pr = entry.pr else { return false }
        switch pr.state {
        case .merged, .closed: return false
        case .open: return now.timeIntervalSince(entry.fetched) >= Self.openTTL
        }
    }

    /// Record a lookup. `pr == nil` records a miss (no such PR in that repo).
    func store(slug: String, number: Int, pr: PullRequest?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries[Self.key(slug: slug, number: number)] = Entry(pr: pr, fetched: now)
    }
}
