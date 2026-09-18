import Foundation

/// Destination identity is captured before confirmation/async work, so tab or
/// session changes cannot redirect the conflict check to another filesystem.
enum TransferConflictDestination {
    case local
    case remote(VirtualFS)
}

enum TransferConflictChecker {
    static func existingNames(of items: [FileItem], at directory: String,
                              destination: TransferConflictDestination,
                              renameTo: String? = nil) async throws -> Set<String> {
        switch destination {
        case .local:
            return Set(items.compactMap { item -> String? in
                let name = renameTo ?? item.name
                let target = (directory as NSString).appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: target) ? name : nil
            })
        case .remote(let fs):
            // Unknown is not empty: callers must stop before creating an
            // overwrite operation when listing fails (including cancellation).
            let listed = try await fs.listDirectory(directory)
            return Set(listed.map { $0.name })
        }
    }
}
