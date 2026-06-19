import AppKit

/// Static data + content loading for the Help window. Pure logic — no UI.
enum HelpContent {
    static let projectURL = URL(string: "https://github.com/qianwch/double-finder")!
    static let issuesURL = URL(string: "https://github.com/qianwch/double-finder/issues")!

    /// App version string from Info.plist (embedded in the Mach-O), default "1.0".
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Translation key for the line pointing users at the shortcut editor.
    static let customizeHintKey = "To customize shortcuts, use Commands ▸ Customize Shortcuts…"

    /// One row in the cheat-sheet: a command-name translation key + its display combo.
    struct Shortcut { let nameKey: String; let keys: String }
    /// A titled group of shortcuts; titleKey is a translation key.
    struct ShortcutGroup { let titleKey: String; let shortcuts: [Shortcut] }

    /// Curated reference of the built-in default shortcuts, grouped by purpose.
    /// Key combos mirror what the menus display. Customizable bindings can be
    /// changed via Commands ▸ Customize Shortcuts (see customizeHintKey).
    static let shortcutGroups: [ShortcutGroup] = [
        ShortcutGroup(titleKey: "Navigation", shortcuts: [
            Shortcut(nameKey: "Open Parent Folder", keys: "⌫"),
            Shortcut(nameKey: "Refresh", keys: "⌘R"),
            Shortcut(nameKey: "Go to Folder…", keys: "⌘⇧G"),
            Shortcut(nameKey: "Focus Command Line", keys: "⌘L"),
            Shortcut(nameKey: "Swap Panels", keys: "⌘U"),
            Shortcut(nameKey: "Open in Terminal", keys: "⌘⇧T"),
        ]),
        ShortcutGroup(titleKey: "Selection", shortcuts: [
            Shortcut(nameKey: "Select All", keys: "⌘A"),
            Shortcut(nameKey: "Select by Pattern", keys: "+"),
            Shortcut(nameKey: "Unselect by Pattern", keys: "-"),
            Shortcut(nameKey: "Invert Selection", keys: "*"),
            Shortcut(nameKey: "Quick Filter", keys: "⌘F"),
        ]),
        ShortcutGroup(titleKey: "File Operations", shortcuts: [
            Shortcut(nameKey: "Quick Look", keys: "F3"),
            Shortcut(nameKey: "Edit", keys: "F4"),
            Shortcut(nameKey: "Copy", keys: "F5"),
            Shortcut(nameKey: "Move", keys: "F6"),
            Shortcut(nameKey: "New Directory", keys: "F7"),
            Shortcut(nameKey: "Delete", keys: "F8"),
            Shortcut(nameKey: "Move to Trash", keys: "⌘⌫"),
        ]),
        ShortcutGroup(titleKey: "Panels & Tabs", shortcuts: [
            Shortcut(nameKey: "New Tab", keys: "⌘T"),
            Shortcut(nameKey: "Close Tab", keys: "⌘W"),
            Shortcut(nameKey: "Directory Tree", keys: "⌘⇧D"),
            Shortcut(nameKey: "Branch View", keys: "⌘⇧B"),
        ]),
        ShortcutGroup(titleKey: "Archives", shortcuts: [
            Shortcut(nameKey: "Pack", keys: "⌥F5"),
            Shortcut(nameKey: "Extract", keys: "⌥F6"),
        ]),
        ShortcutGroup(titleKey: "View", shortcuts: [
            Shortcut(nameKey: "Full View", keys: "⌘1"),
            Shortcut(nameKey: "Brief View", keys: "⌘2"),
            Shortcut(nameKey: "Thumbnails", keys: "⌘3"),
            Shortcut(nameKey: "Show Hidden Files", keys: "⌘⇧."),
        ]),
        ShortcutGroup(titleKey: "Search", shortcuts: [
            Shortcut(nameKey: "Find Files", keys: "⌘⇧F"),
            Shortcut(nameKey: "Multi-Rename", keys: "⌘M"),
            Shortcut(nameKey: "SFTP Connection", keys: "⌘N"),
        ]),
    ]

    /// The getting-started prose for the current UI language: Chinese reads the
    /// zh markdown; every other language falls back to the English markdown.
    @MainActor static func overviewMarkdown() -> String {
        let base = (Localizer.shared.current == .zhHans) ? "overview-zh" : "overview-en"
        if let url = Bundle.module.url(forResource: base, withExtension: "md",
                                       subdirectory: "Help"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return tr("Help content is unavailable.")
    }
}
