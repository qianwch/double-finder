import Foundation
import DoubleFinderPluginKit

/// An open drive provided by a file-system plugin: the plugin's session object
/// plus the static identity the drive bar needs. Class (not struct) because the
/// session is a reference the store must hand back unchanged; equality is
/// identity — one connect = one drive.
final class PluginDriveSession: Equatable {
    /// `RemoteSession.id` for this drive (`plugin://<plugin>/<fs>`).
    let driveID: String
    let pluginID: String
    /// SF Symbol from the extension.
    let symbol: String
    let session: PluginFileSystemSession

    init(driveID: String, pluginID: String, symbol: String, session: PluginFileSystemSession) {
        self.driveID = driveID
        self.pluginID = pluginID
        self.symbol = symbol
        self.session = session
    }

    static func == (a: PluginDriveSession, b: PluginDriveSession) -> Bool { a === b }
}

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
    /// A drive opened through a `FileSystemPlugin`.
    case plugin(PluginDriveSession)

    /// Stable identity for dedupe and per-panel path memory. SFTP mirrors
    /// `sameHost` (host + user + port; the configured initial path / address-book
    /// name don't change which host you're on). S3 identifies the service by
    /// endpoint + access key; the bucket is just a start location.
    var id: String {
        switch self {
        case .sftp(let c): return "sftp://\(c.user)@\(c.host):\(c.port)"
        case .s3(let c, _): return "s3://\(c.accessKey)@\(c.endpoint)"
        case .android(let d, _): return d.sessionID
        case .plugin(let d): return d.driveID
        }
    }

    /// Static drive-bar / dropdown label (unlike the old single-session entry,
    /// it does not track the browsed path).
    var label: String {
        switch self {
        case .sftp(let c): return "sftp://\(c.user)@\(c.host)"
        case .s3(let c, _): return "s3://\(c.name)"
        case .android(_, let label): return label
        case .plugin(let d): return d.session.label
        }
    }

    // MARK: Backend accessors (nil unless this session is that backend)

    var sftpConnection: SFTPConnection? { if case .sftp(let c) = self { return c }; return nil }
    var s3Connection: S3Connection? { if case .s3(let c, _) = self { return c }; return nil }
    var androidDevice: AndroidDevice? { if case .android(let d, _) = self { return d }; return nil }
    var androidLabel: String? { if case .android(_, let l) = self { return l }; return nil }
    var pluginDrive: PluginDriveSession? { if case .plugin(let d) = self { return d }; return nil }

    /// Signed S3 client (the secret rides in the session), nil for other backends.
    var s3Client: S3Client? {
        if case .s3(let c, let secret) = self { return c.makeClient(secret: secret) }
        return nil
    }

    /// True when a destination path in `other` can collide with a source path in
    /// `self` — same SFTP host, same S3 store (bucket may differ), same phone, the
    /// same plugin drive. Precondition of the self-transfer guard and the key for
    /// choosing a server-side / on-device transfer over a download + upload.
    func sharesNamespace(with other: RemoteSession) -> Bool {
        switch (self, other) {
        case (.sftp(let a), .sftp(let b)): return a.sameHost(as: b)
        case (.s3(let a, _), .s3(let b, _)): return a.sameStore(as: b)
        case (.android(let a, _), .android(let b, _)): return a.sessionID == b.sessionID
        case (.plugin(let a), .plugin(let b)): return a === b
        default: return false
        }
    }

    /// SF Symbol name for the drive-bar entry.
    var icon: String {
        switch self {
        case .sftp: return "network"
        case .s3: return "cloud"
        // SF Symbols has no Android glyph; a phone silhouette reads correctly.
        case .android: return "iphone"
        case .plugin(let d): return d.symbol
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
        // A plugin drive owns whatever its session holds (network connection,
        // device handle …): tell it to let go.
        if case .plugin(let d) = session { d.session.disconnect() }
        sessions.removeAll { $0.id == id }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func removeAll() {
        guard !sessions.isEmpty else { return }
        if sessions.contains(where: { if case .android = $0 { return true }; return false }) {
            AndroidDeviceRegistry.shared.closeAll()
        }
        for s in sessions { if case .plugin(let d) = s { d.session.disconnect() } }
        sessions.removeAll()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
