import Foundation

/// Named column configurations (TC custom column sets): a set is just a name
/// plus the optional-column ids it shows. Stored in UserDefaults "ColumnSets";
/// applying one writes AppSettings.visibleColumns.
struct ColumnSet: Equatable {
    var name: String
    var columns: [String]
}

enum ColumnSets {
    private static let key = "ColumnSets"

    static func all() -> [ColumnSet] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty,
                  let columns = dict["columns"] as? [String] else { return nil }
            return ColumnSet(name: name, columns: columns)
        }
    }

    static func setAll(_ sets: [ColumnSet]) {
        UserDefaults.standard.set(sets.map { ["name": $0.name, "columns": $0.columns] },
                                  forKey: key)
    }

    /// Saves (or replaces, by name) a set with the given columns.
    static func save(name: String, columns: [String]) {
        var sets = all()
        if let i = sets.firstIndex(where: { $0.name == name }) {
            sets[i].columns = columns
        } else {
            sets.append(ColumnSet(name: name, columns: columns))
        }
        setAll(sets)
    }

    static func remove(name: String) {
        setAll(all().filter { $0.name != name })
    }
}
