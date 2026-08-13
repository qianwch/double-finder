import Foundation

/// Builds a `FileOperation` for Android download (phone → local) or upload
/// (local → phone), mirroring `S3TransferProvider`'s shape: folders are expanded
/// into per-file units by `transferUnitsProvider`, so a slow expansion doesn't
/// delay the progress sheet.
///
/// **`concurrency = 1` on purpose.** libmtp is not thread-safe and every call is
/// funnelled through one serial queue per device, so parallel units would queue
/// up anyway while multiplying the ways a transfer can go wrong.
struct AndroidTransferProvider: TransferProvider {
    enum Direction { case download, upload }

    let device: AndroidDevice
    let direction: Direction

    @MainActor var verb: String {
        direction == .download ? tr("Download") : tr("Upload")
    }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: .copy, sources: items.map { $0.path }, destination: destPath)
        op.customTitle = direction == .download ? tr("Downloading") : tr("Uploading")
        op.currentFile = tr("Preparing…")
        op.indeterminate = true
        op.concurrency = 1

        let sessionID = device.sessionID
        let registry = AndroidDeviceRegistry.shared
        let newName = items.count == 1 ? renameTo : nil
        let dest = destPath

        switch direction {
        case .download:
            op.transferUnitsProvider = {
                var units: [FileOperation.Unit] = []
                for item in items {
                    if item.isDirectory {
                        let rootName = newName ?? item.name
                        let files: [(relative: String, size: Int64)]
                        do {
                            files = try await registry.listTree(sessionID, path: item.path)
                        } catch {
                            // Surface the listing failure as a failing unit rather
                            // than silently transferring nothing.
                            units.append(FileOperation.Unit(label: item.name) { _ in throw error })
                            continue
                        }
                        for file in files {
                            let remote = MTPPath(item.path).raw + "/" + file.relative
                            let local = (dest as NSString)
                                .appendingPathComponent(rootName + "/" + file.relative)
                            units.append(Self.downloadUnit(registry: registry, sessionID: sessionID,
                                                           remote: remote, local: local,
                                                           size: file.size))
                        }
                    } else {
                        let local = (dest as NSString).appendingPathComponent(newName ?? item.name)
                        units.append(Self.downloadUnit(registry: registry, sessionID: sessionID,
                                                       remote: item.path, local: local,
                                                       size: item.size))
                    }
                }
                return units
            }

        case .upload:
            op.transferUnitsProvider = {
                var units: [FileOperation.Unit] = []
                let fm = FileManager.default
                for item in items {
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: item.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        let root = item.path
                        let rootName = newName ?? item.name
                        let subs = (fm.subpaths(atPath: root) ?? []).filter { sub in
                            var d: ObjCBool = false
                            fm.fileExists(atPath: (root as NSString).appendingPathComponent(sub),
                                          isDirectory: &d)
                            return !d.boolValue
                        }
                        for sub in subs {
                            let full = (root as NSString).appendingPathComponent(sub)
                            let remoteDir = MTPPath(dest).appending(rootName).raw
                                + ((sub as NSString).deletingLastPathComponent.isEmpty
                                   ? "" : "/" + (sub as NSString).deletingLastPathComponent)
                            units.append(Self.uploadUnit(registry: registry, sessionID: sessionID,
                                                         local: full, remoteDir: remoteDir,
                                                         name: (sub as NSString).lastPathComponent,
                                                         size: FileOperation.sizeOnDisk(full)))
                        }
                    } else {
                        units.append(Self.uploadUnit(registry: registry, sessionID: sessionID,
                                                     local: item.path, remoteDir: MTPPath(dest).raw,
                                                     name: newName ?? item.name,
                                                     size: FileOperation.sizeOnDisk(item.path)))
                    }
                }
                return units
            }
        }

        return op
    }

    /// libmtp's progress callback counts PTP container overhead as well as file
    /// bytes, so a raw pass-through overshoots the unit size and pushes the bar
    /// past 100%. Clamping keeps the sheet honest.
    private static func clamped(_ size: Int64,
                                _ report: @escaping @Sendable (Int64) -> Void)
    -> (@Sendable (Int64) -> Void) {
        let sent = Box()
        return { delta in
            let room = max(0, size - sent.value)
            let capped = min(delta, room)
            guard capped > 0 else { return }
            sent.value += capped
            report(capped)
        }
    }

    /// Mutable counter shared with the `@Sendable` reporter. Only ever touched
    /// from the device's serial queue, which the transfer runs on.
    private final class Box: @unchecked Sendable {
        var value: Int64 = 0
    }

    private static func downloadUnit(registry: AndroidDeviceRegistry, sessionID: String,
                                     remote: String, local: String, size: Int64)
    -> FileOperation.Unit {
        FileOperation.Unit(label: (remote as NSString).lastPathComponent, bytes: size) { report in
            let dir = (local as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try await registry.download(sessionID, path: remote, to: local,
                                        progress: clamped(size, report))
        }
    }

    private static func uploadUnit(registry: AndroidDeviceRegistry, sessionID: String,
                                   local: String, remoteDir: String, name: String, size: Int64)
    -> FileOperation.Unit {
        FileOperation.Unit(label: name, bytes: size) { report in
            try await registry.ensureDirectory(sessionID, path: remoteDir)
            try await registry.upload(sessionID, localPath: local, toDir: remoteDir, as: name,
                                      progress: clamped(size, report))
        }
    }
}

// MARK: - AndroidSameDeviceProvider

/// Copy/move **within one phone**: `LIBMTP_Copy_Object` / `LIBMTP_Move_Object`
/// run entirely on the device, so 20 MB lands in a few hundredths of a second
/// instead of crossing USB twice. Mirrors `SFTPSameHostProvider`'s role.
///
/// Not every MTP implementation supports these, so a refusal degrades to a
/// download-to-temp-then-upload relay rather than failing the operation.
struct AndroidSameDeviceProvider: TransferProvider {
    let device: AndroidDevice
    let move: Bool

    @MainActor var verb: String { move ? tr("Move") : tr("Copy") }

    @MainActor
    func makeOperation(items: [FileItem], destPath: String, renameTo: String?) -> FileOperation {
        let op = FileOperation(type: move ? .move : .copy,
                               sources: items.map { $0.path }, destination: destPath)
        op.customTitle = move ? tr("Moving") : tr("Copying")
        op.currentFile = tr("Preparing…")
        op.indeterminate = true
        op.concurrency = 1

        let sessionID = device.sessionID
        let registry = AndroidDeviceRegistry.shared
        let move = self.move
        let dest = destPath
        let newName = items.count == 1 ? renameTo : nil

        op.transferUnitsProvider = {
            items.map { item in
                FileOperation.Unit(label: newName ?? item.name, bytes: item.size) { report in
                    do {
                        try await registry.transferOnDevice(sessionID, path: item.path,
                                                            toDir: dest, move: move)
                        // Rename-on-transfer isn't part of MTP's copy/move, so
                        // it's a second step once the object is in place.
                        if let newName = newName {
                            try await registry.rename(sessionID,
                                                      path: MTPPath(dest).appending(item.name).raw,
                                                      to: newName)
                        }
                    } catch is MTPOnDeviceUnsupported {
                        try await Self.relayThroughTemp(registry: registry, sessionID: sessionID,
                                                        item: item, dest: dest,
                                                        name: newName ?? item.name, move: move)
                    }
                    report(item.size)
                }
            }
        }
        return op
    }

    /// Fallback for devices without CopyObject/MoveObject: pull to a temp file,
    /// push it back to the destination, then delete the source for a move.
    private static func relayThroughTemp(registry: AndroidDeviceRegistry, sessionID: String,
                                         item: FileItem, dest: String, name: String,
                                         move: Bool) async throws {
        guard !item.isDirectory else {
            throw MTPError(message: "This device can't copy folders on its own")
        }
        let temp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("df-mtp-relay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try await registry.download(sessionID, path: item.path, to: temp, progress: { _ in })
        try await registry.upload(sessionID, localPath: temp, toDir: dest, as: name,
                                  progress: { _ in })
        if move { try await registry.delete(sessionID, path: item.path) }
    }
}
