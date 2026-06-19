import Foundation
import NetFS

/// Why an SMB mount failed. App LocalizedError types return BARE English keys
/// (presentLocalizedError translates).
enum SMBMountError: Error, Equatable, LocalizedError {
    case authFailed         // wrong user name / password
    case needsCredentials   // guest / current method rejected — enter a real account
    case other(Int32)

    /// Map a NetFSMountURLSync status to an error, or nil for success.
    /// NetFS reports auth problems with several codes (errno EAUTH/EACCES *and*
    /// negative NetFS/NetAuth codes); all of these must re-prompt rather than
    /// dead-end as a generic failure. Non-auth failures stay `.other`.
    static func classify(_ status: Int32) -> SMBMountError? {
        switch status {
        case 0:
            return nil
        case 80, 13:                        // EAUTH, EACCES
            return .authFailed
        case -6004,                         // kNetAuthErrorGuestNotSupported
             -5997,                         // ENETFSNOAUTHMECHSUPP
             -5999,                         // ENETFSACCOUNTRESTRICTED (e.g. guest)
             -5045, -5046:                  // ENETFSPWDNEEDSCHANGE / ENETFSPWDPOLICY
            return .needsCredentials
        default:
            return .other(status)
        }
    }

    /// True when the user should be re-prompted for (different) credentials.
    var isAuthIssue: Bool {
        switch self {
        case .authFailed, .needsCredentials: return true
        case .other: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .authFailed:       return "Incorrect user name or password."
        case .needsCredentials: return "This server requires a user name and password."
        case .other:            return "Could not connect to the server."
        }
    }
}

/// Mounts an smb:// URL in-process via NetFS. The system UI is suppressed
/// (kNAUIOptionNoUI) so NO Finder window and NO system auth dialog appear —
/// credentials come from the caller (or guest). Returns the mount path.
enum SMBMounter {
    static func mount(_ url: URL, user: String?, password: String?, guest: Bool,
                      onResult: @escaping (Result<String, SMBMountError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, paths) = rawMount(url, user: user, password: password, guest: guest)

            // Success with a concrete share already mounted.
            if status == 0, let path = paths.first {
                DispatchQueue.main.async { onResult(.success(path)) }
                return
            }

            // A genuine credential problem must be reported so the caller can
            // re-prompt — don't try to enumerate past it.
            if let err = SMBMountError.classify(status), err.isAuthIssue {
                DispatchQueue.main.async { onResult(.failure(err)) }
                return
            }

            // Host-only URL (no share path) with auth OK: NetFS+NoUI can't pick a
            // share headlessly and fails with a non-auth code (-6003 / -5998 / 63
            // / success-with-no-mount, etc.). Enumerate the server's shares and
            // mount each one, like Finder does — auth stays fully in-process.
            let hasShare = !(url.path.isEmpty || url.path == "/")
            if !hasShare, let host = url.host {
                let shares = enumerateShares(host: host, user: user, password: password, guest: guest)
                var mounted: [String] = []
                for share in shares {
                    guard let enc = share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                          let shareURL = URL(string: "smb://\(host)/\(enc)") else { continue }
                    let (st, p) = rawMount(shareURL, user: user, password: password, guest: guest)
                    if st == 0 { mounted.append(contentsOf: p) }
                }
                if let first = mounted.sorted().first {
                    DispatchQueue.main.async { onResult(.success(first)) }
                    return
                }
            }

            // Otherwise report the original status.
            DispatchQueue.main.async {
                if let err = SMBMountError.classify(status) {
                    onResult(.failure(err))
                } else if let path = paths.first {
                    onResult(.success(path))
                } else {
                    onResult(.failure(.other(status)))
                }
            }
        }
    }

    /// One NetFSMountURLSync call (kNAUIOptionNoUI). Returns (status, mountPaths).
    private static func rawMount(_ url: URL, user: String?, password: String?,
                                 guest: Bool) -> (Int32, [String]) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI
        if guest { openOptions[kNetFSUseGuestKey as String] = true }
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            url as CFURL, nil,
            guest ? nil : (user as CFString?),
            guest ? nil : (password as CFString?),
            openOptions as CFMutableDictionary, nil, &mountpoints)
        let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []
        FileHandle.standardError.write(Data(
            "[SMB] mount \(url.absoluteString) guest=\(guest) -> status=\(status) paths=\(paths)\n".utf8))
        return (status, paths)
    }

    /// List the server's mountable (disk) share names via `smbutil view`.
    private static func enumerateShares(host: String, user: String?, password: String?,
                                        guest: Bool) -> [String] {
        var target = "//"
        if !guest, let user = user, !user.isEmpty {
            let u = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
            if let pw = password, !pw.isEmpty {
                let p = pw.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? pw
                target += "\(u):\(p)@\(host)"
            } else {
                target += "\(u)@\(host)"
            }
        } else {
            target += host
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        // -N: never block on a password prompt (we pass credentials in the URL).
        proc.arguments = guest ? ["view", "-N", "-g", target] : ["view", "-N", target]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let shares = parseShareNames(from: raw)
        FileHandle.standardError.write(Data(
            "[SMB] smbutil view \(host) exit=\(proc.terminationStatus) shares=\(shares)\n".utf8))
        return shares
    }

    /// Parse `smbutil view` output into mountable disk share names (excludes the
    /// header/separator, non-disk types, and hidden admin shares ending in `$`).
    static func parseShareNames(from output: String) -> [String] {
        var shares: [String] = []
        for raw in output.split(separator: "\n") {
            let cols = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 2 else { continue }
            let name = cols[0]
            let type = cols[1].lowercased()
            guard type == "disk" else { continue }
            if name == "Share" { continue }                    // header
            if name.allSatisfy({ $0 == "-" }) { continue }     // separator
            if name.hasSuffix("$") { continue }                // hidden admin share
            shares.append(name)
        }
        return shares
    }
}

/// Recent SMB server URLs, most-recent-first (max 10).
enum SMBBookmarkStore {
    private static let key = "SMBBookmarks"
    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
    static func add(_ url: String) {
        var list = load().filter { $0 != url }
        list.insert(url, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        UserDefaults.standard.set(list, forKey: key)
    }
}
