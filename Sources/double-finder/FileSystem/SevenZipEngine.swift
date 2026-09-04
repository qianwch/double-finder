import Foundation
import CSevenZip

/// Swift face of the in-process 7-Zip engine (`Sources/CSevenZip`): the 7z
/// format handler compiled into the executable. It is what libarchive can't
/// do — encrypted 7z (data- or header-encrypted) read and write — plus native
/// 7z creation (multi-threaded LZMA2, header encryption, volume splitting).
/// Everything else (zip, tar, rar, plain 7z browsing) stays on libarchive.
///
/// All calls are synchronous and CPU-bound: run them off the main actor.
enum SevenZipEngine {
    /// Version of the bundled 7-Zip sources, e.g. "26.02".
    static var version: String { String(cString: sz_engine_version()) }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Reading

    /// Lists every entry of the 7z archive at `archivePath` (a split set's first
    /// volume is read with all its volumes). Throws `ArchiveEncryptedError` when
    /// the header is encrypted and `password` is missing or wrong, and
    /// `ArchiveOpenError` for anything that is not a readable 7z.
    static func list(archivePath: String, password: String?) throws -> [LibArchive.Entry] {
        let handle = try open(archivePath: archivePath, password: password)
        defer { sz_close(handle) }
        var entries: [LibArchive.Entry] = []
        let count = sz_item_count(handle)
        entries.reserveCapacity(Int(count))
        for i in 0..<count {
            var info = sz_item_info()
            guard sz_item(handle, i, &info) == SZR_OK, let cPath = info.path else { continue }
            let path = String(cString: cPath)
            let mtime = info.mtime >= 0 ? Date(timeIntervalSince1970: TimeInterval(info.mtime)) : nil
            entries.append(LibArchive.Entry(path: path, size: Int64(info.size), mtime: mtime, isDir: info.is_dir != 0))
        }
        return entries
    }

    /// Extracts `entry` (a file, or a folder and everything beneath it) so it
    /// lands under `destDir` by its own last path component — the same flat
    /// result `LibArchive.extractItem` produces. `entry` nil extracts everything,
    /// preserving the archive's tree.
    static func extract(archivePath: String, entry: String?, to destDir: String, password: String?,
                        progress: ((Int64, Int64) -> Void)? = nil,
                        isCancelled: (() -> Bool)? = nil) throws {
        let handle = try open(archivePath: archivePath, password: password)
        defer { sz_close(handle) }

        var indices: [UInt32]? = nil
        var stripPrefix = ""
        if let wanted = entry?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !wanted.isEmpty {
            var picked: [UInt32] = []
            for i in 0..<sz_item_count(handle) {
                var info = sz_item_info()
                guard sz_item(handle, i, &info) == SZR_OK, let cPath = info.path else { continue }
                let path = String(cString: cPath)
                if path == wanted || path.hasPrefix(wanted + "/") { picked.append(i) }
            }
            guard !picked.isEmpty else { throw Failure(message: "Entry not found in archive: \(wanted)") }
            indices = picked
            let parent = (wanted as NSString).deletingLastPathComponent
            stripPrefix = parent.isEmpty ? "" : parent + "/"
        }

        let box = CallbackBox(progress: progress, isCancelled: isCancelled)
        var message: UnsafeMutablePointer<CChar>? = nil
        let status = withExtendedLifetime(box) { () -> sz_status in
            let ctx = Unmanaged.passUnretained(box).toOpaque()
            if let indices = indices {
                return indices.withUnsafeBufferPointer { buf in
                    sz_extract(handle, buf.baseAddress, UInt32(buf.count), destDir, stripPrefix,
                               CallbackBox.progressThunk, CallbackBox.cancelThunk, ctx, &message)
                }
            }
            return sz_extract(handle, nil, 0, destDir, stripPrefix,
                              CallbackBox.progressThunk, CallbackBox.cancelThunk, ctx, &message)
        }
        try check(status, archivePath: archivePath, message: message)
    }

    // MARK: - Writing

    /// Creates a 7z archive from `sources` (each stored under its `entryName`;
    /// directories are added recursively). `password` encrypts the data and,
    /// with `encryptHeaders`, the file names too. `volumeBytes` splits the output
    /// into `<archivePath>.001`, `.002`, … `onBytes` receives source-byte
    /// deltas as compression advances; `shouldCancel` is polled and a true
    /// answer aborts with `CancellationError` (partial output removed).
    static func create(sources: [(absPath: String, entryName: String)], to archivePath: String,
                       level: Int, password: String?, encryptHeaders: Bool = true,
                       volumeBytes: Int64? = nil,
                       onBytes: ((Int64) -> Void)? = nil,
                       shouldCancel: (() -> Bool)? = nil) throws {
        var items: [(disk: String, archive: String)] = []
        for src in sources { collect(absPath: src.absPath, entryName: src.entryName, into: &items) }
        guard !items.isEmpty else { throw Failure(message: "Nothing to pack") }

        // Turn the engine's cumulative counter into the deltas the progress
        // bar consumes.
        var reported: Int64 = 0
        let lock = NSLock()
        let box = CallbackBox(progress: { completed, _ in
            lock.lock()
            let delta = completed - reported
            if delta > 0 { reported = completed }
            lock.unlock()
            if delta > 0 { onBytes?(delta) }
        }, isCancelled: shouldCancel)

        let pw = (password?.isEmpty == false) ? password : nil
        var message: UnsafeMutablePointer<CChar>? = nil
        let cStrings = items.flatMap { [strdup($0.disk), strdup($0.archive)] }
        defer { cStrings.forEach { free($0) } }
        var cItems: [sz_source] = []
        cItems.reserveCapacity(items.count)
        for i in 0..<items.count {
            cItems.append(sz_source(disk_path: UnsafePointer(cStrings[2 * i]),
                                    archive_path: UnsafePointer(cStrings[2 * i + 1])))
        }
        let status = withExtendedLifetime(box) { () -> sz_status in
            let ctx = Unmanaged.passUnretained(box).toOpaque()
            return cItems.withUnsafeBufferPointer { buf in
                sz_create(archivePath, buf.baseAddress, UInt32(buf.count),
                          pw, (pw != nil && encryptHeaders) ? 1 : 0,
                          Int32(max(0, min(9, level))), UInt64(max(0, volumeBytes ?? 0)),
                          CallbackBox.progressThunk, CallbackBox.cancelThunk, ctx, &message)
            }
        }
        try check(status, archivePath: archivePath, message: message)
    }

    /// Flattens a source tree into (disk path, archive path) pairs. Directory
    /// entries are kept so empty folders survive; symlinks are stored as links.
    private static func collect(absPath: String, entryName: String,
                                into items: inout [(disk: String, archive: String)]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: absPath, isDirectory: &isDir) else { return }
        items.append((absPath, entryName))
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: absPath)) != nil
        guard isDir.boolValue, !isSymlink else { return }
        for kid in (try? fm.contentsOfDirectory(atPath: absPath))?.sorted() ?? [] {
            collect(absPath: absPath + "/" + kid, entryName: entryName + "/" + kid, into: &items)
        }
    }

    // MARK: - Plumbing

    private static func open(archivePath: String, password: String?) throws -> OpaquePointer {
        let volumes = SplitVolumes.set(forFirstVolume: archivePath)
        var handle: OpaquePointer? = nil
        let cVolumes = volumes.map { strdup($0) }
        defer { cVolumes.forEach { free($0) } }
        let status = cVolumes.map { UnsafePointer($0) }.withUnsafeBufferPointer { buf in
            sz_open(buf.baseAddress, Int32(buf.count), password, &handle)
        }
        try check(status, archivePath: archivePath, message: nil)
        guard let h = handle else { throw ArchiveOpenError(archivePath: archivePath) }
        return h
    }

    private static func check(_ status: sz_status, archivePath: String,
                              message: UnsafeMutablePointer<CChar>?) throws {
        let text = message.map { String(cString: $0) }
        if let m = message { sz_free_string(m) }
        switch status {
        case SZR_OK: return
        case SZR_ERR_ENCRYPTED: throw ArchiveEncryptedError(archivePath: archivePath)
        case SZR_ERR_OPEN: throw ArchiveOpenError(archivePath: archivePath)
        case SZR_ERR_CANCELLED: throw CancellationError()
        case SZR_ERR_IO: throw Failure(message: text ?? "Can't read \(archivePath)")
        default: throw Failure(message: text ?? "7-Zip engine failed (\(status.rawValue))")
        }
    }

    /// Carries the Swift closures across the C boundary.
    private final class CallbackBox {
        let progress: ((Int64, Int64) -> Void)?
        let isCancelled: (() -> Bool)?
        init(progress: ((Int64, Int64) -> Void)?, isCancelled: (() -> Bool)?) {
            self.progress = progress
            self.isCancelled = isCancelled
        }
        static let progressThunk: sz_progress_fn = { ctx, completed, total in
            guard let ctx = ctx else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            box.progress?(Int64(completed), Int64(total))
        }
        static let cancelThunk: sz_cancel_fn = { ctx in
            guard let ctx = ctx else { return 0 }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            return box.isCancelled?() == true ? 1 : 0
        }
    }
}
