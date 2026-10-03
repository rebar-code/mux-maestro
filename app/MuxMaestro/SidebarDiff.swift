import Foundation

/// The minimal shape the sidebar diff needs from a tree node: a stable identity,
/// a display string, and children. Pure (Foundation-only) so the diff can be
/// compiled into — and asserted by — the test target without AppKit.
protocol DiffableTreeNode {
    var diffIdentity: String { get }
    var diffDisplay: String { get }
    var diffChildren: [Self] { get }
}

/// Deep structural + display equality used by the sidebar's poll so a refresh
/// only reloads the outline (and loses no expansion/selection state) on a real
/// change. Two trees are equal iff they have the same shape, the same node
/// identities in the same order, and the same display strings at every node.
enum SidebarDiff {
    static func treesEqual<Node: DiffableTreeNode>(_ a: [Node], _ b: [Node]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.diffIdentity != y.diffIdentity || x.diffDisplay != y.diffDisplay { return false }
            if !treesEqual(x.diffChildren, y.diffChildren) { return false }
        }
        return true
    }

    /// For ONE level of the tree, compute the animated delta that turns `oldIDs`
    /// (the current children's identities, in order) into `newIDs` (the next
    /// children's identities): the indexes to remove — positions in `oldIDs` — and
    /// to insert — positions in `newIDs`. Returns nil when the rows present in both
    /// change relative order, because a pure remove+insert can't express a move and
    /// the caller must fall back to a full reload rather than feed NSOutlineView an
    /// inconsistent batch (which would crash). Assumes identities are unique within
    /// the level (they are — the tree is built with stable, unique identities).
    static func levelDelta(oldIDs: [String], newIDs: [String]) -> (removes: IndexSet, inserts: IndexSet)? {
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)

        // The surviving rows must keep their relative order in both lists.
        let survivingOld = oldIDs.filter { newSet.contains($0) }
        let survivingNew = newIDs.filter { oldSet.contains($0) }
        guard survivingOld == survivingNew else { return nil }

        var removes = IndexSet()
        for (i, id) in oldIDs.enumerated() where !newSet.contains(id) { removes.insert(i) }

        var inserts = IndexSet()
        for (i, id) in newIDs.enumerated() where !oldSet.contains(id) { inserts.insert(i) }

        return (removes, inserts)
    }
}
