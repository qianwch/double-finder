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

/// Thrown when the external command-line tool needed to read an archive isn't
/// installed (e.g. `7z` missing on a fresh Intel mac). Distinct from
/// `ArchiveEncryptedError` so we don't mistakenly prompt for a password.
struct ArchiveToolMissingError: LocalizedError {
    let tool: String
    let hint: String
    var errorDescription: String? {
        "“\(tool)” is required to open this archive, but it was not found on this Mac.\n\n\(hint)"
    }
}

/// Session cache of archive passwords (keyed by archive path on disk).
enum ArchivePasswords {
    private static var map: [String: String] = [:]
    static func get(_ path: String) -> String? { map[path] }
    static func set(_ path: String, _ pw: String) { map[path] = pw }
}

/// Browses and extracts archives of many formats by dispatching to the right
/// command-line tool (zip→unzip, tar family→tar, 7z→7z, rar→unrar). Listing is
/// normalized to a flat list of internal paths, then a shared tree builder
/// produces the per-directory view. (Class kept named `ZipFS` for call sites.)
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
        let name = (path as NSString).lastPathComponent.lowercased()
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
    /// per-entry metadata. Encrypted-7z fallback (path-only) yields zero sizes.
    static func entryDetails(archivePath: String, kind: Kind, password: String? = nil) throws -> [LibArchive.Entry] {
        if isSplitFirstVolume(archivePath) {
            return try sevenZipListDetailed(tool: requireSevenZipTool(), archivePath: archivePath, password: password)
        }
        if kind == .unknown { return [] }
        if kind == .single {
            let size = (try? FileManager.default.attributesOfItem(atPath: archivePath)[.size] as? Int64) ?? nil
            let mtime = (try? FileManager.default.attributesOfItem(atPath: archivePath)[.modificationDate] as? Date) ?? nil
            return [LibArchive.Entry(path: strippedSingleName(archivePath), size: size ?? 0, mtime: mtime ?? nil, isDir: false)]
        }
        do {
            return try LibArchive.listEntries(archivePath: archivePath, password: password)
        } catch is ArchiveEncryptedError {
            let paths = try sevenZipEncryptedFallback(archivePath: archivePath, kind: kind) { tool in
                try sevenZipList(tool: tool, archivePath: archivePath, password: password)
            }
            return paths.map { LibArchive.Entry(path: $0.hasSuffix("/") ? String($0.dropLast()) : $0,
                                                size: 0, mtime: nil, isDir: $0.hasSuffix("/")) }
        } catch {
            // libarchive couldn't read it (exotic codec / edge case). For 7z/zip/rar
            // retry the listing with 7zz (the 7-Zip/MacZip engine, keeps size/date).
            // NOT for tarballs — `7z l foo.tar.gz` lists the outer `.tar`, not the
            // real contents. No 7zz → surface the original libarchive error.
            guard prefersSevenZip(kind), let tool = SevenZip.resolve() else { throw error }
            return try sevenZipListDetailed(tool: tool, archivePath: archivePath, password: password)
        }
    }

    /// A flat list of internal entry paths. libarchive handles everything except
    /// *encrypted 7z* (which it can't decrypt at all) — those fall back to the
    /// external 7-Zip. Throws `ArchiveEncryptedError` when a password is needed.
    static func entryPaths(archivePath: String, kind: Kind, password: String? = nil) throws -> [String] {
        // libarchive auto-detects the container, reads UTF-8 entry names, and
        // covers zip/tar*/7z/rar — no external tool needed.
        if kind == .unknown { return [] }
        // A bare .gz/.bz2/.xz/.zst holds exactly one file (its name minus the
        // suffix); show that single entry instead of decompressing externally.
        if kind == .single { return [strippedSingleName(archivePath)] }
        do {
            return try LibArchive.list(archivePath: archivePath, password: password)
        } catch is ArchiveEncryptedError {
            return try sevenZipEncryptedFallback(archivePath: archivePath, kind: kind) { tool in
                try sevenZipList(tool: tool, archivePath: archivePath, password: password)
            }
        } catch {
            // libarchive failed (exotic codec / edge case): retry 7z/zip/rar listing
            // with 7zz. Tarballs excluded (7z would list the outer `.tar`).
            guard prefersSevenZip(kind), let tool = SevenZip.resolve() else { throw error }
            return try sevenZipList(tool: tool, archivePath: archivePath, password: password)
        }
    }

    /// libarchive cannot decrypt 7z archives (data- or header-encrypted), so an
    /// encrypted 7z routes here. Uses the external 7-Zip if available; otherwise
    /// surfaces a clear "install 7z" message (for zip/rar, just re-prompts).
    private static func sevenZipEncryptedFallback<T>(archivePath: String, kind: Kind,
                                                     _ body: (String) throws -> T) throws -> T {
        guard kind == .sevenZip else { throw ArchiveEncryptedError(archivePath: archivePath) }
        guard let tool = sevenZipTool() else {
            throw ArchiveToolMissingError(
                tool: "7z",
                hint: "Encrypted 7z archives need 7-Zip — libarchive can't decrypt them.\nInstall it with Homebrew:\n    brew install sevenzip")
        }
        return try body(tool)
    }

    private static func sevenZipTool() -> String? { SevenZip.resolve() }

    /// True if `path` is the first volume of a split archive ("x.7z.001"). 7zz reads
    /// the whole volume set natively when opened on the .001 (libarchive can't).
    static func isSplitFirstVolume(_ path: String) -> Bool {
        FileItem.splitArchiveFirstPartBase((path as NSString).lastPathComponent) != nil
    }

    private static func requireSevenZipTool() throws -> String {
        guard let tool = sevenZipTool() else {
            throw ArchiveToolMissingError(
                tool: "7z",
                hint: "Split (multi-volume) archives need 7-Zip.\nInstall it with Homebrew:\n    brew install sevenzip")
        }
        return tool
    }

    /// Prints a full diagnostic of how this build handles `archivePath`. Run with
    /// `NC_ARCHIVE_DIAG=/path/to/archive "Double Finder"` from Terminal.
    static func runDiagnostic(on archivePath: String) {
        print("=== Double Finder archive diagnostic ===")
        print("path:", archivePath)
        print("exists:", FileManager.default.fileExists(atPath: archivePath))
        print("kind:", kind(of: archivePath))
        print("external 7z:", SevenZip.resolve() ?? "(none)")
        print("--- libarchive ---")
        print(LibArchive.diagnose(archivePath))
        print("--- entryPaths() (what the panel uses to enter) ---")
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

    /// `7z l -slt -ba` → parses the `Path = …` lines. Encryption failure (wrong
    /// or missing password) becomes `ArchiveEncryptedError`.
    private static func sevenZipList(tool: String, archivePath: String, password: String?) throws -> [String] {
        var args = ["l", "-slt", "-ba"]
        if let pw = password, !pw.isEmpty { args.append("-p" + pw) }
        args.append(archivePath)
        let (status, out) = runSevenZip(tool, args)
        if out.contains("Cannot open encrypted archive") || out.contains("Wrong password") {
            throw ArchiveEncryptedError(archivePath: archivePath)
        }
        // A non-zero exit without an encryption marker means the archive is
        // corrupt/incomplete — surface that, don't ask for a password.
        if status != 0 { throw ArchiveOpenError(archivePath: archivePath) }
        return out.split(separator: "\n").compactMap {
            $0.hasPrefix("Path = ") ? String($0.dropFirst("Path = ".count)) : nil
        }
    }

    /// `7z l -slt -ba` with size/date/folder parsing → full entries (used for split
    /// archives, which 7zz reads natively). `-slt` emits a blank-line-separated
    /// block per entry: `Path = …`, `Size = …`, `Modified = …`, `Folder = +/-`.
    private static func sevenZipListDetailed(tool: String, archivePath: String, password: String?) throws -> [LibArchive.Entry] {
        var args = ["l", "-slt", "-ba"]
        if let pw = password, !pw.isEmpty { args.append("-p" + pw) }
        args.append(archivePath)
        let (status, out) = runSevenZip(tool, args)
        if out.contains("Cannot open encrypted archive") || out.contains("Wrong password") {
            throw ArchiveEncryptedError(archivePath: archivePath)
        }
        // A non-zero exit without an encryption marker means the archive is
        // corrupt/incomplete (e.g. a split set missing a volume) — surface that,
        // don't ask for a password.
        if status != 0 { throw ArchiveOpenError(archivePath: archivePath) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var entries: [LibArchive.Entry] = []
        var path = "", size: Int64 = 0, isDir = false, mtime: Date? = nil
        func flush() {
            if !path.isEmpty { entries.append(LibArchive.Entry(path: path, size: size, mtime: mtime, isDir: isDir)) }
            path = ""; size = 0; isDir = false; mtime = nil
        }
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("Path = ") { path = String(line.dropFirst(7)) }
            else if line.hasPrefix("Size = ") { size = Int64(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0 }
            else if line.hasPrefix("Folder = ") { isDir = line.dropFirst(9).trimmingCharacters(in: .whitespaces) == "+" }
            else if line.hasPrefix("Attributes = ") { if line.contains("D") { isDir = true } }
            else if line.hasPrefix("Modified = ") { mtime = df.date(from: String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces)) }
        }
        flush()
        return entries
    }

    /// `7z x` to extract a single entry (or the whole archive when `entry` is nil).
    private static func sevenZipExtract(tool: String, archivePath: String, entry: String?,
                                        to dest: String, password: String?) throws {
        var args = ["x", "-y", "-o" + dest]
        if let pw = password, !pw.isEmpty { args.append("-p" + pw) }
        args.append(archivePath)
        if let entry = entry { args.append(entry) }
        let (status, out) = runSevenZip(tool, args)
        if status != 0 {
            if out.contains("Cannot open encrypted archive") || out.contains("Wrong password") {
                throw ArchiveEncryptedError(archivePath: archivePath)
            }
            throw FSUnsupportedError(message: out.isEmpty ? "Extraction failed" : out)
        }
    }

    private static func runSevenZip(_ tool: String, _ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice   // never block on a password prompt
        do { try proc.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
        try await Task.detached(priority: .userInitiated) {
            try Self.extractEntry(archivePath: archive, entry: entry, to: to, kind: kind, password: pw)
        }.value
    }

    /// Extracts a single internal entry (file, or folder + subtree) to `dest`.
    /// Formats 7zz extracts cleanly in a single pass and is the reference engine for
    /// (7z incl. solid/encrypted, zip, rar). **Tarballs and bare single-file
    /// compressors are excluded** — `7z x foo.tar.gz` peels only the outer gz layer
    /// (leaving a `.tar`), whereas libarchive does the whole thing in one step.
    private static func prefersSevenZip(_ kind: Kind) -> Bool {
        switch kind { case .sevenZip, .zip, .rar: return true; default: return false }
    }

    /// Extracts a SINGLE entry. Stays on libarchive: it strips the entry's parent
    /// path so a copied file lands flat in `dest` the way the panel expects (7-Zip
    /// would recreate the full archive-internal path). The solid-7z case is handled
    /// inside `LibArchive` (read+discard preceding entries). Encrypted 7z, which
    /// libarchive can't decrypt, still falls back to 7zz.
    static func extractEntry(archivePath: String, entry: String, to dest: String, kind: Kind, password: String? = nil) throws {
        if isSplitFirstVolume(archivePath) {
            try sevenZipExtract(tool: requireSevenZipTool(), archivePath: archivePath, entry: entry, to: dest, password: password)
            return
        }
        do {
            try LibArchive.extractItem(archivePath: archivePath, entry: entry, to: dest, password: password)
        } catch is ArchiveEncryptedError {
            try sevenZipEncryptedFallback(archivePath: archivePath, kind: kind) { tool in
                try sevenZipExtract(tool: tool, archivePath: archivePath, entry: entry, to: dest, password: password)
            }
        }
    }

    /// Extracts the whole archive to `dest` (the Extract command). **7zz-first** for
    /// the formats it owns (7z/zip/rar) — the reliable 7-Zip/MacZip engine — with
    /// in-process libarchive as the fallback when 7zz is absent or can't cope.
    /// Tarballs and bare single-file compressors go straight to libarchive (one-step,
    /// where 7-Zip would leave a `.tar`). Throws `ArchiveEncryptedError` for a
    /// wrong/missing password so the caller can prompt.
    static func extractAll(archivePath: String, to dest: String, password: String? = nil) throws {
        if isSplitFirstVolume(archivePath) {
            try sevenZipExtract(tool: requireSevenZipTool(), archivePath: archivePath, entry: nil, to: dest, password: password)
            return
        }
        let k = kind(of: archivePath)
        if prefersSevenZip(k), let tool = SevenZip.resolve() {
            do {
                try sevenZipExtract(tool: tool, archivePath: archivePath, entry: nil, to: dest, password: password)
            } catch is ArchiveEncryptedError {
                throw ArchiveEncryptedError(archivePath: archivePath)   // → password prompt; don't mask with libarchive
            } catch {
                try LibArchive.extractAll(archivePath: archivePath, to: dest, password: password)   // last-resort
            }
        } else {
            do {
                try LibArchive.extractAll(archivePath: archivePath, to: dest, password: password)
            } catch is ArchiveEncryptedError {
                try sevenZipEncryptedFallback(archivePath: archivePath, kind: k) { tool in
                    try sevenZipExtract(tool: tool, archivePath: archivePath, entry: nil, to: dest, password: password)
                }
            }
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
