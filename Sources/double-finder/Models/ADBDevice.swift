import Foundation

struct ADBDevice: Equatable, Sendable {
    let serial: String
    let model: String
    let state: String
    var isAuthorized: Bool { state == "device" }
    var displayName: String { model.isEmpty ? serial : model }
    var sessionID: String { "adb://\(serial)" }
}

struct ADBSession: Equatable, Sendable {
    let device: ADBDevice
    let executablePath: String
    /// Validated wireless connection endpoint, distinct from an mDNS serial.
    var networkEndpoint: String? = nil
    let lifetime = ADBSessionLifetime()
    static func == (a: Self, b: Self) -> Bool { a.device == b.device && a.executablePath == b.executablePath && a.networkEndpoint == b.networkEndpoint && a.lifetime === b.lifetime }
    func invalidate() { lifetime.invalidate() }
    var id: String { device.sessionID }
    var label: String { device.displayName }
}

struct ADBService: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case pairing, connection }
    let name: String
    let kind: Kind
    let endpoint: String
}

/// Copies of a session share one irreversible lifetime. Polling cancellation is
/// consumed by the runner, so no global adb server or other session is affected.
final class ADBSessionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var removed = false
    var isRemoved: Bool { lock.lock(); defer { lock.unlock() }; return removed }
    func invalidate() { lock.lock(); removed = true; lock.unlock() }
}
