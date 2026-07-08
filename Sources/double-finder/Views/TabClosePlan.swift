import Foundation

/// Pure index math for the tab context-menu bulk-close actions. Returns the
/// indices to remove in DESCENDING order (safe for sequential `remove(at:)`).
/// Locked tabs are always protected. `locked[i]` is the lock state of tab i.
enum TabClosePlan {
    /// Close every tab except `keep` and any locked tab.
    static func othersToClose(count: Int, keep: Int, locked: [Bool]) -> [Int] {
        (0..<count).reversed().filter { $0 != keep && !(locked[safe: $0] ?? false) }
    }
    /// Close every tab to the right of `from` that is not locked.
    static func rightToClose(count: Int, from: Int, locked: [Bool]) -> [Int] {
        (0..<count).reversed().filter { $0 > from && !(locked[safe: $0] ?? false) }
    }
}

extension Array {
    /// Bounds-checked subscript (nil when out of range). Shared by TabClosePlan
    /// and TabBarView's per-tab locked lookup.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
