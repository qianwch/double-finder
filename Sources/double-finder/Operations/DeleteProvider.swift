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
