import Foundation

/// Multi-volume ("x.7z.001", "x.7z.002", …) archive sets. 7-Zip's `-v` output is
/// the archive byte stream cut into equal pieces; reading the set means reading
/// the pieces back to back in numeric order.
enum SplitVolumes {
    /// True if `path` names the first volume of a split archive ("x.7z.001").
    static func isFirstVolume(_ path: String) -> Bool {
        FileItem.splitArchiveFirstPartBase((path as NSString).lastPathComponent) != nil
    }

    /// Every volume of the set that starts at `firstVolume`, in order, stopping at
    /// the first gap ("x.7z.001", ".002", ".003" → three paths). A path that is
    /// not a first volume comes back as a one-element list — callers can treat
    /// plain archives and split sets uniformly.
    static func set(forFirstVolume path: String) -> [String] {
        guard isFirstVolume(path), path.count > 4 else { return [path] }
        let base = String(path.dropLast(3))            // "…/x.7z."
        var volumes: [String] = []
        var index = 1
        let fm = FileManager.default
        while true {
            let candidate = base + String(format: "%03d", index)
            guard fm.fileExists(atPath: candidate) else { break }
            volumes.append(candidate)
            index += 1
        }
        return volumes.isEmpty ? [path] : volumes
    }
}
