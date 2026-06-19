import Foundation

/// A parsed network server address (smb:// or sftp://). Pure value type.
struct ServerURL: Equatable {
    enum Scheme: String { case smb, sftp }

    let scheme: Scheme
    let host: String
    let port: Int?
    let user: String?
    /// SMB share name or SFTP path (the URL path with the leading "/" dropped),
    /// or nil when none was given.
    let share: String?

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let comps = URLComponents(string: trimmed),
              let schemeStr = comps.scheme?.lowercased(),
              let scheme = Scheme(rawValue: schemeStr),
              let host = comps.host, !host.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = comps.port
        self.user = (comps.user?.isEmpty == false) ? comps.user : nil
        let path = comps.percentEncodedPath
        let body = path.hasPrefix("/") ? String(path.dropFirst()) : path
        self.share = body.isEmpty ? nil : body.removingPercentEncoding ?? body
    }
}

/// The `/Volumes/*` mount paths present in `after` but not `before` — used to
/// detect the volume macOS just mounted for an smb:// open.
func newMountPaths(before: Set<String>, after: Set<String>) -> [String] {
    after.subtracting(before)
        .filter { $0.hasPrefix("/Volumes/") }
        .sorted()
}
