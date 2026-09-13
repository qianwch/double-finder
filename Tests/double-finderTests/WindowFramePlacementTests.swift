import XCTest
@testable import double_finder

/// Launch placement of the main window from last session's saved frame.
final class WindowFramePlacementTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875)            // visible area of a 1440×900 display
    private let external = NSRect(x: 1440, y: -200, width: 2560, height: 1415)   // to the right, taller

    func testSavedFrameOnAConnectedDisplayIsKeptExactly() {
        let saved = NSStringFromRect(NSRect(x: 1600, y: 100, width: 1800, height: 1100))
        XCTAssertEqual(WindowFramePlacement.frame(saved: saved, visibleFrames: [laptop, external]),
                       NSRect(x: 1600, y: 100, width: 1800, height: 1100))
    }

    func testFramePartlyOffTheEdgeStillCounts() {
        // Hanging off the bottom-left but plenty of title bar still visible.
        let saved = NSStringFromRect(NSRect(x: -300, y: -400, width: 1280, height: 768))
        XCTAssertEqual(WindowFramePlacement.frame(saved: saved, visibleFrames: [laptop]),
                       NSRect(x: -300, y: -400, width: 1280, height: 768))
    }

    func testFrameOnAnUnpluggedDisplayIsCentredOnMainWithClampedSize() {
        // Was on the external display; now only the laptop is connected.
        let saved = NSStringFromRect(NSRect(x: 1600, y: 100, width: 1800, height: 1100))
        let placed = WindowFramePlacement.frame(saved: saved, visibleFrames: [laptop])
        XCTAssertEqual(placed?.size, NSSize(width: 1440, height: 875))      // clamped to what fits
        XCTAssertEqual(placed?.origin, NSPoint(x: 0, y: 0))                 // centred = fills the display
        let small = NSStringFromRect(NSRect(x: 3000, y: 100, width: 1000, height: 600))
        XCTAssertEqual(WindowFramePlacement.frame(saved: small, visibleFrames: [laptop]),
                       NSRect(x: 220, y: 138, width: 1000, height: 600))     // centred (origin rounded), size kept
    }

    func testMissingOrCorruptValuesFallBack() {
        XCTAssertNil(WindowFramePlacement.frame(saved: nil, visibleFrames: [laptop]))
        XCTAssertNil(WindowFramePlacement.frame(saved: "garbage", visibleFrames: [laptop]))          // NSZeroRect
        XCTAssertNil(WindowFramePlacement.frame(saved: "{{0, 0}, {50, 40}}", visibleFrames: [laptop]))
        XCTAssertNil(WindowFramePlacement.frame(saved: "{{0, 0}, {1280, 768}}", visibleFrames: []))  // no displays yet
    }
}
