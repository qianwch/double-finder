import AppKit

/// A key code + modifier combination, persistable as a short string.
struct KeyCombo: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let kc = UInt16(parts[0]), let m = UInt(parts[1]) else { return nil }
        self.keyCode = kc
        self.modifiers = NSEvent.ModifierFlags(rawValue: m).intersection([.command, .option, .control, .shift])
    }

    var storageString: String { "\(keyCode):\(modifiers.rawValue)" }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    /// Human-readable form, e.g. "⌃⇧F5".
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 32: "U", 34: "I",
        31: "O", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    static func keyName(_ code: UInt16) -> String { names[code] ?? "key\(code)" }
}

/// Every command the user can re-bind a shortcut to. The action is dispatched
/// by MainViewController.runCommand(_:).
enum AppCommand: String, CaseIterable {
    case refresh, copy, move, newDir, delete, pack, extract, find, multiRename
    case sftp, swap, branch, tree, commandLine, rename, quickLook
    case viewFull, viewBrief, viewThumbnails, filter, selectAll, newTab, closeTab
    case openInOther, matchOther, openTerminal, checkForUpdates

    var label: String {
        switch self {
        case .refresh: return "Refresh"
        case .copy: return "Copy"
        case .move: return "Move"
        case .newDir: return "New Directory"
        case .delete: return "Delete"
        case .pack: return "Pack"
        case .extract: return "Extract"
        case .find: return "Find Files"
        case .multiRename: return "Multi-Rename"
        case .sftp: return "SFTP Connection"
        case .swap: return "Swap Panels"
        case .branch: return "Branch View"
        case .tree: return "Directory Tree"
        case .commandLine: return "Focus Command Line"
        case .rename: return "Rename"
        case .quickLook: return "Quick Look"
        case .viewFull: return "View: Full"
        case .viewBrief: return "View: Brief"
        case .viewThumbnails: return "View: Thumbnails"
        case .filter: return "Quick Filter"
        case .selectAll: return "Select All"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .openInOther: return "Open Folder in Other Panel"
        case .matchOther: return "Same Folder as Active in Other Panel"
        case .openTerminal: return "Open in Terminal"
        case .checkForUpdates: return "Check for Updates…"
        }
    }

    // MARK: Toolbar metadata (the toolbar draws from the same command list)

    /// Toolbar button id, nil for commands that have no button. The ids are
    /// persisted in `ToolbarButtonIDs`, so they never change.
    var toolbarID: String? {
        switch self {
        case .refresh: return "refresh"
        case .copy: return "copy"
        case .move: return "move"
        case .newDir: return "newdir"
        case .delete: return "delete"
        case .pack: return "pack"
        case .extract: return "extract"
        case .find: return "find"
        case .multiRename: return "multirename"
        case .sftp: return "sftp"
        case .swap: return "swap"
        case .branch: return "branch"
        case .tree: return "tree"
        case .commandLine: return "commandline"
        case .openTerminal: return "terminal"
        case .checkForUpdates: return "checkupdates"
        default: return nil
        }
    }

    /// SF Symbol of the toolbar button (only for commands with a `toolbarID`).
    var symbol: String? {
        switch self {
        case .refresh: return "arrow.clockwise"
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .newDir: return "folder.badge.plus"
        case .delete: return "trash"
        case .pack: return "archivebox"
        case .extract: return "shippingbox"
        case .find: return "magnifyingglass"
        case .multiRename: return "pencil"
        case .sftp: return "network"
        case .swap: return "arrow.left.arrow.right"
        case .branch: return "list.bullet.indent"
        case .tree: return "sidebar.left"
        // Not "terminal": that reads as the same button as "Open in Terminal"
        // next to it, and focusing the command line gives almost no visible
        // feedback — users reported the terminal button "doing nothing".
        case .commandLine: return "rectangle.bottomthird.inset.filled"
        case .openTerminal: return "terminal.fill"
        case .checkForUpdates: return "arrow.down.circle"
        default: return nil
        }
    }

    /// Toolbar tooltip / Settings ▸ Toolbar label — an English source string
    /// (translated at display time). Differs from `label` where the button
    /// traditionally names its key ("Copy (F5)"); kept verbatim so the existing
    /// translations still hit.
    var toolbarTooltip: String? {
        switch self {
        case .refresh: return "Refresh"
        case .copy: return "Copy (F5)"
        case .move: return "Move (F6)"
        case .newDir: return "New Directory (F7)"
        case .delete: return "Delete (F8)"
        case .pack: return "Pack…"
        case .extract: return "Extract"
        case .find: return "Find Files"
        case .multiRename: return "Multi-Rename"
        case .sftp: return "SFTP Connection"
        case .swap: return "Swap Panels"
        case .branch: return "Branch View"
        case .tree: return "Directory Tree"
        case .commandLine: return "Command Line"
        case .openTerminal: return "Open in Terminal"
        case .checkForUpdates: return "Check for Updates…"
        default: return nil
        }
    }

    /// Commands that can sit on the toolbar, in the canonical order Settings ▸
    /// Toolbar lists them (= `ToolbarConfig.defaultIDs` order).
    static var toolbarCommands: [AppCommand] {
        [.refresh, .copy, .move, .newDir, .delete, .pack, .extract, .find, .multiRename,
         .sftp, .swap, .branch, .tree, .commandLine, .openTerminal, .checkForUpdates]
    }

    /// Built-in default shortcut, shown for reference in the editor.
    var defaultHint: String {
        switch self {
        case .refresh: return "⌘R"
        case .copy: return "F5"
        case .move: return "F6"
        case .newDir: return "F7"
        case .delete: return "F8"
        case .pack: return "⌥F5"
        case .extract: return "⌥F6"
        case .find: return "⌘⇧F"
        case .multiRename: return "⌘⇧R"
        case .sftp: return "⌘N"
        case .swap: return "⌘U"
        case .branch: return "⌘⇧B"
        case .tree: return "⌘⇧D"
        case .commandLine: return "⌘L"
        case .rename: return "—"
        case .quickLook: return "F3"
        case .viewFull: return "⌘1"
        case .viewBrief: return "⌘2"
        case .viewThumbnails: return "⌘3"
        case .filter: return "⌘F"
        case .selectAll: return "⌘A"
        case .newTab: return "⌘T"
        case .closeTab: return "⌘W"
        case .openInOther: return "⌘⇧O"
        case .matchOther: return "⌘="
        case .openTerminal: return "⌘⇧T"
        case .checkForUpdates: return "—"
        }
    }
}

/// Anything a shortcut can be bound to: a built-in `AppCommand`, or a command
/// contributed by a plugin (no built-in default key, so no "Enabled" switch).
enum BindableCommand: Equatable {
    case builtIn(AppCommand)
    /// `id` = `PluginManager.RegisteredCommand.id` ("<plugin>/<command>").
    case plugin(id: String, title: String)

    var label: String {
        switch self {
        case .builtIn(let c): return c.label
        case .plugin(_, let title): return title
        }
    }

    var defaultHint: String {
        switch self {
        case .builtIn(let c): return c.defaultHint
        case .plugin: return "—"
        }
    }

    /// UserDefaults key of the custom binding.
    var storageKey: String {
        switch self {
        case .builtIn(let c): return "kb.\(c.rawValue)"
        case .plugin(let id, _): return "kb.plugin.\(id)"
        }
    }

    static func == (a: BindableCommand, b: BindableCommand) -> Bool {
        switch (a, b) {
        case (.builtIn(let x), .builtIn(let y)): return x == y
        case (.plugin(let x, _), .plugin(let y, _)): return x == y
        default: return false
        }
    }
}

/// User-customized shortcuts, stored in UserDefaults. Custom bindings layer on
/// top of the built-in defaults; a default can additionally be *disabled* per
/// command ("kb.off.<cmd>"), which silences the built-in key both in
/// handleKeyDown and in the menu accelerators (menus are rebuilt on change).
enum KeyBindings {
    private static func key(_ c: AppCommand) -> String { "kb.\(c.rawValue)" }
    private static func offKey(_ c: AppCommand) -> String { "kb.off.\(c.rawValue)" }

    static func isDefaultDisabled(_ c: AppCommand) -> Bool {
        UserDefaults.standard.bool(forKey: offKey(c))
    }

    static func setDefaultDisabled(_ disabled: Bool, for c: AppCommand) {
        if disabled { UserDefaults.standard.set(true, forKey: offKey(c)) }
        else { UserDefaults.standard.removeObject(forKey: offKey(c)) }
    }

    /// Guard for the built-in hard-coded key branches.
    static func defaultActive(_ c: AppCommand) -> Bool { !isDefaultDisabled(c) }

    static func combo(for command: AppCommand) -> KeyCombo? {
        guard let s = UserDefaults.standard.string(forKey: key(command)) else { return nil }
        return KeyCombo(storage: s)
    }

    static func set(_ combo: KeyCombo?, for command: AppCommand) {
        if let combo = combo {
            UserDefaults.standard.set(combo.storageString, forKey: key(command))
        } else {
            UserDefaults.standard.removeObject(forKey: key(command))
        }
    }

    /// The command bound to `combo`, if any (used to dispatch a key event).
    static func command(for combo: KeyCombo) -> AppCommand? {
        for c in AppCommand.allCases where KeyBindings.combo(for: c) == combo { return c }
        return nil
    }

    // MARK: Bindable (built-in + plugin) commands

    static func combo(for command: BindableCommand) -> KeyCombo? {
        guard let s = UserDefaults.standard.string(forKey: command.storageKey) else { return nil }
        return KeyCombo(storage: s)
    }

    static func set(_ combo: KeyCombo?, for command: BindableCommand) {
        if let combo = combo {
            UserDefaults.standard.set(combo.storageString, forKey: command.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: command.storageKey)
        }
    }

    /// Every command a key can be bound to right now: the built-ins plus the
    /// commands of active plugins (see `CommandRegistry`).
    @MainActor static var bindableCommands: [BindableCommand] { CommandRegistry.bindable }

    /// Whatever is bound to `combo` — built-in first, then plugin commands.
    @MainActor static func bindable(for combo: KeyCombo) -> BindableCommand? {
        for c in bindableCommands where KeyBindings.combo(for: c) == combo { return c }
        return nil
    }
}
