import Foundation
import IOKit

/// Calls `handler` whenever any USB device disappears from the system.
///
/// An MTP session holds an open handle to a physical device. Pulling the cable
/// kills it, but nothing informs the app — the drive bar would keep offering a
/// phone that is no longer there, and every click on it would fail.
///
/// This uses an IOKit termination notification rather than polling: unplugging
/// is a rare event, and re-scanning the USB bus every few seconds just to catch
/// it would burn cycles continuously for something that happens once an hour.
/// The handler is a coarse "something was unplugged" signal — the caller decides
/// which of its sessions actually went away.
final class USBRemovalWatcher {
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Idempotent: starting an already-running watcher is a no-op.
    func start() {
        guard port == nil else { return }
        // "IOUSBHostDevice" is what modern macOS registers (visible in ioreg);
        // the legacy IOUSBDevice class no longer matches on Apple Silicon.
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return }
        guard let notifyPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = notifyPort
        IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)

        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context = context else { return }
            drain(iterator)
            Unmanaged<USBRemovalWatcher>.fromOpaque(context).takeUnretainedValue().handler()
        }
        let result = IOServiceAddMatchingNotification(
            notifyPort, kIOTerminatedNotification, matching, callback,
            Unmanaged.passUnretained(self).toOpaque(), &iterator)
        guard result == KERN_SUCCESS else {
            stop()
            return
        }
        // Arming step: the iterator must be drained once or no notification is
        // ever delivered.
        drain(iterator)
    }

    func stop() {
        if iterator != 0 {
            IOObjectRelease(iterator)
            iterator = 0
        }
        if let port = port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    deinit { stop() }
}

/// Releases everything the iterator yields. Required both to arm the
/// notification and to re-arm it after each delivery.
private func drain(_ iterator: io_iterator_t) {
    while case let object = IOIteratorNext(iterator), object != 0 {
        IOObjectRelease(object)
    }
}
