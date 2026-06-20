import Foundation

// MARK: - Protocol

/// A strategy object that builds a `FileOperation` for a given set of source
/// items and a destination path.  Each provider encapsulates the logic for one
/// backend (local copy, local move, SFTP, S3, …).
///
/// Providers receive already-filtered items (conflict resolution is the caller's
/// responsibility) and simply configure the `FileOperation`.
protocol TransferProvider {
    /// Human-readable verb for the operation (e.g. "Copy", "Move", "Upload").
    @MainActor var verb: String { get }

    /// Build a `FileOperation` that transfers `items` to `destPath`.
    @MainActor
    func makeOperation(items: [FileItem], destPath: String) -> FileOperation
}

// MARK: - LocalCopyProvider

/// Builds a local copy `FileOperation`, choosing between three sub-cases
/// extracted verbatim from `MainViewController.actionCopy`'s local branch:
///
/// 1. **Archive source** (`archiveRoot == true`): extract via `srcFS.copy` while
///    preserving path structure below the common ancestor.
/// 2. **Expanded items** (any `item.depth > 0`): preserve structure below the
///    common ancestor using `LocalFS.copyPreservingPath`.
/// 3. **Flat** (neither of the above): byte-mode with `totalBytes` / `bytesTransferred`.
struct LocalCopyProvider: TransferProvider {
    let srcFS: VirtualFS
    let archiveRoot: Bool

    init(srcFS: VirtualFS, archiveRoot: Bool) {
        self.srcFS = srcFS
        self.archiveRoot = archiveRoot
    }

    @MainActor var verb: String { tr("Copy") }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String) -> FileOperation {
        let op = FileOperation(type: .copy,
                               sources: items.map { $0.path },
                               destination: destPath,
                               conflictPolicy: .overwrite)
        if archiveRoot {
            // Source is inside an archive: extract each entry instead of a
            // plain local copy (the item paths are virtual). Preserve the
            // structure below the selection's common ancestor, so an entry
            // pulled from a deep sub-folder keeps its folder hierarchy
            // (same behaviour as the local expanded-copy below).
            let base = LocalFS.commonAncestor(of: items.map { $0.path })
            let capturedSrcFS = srcFS
            let dest = destPath
            op.indeterminate = true
            op.perItemOperation = { path in
                let rel = LocalFS.relativePath(path, base: base)
                let relParent = (rel as NSString).deletingLastPathComponent
                let targetDir = relParent.isEmpty ? dest : (dest as NSString).appendingPathComponent(relParent)
                try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
                try await capturedSrcFS.copy(from: path, to: targetDir)
            }
        } else if items.contains(where: { $0.depth > 0 }) {
            // Some selected items come from expanded sub-folders: preserve
            // structure below the selection's common ancestor folder, so
            // shared parent folders aren't duplicated (tar/untar style).
            let base = LocalFS.commonAncestor(of: items.map { $0.path })
            let dest = destPath
            op.indeterminate = true
            op.perItemOperation = { path in
                let rel = LocalFS.relativePath(path, base: base)
                try await LocalFS().copyPreservingPath(from: path, toBaseDir: dest, relativePath: rel)
            }
        } else {
            op.totalBytes = items.reduce(0) { $0 + FileOperation.sizeOnDisk($1.path) }
            let names = items.map { $0.name }
            let dest = destPath
            op.bytesTransferred = {
                names.reduce(Int64(0)) { $0 + FileOperation.sizeOnDisk((dest as NSString).appendingPathComponent($1)) }
            }
        }
        return op
    }
}

// MARK: - LocalMoveProvider

/// Builds a local move `FileOperation`, extracted verbatim from
/// `MainViewController.actionMove` — which sets NO byte-mode (the move shows the
/// plain item-count progress bar, not bytes/speed), so neither does this.
struct LocalMoveProvider: TransferProvider {
    @MainActor var verb: String { tr("Move") }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String) -> FileOperation {
        let op = FileOperation(type: .move,
                               sources: items.map { $0.path },
                               destination: destPath,
                               conflictPolicy: .overwrite)
        return op
    }
}
