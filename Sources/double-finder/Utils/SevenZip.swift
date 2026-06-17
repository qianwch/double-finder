import Foundation

/// Resolves the external 7-Zip executable. It is used ONLY as a fallback for
/// encrypted .7z archives (libarchive can't decrypt those) and for creating
/// encrypted/​full-option 7z — everything else stays internal via libarchive.
///
/// A user-set path (Commands ▸ 7-Zip Location…) takes priority; otherwise we
/// auto-detect 7z / 7zz / 7za in the usual install locations.
enum SevenZip {
    private static let key = "SevenZipPath"

    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    static let executableNames = ["7z", "7zz", "7za"]

    /// Explicit user override (nil/empty → auto-detect).
    static var configuredPath: String? {
        get {
            let v = UserDefaults.standard.string(forKey: key)
            return (v?.isEmpty == false) ? v : nil
        }
        set {
            if let v = newValue, !v.isEmpty { UserDefaults.standard.set(v, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Auto-detected absolute path (7z/7zz/7za in standard dirs), or nil.
    static func autoDetect() -> String? {
        for dir in searchDirs {
            for name in executableNames {
                let p = dir + "/" + name
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// 7zz shipped inside the .app (Contents/MacOS/7zz, next to the main
    /// executable), or nil when running the bare dev binary. Lets encrypted 7z
    /// work out of the box with no `brew install`.
    static func bundledPath() -> String? {
        guard let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let p = exeDir.appendingPathComponent("7zz").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// The path actually used: a valid user override → bundled 7zz → auto-detect.
    /// Lazily called only when an encrypted 7z forces the external fallback.
    static func resolve() -> String? {
        if let p = configuredPath, FileManager.default.isExecutableFile(atPath: p) { return p }
        if let p = bundledPath() { return p }
        return autoDetect()
    }
}
