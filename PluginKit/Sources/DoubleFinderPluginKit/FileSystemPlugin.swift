import Foundation

/// One entry of a listed directory. `name` is the leaf only; paths are built by
/// the host as `<dir>/<name>` (POSIX style, `/` root, no trailing slash).
public struct PluginFileEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var isHidden: Bool
    public var isSymlink: Bool
    /// "rwxr-xr-x"-style string, or "" when the backend has no permissions.
    public var permissions: String

    public init(name: String, isDirectory: Bool, size: Int64 = 0, modified: Date = Date(),
                isHidden: Bool = false, isSymlink: Bool = false, permissions: String = "") {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.permissions = permissions
    }
}

/// A file-system plugin (TC "WFX"): appears as a drive in the drive bar and the
/// Plugins menu; clicking it calls `connect`, and the returned session backs the
/// panel until the user ejects it.
public protocol FileSystemPlugin: AnyObject {
    /// Unique within the plugin (`"dropbox"`); combined with the plugin id by the host.
    var identifier: String { get }
    /// Drive-bar / menu title.
    var displayName: String { get }
    /// SF Symbol for the drive-bar button.
    var symbolName: String { get }

    /// Open the drive. May show its own UI (credentials, account picker) on
    /// `host.mainWindow`. Throw `PluginError.cancelled` for a silent abort.
    @MainActor func connect(host: PluginHost) async throws -> PluginFileSystemSession
}

public extension FileSystemPlugin {
    var symbolName: String { "puzzlepiece.extension" }
}

/// An open drive. All paths are absolute virtual paths rooted at "/". Methods
/// are called off the main thread and may run concurrently; serialize inside if
/// the backend needs it.
public protocol PluginFileSystemSession: AnyObject {
    /// Label for the drive-bar entry while connected (account name, host …).
    var label: String { get }

    func list(_ directory: String) async throws -> [PluginFileEntry]

    /// Fetch one FILE to `localURL` (the parent directory exists; overwrite).
    /// `progress` receives the cumulative byte count.
    func download(_ path: String, to localURL: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws

    /// Store one local FILE at the remote path `path` (its parent exists; overwrite).
    func upload(_ localURL: URL, to path: String,
                progress: @escaping @Sendable (Int64) -> Void) async throws

    /// Remove a file, or a directory with everything below it.
    func delete(_ path: String) async throws

    func createDirectory(_ path: String) async throws

    /// Rename in place (same parent).
    func rename(_ path: String, to newName: String) async throws

    /// Server-side copy / move into `directory`, keeping the leaf name. Optional:
    /// throw `PluginError.unsupported` and the host relays through a temp file
    /// (move = relay + delete).
    func copy(_ path: String, toDirectory directory: String) async throws
    func move(_ path: String, toDirectory directory: String) async throws

    /// Called once when the drive is ejected or the app quits.
    func disconnect()
}

public extension PluginFileSystemSession {
    func copy(_ path: String, toDirectory directory: String) async throws {
        throw PluginError.unsupported("Copying within this drive")
    }
    func move(_ path: String, toDirectory directory: String) async throws {
        throw PluginError.unsupported("Moving within this drive")
    }
    func disconnect() {}
}
