import AppKit
import QuickLookUI

// MARK: - Pure navigation logic (unit-tested in InternalViewerNavTests)

enum ViewerNavDirection { case prev, next }

/// Next index when stepping through a list. Clamps to `[0, count-1]` (no wraparound);
/// returns 0 for an empty list.
func nextIndex(current: Int, count: Int, direction: ViewerNavDirection) -> Int {
    guard count > 0 else { return 0 }
    switch direction {
    case .prev: return max(0, current - 1)
    case .next: return min(count - 1, current + 1)
    }
}

// MARK: - ViewerEntry

/// One previewable item, decoupled from its source. `resolve` materializes it to a
/// local file URL on demand: local = identity, remote (SFTP/S3/archive) = download/extract.
/// Returning nil means the item could not be fetched.
struct ViewerEntry {
    let title: String
    let resolve: () async -> URL?
}

// MARK: - InternalViewerController

/// Embedded Quick Look viewer in our OWN window (via `QLPreviewView`, not the global
/// `QLPreviewPanel`). Because the view lives in our window's responder chain, we fully
/// control the keyboard: arrow keys step file-to-file, Esc closes, space + everything
/// else go to QLPreviewView (e.g. pause a video). Items are loaded lazily one at a time,
/// so opening a huge folder stays instant and remote items download on demand.
@MainActor
final class InternalViewerController: NSObject, NSWindowDelegate {
    static let shared = InternalViewerController()

    private var entries: [ViewerEntry] = []
    private var currentIndex = 0
    private var onIndexChange: ((Int) -> Void)?
    private var navGeneration = 0

    private var window: NSWindow?
    private var previewView: QLPreviewView?
    private var monitor: Any?

    private override init() { super.init() }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Show `entries`, opening on `start`. If already visible, reuses the window and
    /// replaces the list in place. `onIndexChange` fires whenever the shown item changes
    /// (nil for sources without a panel cursor, e.g. search results).
    func show(entries: [ViewerEntry], start: Int, onIndexChange: ((Int) -> Void)?) {
        guard !entries.isEmpty else { NSSound.beep(); return }
        self.entries = entries
        self.onIndexChange = onIndexChange
        let startIdx = max(0, min(start, entries.count - 1))

        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        load(startIdx)
    }

    func close() { window?.performClose(nil) }

    // MARK: Window

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.delegate = self
        w.isReleasedWhenClosed = false
        let pv = QLPreviewView(frame: w.contentView!.bounds, style: .normal)!
        pv.autoresizingMask = [.width, .height]
        pv.shouldCloseWithWindow = true
        pv.autostarts = true
        w.contentView?.addSubview(pv)
        w.center()
        self.window = w
        self.previewView = pv
        installMonitor()
    }

    /// Window-scoped key monitor: only acts on our window. Arrow keys are consumed here
    /// (returning nil) BEFORE the responder chain, so QLPreviewView never sees them.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            switch event.keyCode {
            case 123, 126: self.navigate(.prev); return nil   // ← / ↑
            case 124, 125: self.navigate(.next); return nil   // → / ↓
            case 53: self.close(); return nil                 // Esc
            default: return event                             // space (49) & others → QLPreviewView
            }
        }
    }

    private func navigate(_ dir: ViewerNavDirection) {
        let ni = nextIndex(current: currentIndex, count: entries.count, direction: dir)
        guard ni != currentIndex else { return }
        load(ni)
    }

    /// Resolve and show item `index`. Remote resolves are async; a generation token
    /// discards stale results when the user keeps pressing the arrow keys.
    private func load(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        navGeneration += 1
        let gen = navGeneration
        let entry = entries[index]
        let total = entries.count
        Task { [weak self] in
            let url = await entry.resolve()
            guard let self = self, self.navGeneration == gen else { return }
            if let url = url {
                self.previewView?.previewItem = url as NSURL
                self.window?.title = "\(entry.title) — (\(index + 1)/\(total))"
            } else {
                self.previewView?.previewItem = nil
                self.window?.title = "\(tr("Cannot load")) — (\(index + 1)/\(total))"
                NSSound.beep()
            }
            self.onIndexChange?(index)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        previewView?.close()
        previewView = nil
        window = nil
        entries = []
        onIndexChange = nil
    }
}
