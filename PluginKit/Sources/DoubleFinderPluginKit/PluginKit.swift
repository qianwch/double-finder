import AppKit
import Foundation

/// Double Finder plugin API — the one module a plugin links against.
///
/// A plugin is a `.dfplugin` bundle (or a type compiled into the app) whose
/// principal class conforms to `DFPlugin`. The plugin object is created once at
/// load time and asked for the extensions it provides; each extension kind maps
/// to a Total Commander plugin family:
///
/// | TC   | PluginKit          | What it adds                                   |
/// |------|--------------------|------------------------------------------------|
/// | WFX  | `FileSystemPlugin` | a browsable "drive" (cloud, device, database …) |
/// | WLX  | `ViewerPlugin`     | a custom F3 Lister view for a file type         |
/// | WCX  | `PackerPlugin`     | a browsable / extractable archive format        |
/// | WDX  | `ContentPlugin`    | custom columns in the file list                 |
/// | —    | `CommandPlugin`    | a menu / toolbar / shortcut command             |
///
/// ABI: this module is built as one dynamic library shared by the host and every
/// plugin; `apiVersion` is the compatibility contract. A bundle declares the
/// version it was built against in its Info.plist (`DFPluginAPIVersion`) and is
/// refused when it differs from the host's.
public enum PluginKit {
    /// Major API version. Bumped only for incompatible protocol changes.
    public static let apiVersion = 1

    /// Info.plist key a `.dfplugin` bundle must carry (integer, == apiVersion).
    public static let apiVersionInfoKey = "DFPluginAPIVersion"

    /// Path extension of plugin bundles.
    public static let bundleExtension = "dfplugin"
}

/// Static description of a plugin, shown in Settings ▸ Plugins.
public struct PluginInfo: Sendable, Equatable {
    /// Reverse-DNS unique id (`com.example.dropbox`). Also the key under which
    /// the user's enable/disable choice is stored.
    public let identifier: String
    public let name: String
    public let version: String
    public let summary: String
    public let author: String

    public init(identifier: String, name: String, version: String = "1.0",
                summary: String = "", author: String = "") {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.summary = summary
        self.author = author
    }
}

/// The principal object of a plugin. For a bundle, name the conforming class in
/// Info.plist `NSPrincipalClass`; it must be an `NSObject` subclass exposed to
/// Objective-C (`@objc(MyPlugin)`) so `Bundle.principalClass` can find it.
///
/// Lifecycle: `init()` → `activate(host:)` → (extensions queried and registered)
/// → … → `deactivate()` when the user disables the plugin or the app quits.
public protocol DFPlugin: AnyObject {
    init()

    var info: PluginInfo { get }

    /// Called once after creation, before any extension is used. Throw to refuse
    /// activation (the error is shown in Settings ▸ Plugins and the plugin is
    /// left inactive).
    @MainActor func activate(host: PluginHost) throws

    /// Release resources; sessions opened through this plugin's file systems
    /// are disconnected by the host before this is called.
    @MainActor func deactivate()

    /// Extensions provided by this plugin. Queried once right after `activate`.
    var fileSystems: [FileSystemPlugin] { get }
    var viewers: [ViewerPlugin] { get }
    var commands: [CommandPlugin] { get }
    var packers: [PackerPlugin] { get }
    var contentProviders: [ContentPlugin] { get }

    /// Optional settings UI, shown by Settings ▸ Plugins ▸ "Plugin Settings…"
    /// in a sheet. Return nil (the default) when the plugin has nothing to configure.
    @MainActor func makeSettingsView() -> NSView?
}

public extension DFPlugin {
    @MainActor func deactivate() {}
    var fileSystems: [FileSystemPlugin] { [] }
    var viewers: [ViewerPlugin] { [] }
    var commands: [CommandPlugin] { [] }
    var packers: [PackerPlugin] { [] }
    var contentProviders: [ContentPlugin] { [] }
    @MainActor func makeSettingsView() -> NSView? { nil }
}

/// Services the host application offers to plugins. Everything is main-actor.
@MainActor
public protocol PluginHost: AnyObject {
    /// The main window, to hang sheets/alerts on. nil before the UI exists.
    var mainWindow: NSWindow? { get }

    /// Where a plugin keeps its own files (created on demand, one folder per
    /// plugin identifier under the app's Application Support directory).
    func storageDirectory(for plugin: PluginInfo) -> URL

    /// Reload both panels (after a command changed files on disk, for instance).
    func refreshPanels()

    /// Show an error to the user (localized description), attached to the main window.
    func presentError(_ error: Error)

    /// Append a line to the host's plugin log (visible via Console / stderr).
    func log(_ message: String)

    /// The host's UI language as a BCP-47 tag ("en", "zh-Hans", …), so a plugin
    /// can pick its own localized strings.
    var languageTag: String { get }
}

/// Errors with meaning to the host.
public enum PluginError: Error, LocalizedError, Sendable {
    /// The user cancelled (a credential prompt, say). The host stays silent.
    case cancelled
    /// The operation is not supported by this plugin; the host tries a generic
    /// fallback where one exists (e.g. move = copy + delete).
    case unsupported(String)
    /// Any other failure; `message` is shown to the user verbatim.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .unsupported(let what): return "\(what) is not supported by this plugin"
        case .failed(let message): return message
        }
    }
}
