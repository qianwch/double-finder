import XCTest
@testable import double_finder

final class AppVersionTests: XCTestCase {
    func testComponentsParseDottedIntegers() {
        XCTAssertEqual(AppVersion.components("1.7.10"), [1, 7, 10])
        XCTAssertEqual(AppVersion.components("v1.7.10"), [1, 7, 10])
        XCTAssertEqual(AppVersion.components("2"), [2])
    }

    func testComponentsTreatNonNumericNoiseAsZero() {
        // The CI's rolling prerelease tag — must never look "newer" than a
        // real version (GitHub's releases/latest endpoint already excludes
        // it, but AppVersion must not accidentally undo that if it ever sees it).
        XCTAssertEqual(AppVersion.components("latest"), [0])
    }

    func testIsNewerComparesNumerically() {
        XCTAssertTrue(AppVersion.isNewer("1.7.10", than: "1.7.9"))
        XCTAssertTrue(AppVersion.isNewer("1.8.0", than: "1.7.99"))
        XCTAssertTrue(AppVersion.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(AppVersion.isNewer("1.7.7", than: "1.7.7"))
        XCTAssertFalse(AppVersion.isNewer("1.7.6", than: "1.7.7"))
    }

    func testIsNewerHandlesMismatchedComponentCounts() {
        XCTAssertTrue(AppVersion.isNewer("1.7.1", than: "1.7"))
        XCTAssertFalse(AppVersion.isNewer("1.7", than: "1.7.0"))
        XCTAssertFalse(AppVersion.isNewer("1.7", than: "1.7.1"))
    }

    func testDevPlaceholderNeverLooksUpToDate() {
        // package_app.sh's un-stamped placeholder — a real tagged release
        // must always look newer than it.
        XCTAssertTrue(AppVersion.isNewer("1.0.0", than: "0.0.0"))
    }
}
