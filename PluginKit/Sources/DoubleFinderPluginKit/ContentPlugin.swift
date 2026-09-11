import Foundation

/// A column a content plugin contributes to the file list.
public struct PluginColumn: Sendable, Equatable {
    /// Unique within the plugin (`"dimensions"`); the host namespaces it.
    public let id: String
    /// Header title, already localized by the plugin.
    public let title: String
    public let defaultWidth: Double

    public init(id: String, title: String, defaultWidth: Double = 110) {
        self.id = id
        self.title = title
        self.defaultWidth = defaultWidth
    }
}

/// A content plugin (TC "WDX"): custom columns for the file list, offered in the
/// column-header menu like the built-in ones. Values are fetched off the main
/// thread and cached by the host per (path, size, mtime), so `value` may do
/// real work (open the file, read a header) — but keep it bounded: it runs once
/// per visible row per column.
public protocol ContentPlugin: AnyObject {
    var identifier: String { get }
    var columns: [PluginColumn] { get }

    /// The cell text for `path` (a LOCAL file; the host never asks for remote or
    /// in-archive rows), or nil for "—". `isDirectory` lets a plugin skip folders cheaply.
    func value(column: String, path: String, isDirectory: Bool) -> String?
}
