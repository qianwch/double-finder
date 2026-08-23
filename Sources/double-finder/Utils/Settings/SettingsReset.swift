import Foundation

/// Which UserDefaults keys each Settings category owns, and how to put them back
/// to their factory state (the "Reset to Defaults" buttons).
///
/// Only *preferences* are listed. Everything the user typed or collected —
/// favorites, the server address book, panel paths, tabs, window frame,
/// migration flags — is deliberately absent: resetting preferences must never
/// throw away data. `protectedKeys` states that boundary explicitly so a test
/// can hold the line when new keys are added.
///
/// Pure logic apart from the UserDefaults writes, so the key tables are unit
/// testable (`SettingsResetTests`).
enum SettingsReset {

    /// Category id (matching `SettingsCategory.id`) → the fixed keys it owns.
    static let keysByCategory: [String: [String]] = [
        "general": [
            "ViewMode", "FoldersFirst", "ConfirmTrash", "TerminalApp", "EditorApp", "Language",
        ],
        "appearance": [
            "Appearance", "ColorByType",
            "ListFontName", "ListFontSize", "IconSize", "ZoomLinked",
            "LeftIconSize", "RightIconSize", "LeftListFontSize", "RightListFontSize",
            "TypeColors.light", "TypeColors.dark",
            "CommandLineColors.light", "CommandLineColors.dark",
        ],
        "panels": [
            "VisibleColumns", "ColumnWidths",
            "ShowDriveBar", "ShowDriveDropdown",
            "LeftShowHidden", "RightShowHidden",
        ],
        "toolbar": [
            "ToolbarButtonIDs",
        ],
        // Shortcuts are stored one key per command (kb.<cmd> / kb.off.<cmd>),
        // so they are matched by prefix instead of enumerated here.
        "shortcuts": [],
        // Favorites are data, not preferences — never reset.
        "favorites": [],
    ]

    /// Key prefixes a category owns wholesale (dynamic, one key per command).
    static let prefixesByCategory: [String: [String]] = [
        "shortcuts": ["kb."],
    ]

    /// Categories that offer a "Reset This Page" button, in sidebar order.
    static let resettableCategories = ["general", "appearance", "panels", "toolbar", "shortcuts"]

    /// Keys a reset must never touch: user data, address books, session state.
    /// Anything added here is a promise that "Reset All Settings" keeps it.
    static let protectedKeys: Set<String> = [
        "FavoriteItems", "Favorites",
        "ServerConnections", "ServerConnectionsMigrated",
        "S3Connections", "SFTPBookmarks", "SMBBookmarks", "LastSFTPConnection",
        "LeftPanelPath", "RightPanelPath",
        "LeftPanelTabs", "RightPanelTabs", "LeftPanelActiveTab", "RightPanelActiveTab",
        "MainWindowFrame",
        // Authored by the user, so a preferences reset keeps them: custom
        // toolbar commands carry shell scripts, column sets carry named layouts.
        "CustomToolbarButtons", "ColumnSets",
    ]

    /// Every preference key a full reset clears (static ones; prefixed keys are
    /// resolved against the live defaults at reset time).
    static var allKeys: [String] {
        resettableCategories.flatMap { keysByCategory[$0] ?? [] }
    }

    /// All prefixes a full reset clears.
    static var allPrefixes: [String] {
        resettableCategories.flatMap { prefixesByCategory[$0] ?? [] }
    }

    /// Restores one category to its defaults by removing the keys it owns.
    static func reset(category id: String, in defaults: UserDefaults = .standard) {
        remove(keys: keysByCategory[id] ?? [],
               prefixes: prefixesByCategory[id] ?? [],
               in: defaults)
    }

    /// Restores every preference category to its defaults. Data keys survive.
    static func resetAll(in defaults: UserDefaults = .standard) {
        remove(keys: allKeys, prefixes: allPrefixes, in: defaults)
    }

    private static func remove(keys: [String], prefixes: [String], in defaults: UserDefaults) {
        for key in keys where !protectedKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
        guard !prefixes.isEmpty else { return }
        // Prefixed keys are open-ended (one per command), so sweep the domain.
        for key in defaults.dictionaryRepresentation().keys
        where prefixes.contains(where: { key.hasPrefix($0) }) && !protectedKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }
}
