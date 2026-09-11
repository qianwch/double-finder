import Foundation

/// One entry of an archive. `path` is the entry's path inside the archive,
/// "/"-separated, no leading slash ("docs/readme.txt"). Directories may be
/// listed explicitly or implied by nested entries — the host infers both.
public struct PluginArchiveEntry: Sendable, Equatable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?

    public init(path: String, isDirectory: Bool = false, size: Int64 = 0, modified: Date? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// One file to put into a new archive: where it is on disk and the entry path
/// it gets ("/"-separated, no leading slash). Directories are expanded by the
/// host — a plugin only ever sees files.
public struct PluginArchiveSource: Sendable, Equatable {
    public var localPath: String
    public var entryPath: String

    public init(localPath: String, entryPath: String) {
        self.localPath = localPath
        self.entryPath = entryPath
    }
}

/// An archive-format plugin (TC "WCX"): files with one of `fileExtensions` become
/// browsable containers (double-click enters, F5 copies out, ⌥F6 extracts,
/// F3 views entries). Reading is required; creation (`canCreate` + `create`)
/// is optional and adds the format to the Pack (⌥F5) dialog.
public protocol PackerPlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    /// Lower-case extensions without the dot (`["pak"]`). Compound suffixes are
    /// allowed (`"tar.lz"`); the longest match wins.
    var fileExtensions: [String] { get }

    /// Open the archive. Runs off the main thread. Throw `PluginError.failed`
    /// for a corrupt file; the panel shows the message and stays where it is.
    func open(_ url: URL) throws -> PluginArchiveSession

    /// True when `create` is implemented; the format then appears in Pack.
    var canCreate: Bool { get }

    /// Write a NEW archive at `url` (overwrite) holding `sources`. Runs off the
    /// main thread. Report cumulative bytes consumed through `progress` (drives
    /// the progress bar) and poll `isCancelled` between files — throw
    /// `CancellationError` when it turns true; the host deletes the partial file.
    func create(_ url: URL, sources: [PluginArchiveSource],
                progress: @escaping @Sendable (Int64) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) throws
}

public extension PackerPlugin {
    var canCreate: Bool { false }
    func create(_ url: URL, sources: [PluginArchiveSource],
                progress: @escaping @Sendable (Int64) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) throws {
        throw PluginError.unsupported("Creating \(displayName) archives")
    }
}

/// An open archive. Methods run off the main thread, one call at a time.
public protocol PluginArchiveSession: AnyObject {
    func entries() throws -> [PluginArchiveEntry]

    /// Extract one FILE entry to `localURL` (parent exists; overwrite).
    func extract(_ entryPath: String, to localURL: URL) throws

    func close()
}

public extension PluginArchiveSession {
    func close() {}
}
