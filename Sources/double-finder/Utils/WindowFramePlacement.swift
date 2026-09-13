import Foundation

/// Where the main window goes at launch, from the frame saved last session and
/// the displays connected now. Pure geometry so it can be unit-tested; the
/// window controller feeds it `NSScreen.screens.map(\.visibleFrame)`.
enum WindowFramePlacement {
    /// Least overlap with a display for a saved frame to count as "still on
    /// screen" (enough of the title bar to grab).
    static let minVisible = NSSize(width: 100, height: 50)
    /// Anything smaller than this is a corrupt or absurd saved value.
    static let minSize = NSSize(width: 200, height: 150)

    /// - `saved`: the frame string from UserDefaults (`NSStringFromRect`), or nil.
    /// - `visibleFrames`: every connected display's visible area, main first.
    /// Returns the frame to use, or nil when there is nothing usable and the
    /// caller should fall back to its own default (maximize the main display).
    static func frame(saved: String?, visibleFrames: [NSRect]) -> NSRect? {
        guard let saved else { return nil }
        let r = NSRectFromString(saved)
        guard r.width >= minSize.width, r.height >= minSize.height,
              r.origin.x.isFinite, r.origin.y.isFinite, let main = visibleFrames.first else { return nil }
        // Still on a connected display: keep it exactly (macOS trims anything
        // that hangs off the edge when the window is shown).
        for screen in visibleFrames {
            let i = r.intersection(screen)
            if i.width >= minVisible.width, i.height >= minVisible.height { return r }
        }
        // The display it was on is gone (undocked laptop, monitor unplugged):
        // keep the size, clamped to the main display, and centre it there.
        let size = NSSize(width: min(r.width, main.width), height: min(r.height, main.height))
        return NSRect(x: (main.midX - size.width / 2).rounded(), y: (main.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}
