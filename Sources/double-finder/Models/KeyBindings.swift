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
        }
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
        case .multiRename: return "⌃M"
        case .sftp: return "⌘N"
        case .swap: return "⌃U"
        case .branch: return "⌃B"
        case .tree: return "⌘⇧D"
        case .commandLine: return "⌘L"
        case .rename: return "F2"
        case .quickLook: return "F3"
        case .viewFull: return "⌘1"
        case .viewBrief: return "⌘2"
        case .viewThumbnails: return "⌘3"
        case .filter: return "⌘F"
        case .selectAll: return "⌘A"
        case .newTab: return "⌃T"
        case .closeTab: return "⌃W"
        }
    }
}

/// User-customized shortcuts, stored in UserDefaults. These are *additional*
/// bindings layered on top of the built-in defaults (which still work).
enum KeyBindings {
    private static func key(_ c: AppCommand) -> String { "kb.\(c.rawValue)" }

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
}
