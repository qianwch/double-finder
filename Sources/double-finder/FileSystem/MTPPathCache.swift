import Foundation

/// MTP's real address for anything on a device: a `(storage, object)` pair.
struct MTPNode: Equatable, Hashable {
    let storageID: UInt32
    let objectID: UInt32

    /// MTP's "root of this storage" parent handle (`LIBMTP_FILES_AND_FOLDERS_ROOT`).
    static let rootObjectID: UInt32 = 0xFFFFFFFF
}

struct MTPNotFoundError: LocalizedError {
    let path: String
    // Not localized here: FS errors are thrown off the main actor and get `tr()`-ed
    // at the presentation layer, per the project's i18n rule.
    var errorDescription: String? { "No such file or directory on the device: \(path)" }
}

/// Maps virtual paths (`MTPPath`) to MTP `(storage, object)` addresses.
///
/// Browsing fills this in as a side effect of listing. On a miss — a typed path,
/// a restored startup path, a favorite — `resolve` walks down from the deepest
/// cached ancestor one directory at a time, caching every sibling it sees along
/// the way. The listing step is injected, so this type stays pure and testable;
/// the real one calls `LIBMTP_Get_Files_And_Folders`.
///
/// Not thread-safe on its own: all access goes through the owning device's
/// serial queue in `AndroidDeviceRegistry`.
final class MTPPathCache {
    private var map: [String: MTPNode] = [:]

    func record(path: String, node: MTPNode) {
        map[MTPPath(path).raw] = node
    }

    func cached(_ path: String) -> MTPNode? {
        map[MTPPath(path).raw]
    }

    /// Drops `path` and everything below it. Required after delete / rename /
    /// move, where stale ids would otherwise address objects that are gone.
    func invalidate(_ path: String) {
        let root = MTPPath(path).raw
        let prefix = root == "/" ? "/" : root + "/"
        map = map.filter { $0.key != root && !$0.key.hasPrefix(prefix) }
    }

    func removeAll() { map.removeAll() }

    /// Resolves a path to its MTP address, walking down from the deepest cached
    /// ancestor. `listing` returns one directory's immediate children.
    func resolve(_ path: String,
                 listing: (MTPNode, String) async throws -> [(name: String, id: UInt32, isDir: Bool)])
    async throws -> MTPNode {
        let target = MTPPath(path)
        if let hit = cached(target.raw) { return hit }
        guard let storage = target.storageName else { throw MTPNotFoundError(path: path) }

        // The storage root is recorded when the device's storages are enumerated;
        // without it there's nothing to walk down from.
        let storageRootPath = "/" + storage
        guard var node = cached(storageRootPath) else { throw MTPNotFoundError(path: path) }

        var walked = storageRootPath
        for segment in target.segments {
            let childPath = walked + "/" + segment
            if let hit = cached(childPath) {
                node = hit
                walked = childPath
                continue
            }
            let children = try await listing(node, walked)
            for child in children {
                record(path: walked + "/" + child.name,
                       node: MTPNode(storageID: node.storageID, objectID: child.id))
            }
            guard let match = children.first(where: { $0.name == segment }) else {
                throw MTPNotFoundError(path: childPath)
            }
            node = MTPNode(storageID: node.storageID, objectID: match.id)
            walked = childPath
        }
        return node
    }
}
