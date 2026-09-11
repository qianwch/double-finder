import Foundation
import DoubleFinderPluginKit

/// Builds a `FileOperation` for a plugin drive: download (drive → local),
/// upload (local → drive) or a transfer within the same drive (copy / move).
/// Items are processed one at a time (`perItemOperation`); a plugin that wants
/// concurrency can do it inside its own session.
struct PluginTransferProvider: TransferProvider {
    enum Mode {
        case download
        case upload
        case within(move: Bool)
    }

    let drive: PluginDriveSession
    let mode: Mode

    @MainActor var verb: String {
        switch mode {
        case .download: return tr("Download")
        case .upload: return tr("Upload")
        case .within(let move): return move ? tr("Move") : tr("Copy")
        }
    }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let isMove: Bool = { if case .within(let m) = mode { return m } else { return false } }()
        let op = FileOperation(type: isMove ? .move : .copy,
                               sources: items.map { $0.path },
                               destination: destPath)
        switch mode {
        case .download: op.customTitle = tr("Downloading")
        case .upload: op.customTitle = tr("Uploading")
        case .within(let move): op.customTitle = move ? tr("Moving") : tr("Copying")
        }
        // Byte progress only when every item's size is known (files); a folder
        // reports 0 and the sheet falls back to the indeterminate bar.
        let total = items.contains { $0.isDirectory } ? 0 : items.reduce(Int64(0)) { $0 + $1.size }
        if total > 0 {
            op.totalBytes = total
            op.bytesTransferred = { [weak op] in op?.transferredBytes ?? 0 }
        } else {
            op.indeterminate = true
        }
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let newName = items.count == 1 ? renameTo : nil
        let session = drive.session
        let transferMode = mode

        op.perItemOperation = { [weak op] path in
            guard let op, let item = byPath[path] else { return }
            let report: @Sendable (Int64) -> Void = { op.reportBytes($0) }
            let cancelled: () -> Bool = { op.cancelRequested }
            switch transferMode {
            case .download:
                try await PluginFS.downloadTree(session, path: path, isDirectory: item.isDirectory,
                                                toLocalDirectory: destPath, as: newName,
                                                progress: report, isCancelled: cancelled)
            case .upload:
                try await PluginFS.uploadTree(session, localPath: path, toDirectory: destPath,
                                              as: newName, progress: report, isCancelled: cancelled)
            case .within(let move):
                try await PluginFS.transferWithin(session, path: path, isDirectory: item.isDirectory,
                                                  toDirectory: destPath, as: newName, move: move,
                                                  progress: report, isCancelled: cancelled)
            }
        }
        return op
    }
}
