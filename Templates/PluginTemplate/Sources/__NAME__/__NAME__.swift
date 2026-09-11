import AppKit
import DoubleFinderPluginKit

/// Principal class — named in Info.plist `NSPrincipalClass`. Must be an
/// `@objc` `NSObject` subclass so `Bundle.principalClass` can find it.
@objc(__NAME__)
public final class __NAME__: NSObject, DFPlugin {
    public let info = PluginInfo(identifier: "__BUNDLE_ID__",
                                 name: "__NAME__",
                                 version: "1.0",
                                 summary: "Describe what the plugin does",
                                 author: "")

    private var host: PluginHost?
    private let hello = HelloCommand()

    public required override init() { super.init() }

    public func activate(host: PluginHost) throws {
        self.host = host
        host.log("__NAME__ activated (UI language: \(host.languageTag))")
    }

    public func deactivate() { host = nil }

    // Return the extensions you implement. Each is optional; delete what you
    // don't need. See docs/plugin-development.md for every protocol.
    public var commands: [CommandPlugin] { [hello] }
    // public var fileSystems: [FileSystemPlugin] { [] }
    // public var viewers: [ViewerPlugin] { [] }
    // public var packers: [PackerPlugin] { [] }
    // public var contentProviders: [ContentPlugin] { [] }

    // Optional settings UI: Settings ▸ Plugins ▸ "Plugin Settings…".
    // public func makeSettingsView() -> NSView? { nil }
}

/// A minimal command: shows what the host handed us.
final class HelloCommand: CommandPlugin {
    let identifier = "hello"
    let title = "Hello from __NAME__"
    let symbolName = "hand.wave"

    @MainActor
    func perform(_ context: PluginCommandContext) async throws {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = """
            Source: \(context.sourceDirectory)
            Target: \(context.targetDirectory)
            Selected: \(context.selectedPaths.count) item(s)
            """
        if let window = context.host.mainWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
