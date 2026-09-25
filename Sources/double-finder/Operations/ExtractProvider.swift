import Foundation

/// Builds an extract `FileOperation`: each selected archive is extracted via
/// `ZipFS.extractAll`. Per-archive failures (e.g. encrypted) land in `op.failures`
/// so the coordinator can re-prompt for a password and retry.
struct ExtractProvider {
    /// `intoSubfolders`: when true, each archive is extracted into its own
    /// `<destPath>/<archive-base-name>/` subfolder (used when extracting several
    /// archives at once); when false, all contents go directly into `destPath`.
    @MainActor
    func makeOperation(items: [FileItem], destPath: String, password: String?,
                       intoSubfolders: Bool = false) -> FileOperation {
        let op = FileOperation(type: .copy, sources: items.map { $0.path }, destination: destPath)
        op.customTitle = tr("Extracting")
        op.indeterminate = true
        op.perItemOperation = { path in
            let target: String
            if intoSubfolders {
                let base = FileItem.archiveBaseName(of: (path as NSString).lastPathComponent)
                target = (destPath as NSString).appendingPathComponent(base)
                try await LocalFS().createDirectory(target)
            } else {
                target = destPath
            }
            try await Task.detached {
                // Packer-plugin formats extract through the plugin; everything
                // else is libarchive / the 7-Zip engine.
                if let packer = ArchivePluginRegistry.packer(forFileName: (path as NSString).lastPathComponent) {
                    try PluginArchiveFS.extractAll(archivePath: path, packer: packer, to: target,
                                                   isCancelled: { Task.isCancelled })
                } else {
                    try ZipFS.extractAll(archivePath: path, to: target, password: password)
                }
            }.value
        }
        return op
    }
}
