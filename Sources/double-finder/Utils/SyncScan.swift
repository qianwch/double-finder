import Foundation

/// Size + modification time for one file, backend-agnostic.
struct SyncFileInfo { let size: Int64; let mtime: Date }

/// One side of a directory sync. v1 supports local↔remote only.
enum SyncEndpoint {
    case local(base: String)
    case sftp(SFTPConnection, base: String)
    case s3(S3Client, bucket: String, prefix: String)

    var isS3: Bool { if case .s3 = self { return true }; return false }
    var isRemote: Bool { if case .local = self { return false }; return true }
}

enum SyncScan {
    /// Parses `find -printf '%P\t%s\t%T@\n'` output into rel → (size, mtime).
    /// Lines without exactly the 3 tab fields are skipped. Filenames may contain
    /// spaces (rel is everything before the first tab). Newlines in names are an
    /// accepted limitation (one file per line).
    static func parseFindOutput(_ text: String) -> [String: SyncFileInfo] {
        var map: [String: SyncFileInfo] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let rel = String(parts[0])
            guard !rel.isEmpty, let size = Int64(parts[1]), let epoch = Double(parts[2]) else { continue }
            map[rel] = SyncFileInfo(size: size, mtime: Date(timeIntervalSince1970: epoch))
        }
        return map
    }

    /// Maps S3 objects under `prefix` to rel → info, dropping folder markers.
    static func s3RelMap(_ objects: [S3ObjectInfo], prefix: String) -> [String: SyncFileInfo] {
        var map: [String: SyncFileInfo] = [:]
        for o in objects {
            guard o.key.hasPrefix(prefix) else { continue }
            let rel = String(o.key.dropFirst(prefix.count))
            guard !rel.isEmpty, !rel.hasSuffix("/") else { continue }
            map[rel] = SyncFileInfo(size: o.size, mtime: o.modified)
        }
        return map
    }
}
