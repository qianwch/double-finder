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
    /// `renameTo` is the TC-style single-item rename-on-transfer: when the user
    /// edits the confirm dialog's last path component, the (sole) item lands
    /// under that name. Providers ignore it when several items are selected.
    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation
}

extension TransferProvider {
    @MainActor
    func makeOperation(items: [FileItem], destPath: String) -> FileOperation {
        makeOperation(items: items, destPath: destPath, renameTo: nil)
    }
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
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: .copy,
                               sources: items.map { $0.path },
                               destination: destPath,
                               conflictPolicy: .overwrite)
        let newName = items.count == 1 ? renameTo : nil
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
                // Rename-on-copy: ZipFS extracts under the entry's own name;
                // move the extracted result to the requested one.
                if let newName = newName {
                    let extracted = (targetDir as NSString)
                        .appendingPathComponent((path as NSString).lastPathComponent)
                    let target = (targetDir as NSString).appendingPathComponent(newName)
                    if extracted != target {
                        let fm = FileManager.default
                        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
                        try fm.moveItem(atPath: extracted, toPath: target)
                    }
                }
            }
        } else if let newName = newName {
            // Single-item rename-on-copy: explicit target path.
            let target = (destPath as NSString).appendingPathComponent(newName)
            op.totalBytes = items.reduce(0) { $0 + FileOperation.sizeOnDisk($1.path) }
            op.bytesTransferred = { FileOperation.sizeOnDisk(target) }
            op.perItemOperation = { path in
                try await LocalFS().copy(from: path, toFile: target)
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
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: .move,
                               sources: items.map { $0.path },
                               destination: destPath,
                               conflictPolicy: .overwrite)
        if items.count == 1, let newName = renameTo {
            // Single-item rename-on-move: explicit target path.
            let target = (destPath as NSString).appendingPathComponent(newName)
            op.perItemOperation = { path in
                try await LocalFS().move(from: path, toFile: target)
            }
        }
        return op
    }
}

// MARK: - SFTPTransferProvider

/// Builds a `FileOperation` for SFTP download (remote → local) or upload
/// (local → remote).  Faithfully extracted from `MainViewController.runSFTPTransfer`
/// + the download/upload closures in `actionSFTPTransfer`.
///
/// - **download**: byte-mode (totalBytes = Σitem.size; bytesTransferred polls
///   sizeOnDisk of already-written files); `SFTPFS.copy(from:to:onProcess:)`.
/// - **upload**: indeterminate (no per-byte progress available);
///   `SFTPFS.upload(localPath:to:onProcess:)`.
///
/// In both cases `perItemOperation` captures the scp `Process` into
/// `op.processBox` so the progress sheet's Cancel button works.
struct SFTPTransferProvider: TransferProvider {
    enum Direction { case download, upload }

    let connection: SFTPConnection
    let direction: Direction

    init(connection: SFTPConnection, direction: Direction) {
        self.connection = connection
        self.direction = direction
    }

    @MainActor var verb: String {
        direction == .download ? tr("Download") : tr("Upload")
    }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: .copy,
                               sources: items.map { $0.path },
                               destination: destPath)
        op.customTitle = direction == .download ? tr("Downloading") : tr("Uploading")

        let conn = connection
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let newName = items.count == 1 ? renameTo : nil

        switch direction {
        case .download:
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            op.totalBytes = total
            let names = items.map { newName ?? $0.name }
            let dest = destPath
            op.bytesTransferred = {
                names.reduce(Int64(0)) { $0 + FileOperation.sizeOnDisk((dest as NSString).appendingPathComponent($1)) }
            }
            op.perItemOperation = { [weak op] path in
                guard let op = op, byPath[path] != nil else { return }
                let fs = SFTPFS(connection: conn)
                // Rename-on-download: scp straight to the explicit local target.
                let to = newName.map { (destPath as NSString).appendingPathComponent($0) } ?? destPath
                try await fs.copy(from: path, to: to) { op.processBox.process = $0 }
            }

        case .upload:
            op.indeterminate = true
            op.perItemOperation = { [weak op] path in
                guard let op = op, byPath[path] != nil else { return }
                let fs = SFTPFS(connection: conn)
                // Rename-on-upload: scp straight to the explicit remote target.
                let to = newName.map { (destPath as NSString).appendingPathComponent($0) } ?? destPath
                try await fs.upload(localPath: path, to: to) { op.processBox.process = $0 }
            }
        }

        return op
    }
}

// MARK: - SFTPSameHostProvider

/// Builds a `FileOperation` for a server-side **copy or move within one SFTP host**
/// (both panels connected to the same server). Each selected item is transferred
/// entirely on the remote host via a single `cp -af` / `mv -f` ssh command, so
/// bytes never round-trip through the client. Folders are handled by `cp -a`
/// recursion (one unit per selection) — there's no per-byte progress, so the sheet
/// shows item-count progress (X/Y). Mirrors `S3SameStoreProvider`'s role for SFTP.
struct SFTPSameHostProvider: TransferProvider {
    let connection: SFTPConnection
    let move: Bool

    init(connection: SFTPConnection, move: Bool) {
        self.connection = connection
        self.move = move
    }

    @MainActor var verb: String { move ? tr("Move") : tr("Copy") }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: move ? .move : .copy,
                               sources: items.map { $0.path }, destination: destPath)
        op.customTitle = move ? tr("Moving") : tr("Copying")
        op.currentFile = tr("Preparing…")
        op.indeterminate = true
        op.concurrency = 4

        let conn = connection
        let move = self.move
        let dest = destPath
        let newName = items.count == 1 ? renameTo : nil
        op.transferUnitsProvider = {
            items.map { item in
                let src = item.path
                return FileOperation.Unit(label: newName ?? item.name) { report in
                    let fs = SFTPFS(connection: conn)
                    try await fs.serverTransfer(from: src, toDir: dest, move: move, renameTo: newName)
                    report(item.size)
                }
            }
        }
        return op
    }
}

// MARK: - S3TransferProvider

/// Builds a `FileOperation` for S3 download (S3 → local) or upload (local → S3).
/// Faithfully extracted from `MainViewController.actionS3Transfer`.
///
/// - **download**: deferred expansion via `transferUnitsProvider`; each selected
///   S3 item is expanded (folder → `listAllKeys`, file → single unit) with path-
///   escape guards; `concurrency=6`, `indeterminate=true`, `currentFile="Preparing…"`.
/// - **upload**: same deferred expansion model; local dir → recursive `subpaths`,
///   single file → one unit; `concurrency=6`.
struct S3TransferProvider: TransferProvider {
    let client: S3Client
    let downloading: Bool

    init(client: S3Client, downloading: Bool) {
        self.client = client
        self.downloading = downloading
    }

    @MainActor var verb: String {
        downloading ? tr("Download") : tr("Upload")
    }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: .copy, sources: items.map { $0.path }, destination: destPath)
        op.customTitle = downloading ? tr("Downloading") : tr("Uploading")
        op.currentFile = tr("Preparing…")
        op.indeterminate = true
        op.concurrency = 6

        let capturedClient = client
        let capturedDownloading = downloading
        let newName = items.count == 1 ? renameTo : nil

        op.transferUnitsProvider = {
            var units: [FileOperation.Unit] = []
            if capturedDownloading {
                // Each selected S3 item → file units.
                for item in items {
                    let (b, key) = parseS3Path(item.path)
                    guard let b = b else { continue }
                    if item.isDirectory || key.hasSuffix("/") {
                        let folderKey = key.hasSuffix("/") ? key : key + "/"
                        // M3: surface listing failures instead of silently yielding zero units.
                        // listAllObjects (not listAllKeys) so each unit carries its byte
                        // size for the progress sheet's transfer-speed readout.
                        let objs: [S3ObjectInfo]
                        do {
                            objs = try await capturedClient.listAllObjects(bucket: b, prefix: folderKey)
                        } catch {
                            let capturedError = error
                            units.append(FileOperation.Unit(label: item.name) { _ in
                                throw capturedError
                            })
                            continue
                        }
                        for o in objs where !o.key.hasSuffix("/") {
                            let k = o.key
                            let local = S3TransferPlanner.downloadLocalPath(key: k, folderKey: folderKey,
                                                                            destDir: destPath,
                                                                            renameTo: newName)
                            // C1: reject keys that escape the destination directory.
                            guard S3TransferPlanner.isWithin(local, destDir: destPath) else {
                                units.append(FileOperation.Unit(label: k) { _ in
                                    throw FSUnsupportedError(message: "Unsafe path in key: \(k)")
                                })
                                continue
                            }
                            let sz = o.size
                            units.append(FileOperation.Unit(label: (k as NSString).lastPathComponent, bytes: sz) { report in
                                let dir = (local as NSString).deletingLastPathComponent
                                try FileManager.default.createDirectory(atPath: dir,
                                                                        withIntermediateDirectories: true)
                                try await capturedClient.getObject(bucket: b, key: k, toLocalPath: local, progress: report)
                            })
                        }
                    } else {
                        let local = S3TransferPlanner.downloadLocalPath(key: key, folderKey: nil,
                                                                        destDir: destPath,
                                                                        renameTo: newName)
                        // C1: reject keys that escape the destination directory.
                        guard S3TransferPlanner.isWithin(local, destDir: destPath) else {
                            units.append(FileOperation.Unit(label: key) { _ in
                                throw FSUnsupportedError(message: "Unsafe path in key: \(key)")
                            })
                            continue
                        }
                        // M1: ensure parent directory exists before writing the file.
                        let sz = item.size
                        units.append(FileOperation.Unit(label: (key as NSString).lastPathComponent, bytes: sz) { report in
                            let dir = (local as NSString).deletingLastPathComponent
                            try FileManager.default.createDirectory(atPath: dir,
                                                                    withIntermediateDirectories: true)
                            try await capturedClient.getObject(bucket: b, key: key, toLocalPath: local, progress: report)
                        })
                    }
                }
            } else {
                // Upload: each selected local item → file units; dest is /bucket/prefix.
                let (db, dkDirRaw) = parseS3Path(destPath.hasSuffix("/") ? destPath : destPath + "/")
                guard let db = db else { return units }
                let destPrefix = dkDirRaw
                for item in items {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        let root = item.path
                        let files = (FileManager.default.subpaths(atPath: root) ?? []).compactMap { sub -> String? in
                            let full = (root as NSString).appendingPathComponent(sub)
                            var d: ObjCBool = false
                            FileManager.default.fileExists(atPath: full, isDirectory: &d)
                            return d.boolValue ? nil : full
                        }
                        for f in files {
                            let key = S3TransferPlanner.uploadKey(localPath: f, folderRoot: root,
                                                                  destPrefix: destPrefix,
                                                                  renameTo: newName)
                            let sz = FileOperation.sizeOnDisk(f)
                            units.append(FileOperation.Unit(label: (f as NSString).lastPathComponent,
                                                            bytes: sz) { report in
                                try await capturedClient.putObject(bucket: db, key: key, fromLocalPath: f, progress: report)
                            })
                        }
                    } else {
                        let key = S3TransferPlanner.uploadKey(localPath: item.path, folderRoot: nil,
                                                              destPrefix: destPrefix,
                                                              renameTo: newName)
                        let sz = FileOperation.sizeOnDisk(item.path)
                        units.append(FileOperation.Unit(label: (item.path as NSString).lastPathComponent,
                                                        bytes: sz) { report in
                            try await capturedClient.putObject(bucket: db, key: key, fromLocalPath: item.path, progress: report)
                        })
                    }
                }
            }
            return units
        }

        return op
    }
}

// MARK: - S3SameStoreProvider

/// Builds a `FileOperation` for a server-side **copy or move within one S3 store**
/// (same connection — source and destination buckets may differ). Each object is
/// copied with `copyObject` (PUT + `x-amz-copy-source`), so bytes never round-trip
/// through the client; `move` additionally deletes each source object after the
/// copy. Folders expand via `listAllObjects`, preserving the tree (and any empty-
/// folder marker objects) below the selected folder, mirroring `S3FS.move`.
struct S3SameStoreProvider: TransferProvider {
    let client: S3Client
    let move: Bool

    init(client: S3Client, move: Bool) {
        self.client = client
        self.move = move
    }

    @MainActor var verb: String { move ? tr("Move") : tr("Copy") }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: move ? .move : .copy,
                               sources: items.map { $0.path }, destination: destPath)
        op.customTitle = move ? tr("Moving") : tr("Copying")
        op.currentFile = tr("Preparing…")
        op.indeterminate = true
        op.concurrency = 6

        let client = self.client
        let move = self.move
        let newName = items.count == 1 ? renameTo : nil
        // Destination dir → bucket + prefix (prefix keeps its trailing slash, "" at bucket root).
        let (destBucket, destPrefix) = parseS3Path(destPath.hasSuffix("/") ? destPath : destPath + "/")

        op.transferUnitsProvider = {
            var units: [FileOperation.Unit] = []
            guard let db = destBucket else { return units }
            for item in items {
                let (sb, sk) = parseS3Path(item.path)
                guard let sb = sb, !sk.isEmpty else { continue }
                if item.isDirectory || sk.hasSuffix("/") {
                    // Folder: copy every key under the prefix, rooted at <dest>/<folderName>/.
                    let folderKey = sk.hasSuffix("/") ? sk : sk + "/"
                    let folderName = newName ?? (String(folderKey.dropLast()) as NSString).lastPathComponent
                    let objs: [S3ObjectInfo]
                    do {
                        objs = try await client.listAllObjects(bucket: sb, prefix: folderKey)
                    } catch {
                        let captured = error
                        units.append(FileOperation.Unit(label: item.name) { _ in throw captured })
                        continue
                    }
                    for o in objs {
                        let srcKey = o.key
                        let rel = String(srcKey.dropFirst(folderKey.count))
                        let dstKey = destPrefix + folderName + "/" + rel
                        let sz = o.size
                        units.append(FileOperation.Unit(label: (srcKey as NSString).lastPathComponent,
                                                        bytes: sz) { report in
                            try await client.copyObject(srcBucket: sb, srcKey: srcKey, dstBucket: db, dstKey: dstKey)
                            if move { try await client.deleteObject(bucket: sb, key: srcKey) }
                            report(sz)
                        })
                    }
                } else {
                    // File: single server-side copy (+ delete for move).
                    let name = newName ?? (sk as NSString).lastPathComponent
                    let dstKey = destPrefix + name
                    let sz = item.size
                    units.append(FileOperation.Unit(label: name, bytes: sz) { report in
                        try await client.copyObject(srcBucket: sb, srcKey: sk, dstBucket: db, dstKey: dstKey)
                        if move { try await client.deleteObject(bucket: sb, key: sk) }
                        report(sz)
                    })
                }
            }
            return units
        }

        return op
    }
}
