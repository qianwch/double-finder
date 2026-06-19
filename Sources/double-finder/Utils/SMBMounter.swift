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
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI
            if guest { openOptions[kNetFSUseGuestKey as String] = true }

            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                url as CFURL,
                nil,                                   // mountpath: system picks /Volumes/<share>
                guest ? nil : (user as CFString?),
                guest ? nil : (password as CFString?),
                openOptions as CFMutableDictionary,
                nil,
                &mountpoints)
            let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []
            FileHandle.standardError.write(Data(
                "[SMB] NetFSMountURLSync \(url.absoluteString) guest=\(guest) -> status=\(status) paths=\(paths)\n".utf8))

            DispatchQueue.main.async {
                if let err = SMBMountError.classify(status) {
                    onResult(.failure(err))
                } else if let path = paths.first {
                    onResult(.success(path))
                } else {
                    onResult(.failure(.other(0)))
                }
            }
        }
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
