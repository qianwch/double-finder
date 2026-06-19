import AppKit

/// A layer-backed view whose background color re-resolves on every effective-
/// appearance change. Plain `layer.backgroundColor = NSColor.x.cgColor` snapshots
/// the color for the appearance at assignment time and does NOT update when the
/// app switches light/dark — this view fixes that for the bars that use it.
final class AppearanceAwareView: NSView {
    var backgroundColor: NSColor? {
        didSet { applyBackground() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        guard let color = backgroundColor else {
            layer?.backgroundColor = nil
            return
        }
        // Resolve the cgColor against the CURRENT effective appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
