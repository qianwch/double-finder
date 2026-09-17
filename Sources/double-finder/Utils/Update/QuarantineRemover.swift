import Foundation

/// Strips `com.apple.quarantine` from a downloaded app bundle — the "unlock"
/// step: without it, an ad-hoc-signed, unnotarized app trips Gatekeeper's
/// "cannot be opened because Apple cannot check it for malicious software"
/// dialog on first launch (see README's Gatekeeper note). A plain
/// `removexattr` walk avoids shelling out to `xattr -dr` for something the
/// system call does directly.
enum QuarantineRemover {
    private static let attribute = "com.apple.quarantine"

    /// Removes the quarantine flag from `root` and every file/symlink beneath
    /// it. Best-effort: a missing attribute (ENOATTR) on any one item is not
    /// an error, since most files never had it in the first place.
    static func remove(at root: URL) {
        removeOne(root)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [], errorHandler: nil) else { return }
        for case let url as URL in walker { removeOne(url) }
    }

    private static func removeOne(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, attribute, XATTR_NOFOLLOW) }
        }
    }
}
