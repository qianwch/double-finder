import Foundation

/// Maps an S3 object store onto VirtualFS. Path model: "/" lists buckets,
/// "/bucket/prefix" lists that prefix (CommonPrefixes=folders, Contents=files).
final class S3FS: VirtualFS {
    private let client: S3Client
    private(set) var currentPath: String

    init(client: S3Client, currentPath: String) {
        self.client = client
        self.currentPath = currentPath
    }

    func listDirectory(_ path: String) async throws -> [FileItem] {
        let (bucket, key) = parseS3Path(path)
        guard let bucket = bucket else {
            // Account root → buckets as folders.
            let names = try await client.listBuckets()
            return names.map { name in
                FileItem(id: UUID(), name: name, path: "/" + name, isDirectory: true,
                         isArchive: false, size: 0, modified: Date(), isHidden: false,
                         isSymlink: false, permissions: "drwxr-xr-x")
            }
        }
        // A folder path arrives without a trailing slash (e.g. "/bucket/sub");
        // S3 listing needs the prefix to end in "/" or it returns the folder
        // itself as a single CommonPrefix instead of its contents.
        let prefix = (key.isEmpty || key.hasSuffix("/")) ? key : key + "/"
        let (prefixes, objects) = try await client.listObjects(bucket: bucket, prefix: prefix)
        var items: [FileItem] = []
        let basePath = path.hasSuffix("/") ? path : path + "/"
        for p in prefixes {
            let name = p.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty else { continue }
            // Folder paths keep the trailing slash so delete/rename/move detect
            // them as folders (recursive) — the breadcrumb filters empty segments.
            items.append(FileItem(id: UUID(), name: String(name), path: basePath + name + "/",
                                  isDirectory: true, isArchive: false, size: 0, modified: Date(),
                                  isHidden: name.hasPrefix("."), isSymlink: false,
                                  permissions: "drwxr-xr-x"))
        }
        for o in objects {
            let name = String(o.key.dropFirst(prefix.count))
            guard !name.isEmpty, !name.hasSuffix("/") else { continue }   // skip placeholder objects (folder markers)
            items.append(FileItem(id: UUID(), name: name, path: basePath + name,
                                  isDirectory: false, isArchive: FileItem.isArchiveFileName(name),
                                  size: o.size, modified: o.modified, isHidden: name.hasPrefix("."),
                                  isSymlink: false, permissions: "-rw-r--r--"))
        }
        return items
    }

    /// Space-key folder size: the sum of every object under the prefix. S3 has no
    /// directories, so this is the only meaning "folder size" can have — and
    /// `listAllObjects` already pages through the whole tree.
    func directorySize(_ path: String) async -> Int64 {
        let (bucket, key) = parseS3Path(path)
        guard let bucket = bucket else { return 0 }   // account root: nothing to sum
        let prefix = (key.isEmpty || key.hasSuffix("/")) ? key : key + "/"
        guard let objects = try? await client.listAllObjects(bucket: bucket, prefix: prefix) else {
            return 0
        }
        // Skip the zero-byte placeholder objects that stand in for folders.
        return objects.reduce(Int64(0)) { $0 + ($1.key.hasSuffix("/") ? 0 : $1.size) }
    }

    func createDirectory(_ path: String) async throws {
        let (bucket, key) = parseS3Path(path)
        guard let bucket = bucket, !key.isEmpty else {
            throw FSUnsupportedError(message: "Cannot create a folder here")
        }
        try await client.putEmptyObject(bucket: bucket, key: key.hasSuffix("/") ? key : key + "/")
    }

    func delete(_ path: String) async throws {
        let (bucket, key) = parseS3Path(path)
        guard let bucket = bucket, !key.isEmpty else {
            throw FSUnsupportedError(message: "Cannot delete this")
        }
        if key.hasSuffix("/") {
            // Folder: recursively delete every key under the prefix.
            for k in try await client.listAllKeys(bucket: bucket, prefix: key) {
                try await client.deleteObject(bucket: bucket, key: k)
            }
        } else {
            try await client.deleteObject(bucket: bucket, key: key)
        }
    }

    func rename(at path: String, to newName: String) async throws {
        let (bucket, key) = parseS3Path(path)
        guard let bucket = bucket, !key.isEmpty else {
            throw FSUnsupportedError(message: "Cannot rename this")
        }
        if key.hasSuffix("/") {
            // Folder rename: recursively copy+delete every key under the old prefix.
            let strippedKey = String(key.dropLast())   // "a/b/old"
            let parent = (strippedKey as NSString).deletingLastPathComponent   // "a/b"
            let destPrefix = (parent.isEmpty ? "" : parent + "/") + newName + "/"
            for k in try await client.listAllKeys(bucket: bucket, prefix: key) {
                let suffix = String(k.dropFirst(key.count))
                try await client.copyObject(bucket: bucket, srcKey: k, dstKey: destPrefix + suffix)
                try await client.deleteObject(bucket: bucket, key: k)
            }
        } else {
            // File rename: single copy+delete.
            let parent = (key as NSString).deletingLastPathComponent
            let dst = parent.isEmpty ? newName : parent + "/" + newName
            try await client.copyObject(bucket: bucket, srcKey: key, dstKey: dst)
            try await client.deleteObject(bucket: bucket, key: key)
        }
    }

    func move(from: String, to: String) async throws {
        // S3 move within the same store = copy + delete. `to` is a destination dir path.
        let (sb, sk) = parseS3Path(from)
        let (db, dkDir) = parseS3Path(to.hasSuffix("/") ? to : to + "/")
        guard let sb = sb, let db = db, sb == db, !sk.isEmpty else {
            throw FSUnsupportedError(message: "Unsupported move")
        }
        if sk.hasSuffix("/") {
            // Folder move: recursively copy+delete every key under the old prefix.
            let folderName = (String(sk.dropLast()) as NSString).lastPathComponent
            let destPrefix = dkDir + folderName + "/"
            for k in try await client.listAllKeys(bucket: sb, prefix: sk) {
                let suffix = String(k.dropFirst(sk.count))
                try await client.copyObject(bucket: sb, srcKey: k, dstKey: destPrefix + suffix)
                try await client.deleteObject(bucket: sb, key: k)
            }
        } else {
            // File move: single copy+delete.
            let name = (sk as NSString).lastPathComponent
            let dst = dkDir + name
            try await client.copyObject(bucket: sb, srcKey: sk, dstKey: dst)
            try await client.deleteObject(bucket: sb, key: sk)
        }
    }

    func exportItem(at path: String, toLocalDirectory directory: URL,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        _ = try FileContentTransfer.localPath(directory)
        let (bucket, key) = parseS3Path(path)
        guard let bucket, !key.isEmpty else { throw FSUnsupportedError(message: "Unsupported download") }
        let local = try await FileContentTransfer.prepareDirectory(directory)
        if key.hasSuffix("/") {
            let name = (String(key.dropLast()) as NSString).lastPathComponent
            try FileContentTransfer.validateLeaf(name)
            let root = URL(fileURLWithPath: local).appendingPathComponent(name)
            _ = try await FileContentTransfer.prepareDirectory(root)
            for entry in try await client.listAllKeys(bucket: bucket, prefix: key) {
                try Task.checkCancellation()
                let relative = String(entry.dropFirst(key.count))
                guard !relative.isEmpty else { continue }
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                    throw FSUnsupportedError(message: "Invalid remote file path")
                }
                let target = root.appendingPathComponent(relative)
                if entry.hasSuffix("/") {
                    _ = try await FileContentTransfer.prepareDirectory(target)
                } else {
                    _ = try await FileContentTransfer.prepareDirectory(target.deletingLastPathComponent())
                    try await client.getObject(bucket: bucket, key: entry, toLocalPath: target.path, progress: progress)
                }
            }
        } else {
            let name = (key as NSString).lastPathComponent
            try FileContentTransfer.validateLeaf(name)
            let target = (local as NSString).appendingPathComponent(name)
            try await client.getObject(bucket: bucket, key: key, toLocalPath: target, progress: progress)
        }
    }

    func importItem(from localURL: URL, toPath destinationPath: String,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        let local = try FileContentTransfer.localPath(localURL)
        let (bucket, key) = parseS3Path(destinationPath)
        guard let bucket, !key.isEmpty else { throw FSUnsupportedError(message: "A complete destination path is required") }
        let isDir = try await FileContentTransfer.isLocalDirectory(localURL)
        try Task.checkCancellation()
        if isDir {
            let prefix = key.hasSuffix("/") ? key : key + "/"
            let fileKey = String(prefix.dropLast())
            guard !(try await client.listAllKeys(bucket: bucket, prefix: fileKey)).contains(fileKey) else {
                throw FSUnsupportedError(message: "Cannot upload a directory over a file")
            }
            // Preserve empty directories, just like the create-folder operation.
            try await client.putEmptyObject(bucket: bucket, key: prefix)
            for child in try await FileContentTransfer.localChildren(localURL) {
                try await importItem(from: child, toPath: "/" + bucket + "/" + prefix + child.lastPathComponent, progress: progress)
            }
        } else {
            guard !key.hasSuffix("/") else { throw FSUnsupportedError(message: "Cannot upload a file over a directory") }
            // A prefix with children or a folder marker is a directory in this UI.
            guard try await client.listAllKeys(bucket: bucket, prefix: key + "/").isEmpty else {
                throw FSUnsupportedError(message: "Cannot upload a file over a directory")
            }
            try await client.putObject(bucket: bucket, key: key, fromLocalPath: local, progress: progress)
        }
    }

    /// Compatibility content-read API. Uploads must use importItem explicitly.
    func copy(from: String, to: String) async throws {
        try await exportItem(at: from, toLocalDirectory: URL(fileURLWithPath: to), progress: { _ in })
    }
}
