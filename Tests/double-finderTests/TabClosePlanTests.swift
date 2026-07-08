import XCTest
@testable import double_finder

final class TabClosePlanTests: XCTestCase {
    func testCloseOthers() {
        // 4 tabs, keep index 1, none locked → remove 3,2,0 (descending)
        XCTAssertEqual(TabClosePlan.othersToClose(count: 4, keep: 1, locked: [false, false, false, false]),
                       [3, 2, 0])
    }
    func testCloseOthersSkipsLocked() {
        // keep 1, tab 3 locked → remove 2,0 (3 protected, 1 is the kept)
        XCTAssertEqual(TabClosePlan.othersToClose(count: 4, keep: 1, locked: [false, false, false, true]),
                       [2, 0])
    }
    func testCloseOthersKeepItselfLockedStillKept() {
        // keep 2 which is itself locked → still just the kept; others unlocked removed
        XCTAssertEqual(TabClosePlan.othersToClose(count: 3, keep: 2, locked: [false, false, true]),
                       [1, 0])
    }
    func testCloseOthersAllLocked() {
        XCTAssertEqual(TabClosePlan.othersToClose(count: 3, keep: 0, locked: [true, true, true]), [])
    }
    func testCloseRight() {
        // from 1, count 4, none locked → remove 3,2
        XCTAssertEqual(TabClosePlan.rightToClose(count: 4, from: 1, locked: [false, false, false, false]),
                       [3, 2])
    }
    func testCloseRightSkipsLocked() {
        // from 0, tab 2 locked → remove 3,1 (2 protected)
        XCTAssertEqual(TabClosePlan.rightToClose(count: 4, from: 0, locked: [false, false, true, false]),
                       [3, 1])
    }
    func testCloseRightNothingToTheRight() {
        XCTAssertEqual(TabClosePlan.rightToClose(count: 3, from: 2, locked: [false, false, false]), [])
    }
}
