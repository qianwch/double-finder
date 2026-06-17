import Foundation
import AppKit

/// One mounted volume (disk) for the Total-Commander-style drive list.
struct VolumeInfo {
    let url: URL
    let name: String
    let freeBytes: Int64
    let totalBytes: Int64

    /// Finder's icon for the volume, sized for a menu.
    var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    /// e.g. "Macintosh HD — 120 GB free of 994 GB".
    var menuTitle: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        if totalBytes > 0 {
            return "\(name) — \(f.string(fromByteCount: freeBytes)) free of \(f.string(fromByteCount: totalBytes))"
        }
        return name
    }
}

enum Volumes {
    /// All browsable, non-hidden mounted volumes (root + /Volumes/*).
    static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.volumeIsBrowsable == true else { continue }
            let name = vals.volumeName ?? url.lastPathComponent
            let free = Int64(vals.volumeAvailableCapacityForImportantUsage ?? 0)
            let total = Int64(vals.volumeTotalCapacity ?? 0)
            result.append(VolumeInfo(url: url, name: name, freeBytes: free, totalBytes: total))
        }
        return result
    }

    /// The mounted volume that contains `path` (longest matching mount point).
    static func containing(_ path: String) -> VolumeInfo? {
        mounted()
            .filter { path == $0.url.path || path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }
}
