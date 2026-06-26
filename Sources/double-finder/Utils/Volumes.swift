import Foundation
import AppKit

/// One mounted volume (disk) for the Total-Commander-style drive list.
struct VolumeInfo {
    let url: URL
    let name: String
    let freeBytes: Int64
    let totalBytes: Int64
    /// Removable / ejectable media (USB stick, external disk, mounted DMG) — i.e.
    /// something we can offer an "Eject" action for. The boot volume is never this.
    let isEjectable: Bool

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
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey,
            .volumeIsLocalKey,
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
            // Ejectable = removable/ejectable media, or a network mount (SMB/AFP/NFS —
            // ejecting it unmounts/disconnects the share), but never the boot volume.
            let ejectable = (vals.volumeIsEjectable == true || vals.volumeIsRemovable == true
                             || vals.volumeIsLocal == false)
                && vals.volumeIsRootFileSystem != true
            result.append(VolumeInfo(url: url, name: name, freeBytes: free,
                                     totalBytes: total, isEjectable: ejectable))
        }
        return result
    }

    /// The mounted volume that contains `path` (longest matching mount point).
    static func containing(_ path: String) -> VolumeInfo? {
        mounted()
            .filter { path == $0.url.path || path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }

    /// Unmounts and ejects the volume at `url` **asynchronously** (the work — a
    /// network round-trip for SMB/AFP/NFS, or spinning down a disk — can take a
    /// while and must never block the main thread). `completion` runs on the main
    /// queue with nil on success or the error on failure (busy / in use / …).
    static func eject(_ url: URL, completion: @escaping (Error?) -> Void) {
        // `.allPartitionsAndEjectDisk` matches the old `unmountAndEjectDevice`
        // (physically ejects removable media; a no-op extra for network shares,
        // which just unmount). `.withoutUI` keeps macOS from popping its own
        // dialogs — failures surface through our own alert instead.
        FileManager.default.unmountVolume(at: url,
                                          options: [.allPartitionsAndEjectDisk, .withoutUI]) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
