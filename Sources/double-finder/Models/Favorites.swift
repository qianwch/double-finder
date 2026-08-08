import Foundation

/// One favorites entry (TC directory hotlist): a path plus an optional custom
/// display name and an optional group (groups render as submenus).
struct FavoriteItem: Equatable {
    var path: String
    var name: String = ""    // custom display name; empty → folder name
    var group: String = ""   // empty → top level

    var displayName: String {
        if !name.isEmpty { return name }
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }

    var asDictionary: [String: String] {
        var d = ["path": path]
        if !name.isEmpty { d["name"] = name }
        if !group.isEmpty { d["group"] = group }
        return d
    }

    init(path: String, name: String = "", group: String = "") {
        self.path = path
        self.name = name
        self.group = group
    }

    init?(dictionary: [String: String]) {
        guard let path = dictionary["path"], !path.isEmpty else { return nil }
        self.init(path: path, name: dictionary["name"] ?? "", group: dictionary["group"] ?? "")
    }
}

/// Persistent favorites, stored in UserDefaults under "FavoriteItems"
/// ([[String:String]] with path/name/group). The legacy "Favorites" plain
/// path array migrates on first read.
enum Favorites {
    private static let itemsKey = "FavoriteItems"
    private static let legacyKey = "Favorites"

    static func items() -> [FavoriteItem] {
        let defaults = UserDefaults.standard
        if let raw = defaults.array(forKey: itemsKey) as? [[String: String]] {
            return raw.compactMap { FavoriteItem(dictionary: $0) }
        }
        // One-time migration from the plain path array.
        if let legacy = defaults.stringArray(forKey: legacyKey) {
            let migrated = legacy.map { FavoriteItem(path: $0) }
            setItems(migrated)
            defaults.removeObject(forKey: legacyKey)
            return migrated
        }
        return []
    }

    static func setItems(_ items: [FavoriteItem]) {
        UserDefaults.standard.set(items.map { $0.asDictionary }, forKey: itemsKey)
    }

    /// Paths only, in stored order.
    static func all() -> [String] { items().map(\.path) }

    static func contains(_ path: String) -> Bool { items().contains { $0.path == path } }

    static func add(_ path: String) {
        var list = items()
        guard !list.contains(where: { $0.path == path }) else { return }
        list.append(FavoriteItem(path: path))
        setItems(list)
    }

    static func remove(_ path: String) {
        setItems(items().filter { $0.path != path })
    }

    /// Splits into top-level entries and groups, groups ordered by first
    /// appearance and members keeping stored order.
    static func grouped() -> (top: [FavoriteItem], groups: [(name: String, items: [FavoriteItem])]) {
        var top: [FavoriteItem] = []
        var order: [String] = []
        var byGroup: [String: [FavoriteItem]] = [:]
        for item in items() {
            if item.group.isEmpty {
                top.append(item)
            } else {
                if byGroup[item.group] == nil { order.append(item.group) }
                byGroup[item.group, default: []].append(item)
            }
        }
        return (top, order.map { ($0, byGroup[$0] ?? []) })
    }
}
