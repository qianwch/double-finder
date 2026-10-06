import Foundation
import CryptoKit

/// Naming + freshness rules for the temp copies F3 makes of remote / inside-archive
/// items (pure logic, unit-tested in `MaterializedCacheTests`).
///
/// Stepping through files with ⌘↑/⌘↓ revisits the same entries constantly, and on a
/// solid 7z one entry costs a full decompression pass — so a revisit must reuse the
/// file already on disk. Staleness is handled by the *name*: identity, size and mtime
/// all feed the slug, so a changed remote file simply lands in a different folder and
/// can never be served from an old copy.
///
/// Deliberately NOT used by F4 (edit): that path must always start from the remote
/// bytes, or a second F4 would hand back the user's own unsaved local edits.
enum MaterializedCache {

    /// Cache identity includes the namespace: equal paths on two devices can
    /// have equal metadata while containing completely different bytes.
    static func slug(reference: FileReference, size: Int64, modified: Date) -> String {
        directorySlug(mode: "cache", reference: reference,
                      version: [String(size), String(modified.timeIntervalSince1970)])
    }

    /// F4 and uncached previews must never overwrite a versioned F3 cache entry.
    static func temporarySlug(reference: FileReference) -> String {
        directorySlug(mode: "temporary", reference: reference, version: [])
    }

    private static func directorySlug(mode: String, reference: FileReference, version: [String]) -> String {
        let endpoint: [String]
        switch reference.endpointID {
        case .local: endpoint = ["local", ""]
        case .remote(let id): endpoint = ["remote", id]
        }
        // A fixed array of strings has no fallible custom encoders. JSON escapes
        // separators in paths/IDs and preserves field boundaries unambiguously.
        let fields = ["v2", mode] + endpoint + [reference.path] + version
        let encoded = try! JSONEncoder().encode(fields)
        let digest = SHA256.hash(data: encoded).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return "\(mode)-v2-\(digest)"
    }

    /// True when `localPath` already holds the complete item. Size must match
    /// exactly, so a half-written file from an interrupted extract is never
    /// mistaken for a hit.
    static func isFresh(localPath: String, expectedSize: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return size == expectedSize
    }
}
