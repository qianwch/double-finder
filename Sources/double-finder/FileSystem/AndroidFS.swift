import Foundation

/// `VirtualFS` over one Android device reached by MTP.
///
/// Deliberately stateless: `PanelState.fs` is a computed property that rebuilds
/// this on every access, so all real state — the open libmtp session, the path
/// cache, the storage list — lives in `AndroidDeviceRegistry` and is keyed by
/// `device.sessionID`.
final class AndroidFS: VirtualFS {
    let device: AndroidDevice
    private(set) var currentPath: String

    init(device: AndroidDevice, currentPath: String) {
        self.device = device
        self.currentPath = currentPath
    }

    private var sessionID: String { device.sessionID }
    private var registry: AndroidDeviceRegistry { .shared }

    func listDirectory(_ path: String) async throws -> [FileItem] {
        try await registry.list(sessionID, path: path)
    }

    /// Space-key folder size. MTP has no `du` and no size-of-subtree property, so
    /// the only way is to walk — `listTree` already does that on the device's
    /// serial queue. Costs one USB round-trip per folder underneath, which is why
    /// `calculateAllFolderSizes` probes Android folders one at a time.
    func directorySize(_ path: String) async -> Int64 {
        guard let files = try? await registry.listTree(sessionID, path: path) else { return 0 }
        return files.reduce(Int64(0)) { $0 + $1.size }
    }

    /// Direction is inferred from `from`, mirroring `S3FS.copy`: a path that
    /// exists on disk is a local source (upload), anything else is a device path
    /// (download). Device paths are virtual (`/内部存储/…`) and never collide
    /// with real local ones.
    ///
    /// `to` is always a *directory* — this is what `materialize` (F3/F4/QuickLook)
    /// and the archive/temp paths rely on.
    func copy(from: String, to: String) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: from) {
            try await AndroidDeviceRegistry.shared.ensureDirectory(sessionID, path: to)
            try await registry.upload(sessionID, localPath: from, toDir: to,
                                      as: (from as NSString).lastPathComponent,
                                      progress: { _ in })
        } else {
            try fm.createDirectory(atPath: to, withIntermediateDirectories: true)
            let dest = (to as NSString).appendingPathComponent(MTPPath(from).name)
            try await registry.download(sessionID, path: from, to: dest, progress: { _ in })
        }
    }

    func move(from: String, to: String) async throws {
        // Both endpoints on the device → let MTP do it without moving bytes.
        if !FileManager.default.fileExists(atPath: from) {
            do {
                try await registry.transferOnDevice(sessionID, path: from, toDir: to, move: true)
                return
            } catch is MTPOnDeviceUnsupported {
                // Fall through to the copy+delete relay below.
            }
        }
        try await copy(from: from, to: to)
        if !FileManager.default.fileExists(atPath: from) {
            try await delete(from)
        } else {
            try FileManager.default.removeItem(atPath: from)
        }
    }

    /// Recursive: MTP refuses to delete a non-empty folder.
    func delete(_ path: String) async throws {
        try await registry.delete(sessionID, path: path)
    }

    func createDirectory(_ path: String) async throws {
        try await registry.createDirectory(sessionID, path: path)
    }

    func rename(at path: String, to newName: String) async throws {
        try await registry.rename(sessionID, path: path, to: newName)
    }

    /// MTP carries no POSIX permissions at all.
    func setPermissions(_ path: String, octal: Int) async throws {
        throw FSUnsupportedError(message: "Changing permissions is not supported on this device")
    }
}
