import XCTest
@testable import double_finder

final class MediaByteRangeTests: XCTestCase {
    func testFullAndOpenRanges() throws {
        XCTAssertEqual(try MediaByteRange.parse(nil, size: 100), 0..<100)
        XCTAssertEqual(try MediaByteRange.parse("bytes=20-", size: 100), 20..<100)
        XCTAssertEqual(try MediaByteRange.parse("bytes=20-29", size: 100), 20..<30)
    }
    func testSuffixAndClamping() throws {
        XCTAssertEqual(try MediaByteRange.parse("bytes=-10", size: 100), 90..<100)
        XCTAssertEqual(try MediaByteRange.parse("bytes=90-200", size: 100), 90..<100)
    }
    func testInvalidRanges() {
        for value in ["bytes=100-", "bytes=50-20", "bytes=-0", "bytes=0-1,3-4", "bytes=wat", "items=0-1"] {
            XCTAssertThrowsError(try MediaByteRange.parse(value, size: 100))
        }
        XCTAssertThrowsError(try MediaByteRange.parse("bytes=0-", size: 0))
    }
}
