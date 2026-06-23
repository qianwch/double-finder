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

    /// Scans an endpoint into rel → info, filtering OS junk. Always recursive.
    static func scan(_ endpoint: SyncEndpoint) async throws -> [String: SyncFileInfo] {
        switch endpoint {
        case .local(let base):
            return scanLocal(base)
        case .sftp(let conn, let base):
            let cmd = "find \"\(base)\" -type f -printf '%P\\t%s\\t%T@\\n' 2>/dev/null"
            let out = try await SFTPFS(connection: conn).runCommand(cmd)
            let map = parseFindOutput(out)
            // Non-empty remote dir that yields nothing usually means find -printf is unsupported.
            if map.isEmpty && !out.isEmpty { throw SyncFindUnsupportedError() }
            return map.filter { !SyncDirsSheet.isJunk(rel: $0.key) }
        case .s3(let client, let bucket, let prefix):
            let objs = try await client.listAllObjects(bucket: bucket, prefix: prefix)
            return s3RelMap(objs, prefix: prefix).filter { !SyncDirsSheet.isJunk(rel: $0.key) }
        }
    }

    private static func scanLocal(_ base: String) -> [String: SyncFileInfo] {
        let fm = FileManager.default
        var map: [String: SyncFileInfo] = [:]
        // Canonicalize via realpath so the prefix matches the enumerator's child
        // paths (FileManager yields /private/var… while Foundation's symlink
        // resolvers keep /var…); otherwise rel computation drops subfolders.
        let canonicalBase: String = {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            if realpath(base, &buf) != nil { return String(cString: buf) }
            return (URL(fileURLWithPath: base).resolvingSymlinksInPath()).path
        }()
        let baseURL = URL(fileURLWithPath: canonicalBase)
        guard let en = fm.enumerator(at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []) else { return map }
        let prefix = canonicalBase.hasSuffix("/") ? canonicalBase : canonicalBase + "/"
        for case let url as URL in en {
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if rv?.isDirectory == true { continue }
            let rel = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            if SyncDirsSheet.isJunk(rel: rel) { continue }
            map[rel] = SyncFileInfo(size: Int64(rv?.fileSize ?? 0),
                                    mtime: rv?.contentModificationDate ?? .distantPast)
        }
        return map
    }
}

struct SyncFindUnsupportedError: LocalizedError {
    var errorDescription: String? { "Remote 'find' did not return scannable output (BusyBox find lacks -printf)." }
}
