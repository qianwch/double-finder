import Foundation

/// Dotted-integer version comparison ("1.7.7" vs "1.7.10"), tolerant of a
/// leading "v" and non-numeric noise. Pure logic — matches the bare tag names
/// package_app.sh stamps into CFBundleShortVersionString from `git describe`.
enum AppVersion {
    /// Parses "v1.7.10" / "1.7.10" into [1, 7, 10]; non-numeric components
    /// (and the CI's non-numeric "latest" rolling tag) read as 0.
    static func components(_ raw: String) -> [Int] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True when `remote` names a strictly newer version than `local`.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = components(remote), b = components(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
