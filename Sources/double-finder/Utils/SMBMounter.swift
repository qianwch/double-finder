import AppKit

/// "Mount requested but not detected within the timeout" — informational, not a
/// hard failure (the volume may still appear in the drive bar).
@MainActor
struct SMBMountPending: @preconcurrency LocalizedError {
    var errorDescription: String? { tr("Mount requested — check the drive bar.") }
}

/// Mounts an smb:// share via macOS (which shows the native auth/Keychain UI and
/// share picker), then detects the new /Volumes mount by diffing Volumes.mounted().
@MainActor
enum SMBMounter {
    static func mount(_ url: URL, timeout: TimeInterval = 10,
                      onResult: @escaping (Result<String, Error>) -> Void) {
        let before = Set(Volumes.mounted().map { $0.url.path })
        NSWorkspace.shared.open(url)
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            let now = Set(Volumes.mounted().map { $0.url.path })
            if let mount = newMountPaths(before: before, after: now).first {
                onResult(.success(mount))
                return
            }
            if Date() >= deadline {
                onResult(.failure(SMBMountPending()))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
        }
        // First poll after a short delay to let the mount settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { poll() }
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
