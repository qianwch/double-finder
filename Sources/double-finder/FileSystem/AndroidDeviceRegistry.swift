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
                shared.close(first.sessionID)
                print("session closed cleanly")
            } catch {
                print("open failed: \(error.localizedDescription)")
            }
        }
        sem.wait()
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
