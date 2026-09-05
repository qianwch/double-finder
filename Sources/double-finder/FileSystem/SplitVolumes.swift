import Foundation

/// Multi-volume archive sets, of two kinds:
/// - "x.7z.001", "x.7z.002", … — 7-Zip's `-v` output: the archive byte stream
///   cut into equal pieces, read back by concatenating them in order (any
///   format: 7z, zip, tar…).
/// - RAR volumes: new-style "x.part1.rar", "x.part2.rar", … or old-style
///   "x.rar", "x.r00", "x.r01", … Every volume has its own headers, so the set
///   is NOT concatenated — libarchive is handed the whole file list and
///   switches volumes itself (`archive_read_open_filenames`).
enum SplitVolumes {
    /// True if `path` is the entry point of a set: an "x.<archive>.001", a
    /// "x.part1.rar", or an "x.rar" that has an "x.r00" beside it.
    static func isFirstVolume(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if FileItem.splitArchiveFirstPartBase(name) != nil { return true }
        if let n = FileItem.rarVolumeNumber(name) { return n == 1 }
        return isOldStyleRarFirst(path)
    }

    /// True if the set starting at `path` is a RAR set (own headers per volume).
    static func isRarSet(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return FileItem.rarVolumeNumber(name) == 1 || isOldStyleRarFirst(path)
    }

    /// Every volume of the set that starts at `path`, in order, stopping at the
    /// first gap. A path that is not a first volume comes back as a one-element
    /// list — callers can treat plain archives and sets uniformly.
    static func set(forFirstVolume path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        if FileItem.splitArchiveFirstPartBase(name) != nil {
            // "x.7z.001" → "x.7z.002", … (three digits, like 7-Zip writes them)
            return enumerate(from: 2, exists: { i in
                let candidate = String(path.dropLast(3)) + String(format: "%03d", i)
                return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
            }, first: path)
        }
        if let n = FileItem.rarVolumeNumber(name), n == 1 {
            // "x.part1.rar" / "x.part01.rar" → keep the zero padding of the first
            // volume, but accept an unpadded name too (RAR widens the field only
            // when it knows the count up front).
            let lower = name.lowercased()
            let tagStart = lower.dropLast(4).lastIndex(of: ".")!
            let prefix = String(path.dropLast(name.count - lower.distance(from: lower.startIndex, to: tagStart) - 1))
            let width = name.count - name.distance(from: name.startIndex, to: tagStart) - 1 - 4 - 4   // digits in "part1"
            return enumerate(from: 2, exists: { i in
                for candidate in [prefix + "part" + String(format: "%0\(width)d", i) + ".rar",
                                  prefix + "part\(i).rar"]
                where FileManager.default.fileExists(atPath: candidate) { return candidate }
                return nil
            }, first: path)
        }
        if isOldStyleRarFirst(path) {
            // "x.rar" → "x.r00", "x.r01", …
            let stem = String(path.dropLast(4))
            return enumerate(from: 0, exists: { i in
                let candidate = stem + String(format: ".r%02d", i)
                return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
            }, first: path)
        }
        return [path]
    }

    private static func isOldStyleRarFirst(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name.lowercased().hasSuffix(".rar"), FileItem.rarVolumeNumber(name) == nil else { return false }
        return FileManager.default.fileExists(atPath: String(path.dropLast(4)) + ".r00")
    }

    private static func enumerate(from start: Int, exists: (Int) -> String?, first: String) -> [String] {
        var volumes = [first]
        var i = start
        while let next = exists(i) { volumes.append(next); i += 1 }
        return volumes
    }
}
