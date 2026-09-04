import Foundation

/// Thrown when an archive can't be listed/extracted without a password.
struct ArchiveEncryptedError: Error { let archivePath: String }

/// Thrown when an archive exists but can't be opened for a reason that is NOT a
/// password problem — corrupt data, truncation, or a multi-volume set missing a
/// volume. Kept distinct from `ArchiveEncryptedError` so a broken archive shows a
/// real error instead of falsely prompting for a password.
struct ArchiveOpenError: LocalizedError {
    let archivePath: String
    var errorDescription: String? {
        "Could not open the archive. It may be corrupt or incomplete — for a multi-volume set, a volume may be missing."
    }
}

/// Session cache of archive passwords (keyed by archive path on disk).
enum ArchivePasswords {
    private static var map: [String: String] = [:]
    static func get(_ path: String) -> String? { map[path] }
    static func set(_ path: String, _ pw: String) { map[path] = pw }
}

/// Browses and extracts archives of many formats: libarchive for everything,
/// with the in-process 7-Zip engine (`SevenZipEngine`) for what libarchive
/// can't do — encrypted 7z. Listing is normalized to a flat list of internal
/// paths, then a shared tree builder produces the per-directory view. (Class
/// kept named `ZipFS` for call sites.)
class ZipFS: VirtualFS {
    let archivePath: String
    let password: String?
    private(set) var currentPath: String   // e.g. "/path/to/archive.tgz/subdir"

    init(archivePath: String, subPath: String = "", password: String? = nil) {
        self.archivePath = archivePath
        self.password = password
        self.currentPath = archivePath + (subPath.isEmpty ? "" : "/" + subPath)
    }

    enum Kind { case zip, tar, sevenZip, rar, single, unknown }

    /// Bare single-file compressors (no tar container) — browsable as one entry.
    static let singleSuffixes = [".gz", ".bz2", ".xz", ".zst", ".lz4"]

    static func kind(of path: String) -> Kind {
        var name = (path as NSString).lastPathComponent.lowercased()
        // A split set's first volume ("docs.7z.001") is the archive it wraps.
        if let base = FileItem.splitArchiveFirstPartBase(name) { name = base }
        let tarSuffixes = [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2",
                           ".tar.xz", ".txz", ".tar.zst", ".tzst", ".tar.z"]
        if tarSuffixes.contains(where: { name.hasSuffix($0) }) { return .tar }
        switch (name as NSString).pathExtension {
        case "zip", "jar", "war", "ear", "ipa", "apk", "cbz": return .zip
        case "7z": return .sevenZip
        case "rar", "cbr": return .rar
        default:
            // A lone .gz/.bz2/.xz/.zst (not tar.*): browse it as a one-file archive.
            if singleSuffixes.contains(where: { name.hasSuffix($0) }) { return .single }
            return .unknown
        }
    }

    /// The inner filename of a bare single-file compressor (its name minus the
    /// compression suffix, e.g. "foo.txt.xz" → "foo.txt").
    static func strippedSingleName(_ archivePath: String) -> String {
        let base = (archivePath as NSString).lastPathComponent
        let lower = base.lowercased()
        for suf in singleSuffixes where lower.hasSuffix(suf) {
            return String(base.dropLast(suf.count))
        }
        return base
    }

    var kind: Kind { Self.kind(of: archivePath) }

    private func internalPath(from virtualPath: String) -> String {
        let prefix = archivePath + "/"
        return virtualPath.hasPrefix(prefix) ? String(virtualPath.dropFirst(prefix.count)) : ""
    }

    // MARK: - Listing

    func listDirectory(_ path: String) async throws -> [FileItem] {
        let internalPrefix = internalPath(from: path)
        let archive = archivePath
        let kind = self.kind
        let pw = password
        return try await Task.detached(priority: .userInitiated) {
            let entries = try Self.entryDetails(archivePath: archive, kind: kind, password: pw)
            return Self.buildItems(entries: entries, archivePath: archive, internalPrefix: internalPrefix)
        }.value
    }

    /// Entries with size/mtime for display. Mirrors `entryPaths` but keeps the
    /// per-entry metadata — including on the encrypted-7z fallback.
    static func entryDetails(archivePath: String, kind: Kind, password: String? = nil) throws -> [LibArchive.Entry] {
        let kind = kind == .unknown ? Self.kind(of: archivePath) : kind   // "x.7z.001" → 7z
        if kind == .unknown { return [] }
        if kind == .single {
            let size = (try? FileManager.default.attributesOfItem(atPath: archivePath)[.size] as? Int64) ?? nil
            let mtime = (try? FileManager.default.attributesOfItem(atPath: archivePath)[.modificationDate] as? Date) ?? nil
            return [LibArchive.Entry(path: strippedSingleName(archivePath), size: size ?? 0, mtime: mtime ?? nil, isDir: false)]
        }
        do {
            return try LibArchive.listEntries(archivePath: archivePath, password: password)
        } catch is ArchiveEncryptedError {
            // libarchive can't decrypt 7z at all: the in-process 7-Zip engine can.
            // zip/rar decrypt inside libarchive, so there it really is a bad password.
            guard kind == .sevenZip else { throw ArchiveEncryptedError(archivePath: archivePath) }
            return try SevenZipEngine.list(archivePath: archivePath, password: password)
        } catch {
            // libarchive couldn't read it (exotic codec / edge case): a 7z gets a
            // second chance on the reference engine; other formats surface the error.
            guard kind == .sevenZip else { throw error }
            return try SevenZipEngine.list(archivePath: archivePath, password: password)
        }
    }

    /// A flat list of internal entry paths. libarchive handles everything except
    /// *encrypted 7z* (which it can't decrypt at all) — those fall back to the
    /// external 7-Zip. Throws `ArchiveEncryptedError` when a password is needed.
    static func entryPaths(archivePath: String, kind: Kind, password: String? = nil) throws -> [String] {
        // libarchive auto-detects the container, reads UTF-8 entry names, and
        // covers zip/tar*/7z/rar — no external tool needed.
        let kind = kind == .unknown ? Self.kind(of: archivePath) : kind
        if kind == .unknown { return [] }
        // A bare .gz/.bz2/.xz/.zst holds exactly one file (its name minus the
        // suffix); show that single entry instead of decompressing externally.
        if kind == .single { return [strippedSingleName(archivePath)] }
        do {
            return try LibArchive.list(archivePath: archivePath, password: password)
        } catch is ArchiveEncryptedError {
            guard kind == .sevenZip else { throw ArchiveEncryptedError(archivePath: archivePath) }
            return try SevenZipEngine.list(archivePath: archivePath, password: password).map { $0.path }
        } catch {
            guard kind == .sevenZip else { throw error }
            return try SevenZipEngine.list(archivePath: archivePath, password: password).map { $0.path }
        }
    }

    /// True if `path` is the first volume of a split archive ("x.7z.001"). Both
    /// libarchive (`LibArchive.openInput`) and the 7-Zip engine read the whole
    /// volume set when opened on the .001.
    static func isSplitFirstVolume(_ path: String) -> Bool { SplitVolumes.isFirstVolume(path) }

    /// Prints a full diagnostic of how this build handles `archivePath`. Run with
    /// `NC_ARCHIVE_DIAG=/path/to/archive "Double Finder"` from Terminal.
    static func runDiagnostic(on archivePath: String) {
        print("=== Double Finder archive diagnostic ===")
        print("path:", archivePath)
        print("exists:", FileManager.default.fileExists(atPath: archivePath))
        print("kind:", kind(of: archivePath))
        print("7-Zip engine:", SevenZipEngine.version)
        print("--- libarchive ---")
        print(LibArchive.diagnose(archivePath))
        print("--- entryDetails() (what the panel uses to enter) ---")
        do {
            let entries = try entryDetails(archivePath: archivePath, kind: kind(of: archivePath))
            print("OK: \(entries.count) entries; first:",
                  entries.prefix(5).map { "\($0.path)\($0.isDir ? "/" : " (\($0.size)B)")" }.joined(separator: ", "))
        } catch let e as ArchiveEncryptedError {
            print("THREW ArchiveEncryptedError (→ password prompt) for:", e.archivePath)
        } catch {
            print("THREW \(type(of: error)):", error)
        }
        print("--- entryPaths() (path-only listing) ---")
        do {
            let entries = try entryPaths(archivePath: archivePath, kind: kind(of: archivePath))
            print("OK: \(entries.count) entries; first:", entries.prefix(5).joined(separator: ", "))
        } catch let e as ArchiveEncryptedError {
            print("THREW ArchiveEncryptedError (→ password prompt) for:", e.archivePath)
        } catch {
            print("THREW \(type(of: error)):", error)
        }
        print("--- extractAll() to temp dir (real extract path) ---")
        let tmp = NSTemporaryDirectory() + "df_extract_diag_\(getpid())"
        try? FileManager.default.removeItem(atPath: tmp)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        do {
            try extractAll(archivePath: archivePath, to: tmp)
            let n = (try? FileManager.default.subpathsOfDirectory(atPath: tmp))?.count ?? -1
            print("OK: extracted \(n) paths into \(tmp)")
        } catch let e as ArchiveEncryptedError {
            print("THREW ArchiveEncryptedError (→ password prompt) for:", e.archivePath)
        } catch {
            print("THREW \(type(of: error)):", error)
        }
        try? FileManager.default.removeItem(atPath: tmp)
    }

    /// Path-only overload (remote archives, where size/mtime aren't available).
    static func buildItems(allPaths: [String], archivePath: String, internalPrefix: String) -> [FileItem] {
        let entries = allPaths.map { raw -> LibArchive.Entry in
            let isDir = raw.hasSuffix("/")
            return LibArchive.Entry(path: isDir ? String(raw.dropLast()) : raw, size: 0, mtime: nil, isDir: isDir)
        }
        return buildItems(entries: entries, archivePath: archivePath, internalPrefix: internalPrefix)
    }

    /// Builds the FileItems that are direct children of `internalPrefix`, using
    /// each entry's real size + mtime (directories aggregate from nesting).
    static func buildItems(entries: [LibArchive.Entry], archivePath: String, internalPrefix: String) -> [FileItem] {
        let prefix = internalPrefix.isEmpty ? "" : internalPrefix + "/"
        // A direct child is a directory if any entry nests under it OR it's a
        // dir-entry (some tools list dirs without a trailing slash, so we OR it).
        var order: [String] = []
        var isDir: [String: Bool] = [:]
        var size: [String: Int64] = [:]
        var mtime: [String: Date] = [:]
        for e in entries {
            let clean = e.path.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, clean.hasPrefix(prefix) else { continue }
            let remaining = String(clean.dropFirst(prefix.count))
            guard !remaining.isEmpty else { continue }
            let comps = remaining.components(separatedBy: "/")
            let first = comps[0]
            guard !first.isEmpty else { continue }
            let isChildDir = comps.count > 1 || e.isDir
            if isDir[first] == nil { order.append(first) }
            isDir[first] = (isDir[first] ?? false) || isChildDir
            // Record size/mtime only for the exact direct-child entry (file).
            if comps.count == 1 {
                if !e.isDir { size[first] = e.size }
                if let mt = e.mtime { mtime[first] = mt }
            }
        }
        let items = order.map { name -> FileItem in
            let dir = isDir[name] ?? false
            let childInternal = internalPrefix.isEmpty ? name : internalPrefix + "/" + name
            return FileItem(
                id: UUID(), name: name, path: archivePath + "/" + childInternal,
                isDirectory: dir, isArchive: false,
                size: dir ? 0 : (size[name] ?? 0),
                modified: mtime[name] ?? Date(),
                isHidden: name.hasPrefix("."), isSymlink: false,
                permissions: dir ? "rwxr-xr-x" : "rw-r--r--"
            )
        }
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Extraction

    func copy(from: String, to: String) async throws {
        let entry = internalPath(from: from)
        let archive = archivePath
        let kind = self.kind
        let pw = password
        // Detached (CPU-bound decompression must stay off the caller's actor), but
        // still cancellable: the handler forwards the awaiting task's cancellation
        // into the extract loop, so closing the viewer really does stop a solid-7z
        // pass instead of leaving it grinding in the background.
        let work = Task.detached(priority: .userInitiated) {
            try Self.extractEntry(archivePath: archive, entry: entry, to: to, kind: kind, password: pw,
                                  isCancelled: { Task.isCancelled })
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Extracts a SINGLE entry (file, or folder + subtree) so it lands flat in
    /// `dest` under its own name. libarchive first (charset detection for legacy
    /// zip names, solid-7z early stop); an encrypted 7z, which libarchive can't
    /// decrypt, goes to the in-process 7-Zip engine.
    static func extractEntry(archivePath: String, entry: String, to dest: String, kind: Kind, password: String? = nil,
                             isCancelled: (() -> Bool)? = nil) throws {
        do {
            try LibArchive.extractItem(archivePath: archivePath, entry: entry, to: dest, password: password,
                                       isCancelled: isCancelled)
        } catch is ArchiveEncryptedError {
            guard kind == .sevenZip else { throw ArchiveEncryptedError(archivePath: archivePath) }
            try SevenZipEngine.extract(archivePath: archivePath, entry: entry, to: dest, password: password,
                                       isCancelled: isCancelled)
        }
    }

    /// Extracts the whole archive to `dest` (the Extract command). A 7z goes to
    /// the in-process 7-Zip engine first — the reference implementation for
    /// solid / encrypted / multi-volume 7z — with libarchive as the fallback;
    /// every other format (zip, rar, tarballs, bare single-file compressors) is
    /// libarchive's, which decodes legacy zip names via charset detection.
    /// Throws `ArchiveEncryptedError` for a wrong/missing password so the caller
    /// can prompt.
    static func extractAll(archivePath: String, to dest: String, password: String? = nil,
                           isCancelled: (() -> Bool)? = nil) throws {
        let k = kind(of: archivePath)
        guard k == .sevenZip else {
            try LibArchive.extractAll(archivePath: archivePath, to: dest, password: password)
            return
        }
        do {
            try SevenZipEngine.extract(archivePath: archivePath, entry: nil, to: dest, password: password,
                                       isCancelled: isCancelled)
        } catch is ArchiveEncryptedError {
            throw ArchiveEncryptedError(archivePath: archivePath)   // → password prompt
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try LibArchive.extractAll(archivePath: archivePath, to: dest, password: password)   // last resort
        }
    }

    // MARK: - Unsupported (archives are read-only here)

    /// Recursive size of a directory inside the archive = sum of all file
    /// entries beneath it (Space-key size calculation).
    func directorySize(_ path: String) async -> Int64 {
        let internalDir = internalPath(from: path)
        let archive = archivePath, k = kind, pw = password
        return await Task.detached(priority: .userInitiated) {
            let entries = (try? Self.entryDetails(archivePath: archive, kind: k, password: pw)) ?? []
            let prefix = internalDir.isEmpty ? "" : internalDir + "/"
            return entries.reduce(Int64(0)) { acc, e in
                (!e.isDir && e.path.hasPrefix(prefix)) ? acc + e.size : acc
            }
        }.value
    }

    func move(from: String, to: String) async throws {
        try await copy(from: from, to: to)
    }
    func delete(_ path: String) async throws {
        throw FSUnsupportedError(message: "Deleting inside an archive is not supported")
    }
    func createDirectory(_ path: String) async throws {
        throw FSUnsupportedError(message: "Creating directories inside an archive is not supported")
    }
    /// Renames an entry inside the archive by rewriting it with libarchive (no
    /// external tools — the source format/filters are mirrored). A folder also
    /// renames every entry beneath it. zip/tar*/7z(non-encrypted) supported;
    /// rar (read-only) and bare single-file streams can't be renamed.
    func rename(at path: String, to newName: String) async throws {
        let oldEntry = internalPath(from: path)
        guard !oldEntry.isEmpty else {
            throw FSUnsupportedError(message: "Nothing to rename")
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw FSUnsupportedError(message: "Invalid name")
        }
        let parent = (oldEntry as NSString).deletingLastPathComponent
        let newEntry = parent.isEmpty ? trimmed : parent + "/" + trimmed
        let archive = archivePath
        let k = kind
        let pw = password
        switch k {
        case .rar:
            throw FSUnsupportedError(message: "RAR archives are read-only — can’t rename inside them.")
        case .single, .unknown:
            throw FSUnsupportedError(message: "This archive holds a single stream — nothing to rename inside it.")
        default:
            break
        }
        try await Task.detached(priority: .userInitiated) {
            // Map the entry (and, for a folder, its whole subtree) old → new.
            let prefix = oldEntry + "/"
            try LibArchive.rewriteRenaming(archivePath: archive, password: pw) { name in
                if name == oldEntry { return newEntry }
                if name.hasPrefix(prefix) { return newEntry + String(name.dropFirst(oldEntry.count)) }
                return nil
            }
        }.value
    }
}
