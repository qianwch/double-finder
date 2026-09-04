import Foundation

/// Archive formats supported by the pack dialog.
enum ArchiveFormat: String, CaseIterable {
    case zip = "zip"
    case sevenZip = "7z"
    case tarGz = "tar.gz"
    case tarBz2 = "tar.bz2"
    case tarXz = "tar.xz"
    case tar = "tar"

    var fileExtension: String { rawValue }
    var supportsEncryption: Bool { self == .zip || self == .sevenZip }
    var supportsSplit: Bool { self == .zip || self == .sevenZip }
    var displayName: String {
        switch self {
        case .zip: return "Zip (.zip)"
        case .sevenZip: return "7-Zip (.7z)"
        case .tarGz: return "Tar + Gzip (.tar.gz)"
        case .tarBz2: return "Tar + Bzip2 (.tar.bz2)"
        case .tarXz: return "Tar + XZ (.tar.xz)"
        case .tar: return "Tar, no compression (.tar)"
        }
    }
}

class LocalFS: VirtualFS {
    private(set) var currentPath: String

    init(path: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.currentPath = path
    }

    func listDirectory(_ path: String) async throws -> [FileItem] {
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let url = URL(fileURLWithPath: path)

            let keys: [URLResourceKey] = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isHiddenKey, .isSymbolicLinkKey, .addedToDirectoryDateKey, .creationDateKey
            ]
            let contents = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: []
            )

            var items: [FileItem] = []
            for fileURL in contents {
                let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))

                let name = fileURL.lastPathComponent
                let isDir = resourceValues?.isDirectory ?? false
                let isSymlink = resourceValues?.isSymbolicLink ?? false
                let size = Int64(resourceValues?.fileSize ?? 0)
                let modified = resourceValues?.contentModificationDate ?? Date()
                let isHidden = resourceValues?.isHidden ?? name.hasPrefix(".")
                let isArchive = FileItem.isArchiveFileName(name)

                var item = FileItem(
                    id: UUID(),
                    name: name,
                    path: fileURL.path,
                    isDirectory: isDir,
                    isArchive: isArchive,
                    size: size,
                    modified: modified,
                    isHidden: isHidden,
                    isSymlink: isSymlink,
                    permissions: ""   // lazy: an attributesOfItem() stat per file is ~90% of
                                      // directory-load time; only computed when the perms column shows
                )
                item.dateAdded = resourceValues?.addedToDirectoryDate
                item.dateCreated = resourceValues?.creationDate
                items.append(item)
            }
            return items
        }.value
    }

    func copy(from: String, to: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destURL = URL(fileURLWithPath: to)
            let srcURL = URL(fileURLWithPath: from)
            let dest = destURL.appendingPathComponent(srcURL.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: srcURL, to: dest)
        }.value
    }

    /// Copy to an explicit target path (rename-on-copy from the F5 confirm
    /// dialog); overwrites an existing target.
    func copy(from: String, toFile target: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.copyItem(atPath: from, toPath: target)
        }.value
    }

    /// Move to an explicit target path (rename-on-move); overwrites an existing target.
    func move(from: String, toFile target: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.moveItem(atPath: from, toPath: target)
        }.value
    }

    /// `path` expressed relative to `base` (drops the `base/` prefix); falls back
    /// to the last component when `path` isn't under `base`.
    static func relativePath(_ path: String, base: String) -> String {
        let b = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(b) ? String(path.dropFirst(b.count)) : (path as NSString).lastPathComponent
    }

    /// The deepest directory that contains all of `paths` (the common ancestor of
    /// their parent folders). Used as the root for hierarchy-preserving copy/pack,
    /// so only the structure below the selection's top-most shared folder is kept.
    static func commonAncestor(of paths: [String]) -> String {
        guard let first = paths.first else { return "/" }
        var common = ((first as NSString).deletingLastPathComponent as NSString).pathComponents
        for p in paths.dropFirst() {
            let comps = ((p as NSString).deletingLastPathComponent as NSString).pathComponents
            var i = 0
            while i < common.count, i < comps.count, common[i] == comps[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        return common.isEmpty ? "/" : NSString.path(withComponents: common)
    }

    /// Copies `from` to `destBase/relativePath`, creating intermediate folders —
    /// preserving the source's directory hierarchy (like cd base && tar c rel).
    func copyPreservingPath(from src: String, toBaseDir destBase: String, relativePath rel: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let target = (destBase as NSString).appendingPathComponent(rel)
            let targetDir = (target as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.copyItem(atPath: src, toPath: target)
        }.value
    }

    func move(from: String, to: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destURL = URL(fileURLWithPath: to)
            let srcURL = URL(fileURLWithPath: from)
            let dest = destURL.appendingPathComponent(srcURL.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: srcURL, to: dest)
        }.value
    }

    func delete(_ path: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            // Move to Trash rather than permanently deleting.
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path),
                resultingItemURL: nil
            )
        }.value
    }

    /// Permanently removes the item (does NOT go to Trash — irreversible).
    ///
    /// A nested directory missing its execute/write bit (e.g. `drw-`) makes its
    /// whole subtree undeletable — even `rm -rf` fails with "Permission denied".
    /// When the failure is a permission error and we own the tree, grant
    /// ourselves rwx across it and retry once (file-manager behaviour: "it's
    /// mine, delete it" — unlike plain `rm`).
    func deletePermanently(_ path: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                try fm.removeItem(atPath: path)
            } catch {
                guard Self.isPermissionError(error), Self.grantOwnerAccess(path) else { throw error }
                try fm.removeItem(atPath: path)
            }
        }.value
    }

    /// True for OS-level permission failures (Cocoa no-permission codes or an
    /// underlying POSIX EPERM/EACCES).
    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(EPERM) || posix.code == Int(EACCES) { return true }
        return false
    }

    /// Recursively grants the current owner rwx (dirs) / rw (files) across the
    /// subtree, only touching items we actually own and never following
    /// symlinks. Descends top-down: a dir's search bit is restored before we try
    /// to read its children. Returns false if `path` isn't ours (caller rethrows
    /// the original error rather than silently doing nothing).
    @discardableResult
    private static func grantOwnerAccess(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard st.st_uid == getuid() else { return false }     // only our own files
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return true }                     // don't chmod via symlink
        let isDir = type == S_IFDIR
        chmod(path, st.st_mode | (isDir ? S_IRWXU : (S_IRUSR | S_IWUSR)))
        if isDir {
            let kids = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for k in kids { _ = grantOwnerAccess(path + "/" + k) }
        }
        return true
    }

    func rename(at path: String, to newName: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let src = URL(fileURLWithPath: path)
            let dest = src.deletingLastPathComponent().appendingPathComponent(newName)
            try FileManager.default.moveItem(at: src, to: dest)
        }.value
    }

    func createDirectory(_ path: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }.value
    }

    /// Recursively sums the on-disk allocated size of everything under `path`.
    func directorySize(_ path: String) async -> Int64 {
        await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
            var total: Int64 = 0
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys),
                options: [], errorHandler: { _, _ in true }
            ) else { return 0 }
            while let fileURL = enumerator.nextObject() as? URL {
                guard let v = try? fileURL.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            }
            return total
        }.value
    }

    func createFile(_ path: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard !FileManager.default.fileExists(atPath: path) else {
                throw NSError(domain: "LocalFS", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "A file with that name already exists"])
            }
            if !FileManager.default.createFile(atPath: path, contents: nil) {
                throw NSError(domain: "LocalFS", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create the file"])
            }
        }.value
    }

    func setPermissions(_ path: String, octal: Int) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.setAttributes([.posixPermissions: octal], ofItemAtPath: path)
        }.value
    }

    /// Creates an archive of `sources` at `archivePath` in the chosen format, with
    /// a compression level (0–9), optional password (zip/7z only) and optional
    /// volume size in bytes (zip/7z: output becomes `<archivePath>.001/.002/…`).
    ///
    /// 7z goes to the in-process 7-Zip engine (multi-threaded LZMA2, AES +
    /// header encryption, native splitting); every other format is libarchive's
    /// (zip AES-256 included; zip volumes are cut by `LibArchive.SplitOutput`).
    /// `progress` receives source-byte deltas as data is packed; `shouldCancel`
    /// is polled (true → `CancellationError`, partial output removed by the caller).
    func createArchive(sources: [String], to archivePath: String,
                       format: ArchiveFormat, level: Int, password: String?,
                       baseDir: String? = nil, volumeSize: Int64? = nil,
                       totalSourceBytes: Int64 = 0,
                       progress: (@Sendable (Int64) -> Void)? = nil,
                       shouldCancel: (@Sendable () -> Bool)? = nil) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard !sources.isEmpty else { return }
            // When baseDir is set, store each source by its path relative to it
            // so the archive preserves the folder hierarchy; otherwise by name.
            let entries: [(absPath: String, entryName: String)] = sources.map { src in
                let name = baseDir != nil ? LocalFS.relativePath(src, base: baseDir!)
                                          : (src as NSString).lastPathComponent
                return (src, name)
            }
            let pw = (password?.isEmpty == false) ? password! : nil
            let split = volumeSize != nil && format.supportsSplit
            LocalFS.removePackOutputs(archivePath: archivePath, split: split)   // overwrite cleanly

            if format == .sevenZip {
                try SevenZipEngine.create(sources: entries, to: archivePath,
                                          level: level, password: pw, encryptHeaders: true,
                                          volumeBytes: split ? volumeSize : nil,
                                          onBytes: progress, shouldCancel: shouldCancel)
                return
            }
            try LibArchive.create(sources: entries, to: archivePath,
                                  format: format, level: level, password: pw,
                                  volumeBytes: split ? volumeSize : nil,
                                  onBytes: progress, shouldCancel: shouldCancel)
        }.value
    }

    /// Removes the output(s) of an aborted/failed pack: the archive itself, or
    /// for a split pack every `<archivePath>.NNN` volume.
    static func removePackOutputs(archivePath: String, split: Bool) {
        let fm = FileManager.default
        guard split else { try? fm.removeItem(atPath: archivePath); return }
        let dir = (archivePath as NSString).deletingLastPathComponent
        let base = (archivePath as NSString).lastPathComponent
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            guard f.hasPrefix(base + ".") else { continue }
            let suffix = f.dropFirst(base.count + 1)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                try? fm.removeItem(atPath: dir + "/" + f)
            }
        }
    }


    func extractArchive(_ archivePath: String, to destination: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try ZipFS.extractAll(archivePath: archivePath, to: destination)
        }.value
    }

    static func permissions(for path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let posixPerms = attrs[.posixPermissions] as? Int else {
            return "---------"
        }

        var result = ""
        let bits: [(Int, String)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        for (bit, char) in bits {
            result += (posixPerms & bit) != 0 ? char : "-"
        }
        return result
    }
}
