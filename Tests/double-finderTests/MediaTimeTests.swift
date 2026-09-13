import XCTest
@testable import double_finder

/// The media player's time labels.
final class MediaTimeTests: XCTestCase {
    func testFormatsMinutesAndHours() {
        XCTAssertEqual(MediaTime.format(milliseconds: 0), "0:00")
        XCTAssertEqual(MediaTime.format(milliseconds: 5_999), "0:05")      // floors, never rounds up
        XCTAssertEqual(MediaTime.format(milliseconds: 65_000), "1:05")
        XCTAssertEqual(MediaTime.format(milliseconds: 3_600_000), "1:00:00")
        XCTAssertEqual(MediaTime.format(milliseconds: 37_212_000), "10:20:12")
    }

    func testUnknownDuration() {
        XCTAssertEqual(MediaTime.format(milliseconds: -1), "–:––")
    }
}
