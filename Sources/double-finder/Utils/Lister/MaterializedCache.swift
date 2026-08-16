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

    /// Cache folder name for one item — short hex digest of identity + size + mtime.
    static func slug(path: String, size: Int64, modified: Date) -> String {
        let key = "\(path)\u{0}\(size)\u{0}\(modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(key.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
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
