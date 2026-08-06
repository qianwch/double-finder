import Foundation

/// Pure logic for persisting a panel's folder tabs across launches
/// (encode/decode to a UserDefaults-friendly array). Kept free of AppKit
/// so it can be unit-tested (TabSessionTests).
enum TabSession {
    struct Tab: Equatable {
        var path: String
        var locked: Bool
    }

    /// UserDefaults representation: one dict per tab.
    static func encode(_ tabs: [Tab]) -> [[String: String]] {
        tabs.map { ["path": $0.path, "locked": $0.locked ? "1" : "0"] }
    }

    /// Rebuilds tabs from the stored array. Unreachable directories fall back
    /// to `fallback` (the user's home) so a renamed/unmounted folder doesn't
    /// drop the tab — mirroring AppState's panel-path restore rule.
    static func decode(_ raw: Any?, isDirectory: (String) -> Bool, fallback: String) -> [Tab] {
        guard let list = raw as? [[String: String]] else { return [] }
        return list.compactMap { dict in
            guard let path = dict["path"], !path.isEmpty else { return nil }
            return Tab(path: isDirectory(path) ? path : fallback,
                       locked: dict["locked"] == "1")
        }
    }

    /// Clamps a stored active-tab index to the decoded tab count.
    static func clampActive(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(index, count - 1))
    }
}
