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

    func copy(from: String, to: String) async throws {
        throw FSUnsupportedError(message: "Not implemented yet")
    }

    func move(from: String, to: String) async throws {
        throw FSUnsupportedError(message: "Not implemented yet")
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
