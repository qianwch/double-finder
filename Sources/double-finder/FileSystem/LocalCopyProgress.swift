import Foundation
import Darwin

/// copyfile's callbacks run synchronously on the copying worker. Only byte
/// deltas cross back to FileOperation's locked counter; UI never probes disk.
enum LocalCopyProgress {
    private final class Context {
        let report: @Sendable (Int64) -> Void
        let shouldCancel: @Sendable () -> Bool
        var fileBytes: Int64 = 0
        var reported: Int64 = 0
        var failure: Int32?

        init(report: @escaping @Sendable (Int64) -> Void,
             shouldCancel: @escaping @Sendable () -> Bool) {
            self.report = report
            self.shouldCancel = shouldCancel
        }

        func advance(to bytes: Int64) {
            let value = max(reported, bytes)
            if value > reported { report(value - reported); reported = value }
        }
    }

    private static let callback: copyfile_callback_t = { what, stage, state, source, _, pointer in
        guard let pointer else { return COPYFILE_QUIT }
        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
        if context.shouldCancel() { return COPYFILE_QUIT }
        if stage == COPYFILE_ERR {
            // CONTINUE on an error can retry indefinitely or silently skip a file.
            // A nested xattr error can be re-reported as ECANCELED by copyfile;
            // keep the original cause rather than replacing it on outer unwind.
            if context.failure == nil { context.failure = errno == 0 ? EIO : errno }
            return COPYFILE_QUIT
        }
        if what == COPYFILE_RECURSE_FILE {
            if stage == COPYFILE_START {
                context.reported = 0
                var info = stat()
                context.fileBytes = source != nil && lstat(source!, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                    ? Int64(info.st_size) : 0
            } else if stage == COPYFILE_FINISH {
                // Clones have no data callbacks. Credit logical bytes on success,
                // excluding directories/symlinks and avoiding double counting.
                context.advance(to: context.fileBytes)
            }
        } else if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                context.advance(to: Int64(copied))
            }
        }
        return COPYFILE_CONTINUE
    }

    /// Synchronous worker entry point. The caller must dispatch off MainActor.
    static func copy(from source: String, to target: String, tryClone: Bool = true,
                     report: @escaping @Sendable (Int64) -> Void,
                     shouldCancel: @escaping @Sendable () -> Bool) throws {
        if shouldCancel() { throw CancellationError() }
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = Context(report: report, shouldCancel: shouldCancel)
        let pointer = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<Context>.fromOpaque(pointer).release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), pointer)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let flags = UInt32(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | (tryClone ? COPYFILE_CLONE : 0))
        let result = copyfile(source, target, state, flags)
        let errorCode = context.failure ?? errno
        if result != 0 {
            if shouldCancel() { throw CancellationError() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode == 0 ? EIO : errorCode),
                          userInfo: [NSFilePathErrorKey: source])
        }
    }

    /// One source-only sizing pass; count data forks, matching copy callbacks.
    /// Never follows links, and checks cancellation between directory entries.
    static func totalSize(_ paths: [String], shouldCancel: @Sendable () -> Bool) -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        for path in paths {
            if shouldCancel() { break }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFREG { total += Int64(info.st_size) }
            guard info.st_mode & S_IFMT == S_IFDIR,
                  let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                               includingPropertiesForKeys: Array(keys)) else { continue }
            while !shouldCancel(), let entry = entries.nextObject() as? URL {
                guard let values = try? entry.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
