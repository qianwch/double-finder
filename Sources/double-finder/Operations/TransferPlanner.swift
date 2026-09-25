import Foundation

enum TransferRoutingError: LocalizedError, Equatable {
    case unsupportedRemotePair

    var errorDescription: String? {
        "Transfers between these remote locations are not supported. Copy to a local folder first."
    }
}

/// Resolves remote transfer strategies without depending on panels or AppKit.
/// nil means both endpoints are local; the caller selects its local/archive strategy.
enum TransferPlanner {
    /// Preserve selection order, but ignore a selected ancestor when one of its
    /// descendants is also selected (expanded-view semantics).
    static func pruneSelectedAncestors(_ items: [FileItem]) -> [FileItem] {
        let selected = Set(items.map(\.path))
        var ancestors: Set<String> = []
        // Walk path components, not every other selection: O(total path length)
        // for bounded path depth, instead of O(number of selections squared).
        for path in selected {
            for slash in path.indices where path[slash] == "/" {
                let parent = String(path[..<slash])
                if selected.contains(parent) { ancestors.insert(parent) }
            }
        }
        return items.filter { !ancestors.contains($0.path) }
    }

    static func remoteProvider(from source: RemoteSession?, to destination: RemoteSession?,
                               move: Bool) throws -> TransferProvider? {
        switch (source, destination) {
        case (let s?, let d?) where s.sharesNamespace(with: d):
            return s.sameStoreProvider(move: move)
        case (let s?, let d?):
            // A download provider accepts a LOCAL destination. Passing another
            // remote's path to it can write to the wrong disk and, for a move,
            // delete the source after that misplaced copy succeeds.
            guard let provider = s.crossStoreProvider(to: d) else {
                throw TransferRoutingError.unsupportedRemotePair
            }
            return provider
        case (let s?, nil):
            return s.transferProvider(download: true)
        case (nil, let d?):
            return d.transferProvider(download: false)
        case (nil, nil):
            return nil
        }
    }
}
