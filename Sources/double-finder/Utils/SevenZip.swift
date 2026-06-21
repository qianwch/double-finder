import Foundation

/// Resolves the 7-Zip executable. It is used ONLY as a fallback for encrypted
/// .7z archives (libarchive can't decrypt those) and for creating encrypted/
/// full-option 7z — everything else stays internal via libarchive.
///
/// No user setting: the bundled `7zz` (shipped in the .app) is used by default;
/// if that isn't present (e.g. the bare dev binary) any system 7z / 7zz / 7za is
/// used instead.
enum SevenZip {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    static let executableNames = ["7z", "7zz", "7za"]

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

    /// The path actually used: bundled 7zz → system auto-detect.
    /// Lazily called only when an encrypted 7z forces the external fallback.
    static func resolve() -> String? {
        bundledPath() ?? autoDetect()
    }
}
