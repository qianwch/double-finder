import Foundation
import DoubleFinderPluginKit

/// Thread-safe, `nonisolated` view of the packer plugins currently active —
/// consulted from `FileItem.isArchiveFileName` / `PanelState.archiveRoot(in:)`,
/// which run on background threads (search walks, transfer providers) where the
/// `@MainActor` `PluginManager` is out of reach. `PluginManager` is the only
/// writer (on activate / deactivate).
enum ArchivePluginRegistry {
    private static let lock = NSLock()
    /// Longest extension first, so "tar.lz" beats "lz".
    nonisolated(unsafe) private static var table: [(ext: String, packer: PackerPlugin)] = []

    static func replace(with packers: [PackerPlugin]) {
        var t: [(String, PackerPlugin)] = []
        for p in packers {
            for e in p.fileExtensions {
                let clean = e.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if !clean.isEmpty { t.append((clean, p)) }
            }
        }
        t.sort { $0.0.count > $1.0.count }
        lock.lock(); table = t; lock.unlock()
        // A session belongs to the plugin that opened it: never outlive it.
        PluginArchiveSessionCache.shared.removeAll()
    }

    /// The packer claiming `name` by suffix, nil when none.
    static func packer(forFileName name: String) -> PackerPlugin? {
        let lower = name.lowercased()
        lock.lock(); defer { lock.unlock() }
        return table.first { lower.hasSuffix("." + $0.ext) }?.packer
    }

    static var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return table.isEmpty }
}

/// Open plugin archives, kept across the several `PanelState.fs` accesses one
/// user action makes (list, then copy, then list again…): each would otherwise
/// re-`open` and re-parse the directory. Keyed by path + size + mtime, so an
/// archive rewritten on disk is reopened; small LRU; calls into a session are
/// serialized per archive (the plugin contract is one call at a time).
final class PluginArchiveSessionCache: @unchecked Sendable {
    static let shared = PluginArchiveSessionCache()

    private final class Entry {
        let key: String
        let session: PluginArchiveSession
        let entries: [PluginArchiveEntry]
        let lock = NSLock()
        init(key: String, session: PluginArchiveSession, entries: [PluginArchiveEntry]) {
            self.key = key; self.session = session; self.entries = entries
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]     // archivePath → entry
    private var order: [String] = []               // LRU, most recent last
    private let capacity = 4
    /// Diagnostics / tests: how many real `open` calls happened.
    private(set) var opens = 0

    private static func key(for path: String) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(mtime)"
    }

    /// Runs `body` with the (cached or freshly opened) session and its entry
    /// list, holding that archive's lock for the duration.
    func withSession<T>(archivePath: String, packer: PackerPlugin,
                        _ body: (PluginArchiveSession, [PluginArchiveEntry]) throws -> T) throws -> T {
        let key = Self.key(for: archivePath)
        lock.lock()
        var entry = entries[archivePath]
        if let e = entry, e.key != key {          // rewritten on disk → drop
            entries[archivePath] = nil
            order.removeAll { $0 == archivePath }
            entry = nil
        }
        lock.unlock()
        if entry == nil {
            let session = try packer.open(URL(fileURLWithPath: archivePath))
            let list: [PluginArchiveEntry]
            do { list = try session.entries() } catch { session.close(); throw error }
            let fresh = Entry(key: key, session: session, entries: list)
            lock.lock()
            opens += 1
            entries[archivePath] = fresh
            order.removeAll { $0 == archivePath }
            order.append(archivePath)
            var evicted: [Entry] = []
            while order.count > capacity, let old = order.first {
                order.removeFirst()
                if let e = entries.removeValue(forKey: old) { evicted.append(e) }
            }
            lock.unlock()
            evicted.forEach { $0.session.close() }
            entry = fresh
        } else {
            lock.lock()
            order.removeAll { $0 == archivePath }
            order.append(archivePath)
            lock.unlock()
        }
        let e = entry!
        e.lock.lock(); defer { e.lock.unlock() }
        return try body(e.session, e.entries)
    }

    /// Forgets one archive (it is about to be rewritten).
    func remove(archivePath: String) {
        lock.lock()
        let e = entries.removeValue(forKey: archivePath)
        order.removeAll { $0 == archivePath }
        lock.unlock()
        e?.session.close()
    }

    /// Drops every open session (packer plugins changed, or tests).
    func removeAll() {
        lock.lock()
        let all = Array(entries.values)
        entries.removeAll(); order.removeAll()
        lock.unlock()
        all.forEach { $0.session.close() }
    }
}

/// `VirtualFS` over a `PackerPlugin` archive: the plugin-format twin of `ZipFS`.
/// Read-only. Entry listing is fetched once per FS instance (an instance is
/// short-lived — `PanelState.fs` rebuilds it per access) and directories are
/// inferred from nesting exactly like `ZipFS.buildItems`.
struct PluginArchiveFS: VirtualFS {
    let archivePath: String
    let packer: PackerPlugin

    var currentPath: String { archivePath }

    /// The archive-internal path for a virtual path ("" for the root).
    func internalPath(_ path: String) -> String {
        guard path.hasPrefix(archivePath + "/") else { return "" }
        return String(path.dropFirst(archivePath.count + 1))
    }

    /// Entries with a usable relative path: no leading "/", no ".." component
    /// (an escaping entry must neither list nor extract), no empty path.
    static func sanitized(_ entries: [PluginArchiveEntry]) -> [PluginArchiveEntry] {
        entries.compactMap { e in
            var clean = e.path.trimmingCharacters(in: .whitespaces)
            while clean.hasSuffix("/") { clean.removeLast() }
            guard !clean.isEmpty, !clean.hasPrefix("/"),
                  !clean.components(separatedBy: "/").contains(where: { $0 == ".." || $0.isEmpty }) else { return nil }
            var copy = e
            copy.path = clean
            return copy
        }
    }

    static func libArchiveEntries(_ entries: [PluginArchiveEntry]) -> [LibArchive.Entry] {
        sanitized(entries).map { LibArchive.Entry(path: $0.path, size: $0.size, mtime: $0.modified, isDir: $0.isDirectory) }
    }

    func listDirectory(_ path: String) async throws -> [FileItem] {
        let prefix = internalPath(path)
        let root = archivePath
        let packer = self.packer
        return try await Task.detached {
            try PluginArchiveSessionCache.shared.withSession(archivePath: root, packer: packer) { _, list in
                ZipFS.buildItems(entries: Self.libArchiveEntries(list), archivePath: root, internalPrefix: prefix)
            }
        }.value
    }

    /// Copy-out: extracts the entry (file, or folder + subtree) flat into `to`
    /// under its own name — same contract as `ZipFS.copy`.
    func copy(from: String, to: String) async throws {
        let entry = internalPath(from)
        guard !entry.isEmpty else { throw FSUnsupportedError(message: "Cannot copy the archive root") }
        let root = archivePath
        let packer = self.packer
        try await Task.detached(priority: .userInitiated) {
            try PluginArchiveSessionCache.shared.withSession(archivePath: root, packer: packer) { session, list in
                try Self.extract(session: session, entries: list, matching: entry,
                                 to: to, stripPrefix: (entry as NSString).deletingLastPathComponent,
                                 isCancelled: { Task.isCancelled })
            }
        }.value
    }

    /// Extracts every entry equal to `wanted` or below `wanted/` into `dest`,
    /// keeping the tree below `stripPrefix` ("" = whole archive).
    static func extract(session: PluginArchiveSession, entries: [PluginArchiveEntry], matching wanted: String?,
                        to dest: String, stripPrefix: String, isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        for e in sanitized(entries) {
            if isCancelled() { throw CancellationError() }
            let clean = e.path
            if let wanted, clean != wanted, !clean.hasPrefix(wanted + "/") { continue }
            var rel = clean
            if !stripPrefix.isEmpty, rel.hasPrefix(stripPrefix + "/") { rel = String(rel.dropFirst(stripPrefix.count + 1)) }
            let target = (dest as NSString).appendingPathComponent(rel)
            if e.isDirectory {
                try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
            try session.extract(clean, to: URL(fileURLWithPath: target))
            if let mt = e.modified { try? fm.setAttributes([.modificationDate: mt], ofItemAtPath: target) }
        }
    }

    /// ⌥F6: everything into `dest` (tree preserved).
    static func extractAll(archivePath: String, packer: PackerPlugin, to dest: String,
                           isCancelled: () -> Bool = { false }) throws {
        try PluginArchiveSessionCache.shared.withSession(archivePath: archivePath, packer: packer) { session, list in
            try extract(session: session, entries: list, matching: nil,
                        to: dest, stripPrefix: "", isCancelled: isCancelled)
        }
    }

    /// ⌥F5 through a packer plugin: expands folders to files (entry path =
    /// relative to `baseDir` when given, else to each source's parent, so a
    /// dropped folder keeps its own name as the top level), then hands the flat
    /// list to `PackerPlugin.create`. Any open session on that path is dropped first.
    static func createArchive(sources: [String], to archivePath: String, packer: PackerPlugin,
                              baseDir: String?,
                              progress: @escaping @Sendable (Int64) -> Void,
                              shouldCancel: @escaping @Sendable () -> Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var flat: [PluginArchiveSource] = []
            for src in sources {
                let root = baseDir ?? (src as NSString).deletingLastPathComponent
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src, isDirectory: &isDir) else { continue }
                if !isDir.boolValue {
                    flat.append(PluginArchiveSource(localPath: src, entryPath: LocalFS.relativePath(src, base: root)))
                    continue
                }
                guard let en = fm.enumerator(atPath: src) else { continue }
                while let rel = en.nextObject() as? String {
                    if shouldCancel() { throw CancellationError() }
                    let full = (src as NSString).appendingPathComponent(rel)
                    var childIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &childIsDir), !childIsDir.boolValue else { continue }
                    flat.append(PluginArchiveSource(localPath: full, entryPath: LocalFS.relativePath(full, base: root)))
                }
            }
            PluginArchiveSessionCache.shared.remove(archivePath: archivePath)
            try packer.create(URL(fileURLWithPath: archivePath), sources: flat,
                              progress: progress, isCancelled: shouldCancel)
        }.value
    }

    func directorySize(_ path: String) async -> Int64 {
        let prefix = internalPath(path)
        let root = archivePath
        let packer = self.packer
        return (try? await Task.detached {
            try PluginArchiveSessionCache.shared.withSession(archivePath: root, packer: packer) { _, list in
                Self.sanitized(list)
                    .filter { !$0.isDirectory && (prefix.isEmpty || $0.path.hasPrefix(prefix + "/")) }
                    .reduce(Int64(0)) { $0 + $1.size }
            }
        }.value) ?? 0
    }

    func move(from: String, to: String) async throws {
        throw FSUnsupportedError(message: "This archive format is read-only")
    }
    func delete(_ path: String) async throws {
        throw FSUnsupportedError(message: "This archive format is read-only")
    }
    func createDirectory(_ path: String) async throws {
        throw FSUnsupportedError(message: "This archive format is read-only")
    }
    func rename(at path: String, to newName: String) async throws {
        throw FSUnsupportedError(message: "This archive format is read-only")
    }
}
