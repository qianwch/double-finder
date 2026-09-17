import XCTest
@testable import double_finder

final class UpdateScheduleTests: XCTestCase {
    func testNeverCheckedIsAlwaysDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: nil, intervalDays: 7))
    }

    func testNotYetDueWithinTheInterval() {
        let now = Date()
        let checkedTenHoursAgo = now.addingTimeInterval(-10 * 3600)
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: checkedTenHoursAgo, intervalDays: 1, now: now))
    }

    func testDueOnceTheIntervalHasFullyElapsed() {
        let now = Date()
        let checkedTwoDaysAgo = now.addingTimeInterval(-2 * 86400)
        XCTAssertTrue(UpdateSchedule.isDue(lastChecked: checkedTwoDaysAgo, intervalDays: 1, now: now))
    }

    func testIntervalIsFlooredToOneDay() {
        // A 0 (or negative) interval must not turn into "check constantly".
        let now = Date()
        let checkedOneHourAgo = now.addingTimeInterval(-3600)
        XCTAssertFalse(UpdateSchedule.isDue(lastChecked: checkedOneHourAgo, intervalDays: 0, now: now))
    }
}
