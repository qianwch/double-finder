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

    /// True when both connections address the **same S3 store** — same endpoint,
    /// region, access key and addressing style — so a server-side `copyObject`
    /// between them is valid. The bucket is intentionally NOT compared: it comes
    /// from the browsed path, so same-store cross-bucket copy/move is supported.
    /// (Same endpoint host + access key ⇒ same Keychain secret, so credentials match.)
    func sameStore(as other: S3Connection) -> Bool {
        endpoint == other.endpoint && region == other.region
            && accessKey == other.accessKey && pathStyle == other.pathStyle
    }
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

/// Keychain storage for S3 secret keys. All secrets live in ONE generic-password
/// item (service/label "double-finder") whose payload is a JSON dictionary keyed
/// by "<endpointHost>|<accessKey>". Legacy per-connection internet-password items
/// are migrated into the blob lazily on load and then deleted.
enum S3SecretStore {
    static let service = "double-finder"
    static let account = "S3Secrets"

    // MARK: pure logic (unit-tested)

    static func blobKey(endpointHost: String, accessKey: String) -> String {
        "\(endpointHost)|\(accessKey)"
    }
    static func decodeBlob(_ data: Data) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    static func encodeBlob(_ dict: [String: String]) -> Data {
        (try? JSONEncoder().encode(dict)) ?? Data("{}".utf8)
    }

    // MARK: unified item

    private static var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func loadAll() -> [String: String] {
        var q = itemQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return [:] }
        let all = decodeBlob(data)
        // One successful read reconciles the whole index (the blob holds every
        // connection's key), so a user who has ever connected has an accurate
        // index without anything extra being read.
        setStoredKeys(Set(all.keys))
        return all
    }

    // MARK: - "Is a secret stored?" without asking for secret material

    private static let indexKey = "S3SecretIndex"

    /// Plaintext list of the blob keys that have a stored secret.
    ///
    /// Reading the blob needs `kSecReturnData`, which asks the Keychain for
    /// secret material and therefore raises an authorization prompt whenever the
    /// asking binary is not the one that created the item — and an ad-hoc signed
    /// build changes identity on every rebuild. The connection window has to
    /// answer "does this entry have a key?" while merely *browsing* the list, so
    /// it asks this index instead: it carries no secret material, only which
    /// entries have one. Reading a secret on selection is exactly what used to
    /// freeze the window behind a modal Keychain prompt.
    static func storedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: indexKey) ?? [])
    }

    static func hasSecret(endpointHost: String, accessKey: String,
                          defaults: UserDefaults = .standard) -> Bool {
        storedKeys(defaults: defaults)
            .contains(blobKey(endpointHost: endpointHost, accessKey: accessKey))
    }

    private static func setStoredKeys(_ keys: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(keys.sorted(), forKey: indexKey)
    }

    /// Fills the index in from the Keychain, **off the main thread**, and only
    /// when it has nothing to say yet — secrets stored before the index existed
    /// would otherwise be reported as missing. One successful read covers every
    /// connection (they share one blob), after which save/delete keep it current.
    /// Backgrounded because this is the one call that asks for secret material,
    /// and on a binary the Keychain does not recognise that means a modal prompt.
    static func reconcileIndexIfNeeded(completion: @escaping () -> Void) {
        guard storedKeys().isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = loadAll()                    // its success path writes the index
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func saveAll(_ dict: [String: String]) {
        let data = encodeBlob(dict)
        let status = SecItemUpdate(itemQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = itemQuery
            q[kSecAttrLabel as String] = service   // display name in Keychain Access
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    // MARK: API (unchanged signatures)

    static func load(endpointHost: String, accessKey: String) -> String? {
        let key = blobKey(endpointHost: endpointHost, accessKey: accessKey)
        var all = loadAll()
        if let s = all[key] { return s }
        // Lazy migration from the legacy per-connection internet-password item.
        guard let s = legacyLoad(endpointHost: endpointHost, accessKey: accessKey) else { return nil }
        all[key] = s
        saveAll(all)
        legacyDelete(endpointHost: endpointHost, accessKey: accessKey)
        return s
    }

    static func save(endpointHost: String, accessKey: String, secret: String) {
        let key = blobKey(endpointHost: endpointHost, accessKey: accessKey)
        var all = loadAll()
        all[key] = secret
        saveAll(all)
        setStoredKeys(storedKeys().union([key]))
        legacyDelete(endpointHost: endpointHost, accessKey: accessKey)
    }

    static func delete(endpointHost: String, accessKey: String) {
        let key = blobKey(endpointHost: endpointHost, accessKey: accessKey)
        var all = loadAll()
        all.removeValue(forKey: key)
        saveAll(all)
        setStoredKeys(storedKeys().subtracting([key]))
        legacyDelete(endpointHost: endpointHost, accessKey: accessKey)
    }

    // MARK: legacy internet-password items (pre-consolidation)

    static func legacyQuery(endpointHost: String, accessKey: String) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: endpointHost,
         kSecAttrAccount as String: accessKey]
    }
    private static func legacyLoad(endpointHost: String, accessKey: String) -> String? {
        var q = legacyQuery(endpointHost: endpointHost, accessKey: accessKey)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
    private static func legacyDelete(endpointHost: String, accessKey: String) {
        SecItemDelete(legacyQuery(endpointHost: endpointHost, accessKey: accessKey) as CFDictionary)
    }
}
