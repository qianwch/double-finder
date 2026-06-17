import Foundation

/// Persistent list of favorite directory paths, stored in UserDefaults.
enum Favorites {
    private static let key = "Favorites"

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func contains(_ path: String) -> Bool {
        all().contains(path)
    }

    static func add(_ path: String) {
        var list = all()
        guard !list.contains(path) else { return }
        list.append(path)
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ path: String) {
        UserDefaults.standard.set(all().filter { $0 != path }, forKey: key)
    }

    /// Replaces the whole list (used by the organizer to persist a new order).
    static func setAll(_ list: [String]) {
        UserDefaults.standard.set(list, forKey: key)
    }
}
