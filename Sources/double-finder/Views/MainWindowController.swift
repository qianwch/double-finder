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

    /// True while the launch frame is being applied: the move / resize
    /// notifications that fire meanwhile must not overwrite the saved value.
    private var restoringFrame = false

    func showWindow() {
        guard let window else { return }
        // Restore the frame saved last session BEFORE the window is shown. It
        // used to be applied after showWindow(nil): on a display too small for
        // the 1280×768 default frame macOS constrained the window on the way
        // to the screen, that fired didMove / didResize, the observer saved the
        // constrained default frame — and the restore that followed read that
        // freshly overwritten value instead of last session's ("the app never
        // remembers where I put it" on laptops).
        restoringFrame = true
        let screens = NSScreen.screens
        let visible = ([NSScreen.main].compactMap { $0 } + screens.filter { $0 !== NSScreen.main }).map(\.visibleFrame)
        if let frame = WindowFramePlacement.frame(saved: UserDefaults.standard.string(forKey: Self.frameKey),
                                                  visibleFrames: visible) {
            window.setFrame(frame, display: false)
        } else if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)      // first launch: fill the main display
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        restoringFrame = false
        saveFrame()      // whatever macOS made of it on screen is the new truth
    }

    @objc private func frameDidChange() { if !restoringFrame { saveFrame() } }

    /// Persist the current window frame so it can be restored on next launch.
    func saveFrame() {
        guard let window = window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }
}
