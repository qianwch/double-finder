import AppKit

class MainWindowController: NSWindowController {
    private var mainVC: MainViewController!
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Double Finder"
        window.minSize = NSSize(width: 800, height: 500)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        mainVC = MainViewController()
        mainVC.appState = appState
        window.contentViewController = mainVC

        // Save the frame live on every move/resize so it survives even a crash
        // or force-quit (applicationWillTerminate only fires on a clean quit).
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(frameDidChange),
                       name: NSWindow.didMoveNotification, object: window)
        nc.addObserver(self, selector: #selector(frameDidChange),
                       name: NSWindow.didResizeNotification, object: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    // UserDefaults key holding the window frame ("{{x, y}, {w, h}}") from last session.
    private static let frameKey = "MainWindowFrame"

    func showWindow() {
        showWindow(nil)
        // Restore the frame saved last session; on first launch (no saved frame)
        // fall back to maximizing the screen's visible area.
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            window?.setFrame(NSRectFromString(saved), display: true)
        } else if let screen = window?.screen ?? NSScreen.main {
            window?.setFrame(screen.visibleFrame, display: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func frameDidChange() { saveFrame() }

    /// Persist the current window frame so it can be restored on next launch.
    func saveFrame() {
        guard let window = window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }
}
