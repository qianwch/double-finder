import XCTest
import AppKit
@testable import double_finder

/// Regression for "下拉和取消都点不开": the toolbar queue indicator must actually receive
/// mouse events. The original bug was a zero-size wrapper view — the widget rendered (via
/// compression-resistance overflow) but `hitTest` stopped at the empty wrapper and never
/// descended, so NO click (popover toggle OR cancel button) ever reached the widget.
@MainActor
final class QueueToolbarHitTestTests: XCTestCase {

    private func firstButton(in v: NSView) -> NSButton? {
        for s in v.subviews {
            if let b = s as? NSButton { return b }
            if let b = firstButton(in: s) { return b }
        }
        return nil
    }

    func testAccessoryHasRealFrameAndReceivesClicks() {
        let bar = ToolbarBar(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        let widget = QueueCompactView()
        widget.update(symbol: "arrow.up.circle", name: "df_click_test.bin", fraction: 0.5)
        bar.setTrailingAccessory(widget)
        bar.layoutSubtreeIfNeeded()

        // 1. The widget must get a real, non-zero frame (the wrapper bug gave it none).
        XCTAssertGreaterThan(widget.frame.width, 20, "accessory must have a real width")
        XCTAssertGreaterThan(widget.frame.height, 0, "accessory must have a real height")

        // 2. A click in the widget's body (not on the ✕) must reach the widget itself
        //    (its hitTest returns self → mouseDown → toggles the popover).
        let bodyPoint = NSPoint(x: widget.frame.minX + 6, y: widget.frame.midY)
        let bodyHit = bar.hitTest(bodyPoint)
        XCTAssertTrue(bodyHit === widget,
                      "body click must reach the widget (→ popover); got \(String(describing: bodyHit))")

        // 3. A click on the ✕ cancel button must reach the button (not the widget),
        //    so it can abort the task independently.
        guard let cancel = firstButton(in: widget) else {
            return XCTFail("widget should contain a cancel button")
        }
        let cancelCenter = cancel.convert(NSPoint(x: cancel.bounds.midX, y: cancel.bounds.midY), to: bar)
        let cancelHit = bar.hitTest(cancelCenter)
        XCTAssertTrue(cancelHit === cancel || cancelHit?.isDescendant(of: cancel) == true,
                      "✕ click must reach the cancel button; got \(String(describing: cancelHit))")
    }
}
