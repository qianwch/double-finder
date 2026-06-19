import Foundation
import Security

struct SMBCredential: Equatable {
    let user: String
    let password: String
}

/// Stores SMB credentials as macOS Keychain internet-password items
/// (protocol smb, server = host, account = user). Never persists to plist.
enum SMBCredentialStore {
    /// The base SecItem query for a host (+ optional account). Pure — unit-tested.
    static func query(host: String, account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrServer as String: host,
        ]
        if let account = account, !account.isEmpty {
            q[kSecAttrAccount as String] = account
        }
        return q
    }

    /// The first saved credential for `host`, or nil.
    static func load(host: String) -> SMBCredential? {
        var q = query(host: host, account: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String,
              let data = dict[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return SMBCredential(user: account, password: password)
    }

    /// Save (replace) the credential for host/user.
    static func save(host: String, user: String, password: String) {
        delete(host: host, account: user)
        var q = query(host: host, account: user)
        q[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(host: String, account: String?) {
        SecItemDelete(query(host: host, account: account) as CFDictionary)
    }
}
