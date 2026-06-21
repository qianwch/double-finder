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

    /// Which optional columns are shown (ids from FileColumnLayout.optionalColumns).
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

    /// Per-column widths (id → CGFloat) persisted as [String: Double] in UserDefaults.
    /// Default: empty (each column falls back to its own default width).
    static var columnWidths: [String: CGFloat] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: "ColumnWidths") else { return [:] }
            var result: [String: CGFloat] = [:]
            for (k, v) in raw {
                if let d = v as? Double { result[k] = CGFloat(d) }
            }
            return result
        }
        set {
            var raw: [String: Double] = [:]
            for (k, v) in newValue { raw[k] = Double(v) }
            UserDefaults.standard.set(raw, forKey: "ColumnWidths")
        }
    }

    // MARK: - Per-type color persistence

    /// Read the custom color for a category, or nil if none is set.
    static func typeColor(for cat: TypeCategory) -> NSColor? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "TypeColors") as? [String: String],
              let hex = dict[cat.rawValue] else { return nil }
        return NSColor(hexString: hex)
    }

    /// Write (or clear) the custom color for a category.
    static func setTypeColor(_ color: NSColor?, for cat: TypeCategory) {
        var dict = (UserDefaults.standard.dictionary(forKey: "TypeColors") as? [String: String]) ?? [:]
        if let color = color, let srgb = color.usingColorSpace(.sRGB) {
            dict[cat.rawValue] = srgb.hexString
        } else {
            dict.removeValue(forKey: cat.rawValue)
        }
        UserDefaults.standard.set(dict, forKey: "TypeColors")
    }

    /// Remove all custom type colors, restoring defaults.
    static func resetTypeColors() {
        UserDefaults.standard.removeObject(forKey: "TypeColors")
    }
}

// MARK: - NSColor hex helpers

private extension NSColor {
    convenience init?(hexString: String) {
        guard hexString.count == 6,
              let r = UInt8(hexString.prefix(2), radix: 16),
              let g = UInt8(hexString.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hexString.dropFirst(4).prefix(2), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "808080" }
        let r = Int(max(0, min(1, c.redComponent)) * 255 + 0.5)
        let g = Int(max(0, min(1, c.greenComponent)) * 255 + 0.5)
        let b = Int(max(0, min(1, c.blueComponent)) * 255 + 0.5)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - TypeCategory

/// File type categories used for color-coding. Each maps to a default color and a UI label.
enum TypeCategory: String, CaseIterable {
    case folder
    case symlink
    case executable
    case archive
    case image
    case media
    case code
    case document

    var titleKey: String {
        switch self {
        case .folder:     return "Folders"
        case .symlink:    return "Symbolic Links"
        case .executable: return "Executables"
        case .archive:    return "Archives"
        case .image:      return "Images"
        case .media:      return "Audio / Video"
        case .code:       return "Source Code"
        case .document:   return "Documents"
        }
    }

    var defaultColor: NSColor {
        // Dark-on-dark types get a brighter variant in dark mode for legibility,
        // the standard system color in light mode. Already-bright types
        // (orange / pink / white) stay as adaptive system colors.
        switch self {
        case .folder:     return Self.dynamic(dark: NSColor(srgbRed: 0.42, green: 0.72, blue: 1.00, alpha: 1), light: .systemBlue)
        case .symlink:    return Self.dynamic(dark: NSColor(srgbRed: 0.36, green: 0.85, blue: 0.82, alpha: 1), light: .systemTeal)
        case .executable: return Self.dynamic(dark: NSColor(srgbRed: 1.00, green: 0.48, blue: 0.45, alpha: 1), light: .systemRed)
        case .image:      return Self.dynamic(dark: NSColor(srgbRed: 0.80, green: 0.60, blue: 1.00, alpha: 1), light: .systemPurple)
        case .code:       return Self.dynamic(dark: NSColor(srgbRed: 0.46, green: 0.88, blue: 0.52, alpha: 1), light: .systemGreen)
        case .archive:    return .systemOrange
        case .media:      return .systemPink
        case .document:   return .labelColor
        }
    }

    /// A color that resolves to `dark` in a dark appearance, `light` otherwise.
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        }
    }
}

// MARK: - FileTypeColor

/// Total Commander-style coloring of file names by type.
enum FileTypeColor {
    private static let images: Set<String> = ["jpg","jpeg","png","gif","bmp","tiff","tif","heic","webp","svg","icns","ico"]
    private static let media: Set<String> = ["mp3","wav","flac","aac","m4a","ogg","mp4","mov","mkv","avi","wmv","flv","m4v","webm"]
    private static let code: Set<String> = ["swift","c","h","cpp","cc","hpp","m","mm","java","kt","py","rb","js","ts","jsx","tsx","go","rs","php","cs","sh","bash","zsh","pl","lua","sql","html","css","scss","json","xml","yaml","yml","toml"]
    private static let docs: Set<String> = ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","md","rtf","pages","numbers","key","csv"]
    private static let executable: Set<String> = ["app","exe","sh","bash","command","bin","run","msi","pkg","dmg"]

    /// Classify a file into a TypeCategory, or return nil for plain files.
    static func category(name: String, isDirectory: Bool, isSymlink: Bool) -> TypeCategory? {
        if isSymlink { return .symlink }
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if executable.contains(ext) { return .executable }
        if FileItem.isArchiveFileName(name) { return .archive }
        if images.contains(ext) { return .image }
        if media.contains(ext) { return .media }
        if code.contains(ext) { return .code }
        if docs.contains(ext) { return .document }
        return nil
    }

    static func color(name: String, isDirectory: Bool, isSymlink: Bool) -> NSColor {
        guard let cat = category(name: name, isDirectory: isDirectory, isSymlink: isSymlink) else {
            return .labelColor
        }
        return AppSettings.typeColor(for: cat) ?? cat.defaultColor
    }
}
