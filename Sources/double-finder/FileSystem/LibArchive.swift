import Foundation
import Clibarchive

/// Thin Swift wrapper over the system libarchive (BSD, shipped with macOS as
/// /usr/lib/libarchive — bsdtar's backend). Handles browse/extract/create for
/// zip, tar*, 7z, rar (read), and bare gz/bz2/xz/zst — with no external tools.
enum LibArchive {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // libarchive return codes
    private static let OK: Int32 = 0
    private static let EOFR: Int32 = 1
    private static let WARN: Int32 = -20
    // archive_entry filetype bits
    private static let AE_IFMT: mode_t = 0o170000
    private static let AE_IFREG: mode_t = 0o100000
    private static let AE_IFDIR: mode_t = 0o040000
    private static let AE_IFLNK: mode_t = 0o120000
    // archive_write_disk extraction flags
    private static let EXTRACT_TIME: Int32 = 0x0004
    private static let EXTRACT_PERM: Int32 = 0x0002
    private static let EXTRACT_FFLAGS: Int32 = 0x0040
    private static let EXTRACT_SECURE_SYMLINKS: Int32 = 0x0200
    private static let EXTRACT_SECURE_NODOTDOT: Int32 = 0x0400

    static var versionString: String {
        archive_version_string().map { String(cString: $0) } ?? "libarchive"
    }

    /// Detailed report of how libarchive opens/lists an archive — for debugging
    /// machines where an archive that works elsewhere fails (older system lib).
    static func diagnose(_ archivePath: String) -> String {
        var out = "libarchive: \(versionString)\n"
        guard let a = archive_read_new() else { return out + "archive_read_new failed\n" }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        archive_read_support_format_raw(a)
        let openR = archive_read_open_filename(a, archivePath, 10240)
        out += "open_filename -> \(openR)" + (openR != OK ? " err='\(errString(a))'" : "") + "\n"
        if openR != OK { return out }
        let enc = detectArchiveEncoding(archivePath: archivePath, password: nil)
        out += "detected name charset -> \(enc.map { "\($0)" } ?? "UTF-8/none")\n"
        var entry: OpaquePointer?
        var count = 0
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == EOFR { out += "next_header -> EOF after \(count) entries\n"; break }
            if r < WARN {
                out += "next_header -> FAIL r=\(r) err='\(errString(a))' has_encrypted=\(archive_read_has_encrypted_entries(a))\n"
                break
            }
            count += 1
            if r != OK, let e = entry { out += "  [warn r=\(r)] \(entryName(e, encoding: enc))\n" }
            else if let e = entry, count <= 5 { out += "  [\(count)] \(entryName(e, encoding: enc))\n" }
            if count > 200 { out += "  …(\(count)+ entries)\n"; break }
            archive_read_data_skip(a)
        }
        return out
    }

    // MARK: - Helpers

    private static func errString(_ a: OpaquePointer?) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "unknown libarchive error"
    }

    /// The entry's name and, when libarchive couldn't give a UTF-8 form, its raw
    /// stored bytes. Windows-made zips that DON'T set the UTF-8 flag store the
    /// name in a legacy codepage (GBK / Shift-JIS / Big5 / …): `pathname_utf8` is
    /// nil and `pathname` returns those bytes verbatim — which we must decode
    /// with the archive's detected charset, not blindly as UTF-8 (→ mojibake).
    private static func rawName(_ e: OpaquePointer) -> (utf8: String?, bytes: Data?) {
        if let u = archive_entry_pathname_utf8(e) { return (String(cString: u), nil) }
        if let p = archive_entry_pathname(e) { return (nil, Data(bytes: p, count: strlen(p))) }
        return (nil, nil)
    }

    /// An entry's display name, decoding legacy bytes with `encoding` (the value
    /// detected once for the whole archive by `detectArchiveEncoding`).
    private static func entryName(_ e: OpaquePointer, encoding: String.Encoding?) -> String {
        let (utf8, bytes) = rawName(e)
        if let utf8 = utf8 { return utf8 }
        if let bytes = bytes { return decodeName(bytes, encoding: encoding) }
        return ""
    }

    /// Decodes one raw filename: valid UTF-8 always wins (covers ASCII names and
    /// properly-flagged archives); otherwise use the archive's detected legacy
    /// `encoding`; lossy UTF-8 as a last resort.
    static func decodeName(_ data: Data, encoding: String.Encoding?) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let enc = encoding, let s = String(data: data, encoding: enc), !s.isEmpty { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Guesses the charset used for an archive's non-UTF-8 entry names by running
    /// the system's charset detector (ICU under the hood) over ALL such names
    /// combined — more bytes ⇒ a more reliable guess than per-name detection,
    /// and it adapts per archive (GBK, Shift-JIS, Big5, EUC-KR, …) rather than
    /// assuming one codepage. Returns nil when every name is already UTF-8/ASCII
    /// (nothing to re-decode) or detection is inconclusive.
    static func detectLegacyEncoding(_ rawNames: [Data]) -> String.Encoding? {
        var combined = Data()
        for d in rawNames where d.contains(where: { $0 >= 0x80 }) {   // skip pure-ASCII names
            combined.append(d); combined.append(0x0a)                 // newline-separate for the detector
        }
        guard !combined.isEmpty else { return nil }
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: combined, encodingOptions: [:],
                                          convertedString: nil, usedLossyConversion: &lossy)
        guard raw != 0, !lossy.boolValue else { return nil }
        let enc = String.Encoding(rawValue: raw)
        // Ignore a UTF-8 verdict: those names already round-trip via decodeName's
        // UTF-8 path, and a legacy codepage is what we actually need here.
        return enc == .utf8 ? nil : enc
    }

    /// True when any entry name is stored in a legacy (non-UTF-8) codepage —
    /// e.g. Windows-made zips without the UTF-8 flag (GBK / Shift-JIS / …).
    /// Header-only scan, cheap. Callers use this to keep such archives on
    /// libarchive (which decodes via charset detection) instead of 7zz, whose
    /// macOS build has no Windows codepage tables and mangles these names.
    static func hasLegacyEntryNames(archivePath: String, password: String?) -> Bool {
        guard let a = try? openReader(archivePath, password: password) else { return false }
        defer { archive_read_free(a) }
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == EOFR || r < WARN { break }
            if let e = entry, let bytes = rawName(e).bytes,
               String(data: bytes, encoding: .utf8) == nil { return true }
            archive_read_data_skip(a)
        }
        return false
    }

    /// Pre-scans an archive's headers (no data decompression) to detect the
    /// charset of its legacy entry names, so a streaming extract/rewrite can
    /// decode names consistently. Cheap: reads only the header/central-directory.
    private static func detectArchiveEncoding(archivePath: String, password: String?) -> String.Encoding? {
        guard let a = try? openReader(archivePath, password: password) else { return nil }
        defer { archive_read_free(a) }
        var entry: OpaquePointer?
        var raws: [Data] = []
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == EOFR || r < WARN { break }
            if let e = entry, let bytes = rawName(e).bytes { raws.append(bytes) }
            archive_read_data_skip(a)
        }
        return detectLegacyEncoding(raws)
    }

    private static func normalize(_ s: String) -> String {
        var n = s
        if n.hasPrefix("./") { n = String(n.dropFirst(2)) }
        if n.hasSuffix("/") { n = String(n.dropLast()) }
        return n
    }

    /// True if a read failure is due to encryption (missing/wrong passphrase, or
    /// an encryption scheme libarchive can't decrypt — e.g. any encrypted 7z).
    private static func looksEncrypted(_ a: OpaquePointer?) -> Bool {
        if archive_read_has_encrypted_entries(a) > 0 { return true }
        let m = errString(a).lowercased()
        return m.contains("passphrase") || m.contains("encrypt") || m.contains("password")
    }

    /// Throws `ArchiveEncryptedError` if the reader's current error is
    /// encryption-related, otherwise a generic `Failure`. Used at every failure
    /// point so encrypted zips (whose data error surfaces during extraction, not
    /// at header time) still route to the password prompt.
    private static func throwClassified(_ a: OpaquePointer?, archivePath: String) throws -> Never {
        if looksEncrypted(a) { throw ArchiveEncryptedError(archivePath: archivePath) }
        throw Failure(message: errString(a))
    }

    /// Opens a reader supporting all formats + filters (+ raw for bare streams).
    private static func openReader(_ archivePath: String, password: String?) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw Failure(message: "archive_read_new failed") }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        archive_read_support_format_raw(a)   // bare gz/bz2/xz/zst single streams
        if let pw = password, !pw.isEmpty { archive_read_add_passphrase(a, pw) }
        if archive_read_open_filename(a, archivePath, 10240) != OK {
            let msg = errString(a)
            archive_read_free(a)
            throw Failure(message: msg)
        }
        return a
    }

    // MARK: - Listing

    /// One archive entry with its metadata (path normalized: no "./" prefix or
    /// trailing slash; `isDir` true for directory entries).
    struct Entry {
        let path: String
        let size: Int64
        let mtime: Date?
        let isDir: Bool
    }

    /// All entries with size + mtime. Throws `ArchiveEncryptedError` when a
    /// password is needed.
    static func listEntries(archivePath: String, password: String?) throws -> [Entry] {
        let a = try openReader(archivePath, password: password)
        defer { archive_read_free(a) }
        // Collect raw names + metadata in one pass, detect the archive's name
        // charset from the legacy-byte names, then decode them all consistently.
        struct Raw { let utf8: String?; let bytes: Data?; let size: Int64; let mtime: Date?; let isDir: Bool }
        var raws: [Raw] = []
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == EOFR { break }
            if r < WARN { try throwClassified(a, archivePath: archivePath) }
            if let e = entry {
                let (u, b) = rawName(e)
                let mt = archive_entry_mtime(e)
                raws.append(Raw(utf8: u, bytes: b,
                                size: archive_entry_size(e),
                                mtime: mt > 0 ? Date(timeIntervalSince1970: TimeInterval(mt)) : nil,
                                isDir: (archive_entry_filetype(e) & AE_IFMT) == AE_IFDIR))
            }
            archive_read_data_skip(a)
        }
        let enc = detectLegacyEncoding(raws.compactMap { $0.bytes })
        var result: [Entry] = []
        for raw in raws {
            let name = raw.utf8 ?? decodeName(raw.bytes ?? Data(), encoding: enc)
            // The raw-format reader names a bare stream "data"; skip that
            // synthetic name (bare single-file archives aren't browsable).
            if name == "data" { continue }
            let n = normalize(name)
            if !n.isEmpty {
                result.append(Entry(path: n, size: raw.size, mtime: raw.mtime, isDir: raw.isDir))
            }
        }
        return result
    }

    /// All entry paths (normalized). Throws `ArchiveEncryptedError` if a password
    /// is needed.
    static func list(archivePath: String, password: String?) throws -> [String] {
        try listEntries(archivePath: archivePath, password: password).map { $0.path }
    }

    // MARK: - Extraction (read → write-to-disk)

    /// Core extractor. For each entry, `outputPath(normalizedName)` returns the
    /// absolute destination path, or nil to skip the entry.
    private static func extract(archivePath: String, password: String?,
                                outputPath: (String) -> String?) throws {
        // Detect the name charset up front so entries decode to the same names
        // shown in the panel (and land on disk with correct UTF-8 names).
        let enc = detectArchiveEncoding(archivePath: archivePath, password: password)
        let a = try openReader(archivePath, password: password)
        defer { archive_read_free(a) }
        guard let disk = archive_write_disk_new() else { throw Failure(message: "write_disk_new failed") }
        defer { archive_write_free(disk) }
        let flags = EXTRACT_TIME | EXTRACT_PERM | EXTRACT_FFLAGS | EXTRACT_SECURE_SYMLINKS | EXTRACT_SECURE_NODOTDOT
        archive_write_disk_set_options(disk, flags)
        archive_write_disk_set_standard_lookup(disk)

        var entry: OpaquePointer?
        var wroteAny = false
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == EOFR { break }
            if r < WARN { try throwClassified(a, archivePath: archivePath) }
            guard let e = entry else { continue }
            let name = normalize(entryName(e, encoding: enc))
            guard let out = outputPath(name) else {
                // Skip this entry. In a SOLID 7z all entries share one compressed
                // block, and `archive_read_data_skip` can't advance through it
                // without decompressing — a later wanted entry would then fail with
                // "Truncated 7-Zip file body". So for 7z, read+discard (forces the
                // decompression) instead of seeking. Other formats skip cheaply.
                if archive_format(a) == ARCHIVE_FORMAT_7ZIP {
                    try drainData(from: a, archivePath: archivePath)
                } else {
                    archive_read_data_skip(a)
                }
                continue
            }
            // Redirect this entry to the chosen destination (keep type/perm/symlink).
            archive_entry_set_pathname(e, out)
            archive_entry_set_pathname_utf8(e, out)
            // Archives that omit explicit directory entries (e.g. many Windows
            // zips list files like "doublecmd/7z.dll" with no "doublecmd/" entry)
            // would fail with ENOENT — archive_write_disk doesn't reliably create
            // missing parents here. Create the entry's parent dir ourselves.
            let parent = (out as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            let wr = archive_write_header(disk, e)
            if wr < WARN { throw Failure(message: errString(disk)) }
            if archive_entry_size(e) > 0 { try copyData(from: a, to: disk, archivePath: archivePath) }
            archive_write_finish_entry(disk)
            wroteAny = true
        }
        archive_write_close(disk)
        if !wroteAny {
            // Bare single-file stream (raw): libarchive named it "data"; write it
            // out under the source name minus its compression suffix.
            try extractRaw(archivePath: archivePath, password: password, outputPath: outputPath)
        }
    }

    /// libarchive's format code for 7-Zip (`ARCHIVE_FORMAT_7ZIP` from archive.h).
    private static let ARCHIVE_FORMAT_7ZIP: Int32 = 0xE0000

    /// Reads and discards the current entry's data — used to advance past an
    /// unwanted entry in a solid archive (where a plain skip can't decompress).
    private static func drainData(from a: OpaquePointer, archivePath: String) throws {
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = archive_read_data(a, buf, bufSize)
            if n == 0 { break }
            if n < 0 { try throwClassified(a, archivePath: archivePath) }
        }
    }

    private static func copyData(from a: OpaquePointer, to disk: OpaquePointer, archivePath: String) throws {
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = archive_read_data(a, buf, bufSize)
            if n == 0 { break }
            if n < 0 { try throwClassified(a, archivePath: archivePath) }
            var written = 0
            while written < n {
                let w = archive_write_data(disk, buf.advanced(by: written), n - written)
                if w < 0 { throw Failure(message: errString(disk)) }
                written += w
            }
        }
    }

    /// Bare single-file compressor (.gz/.bz2/.xz/.zst with no tar container):
    /// the raw reader yields one stream named "data"; we write it to the
    /// source's basename with the compression suffix stripped.
    private static func extractRaw(archivePath: String, password: String?,
                                   outputPath: (String) -> String?) throws {
        let base = (archivePath as NSString).lastPathComponent
        let lower = base.lowercased()
        var stripped = base
        for suf in [".gz", ".bz2", ".xz", ".zst", ".lz4", ".z"] where lower.hasSuffix(suf) {
            stripped = String(base.dropLast(suf.count)); break
        }
        guard let out = outputPath(stripped) else { return }
        let a = try openReader(archivePath, password: password)
        defer { archive_read_free(a) }
        var entry: OpaquePointer?
        if archive_read_next_header(a, &entry) < WARN { try throwClassified(a, archivePath: archivePath) }
        FileManager.default.createFile(atPath: out, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: out) else {
            throw Failure(message: "Can't write \(out)")
        }
        defer { try? fh.close() }
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = archive_read_data(a, buf, bufSize)
            if n == 0 { break }
            if n < 0 { try throwClassified(a, archivePath: archivePath) }
            fh.write(Data(bytes: buf, count: n))
        }
    }

    /// Extracts everything to `destDir`, recreating the folder tree.
    static func extractAll(archivePath: String, to destDir: String, password: String?) throws {
        try extract(archivePath: archivePath, password: password) { name in
            name.isEmpty ? destDir : (destDir as NSString).appendingPathComponent(name)
        }
    }

    /// Extracts a single entry (a file, or a folder + its whole subtree) to
    /// `destDir`, preserving the item's own name (but not its parent path).
    static func extractItem(archivePath: String, entry wanted: String, to destDir: String, password: String?) throws {
        let w = normalize(wanted)
        let parent = (w as NSString).deletingLastPathComponent
        let stripPrefix = parent.isEmpty ? "" : parent + "/"
        try extract(archivePath: archivePath, password: password) { name in
            guard name == w || name.hasPrefix(w + "/") else { return nil }
            let rel = stripPrefix.isEmpty ? name : String(name.dropFirst(stripPrefix.count))
            return (destDir as NSString).appendingPathComponent(rel)
        }
    }

    // MARK: - In-place rewrite (used for renaming entries)

    /// Rewrites the archive applying `rename` to each entry's path (return a new
    /// path, or nil to keep). The output mirrors the source's format + filters,
    /// then atomically replaces the original. Zero external tools — works for
    /// zip/tar*/7z (non-encrypted). Used to rename an entry inside an archive.
    static func rewriteRenaming(archivePath: String, password: String?,
                                rename: (String) -> String?) throws {
        let enc = detectArchiveEncoding(archivePath: archivePath, password: password)
        let a = try openReader(archivePath, password: password)
        defer { archive_read_free(a) }
        guard let w = archive_write_new() else { throw Failure(message: "archive_write_new failed") }
        defer { archive_write_free(w) }

        var entry: OpaquePointer?
        var r = archive_read_next_header(a, &entry)
        if r == EOFR { return }                                   // empty archive
        if r < WARN { try throwClassified(a, archivePath: archivePath) }

        // Mirror the source container format + compression filters onto the
        // writer. Read filter index 0 is closest to the format (e.g. gzip for a
        // .tar.gz); add every non-"none" filter in that order so the write
        // pipeline matches (tar → gzip → file).
        archive_write_set_format(w, archive_format(a))
        for fi in 0..<archive_filter_count(a) {
            let code = archive_filter_code(a, fi)
            if code != 0 { archive_write_add_filter(w, code) }    // 0 = ARCHIVE_FILTER_NONE
        }
        let tmp = archivePath + ".dfrename.tmp"
        try? FileManager.default.removeItem(atPath: tmp)
        if archive_write_open_filename(w, tmp) != OK {
            throw Failure(message: errString(w))
        }

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while r != EOFR {
            if r < WARN { try? FileManager.default.removeItem(atPath: tmp); try throwClassified(a, archivePath: archivePath) }
            if let e = entry {
                if let newName = rename(normalize(entryName(e, encoding: enc))) {
                    archive_entry_set_pathname(e, newName)
                    archive_entry_set_pathname_utf8(e, newName)
                }
                if archive_write_header(w, e) < WARN {
                    let msg = errString(w); try? FileManager.default.removeItem(atPath: tmp)
                    throw Failure(message: msg)
                }
                if archive_entry_size(e) > 0 {
                    while true {
                        let n = archive_read_data(a, buf, bufSize)
                        if n == 0 { break }
                        if n < 0 { try? FileManager.default.removeItem(atPath: tmp); try throwClassified(a, archivePath: archivePath) }
                        var written = 0
                        while written < n {
                            let wn = archive_write_data(w, buf.advanced(by: written), n - written)
                            if wn < 0 { let msg = errString(w); try? FileManager.default.removeItem(atPath: tmp); throw Failure(message: msg) }
                            written += wn
                        }
                    }
                }
            }
            r = archive_read_next_header(a, &entry)
        }
        if archive_write_close(w) != OK {
            let msg = errString(w); try? FileManager.default.removeItem(atPath: tmp)
            throw Failure(message: msg)
        }
        // Atomically swap the rewritten archive in.
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: archivePath),
                                                  withItemAt: URL(fileURLWithPath: tmp))
    }

    // MARK: - Creation

    /// Creates an archive at `archivePath` from `sources` (absolute path +
    /// the entry name to store it under). Directories are added recursively.
    static func create(sources: [(absPath: String, entryName: String)], to archivePath: String,
                       format: ArchiveFormat, level: Int, password: String?) throws {
        guard let a = archive_write_new() else { throw Failure(message: "archive_write_new failed") }
        defer { archive_write_free(a) }
        let pw = (password?.isEmpty == false) ? password! : nil
        let lvl = max(0, min(9, level))

        switch format {
        case .zip:
            archive_write_set_format_zip(a)
            archive_write_set_options(a, "zip:compression-level=\(lvl)")
            if pw != nil { archive_write_set_options(a, "zip:encryption=aes256") }
        case .sevenZip:
            archive_write_set_format_7zip(a)
            archive_write_set_options(a, "7zip:compression-level=\(lvl)")
        case .tar:
            archive_write_set_format_pax_restricted(a)
            archive_write_add_filter_none(a)
        case .tarGz:
            archive_write_set_format_pax_restricted(a)
            archive_write_add_filter_gzip(a)
            archive_write_set_options(a, "gzip:compression-level=\(max(1, lvl))")
        case .tarBz2:
            archive_write_set_format_pax_restricted(a)
            archive_write_add_filter_bzip2(a)
        case .tarXz:
            archive_write_set_format_pax_restricted(a)
            archive_write_add_filter_xz(a)
            archive_write_set_options(a, "xz:compression-level=\(max(1, lvl))")
        }
        if let pw = pw { archive_write_set_passphrase(a, pw) }

        if archive_write_open_filename(a, archivePath) != OK {
            throw Failure(message: errString(a))
        }
        for src in sources {
            try addToArchive(a, absPath: src.absPath, entryName: src.entryName)
        }
        if archive_write_close(a) != OK { throw Failure(message: errString(a)) }
    }

    private static func addToArchive(_ a: OpaquePointer, absPath: String, entryName: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: absPath, isDirectory: &isDir) else { return }
        let attrs = try? fm.attributesOfItem(atPath: absPath)
        let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let perm = mode_t(truncatingIfNeeded: (attrs?[.posixPermissions] as? Int) ?? (isDir.boolValue ? 0o755 : 0o644))

        guard let entry = archive_entry_new() else { throw Failure(message: "archive_entry_new failed") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, entryName)
        archive_entry_set_pathname_utf8(entry, entryName)
        archive_entry_set_mtime(entry, time_t(mtime), 0)
        archive_entry_set_perm(entry, perm)

        if isSymlink {
            let target = (try? fm.destinationOfSymbolicLink(atPath: absPath)) ?? ""
            archive_entry_set_filetype(entry, UInt32(AE_IFLNK))
            archive_entry_set_symlink(entry, target)
            archive_entry_set_size(entry, 0)
            if archive_write_header(a, entry) < WARN { throw Failure(message: errString(a)) }
        } else if isDir.boolValue {
            archive_entry_set_filetype(entry, UInt32(AE_IFDIR))
            archive_entry_set_size(entry, 0)
            if archive_write_header(a, entry) < WARN { throw Failure(message: errString(a)) }
            let kids = (try? fm.contentsOfDirectory(atPath: absPath))?.sorted() ?? []
            for k in kids {
                try addToArchive(a, absPath: absPath + "/" + k, entryName: entryName + "/" + k)
            }
        } else {
            let data = fm.contents(atPath: absPath) ?? Data()
            archive_entry_set_filetype(entry, UInt32(AE_IFREG))
            archive_entry_set_size(entry, Int64(data.count))
            if archive_write_header(a, entry) < WARN { throw Failure(message: errString(a)) }
            if !data.isEmpty {
                try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    var written = 0
                    let total = raw.count
                    guard let baseAddr = raw.baseAddress else { return }
                    while written < total {
                        let w = archive_write_data(a, baseAddr.advanced(by: written), total - written)
                        if w < 0 { throw Failure(message: errString(a)) }
                        if w == 0 { break }
                        written += w
                    }
                }
            }
        }
    }
}
