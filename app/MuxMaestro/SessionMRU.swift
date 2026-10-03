import Foundation

/// A switchable session identity: name + host. Shared by the AppDelegate MRU
/// tracker and the ⌘` cycler overlay. Defined here (not in AppDelegate) so the
/// test target links the pure ordering logic without pulling in AppKit.
struct SessionRef: Equatable {
    let name: String
    let host: Host
}

/// A switchable window identity: a window index inside its session, on a host.
/// The ⌘` cycler walks these — one flat stack across every session, so the
/// window you were just in is one tap away wherever it lives.
struct WindowRef: Equatable {
    let session: String
    let window: Int
    let host: Host

    /// The session this window belongs to — what committing a pick attaches to.
    var sessionRef: SessionRef { SessionRef(name: session, host: host) }
}

/// Pure most-recently-used ordering for the ⌘` cycler. Unit-tested.
enum SessionMRU {
    /// Order entries for the cycler: MRU entries that still exist come first (in
    /// MRU order), then the remaining `existing` entries in their given order.
    /// Seeding from `existing` makes ⌘` useful immediately, before any in-app
    /// switch has populated the MRU stack. MRU entries that no longer exist (a
    /// killed session, a closed window) are dropped.
    ///
    /// Generic over the entry type so sessions and windows share one tested rule.
    static func order<Ref: Equatable>(mru: [Ref], existing: [Ref]) -> [Ref] {
        var out: [Ref] = []
        for ref in mru where existing.contains(ref) && !out.contains(ref) {
            out.append(ref)
        }
        for ref in existing where !out.contains(ref) {
            out.append(ref)
        }
        return out
    }
}
