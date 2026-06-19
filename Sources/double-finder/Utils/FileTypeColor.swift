import AppKit

/// How the file list renders its rows (Total Commander's view modes).
enum FileViewMode: Int {
    case full = 0        // icon + name + size + date, comfortable rows
    case brief = 1       // name only, compact rows
    case thumbnails = 2  // large QuickLook thumbnails

    var next: FileViewMode { FileViewMode(rawValue: (rawValue + 1) % 3) ?? .full }
    var title: String {
        switch self {
        case .full: return "Full"
        case .brief: return "Brief"
        case .thumbnails: return "Thumbnails"
        }
    }
}

/// App-wide light/dark appearance choice. Empty raw value = follow the system.
enum AppAppearance: String, CaseIterable {
    case system = ""
    case light = "light"
    case dark = "dark"

    /// The AppKit appearance to force, or nil to follow the system.
    var appKitName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light:  return .aqua
        case .dark:   return .darkAqua
        }
    }
}

/// Persistent app-level toggles.
enum AppSettings {
    static var colorByType: Bool {
        get { UserDefaults.standard.object(forKey: "ColorByType") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ColorByType") }
    }

    static var viewMode: FileViewMode {
        get { FileViewMode(rawValue: UserDefaults.standard.integer(forKey: "ViewMode")) ?? .full }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ViewMode") }
    }

    /// Sort folders ahead of files (TC default). When false, files and folders
    /// are intermixed by name (Finder-style).
    static var foldersFirst: Bool {
        get { UserDefaults.standard.object(forKey: "FoldersFirst") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "FoldersFirst") }
    }

    /// Which optional columns are shown (ids from FileTableView.optionalColumns).
    static var visibleColumns: [String] {
        get { UserDefaults.standard.stringArray(forKey: "VisibleColumns") ?? ["size", "date"] }
        set { UserDefaults.standard.set(newValue, forKey: "VisibleColumns") }
    }

    /// App name used to open a terminal at the current folder (e.g. "Terminal", "iTerm").
    static var terminalApp: String {
        get { UserDefaults.standard.string(forKey: "TerminalApp") ?? "Terminal" }
        set { UserDefaults.standard.set(newValue, forKey: "TerminalApp") }
    }

    /// Show the drive dropdown button on the left of each panel's path bar.
    static var showDriveDropdown: Bool {
        get { UserDefaults.standard.object(forKey: "ShowDriveDropdown") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ShowDriveDropdown") }
    }

    /// Show the row of drive (volume) buttons above each panel.
    static var showDriveBar: Bool {
        get { UserDefaults.standard.object(forKey: "ShowDriveBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ShowDriveBar") }
    }

    /// Ask for confirmation before moving items to the Trash (⌘⌫). Off by default.
    static var confirmTrash: Bool {
        get { UserDefaults.standard.object(forKey: "ConfirmTrash") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "ConfirmTrash") }
    }

    /// File-icon size (points) for the Full and Brief list views. Default 24.
    static var iconSize: Int {
        get { let v = UserDefaults.standard.integer(forKey: "IconSize"); return v == 0 ? 24 : v }
        set { UserDefaults.standard.set(newValue, forKey: "IconSize") }
    }

    /// Light/dark appearance. Empty/absent = follow the system.
    static var appearance: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.string(forKey: "Appearance") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "Appearance") }
    }

    /// Apply the stored appearance to the whole app. nil = follow system.
    @MainActor static func applyAppearance() {
        if let name = appearance.appKitName {
            NSApp.appearance = NSAppearance(named: name)
        } else {
            NSApp.appearance = nil
        }
    }

    /// Active UI language. Empty string = follow system. Stored as Language.rawValue.
    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: "Language") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "Language") }
    }
}

/// Total Commander-style coloring of file names by type.
enum FileTypeColor {
    private static let images: Set<String> = ["jpg","jpeg","png","gif","bmp","tiff","tif","heic","webp","svg","icns","ico"]
    private static let media: Set<String> = ["mp3","wav","flac","aac","m4a","ogg","mp4","mov","mkv","avi","wmv","flv","m4v","webm"]
    private static let code: Set<String> = ["swift","c","h","cpp","cc","hpp","m","mm","java","kt","py","rb","js","ts","jsx","tsx","go","rs","php","cs","sh","bash","zsh","pl","lua","sql","html","css","scss","json","xml","yaml","yml","toml"]
    private static let docs: Set<String> = ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","md","rtf","pages","numbers","key","csv"]
    private static let executable: Set<String> = ["app","exe","sh","bash","command","bin","run","msi","pkg","dmg"]

    static func color(name: String, isDirectory: Bool, isSymlink: Bool) -> NSColor {
        if isSymlink { return .systemTeal }
        if isDirectory { return .systemBlue }
        let ext = (name as NSString).pathExtension.lowercased()
        if executable.contains(ext) { return .systemRed }
        if FileItem.isArchiveFileName(name) { return .systemOrange }
        if images.contains(ext) { return .systemPurple }
        if media.contains(ext) { return .systemPink }
        if code.contains(ext) { return .systemGreen }
        if docs.contains(ext) { return .labelColor }
        return .labelColor
    }
}
