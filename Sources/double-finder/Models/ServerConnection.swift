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

    var name: String {
        switch self {
        case .sftp(let c): return c.host.isEmpty ? c.displayName : "\(c.user)@\(c.host)"
        case .s3(let c):   return c.name.isEmpty ? c.endpoint : c.name
        case .smb(let c):  return c.name
        }
    }

    /// Flat string dict with a `kind` discriminator (for UserDefaults).
    var dict: [String: String] {
        switch self {
        case .sftp(let c):
            return ["kind": "sftp", "host": c.host, "user": c.user, "port": "\(c.port)",
                    "keyPath": c.keyPath, "remotePath": c.remotePath]
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
                remotePath: dict["remotePath"] ?? "~"))
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
