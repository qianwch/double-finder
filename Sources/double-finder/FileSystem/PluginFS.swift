import Foundation
import DoubleFinderPluginKit

/// `VirtualFS` over a plugin drive (`PluginFileSystemSession`). Stateless like
/// the other remote adapters — the session object lives in the
/// `PluginDriveSession` registered with `RemoteSessionStore`.
///
/// Direction of `copy(from:to:)` is inferred from `from` exactly like S3FS /
/// AndroidFS: a path that exists on disk is a local source (upload), anything
/// else is a drive path (download). Directories are walked here, so a plugin
/// only ever moves single files.
struct PluginFS: VirtualFS {
    let drive: PluginDriveSession
    let currentPath: String

    private var session: PluginFileSystemSession { drive.session }

    // MARK: Path helpers (POSIX-style virtual paths rooted at "/")

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" || dir.isEmpty ? "/" + name : dir + "/" + name
    }

    static func parent(of path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    static func leaf(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: VirtualFS

    func listDirectory(_ path: String) async throws -> [FileItem] {
        try await session.list(path).map { Self.item(for: $0, in: path) }
    }

    static func item(for e: PluginFileEntry, in dir: String) -> FileItem {
        FileItem(id: UUID(), name: e.name, path: join(dir, e.name), isDirectory: e.isDirectory,
                 isArchive: !e.isDirectory && FileItem.isArchiveFileName(e.name),
                 size: e.size, modified: e.modified, isHidden: e.isHidden,
                 isSymlink: e.isSymlink, permissions: e.permissions)
    }

    func copy(from: String, to: String) async throws {
        if FileManager.default.fileExists(atPath: from) {
            try await Self.uploadTree(session, localPath: from, toDirectory: to, progress: { _ in })
        } else {
            let isDir = try await Self.isDirectory(session, path: from)
            try await Self.downloadTree(session, path: from, isDirectory: isDir,
                                        toLocalDirectory: to, progress: { _ in })
        }
    }

    func move(from: String, to: String) async throws {
        if FileManager.default.fileExists(atPath: from) {
            try await copy(from: from, to: to)
            try FileManager.default.removeItem(atPath: from)
            return
        }
        try await Self.transferWithin(session, path: from, isDirectory: Self.isDirectory(session, path: from),
                                      toDirectory: to, move: true, progress: { _ in })
    }

    func delete(_ path: String) async throws { try await session.delete(path) }

    func createDirectory(_ path: String) async throws { try await session.createDirectory(path) }

    func rename(at path: String, to newName: String) async throws {
        try await session.rename(path, to: newName)
    }

    /// Space-key folder size: walk the tree (one list call per folder).
    func directorySize(_ path: String) async -> Int64 {
        var total: Int64 = 0
        var queue = [path]
        while let dir = queue.popLast() {
            guard let entries = try? await session.list(dir) else { continue }
            for e in entries {
                if e.isDirectory { queue.append(Self.join(dir, e.name)) } else { total += e.size }
            }
        }
        return total
    }

    // MARK: Tree transfer helpers (shared with PluginTransferProvider)

    /// Whether `path` is a directory, by looking it up in its parent's listing.
    /// Unknown entries count as files (the download then fails with the
    /// plugin's own error, which is the more useful message).
    static func isDirectory(_ s: PluginFileSystemSession, path: String) async throws -> Bool {
        guard path != "/" else { return true }
        let entries = try await s.list(parent(of: path))
        return entries.first { $0.name == leaf(path) }?.isDirectory ?? false
    }

    /// Fetches a file, or a whole directory tree, into the local folder `dir`
    /// (created if needed) under `name` (default: the drive-side leaf).
    /// `progress` receives byte DELTAS across the whole tree.
    static func downloadTree(_ s: PluginFileSystemSession, path: String, isDirectory: Bool,
                             toLocalDirectory dir: String, as name: String? = nil,
                             progress: @escaping @Sendable (Int64) -> Void,
                             isCancelled: (() -> Bool)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let target = (dir as NSString).appendingPathComponent(name ?? leaf(path))
        if isDirectory {
            try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
            for e in try await s.list(path) {
                if isCancelled?() == true { throw CancellationError() }
                try await downloadTree(s, path: join(path, e.name), isDirectory: e.isDirectory,
                                       toLocalDirectory: target, progress: progress, isCancelled: isCancelled)
            }
            return
        }
        if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
        let reporter = DeltaReporter(progress)
        try await s.download(path, to: URL(fileURLWithPath: target), progress: { reporter.report($0) })
    }

    /// Stores a local file, or a whole directory tree, into the drive folder
    /// `dir` under `name` (default: the local leaf).
    static func uploadTree(_ s: PluginFileSystemSession, localPath: String, toDirectory dir: String,
                           as name: String? = nil,
                           progress: @escaping @Sendable (Int64) -> Void,
                           isCancelled: (() -> Bool)? = nil) async throws {
        let fm = FileManager.default
        let target = join(dir, name ?? (localPath as NSString).lastPathComponent)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: localPath, isDirectory: &isDir) else {
            throw FSUnsupportedError(message: "No such file: \(localPath)")
        }
        if isDir.boolValue {
            try await s.createDirectory(target)
            let children = (try? fm.contentsOfDirectory(atPath: localPath)) ?? []
            for child in children.sorted() {
                if isCancelled?() == true { throw CancellationError() }
                try await uploadTree(s, localPath: (localPath as NSString).appendingPathComponent(child),
                                     toDirectory: target, progress: progress, isCancelled: isCancelled)
            }
            return
        }
        let reporter = DeltaReporter(progress)
        try await s.upload(URL(fileURLWithPath: localPath), to: target, progress: { reporter.report($0) })
    }

    /// Drive-internal copy/move into `dir`. Uses the plugin's server-side
    /// operation when it has one, otherwise relays through a temp folder
    /// (download → upload, then delete the source for a move).
    static func transferWithin(_ s: PluginFileSystemSession, path: String, isDirectory: Bool,
                               toDirectory dir: String, as name: String? = nil, move: Bool,
                               progress: @escaping @Sendable (Int64) -> Void,
                               isCancelled: (() -> Bool)? = nil) async throws {
        let newName = name ?? leaf(path)
        do {
            if move { try await s.move(path, toDirectory: dir) } else { try await s.copy(path, toDirectory: dir) }
            if newName != leaf(path) { try await s.rename(join(dir, leaf(path)), to: newName) }
            return
        } catch PluginError.unsupported {
            // fall through to the relay
        }
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("DoubleFinder-PluginRelay/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try await downloadTree(s, path: path, isDirectory: isDirectory, toLocalDirectory: tmp,
                               progress: progress, isCancelled: isCancelled)
        try await uploadTree(s, localPath: (tmp as NSString).appendingPathComponent(leaf(path)),
                             toDirectory: dir, as: newName, progress: progress, isCancelled: isCancelled)
        if move { try await s.delete(path) }
    }

    /// Turns a plugin's cumulative per-file byte count into deltas, so several
    /// files can feed one operation-wide counter.
    private final class DeltaReporter: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Int64 = 0
        private let sink: @Sendable (Int64) -> Void
        init(_ sink: @escaping @Sendable (Int64) -> Void) { self.sink = sink }
        func report(_ cumulative: Int64) {
            lock.lock()
            let delta = cumulative - last
            last = cumulative
            lock.unlock()
            if delta != 0 { sink(delta) }
        }
    }
}
