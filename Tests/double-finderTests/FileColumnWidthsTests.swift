import XCTest
@testable import double_finder

/// TDD for AppSettings.columnWidths — round-trip via UserDefaults.
/// These tests run against the shared UserDefaults suite and clean up after themselves.
final class FileColumnWidthsTests: XCTestCase {

    private let key = "ColumnWidths"

    override func setUp() {
        super.setUp()
        // Remove any leftover value so each test starts clean.
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - Tests

    /// Default must be an empty dictionary (no stored value).
    func testDefaultIsEmpty() {
        XCTAssertTrue(AppSettings.columnWidths.isEmpty)
    }

    /// Setting a single key must round-trip with the same CGFloat value.
    func testSingleKeyPersists() {
        AppSettings.columnWidths = ["size": 120.5]
        let readBack = AppSettings.columnWidths
        XCTAssertEqual(Double(readBack["size"] ?? 0), 120.5, accuracy: 0.001)
        XCTAssertEqual(readBack.count, 1)
    }

    /// Full round-trip: multiple keys, values survive a get → set → get cycle.
    func testRoundTrip() {
        let original: [String: CGFloat] = ["size": 95.0, "date": 160.0, "kind": 200.0]
        AppSettings.columnWidths = original
        let readBack = AppSettings.columnWidths
        XCTAssertEqual(readBack.count, original.count)
        for (k, v) in original {
            XCTAssertEqual(Double(readBack[k] ?? -1), Double(v), accuracy: 0.001,
                           "Key '\(k)' mismatch: expected \(v), got \(readBack[k] ?? -1)")
        }
    }

    /// Overwriting with a new dict must fully replace (not merge) the old value.
    func testOverwrite() {
        AppSettings.columnWidths = ["size": 80.0, "date": 130.0]
        AppSettings.columnWidths = ["size": 200.0]
        let readBack = AppSettings.columnWidths
        XCTAssertEqual(readBack.count, 1)
        XCTAssertEqual(Double(readBack["size"] ?? 0), 200.0, accuracy: 0.001)
        XCTAssertNil(readBack["date"])
    }

    /// Setting to empty dict must produce an empty result on read-back.
    func testSetEmpty() {
        AppSettings.columnWidths = ["size": 80.0]
        AppSettings.columnWidths = [:]
        XCTAssertTrue(AppSettings.columnWidths.isEmpty)
    }
}
