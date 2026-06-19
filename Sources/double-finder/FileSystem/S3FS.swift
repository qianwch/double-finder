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
        let prefix = key   // already "" or "sub/"
        let (prefixes, objects) = try await client.listObjects(bucket: bucket, prefix: prefix)
        var items: [FileItem] = []
        let basePath = path.hasSuffix("/") ? path : path + "/"
        for p in prefixes {
            let name = p.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty else { continue }
            items.append(FileItem(id: UUID(), name: String(name), path: basePath + name,
                                  isDirectory: true, isArchive: false, size: 0, modified: Date(),
                                  isHidden: name.hasPrefix("."), isSymlink: false,
                                  permissions: "drwxr-xr-x"))
        }
        for o in objects {
            let name = String(o.key.dropFirst(prefix.count))
            guard !name.isEmpty, name != "/" else { continue }   // skip the prefix placeholder object
            items.append(FileItem(id: UUID(), name: name, path: basePath + name,
                                  isDirectory: false, isArchive: FileItem.isArchiveFileName(name),
                                  size: o.size, modified: o.modified, isHidden: name.hasPrefix("."),
                                  isSymlink: false, permissions: "-rw-r--r--"))
        }
        return items
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
        let parent = (key as NSString).deletingLastPathComponent
        let dst = parent.isEmpty ? newName : parent + "/" + newName
        try await client.copyObject(bucket: bucket, srcKey: key, dstKey: dst)
        try await client.deleteObject(bucket: bucket, key: key)
    }

    func move(from: String, to: String) async throws {
        // S3 move within the same store = copy + delete. `to` is a destination dir path.
        let (sb, sk) = parseS3Path(from)
        let (db, dkDir) = parseS3Path(to.hasSuffix("/") ? to : to + "/")
        guard let sb = sb, let db = db, sb == db, !sk.isEmpty else {
            throw FSUnsupportedError(message: "Unsupported move")
        }
        let name = (sk as NSString).lastPathComponent
        let dst = dkDir + name
        try await client.copyObject(bucket: sb, srcKey: sk, dstKey: dst)
        try await client.deleteObject(bucket: sb, key: sk)
    }

    func copy(from: String, to: String) async throws {
        let (sb, sk) = parseS3Path(from)
        if let sb = sb, !sk.isEmpty, !from.hasPrefix("/Volumes"), !from.hasPrefix("/Users"),
           parseS3Path(from).bucket != nil, !FileManager.default.fileExists(atPath: from) {
            // Download: source is an S3 path (not a real local file), `to` is a local dir.
            let name = (sk as NSString).lastPathComponent
            let dest = (to as NSString).appendingPathComponent(name)
            try await client.getObject(bucket: sb, key: sk, toLocalPath: dest)
        } else {
            // Upload: `from` is a local file, `to` is an S3 dir path (/bucket/prefix/).
            let (db, dkDir) = parseS3Path(to.hasSuffix("/") ? to : to + "/")
            guard let db = db else { throw FSUnsupportedError(message: "Unsupported copy") }
            let name = (from as NSString).lastPathComponent
            try await client.putObject(bucket: db, key: dkDir + name, fromLocalPath: from)
        }
    }
}
