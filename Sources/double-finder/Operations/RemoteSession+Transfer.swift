import Foundation

/// Which transfer provider serves a remote session — the one place that maps a
/// backend to its download / upload / same-store strategy. `MainViewController`
/// only decides the direction; adding a backend means adding a case here.
extension RemoteSession {
    /// Server-side (SFTP `cp`/`mv`, S3 copyObject) or on-device (MTP, plugin
    /// `copy`/`move`) transfer, for when both panels share this namespace.
    func sameStoreProvider(move: Bool) -> TransferProvider {
        switch self {
        case .sftp(let c): return SFTPSameHostProvider(connection: c, move: move)
        case .s3(let c, let secret): return S3SameStoreProvider(client: c.makeClient(secret: secret), move: move)
        case .android(let d, _): return AndroidSameDeviceProvider(device: d, move: move)
        case .plugin(let drive): return PluginTransferProvider(drive: drive, mode: .within(move: move))
        }
    }

    /// remote → local (`download`) or local → remote.
    func transferProvider(download: Bool) -> TransferProvider {
        switch self {
        case .sftp(let c): return SFTPTransferProvider(connection: c, direction: download ? .download : .upload)
        case .s3(let c, let secret): return S3TransferProvider(client: c.makeClient(secret: secret), downloading: download)
        case .android(let d, _): return AndroidTransferProvider(device: d, direction: download ? .download : .upload)
        case .plugin(let drive): return PluginTransferProvider(drive: drive, mode: download ? .download : .upload)
        }
    }

    /// Two different stores of the same kind that can relay through a temp file
    /// (today: S3 ↔ S3 across services). nil = unsupported remote pair; the
    /// planner must reject it, never interpret the remote target as local.
    func crossStoreProvider(to other: RemoteSession) -> TransferProvider? {
        if case .s3(let a, let sa) = self, case .s3(let b, let sb) = other {
            return S3CrossStoreProvider(srcClient: a.makeClient(secret: sa), dstClient: b.makeClient(secret: sb))
        }
        return nil
    }
}
