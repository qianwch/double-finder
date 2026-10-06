import Foundation

/// Only protects a cancellation flag; filesystem/session values are never made
/// Sendable through this object. The commit boundary reads it once before disk IO.
final class ContentPublicationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

/// A recovery failure can leave a receipt that the OS refuses to remove.
/// Reject it in this process until a new successful publication replaces it.
/// Key normalization happens on the disk worker, before taking the lock.
private final class ContentReceiptInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var invalid: Set<String> = []
    private func key(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }
    func contains(_ url: URL) -> Bool {
        let key = key(url); lock.lock(); defer { lock.unlock() }; return invalid.contains(key)
    }
    func insert(_ url: URL) {
        let key = key(url); lock.lock(); defer { lock.unlock() }; invalid.insert(key)
    }
    func remove(_ url: URL) {
        let key = key(url); lock.lock(); defer { lock.unlock() }; invalid.remove(key)
    }
}

/// FileManager is not declared Sendable on the deployment SDK. This immutable
/// handle is accessed exclusively by the shared publication queue; no backend
/// FS or session is wrapped here. Injected managers follow that same contract.
private final class QueuedPublicationFileManager: @unchecked Sendable {
    let manager: FileManager
    init(_ manager: FileManager) { self.manager = manager }
}

/// Process-local coordination of cache reads and disk commits across service
/// instances. Exports and owned-stage cleanup never run on the shared queue.
struct MaterializedContentStore: Sendable {
    private static let invalidated = ContentReceiptInvalidation()
    private static let queue = DispatchQueue(label: "net.qian.double-finder.content-publication", qos: .userInitiated)

    private let publicationIO: QueuedPublicationFileManager

    init(fileManager: FileManager = .default) { self.publicationIO = QueuedPublicationFileManager(fileManager) }

    private struct Receipt: Codable {
        let version: Int
        let slug: String
        let expectedSize: Int64
    }

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func fresh(output: URL, receipt: URL, slug: String, size: Int64) -> Bool {
        guard !invalidated.contains(receipt),
              let bytes = try? Data(contentsOf: receipt),
              let record = try? JSONDecoder().decode(Receipt.self, from: bytes),
              record.version == 1, record.slug == slug, record.expectedSize == size else { return false }
        return MaterializedCache.isFresh(localPath: output.path, expectedSize: size)
    }

    func isFresh(output: URL, receipt: URL, slug: String, size: Int64) async throws -> Bool {
        try await Self.onQueue { Self.fresh(output: output, receipt: receipt, slug: slug, size: size) }
    }

    func prepare(stage: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: stage.appendingPathComponent("content"), withIntermediateDirectories: true)
        }.value
    }

    func cleanup(stage: URL) async {
        await Task.detached(priority: .utility) {
            // Only the caller's UUID stage is owned here. Failure to clean it
            // must not hide an export/commit error or invalidate published data.
            try? FileManager.default.removeItem(at: stage)
        }.value
    }

    func publish(stage: URL, directory: URL, output: URL, receipt: URL?, slug: String, size: Int64,
                 cancellation: ContentPublicationCancellation) async throws {
        let publicationIO = self.publicationIO
        try await Self.onQueue {
            let fm = publicationIO.manager
            try cancellation.check()
            // A peer can finish the same cache version during our export. Reuse
            // that completed result; duplicate export does not replace a reader's URL.
            if let receipt, Self.fresh(output: output, receipt: receipt, slug: slug, size: size) { return }
            let payload = stage.appendingPathComponent("content")
            let stagedReceipt = stage.appendingPathComponent("receipt.json")
            if receipt != nil {
                try JSONEncoder().encode(Receipt(version: 1, slug: slug, expectedSize: size))
                    .write(to: stagedReceipt, options: .atomic)
            }
            let backup = stage.appendingPathComponent("backup")
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            let oldContent = backup.appendingPathComponent("content")
            let oldReceipt = backup.appendingPathComponent("receipt.json")
            var backedContent = false, backedReceipt = false
            var installedContent = false
            do {
                if (try? fm.attributesOfItem(atPath: directory.path)) != nil {
                    try fm.moveItem(at: directory, to: oldContent); backedContent = true
                }
                // An unexpected receipt directory belongs to nobody we know:
                // leave it in place. Receipt installation will fail and roll back.
                if let receipt,
                   (try? fm.attributesOfItem(atPath: receipt.path)[.type] as? FileAttributeType) == .typeRegular {
                    try fm.moveItem(at: receipt, to: oldReceipt); backedReceipt = true
                }
                try fm.moveItem(at: payload, to: directory); installedContent = true
                if let receipt {
                    try fm.moveItem(at: stagedReceipt, to: receipt)
                }
            } catch {
                let original = error
                var recoveryErrors: [String] = []
                func recover(_ action: () throws -> Void) {
                    do { try action() } catch { recoveryErrors.append(error.localizedDescription) }
                }
                if installedContent { recover { try fm.removeItem(at: directory) } }
                if backedContent { recover { try fm.moveItem(at: oldContent, to: directory) } }
                if backedReceipt, let receipt { recover { try fm.moveItem(at: oldReceipt, to: receipt) } }
                if !recoveryErrors.isEmpty {
                    // A backup may be the only surviving original. Never clean
                    // the stage on this error, and never leave a valid receipt.
                    if let receipt {
                        Self.invalidated.insert(receipt)
                        if (try? fm.attributesOfItem(atPath: receipt.path)[.type] as? FileAttributeType) == .typeRegular {
                            recover { try fm.removeItem(at: receipt) }
                        }
                    }
                    throw FileContentError.publicationRecoveryFailed(original.localizedDescription,
                                                                      recoveryErrors.joined(separator: "; ") +
                                                                        ". Recovery files were kept at " + stage.path)
                }
                throw original
            }
            if let receipt { Self.invalidated.remove(receipt) }
            // No cancellation check inside this bounded transaction: once it
            // starts we finish installation or recovery before releasing readers.
        }
    }
}
