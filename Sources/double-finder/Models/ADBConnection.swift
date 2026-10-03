import Foundation

/// Only connection addresses are saved; pairing codes are ephemeral stdin data.
struct ADBConnection: Equatable, Codable, Sendable {
    var name: String
    var host: String
    var port: Int
    var initialPath: String = "/sdcard"
    var endpoint: String {
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(address):\(port)"
    }
}

/// Pure validation shared by wireless drafts and persisted addresses.
enum ADBConnectionDraft {
    /// Never infer identity from a prefix: different devices may share one.
    static func networkEndpoint(serial: String, services: [ADBService]) -> String? {
        if let endpoint = try? ADBClient.validateEndpoint(serial) { return endpoint }
        let suffix = "_adb-tls-connect._tcp"
        let candidates = services.filter { service in
            service.kind == .connection && !service.name.isEmpty
                && (serial == service.name || serial == service.name + suffix || serial == service.name + suffix + ".")
                && (try? ADBClient.validateEndpoint(service.endpoint)) != nil
        }
        let endpoints = Set(candidates.map(\.endpoint))
        return endpoints.count == 1 ? endpoints.first : nil
    }

    static func endpoint(host: String, port: String) throws -> String {
        guard let number = Int(port), (1...65535).contains(number) else { throw ADBError.invalidArgument }
        let connection = ADBConnection(name: "", host: host, port: number)
        return try ADBClient.validateEndpoint(connection.endpoint)
    }
}
