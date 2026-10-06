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

    func exportItem(at path: String, toLocalDirectory directory: URL,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        _ = try FileContentTransfer.localPath(directory)
        let source = MTPPath(path)
        guard let parent = source.parent,
              let item = try await registry.list(sessionID, path: parent.raw).first(where: { $0.name == source.name }) else {
            throw FSUnsupportedError(message: "No such file on the device")
        }
        let local = try await FileContentTransfer.prepareDirectory(directory)
        try FileContentTransfer.validateLeaf(source.name)
        let target = URL(fileURLWithPath: local).appendingPathComponent(source.name)
        if item.isDirectory {
            _ = try await FileContentTransfer.prepareDirectory(target)
            for child in try await registry.list(sessionID, path: source.raw) {
                try Task.checkCancellation()
                try await exportItem(at: child.path, toLocalDirectory: target, progress: progress)
            }
        } else {
            try Task.checkCancellation()
            try await registry.download(sessionID, path: path, to: target.path, progress: progress)
        }
    }

    func importItem(from localURL: URL, toPath destinationPath: String,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        let local = try FileContentTransfer.localPath(localURL)
        let target = try FileContentTransfer.destination(destinationPath)
        let isDir = try await FileContentTransfer.isLocalDirectory(localURL)
        let existing = try await registry.list(sessionID, path: target.parent).first { $0.name == target.name }
        if let existing, existing.isDirectory != isDir {
            throw FSUnsupportedError(message: "The destination has a different file type")
        }
        try Task.checkCancellation()
        if isDir {
            if existing == nil { try await registry.createDirectory(sessionID, path: destinationPath) }
            for child in try await FileContentTransfer.localChildren(localURL) {
                let destination = MTPPath(destinationPath).appending(child.lastPathComponent).raw
                try await importItem(from: child, toPath: destination, progress: progress)
            }
        } else {
            try await registry.upload(sessionID, localPath: local, toDir: target.parent,
                                      as: target.name, progress: progress)
        }
    }

    /// Compatibility content-read API; never infers upload from local existence.
    func copy(from: String, to: String) async throws {
        try await exportItem(at: from, toLocalDirectory: URL(fileURLWithPath: to), progress: { _ in })
    }

    func move(from: String, to: String) async throws {
        try FileContentTransfer.validateWithinTransfer(from: from, toDirectory: to)
        try Task.checkCancellation()
        do {
            try await registry.transferOnDevice(sessionID, path: from, toDir: to, move: true)
        } catch is MTPOnDeviceUnsupported {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DoubleFinder-MTPRelay/" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await exportItem(at: from, toLocalDirectory: temporary, progress: { _ in })
            let name = MTPPath(from).name
            try await importItem(from: temporary.appendingPathComponent(name),
                                 toPath: MTPPath(to).appending(name).raw, progress: { _ in })
            try Task.checkCancellation()
            try await delete(from)
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
