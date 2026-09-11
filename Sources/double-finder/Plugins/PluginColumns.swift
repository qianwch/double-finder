import Foundation
import DoubleFinderPluginKit

/// The content-plugin columns currently active, as the file list sees them.
/// `nonisolated` + lock-guarded because `FileColumnLayout.optionalColumns` is
/// read while drawing and by pure-logic code with no actor context.
/// `PluginManager` is the only writer.
enum PluginColumnRegistry {
    struct Column {
        let id: String          // "plugin.<pluginID>.<columnID>"
        let title: String
        let width: CGFloat
        let provider: ContentPlugin
        let columnID: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var list: [Column] = []

    static func replace(with providers: [(pluginID: String, plugin: ContentPlugin)]) {
        var cols: [Column] = []
        for (pid, p) in providers {
            for c in p.columns {
                cols.append(Column(id: "plugin.\(pid).\(c.id)", title: c.title,
                                   width: CGFloat(c.defaultWidth), provider: p, columnID: c.id))
            }
        }
        lock.lock(); list = cols; lock.unlock()
        PluginColumnValues.shared.invalidateAll()
    }

    static var columns: [Column] { lock.lock(); defer { lock.unlock() }; return list }

    static func column(id: String) -> Column? { columns.first { $0.id == id } }

    static func isPluginColumn(_ id: String) -> Bool { id.hasPrefix("plugin.") }
}

/// Cache + background fetcher for plugin column values, mirroring
/// `FileIconProvider`: the draw loop only reads cache hits, a miss is queued
/// once, and `onReady` asks the list to repaint when a batch has landed.
/// Keyed by (column, path, size, mtime) so an edited file refreshes.
final class PluginColumnValues: @unchecked Sendable {
    static let shared = PluginColumnValues()

    /// Posted on the main thread after new values arrived (coalesced); both
    /// panels' lists observe it.
    static let didUpdate = Notification.Name("PluginColumnValuesDidUpdate")

    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "net.qian.double-finder.plugin-columns", qos: .utility)
    private var flushScheduled = false

    private func key(_ columnID: String, _ item: FileItem) -> String {
        "\(columnID)|\(item.path)|\(item.size)|\(item.modified.timeIntervalSince1970)"
    }

    /// Cached text, or "" while a fetch is in flight (queued here on first miss).
    func text(columnID: String, item: FileItem) -> String {
        guard let col = PluginColumnRegistry.column(id: columnID) else { return "" }
        let k = key(columnID, item)
        lock.lock()
        if let v = cache[k] { lock.unlock(); return v }
        let alreadyQueued = pending.contains(k)
        if !alreadyQueued { pending.insert(k) }
        lock.unlock()
        if alreadyQueued { return "" }
        let path = item.path, isDir = item.isDirectory
        queue.async { [weak self] in
            guard let self else { return }
            // Remote / in-archive rows have virtual paths: nothing to hand a plugin.
            let value = FileManager.default.fileExists(atPath: path)
                ? (col.provider.value(column: col.columnID, path: path, isDirectory: isDir) ?? "—")
                : ""
            self.lock.lock()
            self.cache[k] = value
            self.pending.remove(k)
            if self.cache.count > 20_000 { self.cache.removeAll() }   // crude bound; refetch is cheap
            let schedule = !self.flushScheduled
            self.flushScheduled = true
            self.lock.unlock()
            if schedule {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.flushScheduled = false; self.lock.unlock()
                    NotificationCenter.default.post(name: Self.didUpdate, object: nil)
                }
            }
        }
        return ""
    }

    func invalidateAll() {
        lock.lock(); cache.removeAll(); pending.removeAll(); lock.unlock()
    }
}
