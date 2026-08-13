import Foundation
import IOKit

/// Answers "who is holding this USB device?" by reading the IO registry.
///
/// When libmtp can't open a phone it only reports `LIBUSB_ERROR_ACCESS` — the
/// interface is claimed, but not by whom. macOS does know: every open handle
/// shows up in the registry as a user-client node **named after the owning
/// process**, which is exactly what `ioreg` prints when diagnosing this by hand:
///
///     +-o SAMSUNG_Android@01100000  <class IOUSBHostDevice>
///       +-o Google Chrome           <class AppleUSBHostDeviceUserClient>
///       +-o MTP@0                   <class IOUSBHostInterface>
///       | +-o ptpcamerad            <class AppleUSBHostInterfaceUserClient>
///
/// Turning that into a name lets the error say "Google Chrome is using the
/// phone" instead of listing three programs it might be.
enum USBOccupancy {
    /// Process names holding a handle on the USB device with this vendor/product
    /// id, covering both device-level and interface-level clients. Empty when
    /// nothing holds it (or the registry can't be read).
    static func holders(vendorID: UInt16, productID: UInt16) -> [String] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var names: [String] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard intProperty(device, "idVendor") == Int(vendorID),
                  intProperty(device, "idProduct") == Int(productID) else { continue }
            collectClients(under: device, into: &names, depth: 0)
        }
        // De-duplicate: one process often holds several interfaces at once.
        return Array(Set(names)).sorted()
    }

    /// One MTP-capable USB device as seen by IOKit alone.
    struct Device {
        /// Registry name, e.g. "SAMSUNG_Android".
        let name: String
        /// Processes holding it right now (empty when free).
        let holders: [String]
    }

    /// MTP-capable devices found purely through IOKit — no libmtp involved.
    ///
    /// This exists because `LIBMTP_Detect_Raw_Devices` **blocks for minutes**
    /// when the device is already claimed by another process (measured: 4m17s
    /// with a second app holding the interface). That makes it useless for
    /// telling the user what's wrong, since the very situation worth reporting
    /// is the one that hangs the scan. Reading the registry is instant and works
    /// regardless of who holds the device.
    ///
    /// A device qualifies when it exposes an interface with USB class 6 /
    /// subclass 1 / protocol 1 — the still-image class that MTP rides on.
    static func mtpDevices() -> [Device] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Device] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard hasStillImageInterface(device) else { continue }
            var holders: [String] = []
            collectClients(under: device, into: &holders, depth: 0)
            found.append(Device(name: registryName(of: device),
                                holders: Array(Set(holders)).sorted()))
        }
        return found
    }

    private static func hasStillImageInterface(_ device: io_registry_entry_t) -> Bool {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(children) }

        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if intProperty(child, "bInterfaceClass") == 6,
               intProperty(child, "bInterfaceSubClass") == 1,
               intProperty(child, "bInterfaceProtocol") == 1 {
                return true
            }
        }
        return false
    }

    /// Walks down from a device node collecting user-client names. Depth is
    /// bounded because only device → interface → client is meaningful here.
    private static func collectClients(under entry: io_registry_entry_t,
                                       into names: inout [String], depth: Int) {
        guard depth < 3 else { return }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(children) }

        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if className(of: child).hasSuffix("UserClient") {
                if let name = holderName(of: child) { names.append(name) }
            } else {
                collectClients(under: child, into: &names, depth: depth + 1)
            }
        }
    }

    /// Owning process of a user client, or nil when it is **this** process.
    ///
    /// `IOUserClientCreator` reads "pid 14805, Double Finder" — the pid matters:
    /// a second copy of this app holding the phone has the very same name, and
    /// filtering by name alone would hide the one case most worth reporting
    /// while still showing the handle our own probe just opened.
    private static func holderName(of entry: io_registry_entry_t) -> String? {
        guard let creator = stringProperty(entry, "IOUserClientCreator") else {
            let name = registryName(of: entry)
            return name.hasSuffix("UserClient") || name.isEmpty ? nil : name
        }
        let parts = creator.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        if let pid = pid_t(parts[0].replacingOccurrences(of: "pid ", with: "")),
           pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        return name.isEmpty ? nil : name
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func className(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private static func registryName(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        else { return nil }
        return value.intValue
    }
}
