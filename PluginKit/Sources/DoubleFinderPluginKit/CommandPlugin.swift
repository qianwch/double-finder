import Foundation

/// What a command sees when it runs: both panels' locations plus the selection.
public struct PluginCommandContext {
    /// Active (source) panel directory and the other (target) panel directory.
    public let sourceDirectory: String
    public let targetDirectory: String
    /// Selected paths in the source panel, or the cursor item when nothing is selected.
    public let selectedPaths: [String]
    /// True when the directory is a plain local folder (not remote, not an archive).
    public let sourceIsLocal: Bool
    public let targetIsLocal: Bool
    public let host: PluginHost

    public init(sourceDirectory: String, targetDirectory: String, selectedPaths: [String],
                sourceIsLocal: Bool, targetIsLocal: Bool, host: PluginHost) {
        self.sourceDirectory = sourceDirectory
        self.targetDirectory = targetDirectory
        self.selectedPaths = selectedPaths
        self.sourceIsLocal = sourceIsLocal
        self.targetIsLocal = targetIsLocal
        self.host = host
    }
}

/// A menu command (Plugins menu, toolbar, shortcut) acting on the current selection.
public protocol CommandPlugin: AnyObject {
    var identifier: String { get }
    /// Menu title, already localized by the plugin.
    var title: String { get }
    /// SF Symbol for the toolbar button (the command can be added to the
    /// toolbar in Settings ▸ Toolbar and bound to a key in Settings ▸ Shortcuts).
    var symbolName: String { get }

    /// Run. Throw to have the host show the error; `PluginError.cancelled` is silent.
    @MainActor func perform(_ context: PluginCommandContext) async throws
}

public extension CommandPlugin {
    var symbolName: String { "puzzlepiece.extension" }
}
