import Foundation
import Clibmtp

/// One Android device reachable over MTP.
///
/// Unlike SFTP/S3 there is nothing to save in an address book — no host, no
/// credentials, no port. The identity *is* the cable, so this is never persisted
/// and lives only as long as the device stays plugged in.
///
/// Identified by USB location (bus + device number) rather than serial number:
/// the serial requires opening a session, which costs seconds and claims the USB
/// interface exclusively — far too expensive for the connection sheet's device
/// list. The friendly name and serial are read once the session is open and kept
/// in `AndroidDeviceRegistry`.
struct AndroidDevice: Equatable {
    /// libmtp's vendor string from its device database (e.g. "Samsung").
    let vendor: String
    /// libmtp's product string (e.g. "Galaxy models (MTP)").
    let product: String
    let vendorID: UInt16
    let productID: UInt16
    let busLocation: UInt32
    let devNumber: UInt8
    /// Index into the raw-device array of the scan this came from.
    let rawIndex: Int

    /// Stable within one plug-in; re-plugging renumbers the device, which is
    /// correct — the old session is dead anyway.
    var usbKey: String {
        String(format: "%04x:%04x@%u-%u", vendorID, productID, busLocation, UInt32(devNumber))
    }

    /// Drive-bar / session identity.
    var sessionID: String { "mtp://\(usbKey)" }

    /// Label for the connection sheet's device list, before a session exists.
    var displayName: String {
        let head = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        return head.isEmpty ? usbKey : head
    }
}

/// What the device reports once a session is open — nothing here is available
/// from a plain USB enumeration.
struct AndroidDeviceInfo: Equatable {
    /// User-set device name (e.g. "卫春 的 S25 Edge"); may be empty.
    let friendlyName: String
    let model: String
    let serial: String
    /// True when the device implements `GetPartialObject`, which lets the viewer
    /// read a chunk of a big file instead of downloading all of it.
    let supportsPartialRead: Bool

    /// Best available human label, preferring what the user named the phone.
    var label: String {
        if !friendlyName.isEmpty { return friendlyName }
        if !model.isEmpty { return model }
        return serial
    }
}

enum AndroidDeviceScanner {
    /// Enumerates plugged-in MTP devices without opening any session, so this is
    /// cheap enough for a Refresh button.
    static func detect() -> [AndroidDevice] {
        LIBMTP_Init()
        // Silences libmtp's debug channel. It does NOT silence the
        // "Device N (VID=… and PID=…) is a …" line that detection prints
        // unconditionally with printf — libmtp exposes no way to turn that off.
        // It only reaches stdout, which is invisible in a packaged .app.
        LIBMTP_Set_Debug(0)
        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        guard LIBMTP_Detect_Raw_Devices(&raw, &count) == LIBMTP_ERROR_NONE,
              let list = raw, count > 0 else { return [] }
        defer { free(list) }

        return (0..<Int(count)).map { (i: Int) -> AndroidDevice in
            let entry = list[i]
            return AndroidDevice(
                vendor: entry.device_entry.vendor.map { String(cString: $0) } ?? "",
                product: entry.device_entry.product.map { String(cString: $0) } ?? "",
                vendorID: entry.device_entry.vendor_id,
                productID: entry.device_entry.product_id,
                busLocation: entry.bus_location,
                devNumber: entry.devnum,
                rawIndex: i)
        }
    }

}
