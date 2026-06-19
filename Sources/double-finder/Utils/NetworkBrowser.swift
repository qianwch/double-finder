import Foundation

/// Discovers SMB and SFTP file-sharing services on the local network via
/// Bonjour. Callback-based (no Combine), main-actor confined.
@MainActor
final class NetworkBrowser: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {

    enum Kind { case smb, sftp }

    struct Service: Equatable {
        let name: String
        let kind: Kind
        var host: String?
        var port: Int?
    }

    /// Called whenever the discovered set changes (added / removed / resolved).
    var onChange: (([Service]) -> Void)?

    private var browsers: [NetServiceBrowser] = []
    private var resolving: Set<NetService> = []      // strong refs while resolving
    private var services: [Service] = []

    /// Bonjour types we browse, mapped to our Kind.
    private static let types: [(type: String, kind: Kind)] = [
        ("_smb._tcp.", .smb),
        ("_sftp-ssh._tcp.", .sftp),
        ("_ssh._tcp.", .sftp),
    ]

    private func kind(forType type: String) -> Kind {
        // NetService.type comes back like "_smb._tcp." — match by prefix.
        if type.hasPrefix("_smb") { return .smb }
        return .sftp
    }

    func start() {
        stop()
        for (type, _) in Self.types {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(b)
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        resolving.removeAll()
        services.removeAll()
    }

    private func emit() { onChange?(services) }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        let k = kind(forType: service.type)
        if !services.contains(where: { $0.name == service.name && $0.kind == k }) {
            services.append(Service(name: service.name, kind: k, host: nil, port: nil))
        }
        resolving.insert(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
        if !moreComing { emit() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService,
                           moreComing: Bool) {
        let k = kind(forType: service.type)
        services.removeAll { $0.name == service.name && $0.kind == k }
        if !moreComing { emit() }
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        let k = kind(forType: sender.type)
        if let i = services.firstIndex(where: { $0.name == sender.name && $0.kind == k }) {
            services[i].host = sender.hostName?.hasSuffix(".")
                == true ? String(sender.hostName!.dropLast()) : sender.hostName
            services[i].port = sender.port > 0 ? sender.port : nil
            emit()
        }
        resolving.remove(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)   // leave it listed unresolved; not fatal
    }
}
