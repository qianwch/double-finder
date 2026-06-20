import Foundation
import NetFS

/// An SMB mount failure (other than the user cancelling the auth dialog).
struct SMBMountError: Error, LocalizedError {
    let status: Int32
    var errorDescription: String? { "Could not connect to the server." }
}

/// Mounts an smb:// URL via NetFS using the native macOS connection UI
/// (`kNAUIOptionAllowUI`): the system handles authentication (Keychain) and
/// share selection. No Finder window is opened. Returns the mount path.
enum SMBMounter {
    /// Result of a mount attempt. `.cancelled` means the user dismissed the
    /// native auth dialog (no error should be shown).
    enum Outcome {
        case mounted(String)
        case cancelled
        case failed(SMBMountError)
    }

    static func mount(_ url: URL, onResult: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey as String] = kNAUIOptionAllowUI
            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                url as CFURL, nil, nil, nil,
                openOptions as CFMutableDictionary, nil, &mountpoints)
            let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []

            DispatchQueue.main.async {
                if status == 0 {
                    onResult(.mounted(paths.first ?? ""))
                } else if status == -128 {          // userCanceledErr — auth dialog dismissed
                    onResult(.cancelled)
                } else {
                    onResult(.failed(SMBMountError(status: status)))
                }
            }
        }
    }
}
