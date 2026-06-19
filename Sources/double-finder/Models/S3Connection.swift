import Foundation
import Security

/// A saved S3 connection (no secret — that lives in the Keychain).
struct S3Connection: Equatable {
    var name: String
    var endpoint: String
    var region: String
    var bucket: String       // optional default bucket ("" = none)
    var accessKey: String
    var pathStyle: Bool

    var dict: [String: String] {
        ["name": name, "endpoint": endpoint, "region": region, "bucket": bucket,
         "accessKey": accessKey, "pathStyle": pathStyle ? "1" : "0"]
    }

    init(name: String, endpoint: String, region: String, bucket: String,
         accessKey: String, pathStyle: Bool) {
        self.name = name; self.endpoint = endpoint; self.region = region
        self.bucket = bucket; self.accessKey = accessKey; self.pathStyle = pathStyle
    }

    init?(dict: [String: String]) {
        guard let name = dict["name"], let endpoint = dict["endpoint"], !endpoint.isEmpty
        else { return nil }
        self.name = name
        self.endpoint = endpoint
        self.region = dict["region"] ?? "us-east-1"
        self.bucket = dict["bucket"] ?? ""
        self.accessKey = dict["accessKey"] ?? ""
        self.pathStyle = (dict["pathStyle"] ?? "0") == "1"
    }

    /// Host of the endpoint URL (Keychain server attribute).
    var endpointHost: String { URL(string: endpoint)?.host ?? endpoint }
}

enum S3ConnectionStore {
    private static let key = "S3Connections"
    static func load() -> [S3Connection] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap(S3Connection.init(dict:))
    }
    static func save(_ items: [S3Connection]) {
        UserDefaults.standard.set(items.map { $0.dict }, forKey: key)
    }
}

/// Keychain storage for S3 secret keys (internet-password; server=endpoint host,
/// account=access key).
enum S3SecretStore {
    static func query(endpointHost: String, accessKey: String) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: endpointHost,
         kSecAttrAccount as String: accessKey]
    }
    static func load(endpointHost: String, accessKey: String) -> String? {
        var q = query(endpointHost: endpointHost, accessKey: accessKey)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
    static func save(endpointHost: String, accessKey: String, secret: String) {
        delete(endpointHost: endpointHost, accessKey: accessKey)
        var q = query(endpointHost: endpointHost, accessKey: accessKey)
        q[kSecValueData as String] = Data(secret.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(endpointHost: String, accessKey: String) {
        SecItemDelete(query(endpointHost: endpointHost, accessKey: accessKey) as CFDictionary)
    }
}
