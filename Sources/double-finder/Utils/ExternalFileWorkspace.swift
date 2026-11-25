import Foundation

/// Owns only the external-open copies created by this app run. Viewer caches
/// and other runs' directories have independent lifetimes.
@MainActor
final class ExternalFileWorkspace {
    let rootDirectory: URL
    private var copies: [FileReference: URL] = [:]
    private var loads: [FileReference: Task<URL, Error>] = [:]
    private var isClosed = false

    var hasActiveLoads: Bool { !loads.isEmpty }

    init(parentDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DoubleFinder-Open", isDirectory: true)) {
        rootDirectory = parentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func existingCopy(for reference: FileReference) -> URL? {
        guard let url = copies[reference], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func materialize(_ request: FileContentRequest, using fs: VirtualFS) async throws -> URL {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        if let url = existingCopy(for: request.reference) { return url }
        if let load = loads[request.reference] {
            let url = try await load.value
            try Task.checkCancellation()
            return url
        }
        let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let load = Task {
            try await FileContentService(rootDirectory: directory).materialize(request, using: fs, mode: .temporary)
        }
        loads[request.reference] = load
        defer { loads.removeValue(forKey: request.reference) }
        do {
            let url = try await withTaskCancellationHandler {
                try await load.value
            } onCancel: { load.cancel() }
            try Task.checkCancellation()
            copies[request.reference] = url
            return url
        } catch {
            await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
            throw error
        }
    }

    /// The caller resolves edits and waits for loads before committing to exit.
    func cleanup() async throws {
        guard !hasActiveLoads else { throw CocoaError(.fileWriteFileExists) }
        isClosed = true
        let root = rootDirectory
        // Cleanup is the committed exit phase, not a transaction: removeItem
        // can partially succeed before throwing. Never reopen this workspace.
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }.value
        copies.removeAll()
    }
}
