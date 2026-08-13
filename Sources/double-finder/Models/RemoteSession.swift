import Foundation

/// One open remote connection, shown as a "drive" in the drive bar. Sessions
/// are app-global (both panels see the same drives) and live only for this run
/// of the app — nothing is persisted.
enum RemoteSession: Equatable {
    case sftp(SFTPConnection)
    case s3(S3Connection, secret: String)
    /// A phone plugged in over USB. Carries the label separately because the
    /// device's friendly name ("卫春 的 S25 Edge") only becomes known once the
    /// MTP session is open, while `AndroidDevice` comes from a plain USB scan.
    case android(AndroidDevice, label: String)

    /// Stable identity for dedupe and per-panel path memory. SFTP mirrors
    /// `sameHost` (host + user + port; the configured initial path / address-book
    /// name don't change which host you're on). S3 identifies the service by
    /// endpoint + access key; the bucket is just a start location.
    var id: String {
        switch self {
        case .sftp(let c): return "sftp://\(c.user)@\(c.host):\(c.port)"
        case .s3(let c, _): return "s3://\(c.accessKey)@\(c.endpoint)"
        case .android(let d, _): return d.sessionID
        }
    }

    /// Static drive-bar / dropdown label (unlike the old single-session entry,
    /// it does not track the browsed path).
    var label: String {
        switch self {
        case .sftp(let c): return "sftp://\(c.user)@\(c.host)"
        case .s3(let c, _): return "s3://\(c.name)"
        case .android(_, let label): return label
        }
    }

    /// SF Symbol name for the drive-bar entry.
    var icon: String {
        switch self {
        case .sftp: return "network"
        case .s3: return "cloud"
        // SF Symbols has no Android glyph; a phone silhouette reads correctly.
        case .android: return "iphone"
        }
    }
}

/// App-global ordered registry of open remote sessions. `PanelState.connectSFTP/
/// connectS3` register here; the drive-bar ⏏ removes. Every mutation posts
/// `didChange` so both panels' drive bars rebuild and a panel sitting in a
/// removed session falls back to local (`PanelState.leaveRemovedSessions`).
@MainActor
final class RemoteSessionStore {
    static let shared = RemoteSessionStore()
    static let didChange = Notification.Name("RemoteSessionStoreDidChange")

    private(set) var sessions: [RemoteSession] = []

    var ids: Set<String> { Set(sessions.map { $0.id }) }

    func session(withID id: String) -> RemoteSession? {
        sessions.first { $0.id == id }
    }

    /// Adds a session, or refreshes the stored one in place (fresh secret /
    /// settings) when the same host/service is already connected.
    func register(_ session: RemoteSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func remove(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Android sessions own an exclusive USB claim: until it's released,
        // Chrome / Android File Transfer / Image Capture can't open the phone
        // either. Every disconnect path funnels through here, so this is the
        // one place that has to get it right.
        if case .android = session { AndroidDeviceRegistry.shared.close(id) }
        sessions.removeAll { $0.id == id }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func removeAll() {
        guard !sessions.isEmpty else { return }
        if sessions.contains(where: { if case .android = $0 { return true }; return false }) {
            AndroidDeviceRegistry.shared.closeAll()
        }
        sessions.removeAll()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
