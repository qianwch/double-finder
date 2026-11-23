import Foundation

/// Pure logic for persisting a panel's folder tabs across launches
/// (encode/decode to a UserDefaults-friendly array). Kept free of AppKit
/// so it can be unit-tested (TabSessionTests).
enum TabSession {
    struct Tab: Equatable {
        var path: String
        var locked: Bool
        /// Folder captured when the tab was folder-locked ("Lock Tab and
        /// Folder"). nil = unlocked or plain lock (close protection only).
        var lockedPath: String? = nil
        /// Title frozen when the tab was locked (either mode): the tab keeps
        /// showing this name instead of following the directory it has since
        /// navigated to. nil = unlocked, or a plain-locked tab saved before
        /// this field existed (its title keeps following the current path).
        var lockedTitle: String? = nil
    }

    /// UserDefaults representation: one dict per tab.
    static func encode(_ tabs: [Tab]) -> [[String: String]] {
        tabs.map {
            var dict = ["path": $0.path, "locked": $0.locked ? "1" : "0"]
            if let lockedPath = $0.lockedPath { dict["lockedPath"] = lockedPath }
            if let lockedTitle = $0.lockedTitle { dict["lockedTitle"] = lockedTitle }
            return dict
        }
    }

    /// Rebuilds tabs from the stored array. Unreachable directories fall back
    /// to `fallback` (the user's home) so a renamed/unmounted folder doesn't
    /// drop the tab — mirroring AppState's panel-path restore rule. A locked
    /// tab's captured folder is kept only while it still resolves (a deleted
    /// folder drops the memory, not the lock).
    static func decode(_ raw: Any?, isDirectory: (String) -> Bool, fallback: String) -> [Tab] {
        guard let list = raw as? [[String: String]] else { return [] }
        return list.compactMap { dict in
            guard let path = dict["path"], !path.isEmpty else { return nil }
            let locked = dict["locked"] == "1"
            var lockedPath: String?
            if locked, let stored = dict["lockedPath"], isDirectory(stored) {
                lockedPath = stored
            }
            var lockedTitle: String?
            if locked, let stored = dict["lockedTitle"], !stored.isEmpty {
                lockedTitle = stored
            }
            // Sessions saved before lockedTitle existed: a folder-locked tab
            // can still recover its frozen name from the captured folder; a
            // plain-locked tab stored nothing to recover (title keeps
            // following the path).
            if locked, lockedTitle == nil, let lockedPath = lockedPath {
                let component = (lockedPath as NSString).lastPathComponent
                lockedTitle = component.isEmpty ? "/" : component
            }
            return Tab(path: isDirectory(path) ? path : fallback,
                       locked: locked, lockedPath: lockedPath, lockedTitle: lockedTitle)
        }
    }

    /// Clamps a stored active-tab index to the decoded tab count.
    static func clampActive(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(index, count - 1))
    }
}
