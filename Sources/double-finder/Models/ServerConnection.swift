import Foundation

enum ServerKind: String { case sftp, s3, smb }

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

    var kind: ServerKind {
        switch self {
        case .sftp: return .sftp
        case .s3:   return .s3
        case .smb:  return .smb
        }
    }

    /// Short uppercase label for the address-book row (e.g. "[SFTP] host").
    var kindLabel: String {
        switch self {
        case .sftp: return "SFTP"
        case .s3:   return "S3"
        case .smb:  return "SMB"
        }
    }

    var name: String {
        switch self {
        case .sftp(let c): return c.name.isEmpty ? "\(c.user)@\(c.host)" : c.name
        case .s3(let c):   return c.name.isEmpty ? c.endpoint : c.name
        case .smb(let c):  return c.name
        }
    }

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
    static func add(_ conn: ServerConnection, defaults: UserDefaults = .standard) {
        var conns = load(defaults: defaults)
        conns.removeAll { $0.kind == conn.kind && $0.name == conn.name }
        conns.append(conn)
        save(conns, defaults: defaults)
    }

    static func delete(name: String, kind: ServerKind, defaults: UserDefaults = .standard) {
        var conns = load(defaults: defaults)
        conns.removeAll { $0.kind == kind && $0.name == name }
        save(conns, defaults: defaults)
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
