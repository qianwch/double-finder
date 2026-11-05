import Foundation

/// Archive/search paths are virtual. Export through their owning FS before upload.
struct MaterializedUploadProvider: TransferProvider {
    let srcFS: VirtualFS
    let destFS: VirtualFS

    @MainActor var verb: String { tr("Upload") }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: .copy, sources: items.map(\.path), destination: destPath)
        op.customTitle = tr("Uploading")
        op.indeterminate = true
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        op.perItemOperation = { [weak op] path in
            guard let op, let item = byPath[path] else { return }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("df-upload-" + UUID().uuidString)
            do {
                try Task.checkCancellation()
                guard !op.cancelRequested else { throw CancellationError() }
                let name = items.count == 1 ? (renameTo ?? item.name) : item.name
                try FileContentTransfer.validateLeaf(name)
                try await FileContentTransfer.checkMaterializedExport(at: path, from: srcFS, to: temp,
                                                                      isDirectory: item.isDirectory)
                try await srcFS.exportItem(at: path, toLocalDirectory: temp, progress: { _ in })
                try Task.checkCancellation()
                guard !op.cancelRequested else { throw CancellationError() }
                try await destFS.importItem(
                    from: temp.appendingPathComponent((path as NSString).lastPathComponent),
                    toPath: (destPath as NSString).appendingPathComponent(name), progress: { _ in })
            } catch {
                await Task.detached { try? FileManager.default.removeItem(at: temp) }.value
                throw error
            }
            await Task.detached { try? FileManager.default.removeItem(at: temp) }.value
        }
        return op
    }
}
