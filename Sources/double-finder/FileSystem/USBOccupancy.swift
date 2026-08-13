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
                let name = registryName(of: child)
                // Nodes that kept their class name carry no process information.
                if !name.isEmpty, !name.hasSuffix("UserClient") { names.append(name) }
            } else {
                collectClients(under: child, into: &names, depth: depth + 1)
            }
        }
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
