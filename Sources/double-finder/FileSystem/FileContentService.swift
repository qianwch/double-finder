import Foundation

/// Captured content identity and version; independent of panel/display state.
struct FileContentRequest: Sendable {
    let reference: FileReference
    let size: Int64
    let modified: Date
}

enum FileContentMode: Sendable {
    case viewCache
    case temporary
}

enum FileContentError: LocalizedError, Equatable {
    case missingOutput
    case publicationRecoveryFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingOutput:
            return "The file could not be loaded because the download produced no output."
        case .publicationRecoveryFailed(let original, let recovery):
            return "Content publication failed: \(original). Restoring the previous copy also failed: \(recovery)"
        }
    }
}

/// Materializes content from a captured filesystem. Connection lookup, UI,
/// editing write-back and task ownership stay with the caller. Concurrent loads
/// export independently; only completed results are published/reused.
struct FileContentService {
    private let rootDirectory: URL
    private let store: MaterializedContentStore

    init(rootDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DoubleFinder-View", isDirectory: true), fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.store = MaterializedContentStore(fileManager: fileManager)
    }

    func materialize(_ request: FileContentRequest, using fs: VirtualFS,
                     mode: FileContentMode,
                     progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        _ = try FileContentTransfer.localPath(rootDirectory)
        // Search/branch row titles may contain a relative display path. Only the
        // backend path determines the exported leaf.
        let name = (request.reference.path as NSString).lastPathComponent
        try FileContentTransfer.validateLeaf(name)
        let slug: String
        switch mode {
        case .viewCache:
            slug = MaterializedCache.slug(reference: request.reference,
                                          size: request.size, modified: request.modified)
        case .temporary:
            slug = MaterializedCache.temporarySlug(reference: request.reference)
        }
        let directory = rootDirectory.appendingPathComponent(slug, isDirectory: true)
        let output = directory.appendingPathComponent(name)
        let receipt: URL? = {
            if case .viewCache = mode { return rootDirectory.appendingPathComponent(slug + ".complete") }
            return nil
        }()
        if let receipt {
            let fresh = try await store.isFresh(output: output, receipt: receipt, slug: slug, size: request.size)
            try Task.checkCancellation()
            if fresh { return output }
        }
        try Task.checkCancellation()
        let stage = rootDirectory.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        let stagingDirectory = stage.appendingPathComponent("content", isDirectory: true)
        let stagingOutput = stagingDirectory.appendingPathComponent(name)
        do {
            try await store.prepare(stage: stage)
            try Task.checkCancellation()
            try await fs.exportItem(at: request.reference.path, toLocalDirectory: stagingDirectory, progress: progress)
            try Task.checkCancellation()
            let exists = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: stagingOutput.path)
            }.value
            try Task.checkCancellation()
            guard exists else { throw FileContentError.missingOutput }
            let cancellation = ContentPublicationCancellation()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await store.publish(stage: stage, directory: directory, output: output,
                                        receipt: receipt, slug: slug, size: request.size, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
            await store.cleanup(stage: stage)
            try Task.checkCancellation()
            return output
        } catch {
            if let contentError = error as? FileContentError,
               case .publicationRecoveryFailed = contentError { throw error }
            await store.cleanup(stage: stage)
            try Task.checkCancellation()
            throw error
        }
    }
}
