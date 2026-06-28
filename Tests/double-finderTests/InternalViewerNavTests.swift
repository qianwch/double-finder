import XCTest
@testable import double_finder

final class InternalViewerNavTests: XCTestCase {
    func testNext() { XCTAssertEqual(nextIndex(current: 0, count: 3, direction: .next), 1) }
    func testNextClampAtEnd() { XCTAssertEqual(nextIndex(current: 2, count: 3, direction: .next), 2) }
    func testPrev() { XCTAssertEqual(nextIndex(current: 2, count: 3, direction: .prev), 1) }
    func testPrevClampAtStart() { XCTAssertEqual(nextIndex(current: 0, count: 3, direction: .prev), 0) }
    func testEmpty() { XCTAssertEqual(nextIndex(current: 0, count: 0, direction: .next), 0) }
    func testSingle() {
        XCTAssertEqual(nextIndex(current: 0, count: 1, direction: .next), 0)
        XCTAssertEqual(nextIndex(current: 0, count: 1, direction: .prev), 0)
    }
}
