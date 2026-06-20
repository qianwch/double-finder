import Foundation

/// Builds an extract `FileOperation`: each selected archive is extracted to
/// `destPath` via `ZipFS.extractAll`. Per-archive failures (e.g. encrypted) land
/// in `op.failures` so the coordinator can re-prompt for a password and retry.
struct ExtractProvider {
    @MainActor
    func makeOperation(items: [FileItem], destPath: String, password: String?) -> FileOperation {
        let op = FileOperation(type: .copy, sources: items.map { $0.path }, destination: destPath)
        op.customTitle = tr("Extracting")
        op.indeterminate = true
        op.perItemOperation = { path in
            try await Task.detached { try ZipFS.extractAll(archivePath: path, to: destPath, password: password) }.value
        }
        return op
    }
}
