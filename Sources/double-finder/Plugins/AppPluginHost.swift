import AppKit
import DoubleFinderPluginKit

/// The app's implementation of `PluginHost` — the only object plugins hold a
/// reference to. Wired to the main view controller once the UI exists.
@MainActor
final class AppPluginHost: PluginHost {
    weak var mainVC: MainViewController?

    var mainWindow: NSWindow? { mainVC?.view.window ?? NSApp.mainWindow }

    func storageDirectory(for plugin: PluginInfo) -> URL {
        let dir = PluginManager.userPluginsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("PluginData/\(plugin.identifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func refreshPanels() {
        guard let vc = mainVC else { return }
        vc.appState.leftPanel.refresh()
        vc.appState.rightPanel.refresh()
    }

    func presentError(_ error: Error) {
        if case PluginError.cancelled = error { return }
        if let vc = mainVC, let window = vc.view.window {
            vc.presentLocalizedError(error, in: window)
        } else {
            NSAlert(error: error).runModal()
        }
    }

    func log(_ message: String) {
        NSLog("[plugin] %@", message)
    }

    var languageTag: String { Localizer.shared.current.jsonName ?? "en" }
}
