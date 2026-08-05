import Foundation

/// Builds a delete `FileOperation` for the active panel's backend. The backend
/// is resolved by the caller (sftp connection / S3 filesystem / permanent flag),
/// keeping this provider decoupled from PanelState and unit-testable.
struct DeleteProvider {
    let sftp: SFTPConnection?
    let s3FS: VirtualFS?
    let permanent: Bool

    init(sftp: SFTPConnection?, s3FS: VirtualFS?, permanent: Bool) {
        self.sftp = sftp
        self.s3FS = s3FS
        self.permanent = permanent
    }

    /// Listing for the delete-confirm sheet: the first `limit` names one per
    /// line, any remainder folded into a single "… and N more" line.
    @MainActor
    static func confirmListing(names: [String], limit: Int = 10) -> String {
        var lines = Array(names.prefix(limit))
        if names.count > limit {
            lines.append(tr("… and %d more", names.count - limit))
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    func makeOperation(items: [FileItem]) -> FileOperation {
        let op = FileOperation(type: .delete, sources: items.map { $0.path })
        if let conn = sftp {
            op.indeterminate = true
            op.perItemOperation = { path in try await SFTPFS(connection: conn).delete(path) }
        } else if let fs = s3FS {
            op.indeterminate = true
            op.perItemOperation = { path in try await fs.delete(path) }
        } else if permanent {
            op.indeterminate = true
            op.perItemOperation = { path in try await LocalFS().deletePermanently(path) }
        }   // else: local Trash via FileOperation's default fs.delete (trashItem)
        return op
    }
}
