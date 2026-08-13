import Foundation

enum ActivePanel {
    case left, right
}

@MainActor
class AppState: ObservableObject {
    @Published var leftPanel: PanelState
    @Published var rightPanel: PanelState
    @Published var activePanel: ActivePanel = .left
    @Published var activeOperation: FileOperation?

    private let defaults = UserDefaults.standard

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func savedPath(_ key: String) -> String {
            guard let p = UserDefaults.standard.string(forKey: key),
                  Self.isReachableDirectory(p) else { return home }
            return p
        }
        leftPanel = PanelState(path: savedPath("LeftPanelPath"))
        rightPanel = PanelState(path: savedPath("RightPanelPath"))
        leftPanel.showHidden = defaults.bool(forKey: "LeftShowHidden")
        rightPanel.showHidden = defaults.bool(forKey: "RightShowHidden")
        if defaults.string(forKey: "ActivePanel") == "right" {
            activePanel = .right
        }
    }

    private static func isReachableDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Persists panel paths and view options so the next launch restores them.
    func save() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Never persist a remote path as a local one: SFTP/S3/Android paths are
        // virtual and would leave the panel pointing at a non-existent directory
        // on the next launch. `isRemote` covers every backend, including archives.
        defaults.set(leftPanel.isRemote ? home : leftPanel.currentPath, forKey: "LeftPanelPath")
        defaults.set(rightPanel.isRemote ? home : rightPanel.currentPath, forKey: "RightPanelPath")
        defaults.set(leftPanel.showHidden, forKey: "LeftShowHidden")
        defaults.set(rightPanel.showHidden, forKey: "RightShowHidden")
        defaults.set(activePanel == .right ? "right" : "left", forKey: "ActivePanel")
    }

    var activePanelState: PanelState {
        activePanel == .left ? leftPanel : rightPanel
    }

    var inactivePanelState: PanelState {
        activePanel == .left ? rightPanel : leftPanel
    }

    func switchPanel() {
        activePanel = activePanel == .left ? .right : .left
    }

    func load() {
        leftPanel.loadDirectory()
        rightPanel.loadDirectory()
    }
}
