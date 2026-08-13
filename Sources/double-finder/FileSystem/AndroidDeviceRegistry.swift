import Foundation
import Clibmtp

/// Errors surfaced to the UI. Messages stay in English here and are `tr()`-ed at
/// the presentation layer (`presentLocalizedError`), per the project's i18n rule.
struct MTPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// The USB interface is held by another process. On macOS the usual culprit
    /// is **Google Chrome** (WebUSB / chrome://inspect grabs Android devices and
    /// keeps them), followed by `ptpcamerad` — macOS treats the MTP interface as
    /// a camera because MTP rides on USB class 6 (PTP) — then Android File
    /// Transfer / OpenMTP.
    static let deviceBusy = MTPError(message:
        "Another program is using the phone. Quit Google Chrome, Android File Transfer or Image Capture, then reconnect.")
    static let openFailed = MTPError(message:
        "Can't open the phone. Unlock it and set the USB connection to \"File transfer\".")
    /// Session opened but no storage came back — on Android this means the phone
    /// is still locked or the "Allow access to phone data" prompt is unanswered.
    static let noStorage = MTPError(message:
        "The phone exposed no storage. Unlock it and tap \"Allow\" on the phone, then reconnect.")
    static let disconnected = MTPError(message: "The phone was disconnected.")
}

/// Owns the open `LIBMTP_mtpdevice_t*` sessions, one per device.
///
/// **Why a registry instead of building an FS per access like `SFTPFS`:**
/// `PanelState.fs` is a *computed property* — it runs on every access. Opening
/// an MTP session costs seconds and claims the USB interface exclusively, so
/// sessions must outlive any single FS object. `AndroidFS` is a thin shell that
/// forwards here.
///
/// **libmtp is not thread-safe**: every call for a given device is funnelled
/// through that device's serial queue.
final class AndroidDeviceRegistry: @unchecked Sendable {
    static let shared = AndroidDeviceRegistry()

    /// `@unchecked Sendable`: every mutable member is only ever touched from
    /// `queue`, the per-device serial queue that `perform` funnels all work
    /// through. That serialization *is* the thread-safety story here, because
    /// libmtp itself has none.
    private final class Session: @unchecked Sendable {
        let device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
        let queue: DispatchQueue
        let cache = MTPPathCache()
        var info: AndroidDeviceInfo
        /// Storage list, refreshed on connect. Also drives the status bar's
        /// free-space note.
        var storages: [MTPStorage] = []

        init(device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, key: String, info: AndroidDeviceInfo) {
            self.device = device
            self.info = info
            self.queue = DispatchQueue(label: "net.qian.double-finder.mtp.\(key)")
        }
    }

    private var sessions: [String: Session] = [:]
    private let lock = NSLock()

    private func session(for id: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    func isOpen(_ sessionID: String) -> Bool { session(for: sessionID) != nil }

    func info(_ sessionID: String) -> AndroidDeviceInfo? { session(for: sessionID)?.info }

    func storages(_ sessionID: String) -> [MTPStorage] { session(for: sessionID)?.storages ?? [] }

    // MARK: - Session lifecycle

    /// Opens a device and keeps the session alive until `close`.
    ///
    /// Uses **`LIBMTP_Open_Raw_Device_Uncached`**: the cached variant pre-loads
    /// the entire object tree up front, which stalls for minutes on a phone
    /// holding tens of thousands of photos.
    @discardableResult
    func open(_ device: AndroidDevice) async throws -> AndroidDeviceInfo {
        if let existing = session(for: device.sessionID) { return existing.info }

        let info: AndroidDeviceInfo = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                LIBMTP_Init()
                LIBMTP_Set_Debug(0)

                var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
                var count: Int32 = 0
                guard LIBMTP_Detect_Raw_Devices(&raw, &count) == LIBMTP_ERROR_NONE,
                      let list = raw, Int(count) > 0 else {
                    cont.resume(throwing: MTPError.disconnected); return
                }
                defer { free(list) }

                // Re-find by USB location: the index from the caller's scan may
                // be stale if devices were plugged/unplugged since.
                var index = -1
                for i in 0..<Int(count) where list[i].bus_location == device.busLocation
                    && list[i].devnum == device.devNumber {
                    index = i
                }
                guard index >= 0 else {
                    cont.resume(throwing: MTPError.disconnected); return
                }
                guard let dev = LIBMTP_Open_Raw_Device_Uncached(&list[index]) else {
                    cont.resume(throwing: MTPError.deviceBusy); return
                }

                let info = AndroidDeviceInfo(
                    friendlyName: Self.takeString(LIBMTP_Get_Friendlyname(dev)),
                    model: Self.takeString(LIBMTP_Get_Modelname(dev)),
                    serial: Self.takeString(LIBMTP_Get_Serialnumber(dev)),
                    supportsPartialRead:
                        LIBMTP_Check_Capability(dev, LIBMTP_DEVICECAP_GetPartialObject) != 0)

                let s = Session(device: dev, key: device.usbKey, info: info)
                self.lock.lock(); self.sessions[device.sessionID] = s; self.lock.unlock()
                cont.resume(returning: info)
            }
        }

        try await refreshStorages(device.sessionID)
        guard !storages(device.sessionID).isEmpty else {
            // A locked phone opens fine but exposes nothing — don't leave a
            // useless session (and the USB claim) behind.
            close(device.sessionID)
            throw MTPError.noStorage
        }
        return info
    }

    func close(_ sessionID: String) {
        lock.lock()
        let s = sessions.removeValue(forKey: sessionID)
        lock.unlock()
        guard let s = s else { return }
        s.queue.sync { LIBMTP_Release_Device(s.device) }
    }

    func closeAll() {
        lock.lock()
        let all = sessions
        sessions.removeAll()
        lock.unlock()
        for (_, s) in all { s.queue.sync { LIBMTP_Release_Device(s.device) } }
    }

    /// libmtp hands out malloc'd strings that the caller owns.
    private static func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p = p else { return "" }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: - Serial execution

    /// Runs `body` on the device's serial queue — the single funnel through which
    /// every libmtp call must pass, since the library is not thread-safe.
    private func perform<T>(_ sessionID: String,
                            _ body: @escaping (Session) throws -> T) async throws -> T {
        guard let s = session(for: sessionID) else { throw MTPError.disconnected }
        return try await withCheckedThrowingContinuation { cont in
            s.queue.async {
                do { cont.resume(returning: try body(s)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - Storages

    func refreshStorages(_ sessionID: String) async throws {
        try await perform(sessionID) { s in
            LIBMTP_Get_Storage(s.device, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED))
            var out: [MTPStorage] = []
            var cur = s.device.pointee.storage
            var index = 0
            while let st = cur {
                let described = st.pointee.StorageDescription.map { String(cString: $0) } ?? ""
                // Some devices report an empty description; keep a stable label
                // so the virtual path stays addressable.
                let name = MTPPath.sanitizeStorageName(
                    described.isEmpty ? "Storage \(index + 1)" : described)
                out.append(MTPStorage(id: st.pointee.id, name: name,
                                      freeBytes: Int64(bitPattern: st.pointee.FreeSpaceInBytes),
                                      capacityBytes: Int64(bitPattern: st.pointee.MaxCapacity)))
                s.cache.record(path: "/" + name,
                               node: MTPNode(storageID: st.pointee.id,
                                             objectID: MTPNode.rootObjectID))
                cur = st.pointee.next
                index += 1
            }
            s.storages = out
        }
    }
}

// MARK: - Listing

extension AndroidDeviceRegistry {
    /// One directory's immediate children.
    ///
    /// `LIBMTP_Get_Files_And_Folders` is the only listing call that doesn't walk
    /// the whole tree — the reason sessions are opened *uncached*.
    fileprivate static func children(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>,
                                     node: MTPNode) -> [MTPChild] {
        var out: [MTPChild] = []
        var f = LIBMTP_Get_Files_And_Folders(device, node.storageID, node.objectID)
        while let file = f {
            let name = file.pointee.filename.map { String(cString: $0) } ?? ""
            if !name.isEmpty {
                out.append(MTPChild(
                    name: name,
                    id: file.pointee.item_id,
                    isDir: file.pointee.filetype == LIBMTP_FILETYPE_FOLDER,
                    size: Int64(bitPattern: file.pointee.filesize),
                    modified: Date(timeIntervalSince1970: TimeInterval(file.pointee.modificationdate))))
            }
            let next = file.pointee.next
            LIBMTP_destroy_file_t(file)
            f = next
        }
        return out
    }

    /// Lists a virtual path. The device root enumerates storages as folders.
    func list(_ sessionID: String, path: String) async throws -> [FileItem] {
        if MTPPath(path).isDeviceRoot {
            return storages(sessionID).map { st in
                FileItem(id: UUID(), name: st.name, path: "/" + st.name,
                         isDirectory: true, isArchive: false, size: 0, modified: Date(),
                         isHidden: false, isSymlink: false, permissions: "drwxr-xr-x")
            }
        }
        return try await perform(sessionID) { s in
            let node = try s.cache.resolve(path) { parent, _ in
                Self.children(s.device, node: parent).map {
                    (name: $0.name, id: $0.id, isDir: $0.isDir)
                }
            }
            let base = MTPPath(path)
            return Self.children(s.device, node: node).map { child in
                let childPath = base.appending(child.name).raw
                s.cache.record(path: childPath,
                               node: MTPNode(storageID: node.storageID, objectID: child.id))
                return FileItem(
                    id: UUID(), name: child.name, path: childPath,
                    isDirectory: child.isDir,
                    isArchive: FileItem.isArchiveFileName(child.name),
                    size: child.size, modified: child.modified,
                    // MTP has no POSIX metadata: dot-files are the only notion of
                    // "hidden", there are no symlinks, and the permission column
                    // is synthesized so the UI has something consistent to show.
                    isHidden: child.name.hasPrefix("."),
                    isSymlink: false,
                    permissions: child.isDir ? "drwxr-xr-x" : "-rw-r--r--")
            }
        }
    }
}

// MARK: - Mutations

extension AndroidDeviceRegistry {
    /// Resolves a path on the session's queue (caller must already be on it).
    private static func resolve(_ s: Session, path: String) throws -> MTPNode {
        try s.cache.resolve(path) { parent, _ in
            children(s.device, node: parent).map { (name: $0.name, id: $0.id, isDir: $0.isDir) }
        }
    }

    func createDirectory(_ sessionID: String, path: String) async throws {
        try await perform(sessionID) { s in
            let p = MTPPath(path)
            guard let parentPath = p.parent?.raw, !p.isDeviceRoot else {
                throw MTPError(message: "Can't create a folder here")
            }
            let parent = try Self.resolve(s, path: parentPath)
            // LIBMTP_Create_Folder takes a mutable C string and returns the new
            // object id, or 0 on failure.
            var name = Array(p.name.utf8CString)
            let id = name.withUnsafeMutableBufferPointer { buf in
                LIBMTP_Create_Folder(s.device, buf.baseAddress, parent.objectID, parent.storageID)
            }
            guard id != 0 else {
                throw MTPError(message: "Could not create the folder on the device")
            }
            s.cache.record(path: p.raw, node: MTPNode(storageID: parent.storageID, objectID: id))
        }
    }

    func delete(_ sessionID: String, path: String) async throws {
        try await perform(sessionID) { s in
            let node = try Self.resolve(s, path: path)
            try Self.deleteRecursive(s, node: node, name: MTPPath(path).name)
            s.cache.invalidate(path)
        }
    }

    /// MTP's DeleteObject refuses a non-empty folder, so children go first,
    /// depth-first.
    private static func deleteRecursive(_ s: Session, node: MTPNode, name: String) throws {
        for child in children(s.device, node: node) {
            if child.isDir {
                try deleteRecursive(s, node: MTPNode(storageID: node.storageID, objectID: child.id),
                                    name: child.name)
            } else if LIBMTP_Delete_Object(s.device, child.id) != 0 {
                throw MTPError(message: "Could not delete \(child.name) on the device")
            }
        }
        if LIBMTP_Delete_Object(s.device, node.objectID) != 0 {
            throw MTPError(message: "Could not delete \(name) on the device")
        }
    }

    func rename(_ sessionID: String, path: String, to newName: String) async throws {
        try await perform(sessionID) { s in
            let node = try Self.resolve(s, path: path)
            guard let meta = LIBMTP_Get_Filemetadata(s.device, node.objectID) else {
                throw MTPError(message: "Could not read the item on the device")
            }
            defer { LIBMTP_destroy_file_t(meta) }

            // Folders and files rename through different libmtp entry points.
            let rc: Int32
            if meta.pointee.filetype == LIBMTP_FILETYPE_FOLDER {
                guard let folder = LIBMTP_new_folder_t() else {
                    throw MTPError(message: "Could not rename the folder on the device")
                }
                defer { LIBMTP_destroy_folder_t(folder) }
                folder.pointee.folder_id = node.objectID
                folder.pointee.parent_id = meta.pointee.parent_id
                folder.pointee.storage_id = node.storageID
                rc = LIBMTP_Set_Folder_Name(s.device, folder, newName)
            } else {
                rc = LIBMTP_Set_File_Name(s.device, meta, newName)
            }
            guard rc == 0 else {
                throw MTPError(message: "Could not rename \(MTPPath(path).name) on the device")
            }
            // The object keeps its id but changes address; drop the old subtree
            // and record the new name.
            s.cache.invalidate(path)
            if let parent = MTPPath(path).parent {
                s.cache.record(path: parent.appending(newName).raw, node: node)
            }
        }
    }
}

/// A raw child entry as libmtp reports it.
struct MTPChild {
    let name: String
    let id: UInt32
    let isDir: Bool
    let size: Int64
    let modified: Date
}

// MARK: - Transfers

/// Carries a Swift progress closure through libmtp's C callback.
///
/// `LIBMTP_progressfunc_t` is a bare C function pointer, so it cannot capture
/// anything: the closure travels in the callback's `userdata` as an unmanaged
/// pointer to this box. Also doubles as the cancel channel — returning non-zero
/// from the callback aborts the transfer.
private final class MTPProgressBox {
    let report: (Int64) -> Void
    var lastSent: UInt64 = 0
    var cancelled = false
    init(report: @escaping (Int64) -> Void) { self.report = report }
}

/// Reports byte *deltas*, matching what `FileOperation`'s reporter expects.
private let mtpProgressCallback: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data = data else { return 0 }
    let box = Unmanaged<MTPProgressBox>.fromOpaque(data).takeUnretainedValue()
    if sent > box.lastSent {
        box.report(Int64(sent - box.lastSent))
        box.lastSent = sent
    }
    return box.cancelled ? 1 : 0   // non-zero aborts the transfer
}

extension AndroidDeviceRegistry {
    /// Downloads one file to a local path.
    func download(_ sessionID: String, path: String, to localPath: String,
                  progress: @escaping (Int64) -> Void) async throws {
        try await perform(sessionID) { s in
            let node = try Self.resolve(s, path: path)
            let box = MTPProgressBox(report: progress)
            let rc = LIBMTP_Get_File_To_File(s.device, node.objectID, localPath,
                                             mtpProgressCallback,
                                             Unmanaged.passUnretained(box).toOpaque())
            guard rc == 0 else {
                throw MTPError(message: "Could not download \(MTPPath(path).name) from the device")
            }
        }
    }

    /// Uploads one local file into `destDir` on the device.
    ///
    /// Deletes same-named objects first: MTP is an object tree and happily keeps
    /// duplicates, which would leave the phone with two identical names.
    func upload(_ sessionID: String, localPath: String, toDir destDir: String,
                as name: String, progress: @escaping (Int64) -> Void) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? 0
        try await perform(sessionID) { s in
            let parent = try Self.resolve(s, path: destDir)

            for id in MTPConflict.objectsToReplace(
                named: name,
                in: Self.children(s.device, node: parent).map {
                    (name: $0.name, id: $0.id, isDir: $0.isDir)
                }) {
                _ = LIBMTP_Delete_Object(s.device, id)
            }

            guard let meta = LIBMTP_new_file_t() else {
                throw MTPError(message: "Out of memory preparing the upload")
            }
            defer { LIBMTP_destroy_file_t(meta) }
            meta.pointee.filesize = UInt64(max(0, size))
            meta.pointee.filename = strdup(name)
            meta.pointee.parent_id = parent.objectID
            meta.pointee.storage_id = parent.storageID
            meta.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN

            let box = MTPProgressBox(report: progress)
            let rc = LIBMTP_Send_File_From_File(s.device, localPath, meta,
                                                mtpProgressCallback,
                                                Unmanaged.passUnretained(box).toOpaque())
            guard rc == 0 else {
                throw MTPError(message: "Could not upload \(name) to the device")
            }
            s.cache.record(path: MTPPath(destDir).appending(name).raw,
                           node: MTPNode(storageID: parent.storageID, objectID: meta.pointee.item_id))
        }
    }
}

// MARK: - Diagnostic

extension AndroidDeviceRegistry {
    /// Prints what libmtp can see and how far a session gets (driven by
    /// `NC_MTP_DIAG`). Mirrors `ZipFS.runDiagnostic`: MTP failures are nearly
    /// always environmental, so users can run this and paste the output.
    static func runDiagnostic() {
        let devices = AndroidDeviceScanner.detect()
        print("libmtp raw devices: \(devices.count)")
        for d in devices {
            print("  \(d.displayName)  [\(d.usbKey)]  session=\(d.sessionID)")
        }
        guard let first = devices.first else {
            print("  no device — unlock the phone and set USB mode to \"File transfer\"")
            return
        }

        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                let info = try await shared.open(first)
                print("opened: \(info.label)  model=\(info.model) serial=\(info.serial)")
                print("partial read (GetPartialObject): \(info.supportsPartialRead)")
                for st in shared.storages(first.sessionID) {
                    print("  storage \(st.id): \"\(st.name)\" free=\(st.freeBytes) cap=\(st.capacityBytes)")
                }
                for st in shared.storages(first.sessionID) {
                    let items = try await shared.list(first.sessionID, path: "/" + st.name)
                    print("  \"/\(st.name)\" -> \(items.count) entries")
                    for item in items.prefix(8) {
                        print("      \(item.name)\(item.isDirectory ? "/" : "")  \(item.size) bytes")
                    }
                    // Descend two levels to exercise MTPPathCache's lazy
                    // root-down resolution against a real device.
                    guard let dir = items.first(where: { $0.isDirectory }) else { continue }
                    let sub = try await shared.list(first.sessionID, path: dir.path)
                    print("  deep: \"\(dir.path)\" -> \(sub.count) entries")
                    if let dir2 = sub.first(where: { $0.isDirectory }) {
                        let sub2 = try await shared.list(first.sessionID, path: dir2.path)
                        print("  deep: \"\(dir2.path)\" -> \(sub2.count) entries")
                    }
                }
                if ProcessInfo.processInfo.environment["NC_MTP_DIAG"] == "write" {
                    try await runWriteChecks(first.sessionID)
                }
                shared.close(first.sessionID)
                print("session closed cleanly")
            } catch {
                print("open failed: \(error.localizedDescription)")
            }
        }
        sem.wait()
    }

    /// Exercises mkdir / rename / recursive delete on a scratch folder.
    /// Only runs with `NC_MTP_DIAG=write`, since it writes to a real phone.
    /// Everything it creates is removed again.
    private static func runWriteChecks(_ sessionID: String) async throws {
        guard let storage = shared.storages(sessionID).first else { return }
        let root = "/\(storage.name)/DFWriteTest"
        print("write checks in \(root)")

        try await shared.createDirectory(sessionID, path: root)
        try await shared.createDirectory(sessionID, path: root + "/sub")
        try await shared.createDirectory(sessionID, path: root + "/sub/深层 目录")
        print("  created nested folders (incl. Chinese + space)")

        try await shared.rename(sessionID, path: root + "/sub", to: "renamed")
        let afterRename = try await shared.list(sessionID, path: root)
        print("  after rename: \(afterRename.map { $0.name })")

        // The nested child must still be reachable under the new parent name —
        // proves the path cache was invalidated and re-resolved correctly.
        let deep = try await shared.list(sessionID, path: root + "/renamed")
        print("  under renamed: \(deep.map { $0.name })")

        try await runTransferChecks(sessionID, root: root)

        // Recursive delete: MTP would refuse this folder as non-empty.
        try await shared.delete(sessionID, path: root)
        let storageRoot = try await shared.list(sessionID, path: "/\(storage.name)")
        let leftover = storageRoot.contains { $0.name == "DFWriteTest" }
        print("  recursive delete: \(leftover ? "FAILED — leftover" : "clean")")
    }

    /// Round-trips a file: upload with progress, upload again (duplicate check),
    /// download, compare bytes.
    private static func runTransferChecks(_ sessionID: String, root: String) async throws {
        let tmp = NSTemporaryDirectory()
        let srcPath = (tmp as NSString).appendingPathComponent("df-mtp-上传测试.bin")
        let backPath = (tmp as NSString).appendingPathComponent("df-mtp-back.bin")
        defer {
            try? FileManager.default.removeItem(atPath: srcPath)
            try? FileManager.default.removeItem(atPath: backPath)
        }

        // 20 MB of non-repeating data — big enough for several progress ticks.
        var payload = Data(count: 20 << 20)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<raw.count { base[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        }
        try payload.write(to: URL(fileURLWithPath: srcPath))
        let name = "上传测试.bin"

        var ticks = 0
        var sent: Int64 = 0
        try await shared.upload(sessionID, localPath: srcPath, toDir: root, as: name) { delta in
            ticks += 1; sent += delta
        }
        print("  upload: \(sent) bytes in \(ticks) progress ticks (expected \(payload.count))")

        // Second upload of the same name must replace, not duplicate.
        try await shared.upload(sessionID, localPath: srcPath, toDir: root, as: name) { _ in }
        let listing = try await shared.list(sessionID, path: root)
        let dupes = listing.filter { $0.name == name }.count
        print("  duplicate check: \(dupes) object(s) named \(name) — \(dupes == 1 ? "ok" : "FAILED")")

        var got: Int64 = 0
        try await shared.download(sessionID, path: root + "/" + name, to: backPath) { got += $0 }
        let round = (try? Data(contentsOf: URL(fileURLWithPath: backPath))) ?? Data()
        print("  download: \(got) bytes, content \(round == payload ? "identical" : "MISMATCH")")
    }
}

/// One storage volume on a device (internal storage, SD card…).
struct MTPStorage: Equatable {
    let id: UInt32
    /// Already sanitized for use as a path component.
    let name: String
    let freeBytes: Int64
    let capacityBytes: Int64
}
