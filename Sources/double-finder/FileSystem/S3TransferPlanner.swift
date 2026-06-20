import Foundation

/// Pure path math for expanding an S3 folder transfer into per-file units.
enum S3TransferPlanner {
    /// Local destination path for a downloaded object.
    /// - folderKey: the selected folder's prefix (ends in "/") when the object
    ///   came from a folder download; nil for a single-file download.
    static func downloadLocalPath(key: String, folderKey: String?, destDir: String) -> String {
        if let folderKey = folderKey, !folderKey.isEmpty {
            let folderName = (String(folderKey.dropLast()) as NSString).lastPathComponent
            let rel = String(key.dropFirst(folderKey.count))
            return (destDir as NSString).appendingPathComponent(folderName + "/" + rel)
        }
        let name = (key as NSString).lastPathComponent
        return (destDir as NSString).appendingPathComponent(name)
    }

    /// True iff `localPath` (after resolving "..") stays within `destDir`.
    /// Used to reject S3 keys that try to escape the download directory.
    static func isWithin(_ localPath: String, destDir: String) -> Bool {
        let resolved = (localPath as NSString).standardizingPath
        let root = (destDir as NSString).standardizingPath
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    /// Remote key for an uploaded local file.
    /// - folderRoot: the selected local directory (no trailing slash) when the
    ///   file came from a folder upload; nil for a single-file upload.
    static func uploadKey(localPath: String, folderRoot: String?, destPrefix: String) -> String {
        if let folderRoot = folderRoot, !folderRoot.isEmpty {
            let folderName = (folderRoot as NSString).lastPathComponent
            var rel = localPath
            if rel.hasPrefix(folderRoot) { rel.removeFirst(folderRoot.count) }
            if rel.hasPrefix("/") { rel.removeFirst() }
            return destPrefix + folderName + "/" + rel
        }
        let name = (localPath as NSString).lastPathComponent
        return destPrefix + name
    }
}
