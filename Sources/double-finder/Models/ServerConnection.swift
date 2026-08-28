import Foundation

enum ServerKind: String { case sftp, s3, smb, android }

/// An SMB server (host only). Shares are listed after NetFS mounts them; no
/// password is stored (NetFS native auth handles credentials).
struct SMBConnection: Equatable {
    var name: String
    var host: String

    var dict: [String: String] { ["name": name, "host": host] }

    init(name: String, host: String) { self.name = name; self.host = host }

    init?(dict: [String: String]) {
        guard let host = dict["host"], !host.isEmpty else { return nil }
        self.host = host
        self.name = dict["name"] ?? host
    }
}

/// One saved server connection across all backends.
enum ServerConnection: Equatable {
    case sftp(SFTPConnection)
    case s3(S3Connection)
    case smb(SMBConnection)
    /// A phone plugged in over USB (MTP). Unlike the others this is never
    /// persisted — there is nothing to save but the cable.
    case android(AndroidDevice)

    var kind: ServerKind {
        switch self {
        case .sftp:    return .sftp
        case .s3:      return .s3
        case .smb:     return .smb
        case .android: return .android
        }
    }

    /// Short uppercase label for the address-book row (e.g. "[SFTP] host").
    var kindLabel: String {
        switch self {
        case .sftp:    return "SFTP"
        case .s3:      return "S3"
        case .smb:     return "SMB"
        case .android: return "Android"
        }
    }

    var name: String {
        switch self {
        case .sftp(let c): return c.name.isEmpty ? "\(c.user)@\(c.host)" : c.name
        case .s3(let c):   return c.name.isEmpty ? c.endpoint : c.name
        case .smb(let c):  return c.name
        case .android(let d): return d.displayName
        }
    }

    /// Second line of an address-book row: enough to tell two entries apart
    /// when their names cannot (three S3 connections on one endpoint used to be
    /// indistinguishable). Kept free of the name itself — that is the line above.
    var subtitle: String {
        switch self {
        case .sftp(let c):
            let who = c.user.isEmpty ? c.host : "\(c.user)@\(c.host)"
            return c.port == 22 ? who : "\(who):\(c.port)"
        case .s3(let c):
            // Bucket first: two connections to the same endpoint differ by their
            // bucket, and the rail is narrow enough that whatever comes first is
            // the part that survives truncation.
            let host = URL(string: c.endpoint)?.host ?? c.endpoint
            return c.bucket.isEmpty ? host : "\(c.bucket) · \(host)"
        case .smb(let c):
            return c.host
        case .android:
            return "USB"
        }
    }

    /// SF Symbol for the row / detail header, one per backend.
    var symbolName: String {
        switch self {
        case .sftp:    return "externaldrive.connected.to.line.below"
        case .s3:      return "cloud"
        case .smb:     return "network"
        case .android: return "iphone"
        }
    }

    /// Identity in the address book — `add`/`delete`/`update` all key on this.
    var storeKey: String { "\(kind.rawValue)|\(name)" }

    /// Flat string dict with a `kind` discriminator (for UserDefaults).
    var dict: [String: String] {
        switch self {
        case .sftp(let c):
            return ["kind": "sftp", "name": c.name, "host": c.host, "user": c.user,
                    "port": "\(c.port)", "keyPath": c.keyPath, "remotePath": c.remotePath]
        case .s3(let c):
            var d = c.dict; d["kind"] = "s3"; return d
        case .smb(let c):
            var d = c.dict; d["kind"] = "smb"; return d
        case .android:
            // Never persisted (see ServerConnectionStore.add); the marker exists
            // only so `dict` stays total.
            return ["kind": "android"]
        }
    }

    init?(dict: [String: String]) {
        switch dict["kind"] {
        case "sftp":
            guard let host = dict["host"], !host.isEmpty else { return nil }
            self = .sftp(SFTPConnection(
                host: host, user: dict["user"] ?? "",
                port: Int(dict["port"] ?? "22") ?? 22,
                keyPath: dict["keyPath"] ?? "~/.ssh/id_rsa",
                remotePath: dict["remotePath"] ?? "~",
                name: dict["name"] ?? ""))
        case "s3":
            guard let c = S3Connection(dict: dict) else { return nil }
            self = .s3(c)
        case "smb":
            guard let c = SMBConnection(dict: dict) else { return nil }
            self = .smb(c)
        case "android":
            // A phone can't be restored from disk — it has to be plugged in and
            // rescanned. Drop any stray entry instead of resurrecting it.
            return nil
        default:
            return nil
        }
    }
}

/// Unified address book for all server connections (UserDefaults `ServerConnections`).
enum ServerConnectionStore {
    private static let key = "ServerConnections"
    private static let migratedFlag = "ServerConnectionsMigrated"

    static func load(defaults: UserDefaults = .standard) -> [ServerConnection] {
        let raw = defaults.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap(ServerConnection.init(dict:))
    }

    /// Connections grouped by kind in SFTP → S3 → SMB order; empty groups omitted.
    /// Used by the address-book tree in the connection sheet.
    static func grouped(_ conns: [ServerConnection]) -> [(kind: ServerKind, items: [ServerConnection])] {
        let order: [ServerKind] = [.sftp, .s3, .smb]
        return order.compactMap { k in
            let items = conns.filter { $0.kind == k }
            return items.isEmpty ? nil : (k, items)
        }
    }

    static func save(_ conns: [ServerConnection], defaults: UserDefaults = .standard) {
        defaults.set(conns.map { $0.dict }, forKey: key)
    }

    /// Add or replace by (name, kind).
    ///
    /// Android devices are ignored: their identity is the USB cable, so there is
    /// nothing meaningful to store and a stale entry would only mislead.
    static func add(_ conn: ServerConnection, defaults: UserDefaults = .standard) {
        guard conn.kind != .android else { return }
        var conns = load(defaults: defaults)
        conns.removeAll { $0.kind == conn.kind && $0.name == conn.name }
        conns.append(conn)
        save(conns, defaults: defaults)
    }

    static func delete(name: String, kind: ServerKind, defaults: UserDefaults = .standard) {
        var conns = load(defaults: defaults)
        conns.removeAll { $0.kind == kind && $0.name == name }
        save(conns, defaults: defaults)
        var stamps = lastConnectedMap(defaults: defaults)
        if stamps.removeValue(forKey: "\(kind.rawValue)|\(name)") != nil {
            defaults.set(stamps, forKey: lastConnectedKey)
        }
    }

    /// Replaces the entry stored under `oldKey` with `conn`, **in place**.
    ///
    /// `add` keys on the new name, so using it to commit an edit that renamed
    /// the connection would leave the old row behind as a duplicate. Editing is
    /// continuous in the connection window (there is no Save button any more),
    /// so this runs on every keystroke-committed field — it must be identity
    /// preserving, including the last-connected timestamp.
    static func update(oldKey: String, to conn: ServerConnection,
                       defaults: UserDefaults = .standard) {
        guard conn.kind != .android else { return }
        var conns = load(defaults: defaults)
        // A rename that collides with another existing entry would silently
        // shadow it; drop the collision rather than keep two rows with one name.
        conns.removeAll { $0.storeKey == conn.storeKey && $0.storeKey != oldKey }
        guard let index = conns.firstIndex(where: { $0.storeKey == oldKey }) else {
            add(conn, defaults: defaults); return
        }
        conns[index] = conn                       // in place: order is the user's
        save(conns, defaults: defaults)
        if oldKey != conn.storeKey {
            var m = lastConnectedMap(defaults: defaults)
            if let stamp = m.removeValue(forKey: oldKey) { m[conn.storeKey] = stamp }
            defaults.set(m, forKey: lastConnectedKey)
        }
    }

    // MARK: - Last connected

    private static let lastConnectedKey = "ServerLastConnected"

    /// Kept in a side table keyed by `storeKey` rather than as a field on the
    /// connection structs: those round-trip through `dict` in several places
    /// (and in tests), and a timestamp is not part of a connection's identity.
    private static func lastConnectedMap(defaults: UserDefaults) -> [String: Double] {
        defaults.dictionary(forKey: lastConnectedKey) as? [String: Double] ?? [:]
    }

    static func lastConnected(_ conn: ServerConnection,
                              defaults: UserDefaults = .standard) -> Date? {
        lastConnectedMap(defaults: defaults)[conn.storeKey].map(Date.init(timeIntervalSince1970:))
    }

    static func markConnected(_ conn: ServerConnection, at date: Date = Date(),
                              defaults: UserDefaults = .standard) {
        guard conn.kind != .android else { return }   // the cable is not an address
        var m = lastConnectedMap(defaults: defaults)
        m[conn.storeKey] = date.timeIntervalSince1970
        defaults.set(m, forKey: lastConnectedKey)
    }

    /// One-time migration of the three legacy address books into the unified one.
    /// Reads raw UserDefaults dicts (no dependency on the old sheet code).
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedFlag) else { return }
        var migrated = load(defaults: defaults)

        // SFTP: SFTPBookmark dict shape {name,host,port,user,key,path}
        let sftpRaw = defaults.array(forKey: "SFTPBookmarks") as? [[String: String]] ?? []
        for b in sftpRaw {
            guard let host = b["host"], !host.isEmpty else { continue }
            let c = SFTPConnection(host: host, user: b["user"] ?? "",
                                   port: Int(b["port"] ?? "22") ?? 22,
                                   keyPath: b["key"] ?? "~/.ssh/id_rsa",
                                   remotePath: b["path"] ?? "~",
                                   name: b["name"] ?? "")
            migrated.append(.sftp(c))
        }

        // S3: S3Connections (already the right dict shape).
        let s3Raw = defaults.array(forKey: "S3Connections") as? [[String: String]] ?? []
        for d in s3Raw { if let c = S3Connection(dict: d) { migrated.append(.s3(c)) } }

        // SMB: SMBBookmarks (array of smb:// url strings).
        let smbRaw = defaults.array(forKey: "SMBBookmarks") as? [String] ?? []
        for urlString in smbRaw {
            guard let host = URL(string: urlString)?.host else { continue }
            migrated.append(.smb(SMBConnection(name: host, host: host)))
        }

        // De-dup by (kind, name) keeping first.
        var seen = Set<String>()
        let deduped = migrated.filter { seen.insert("\($0.kind.rawValue)|\($0.name)").inserted }
        save(deduped, defaults: defaults)
        defaults.set(true, forKey: migratedFlag)
    }
}
