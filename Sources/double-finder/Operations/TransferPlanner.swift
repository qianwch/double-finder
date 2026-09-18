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
