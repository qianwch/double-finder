import XCTest
@testable import double_finder
final class FileColumnLayoutTests: XCTestCase {
    func testNameFlexFillsRemaining() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size","date"], widths: [:])
        // size=80, date=130 (defaults) → name = 600-210 = 390
        XCTAssertEqual(l.columns.first?.id, "name")
        XCTAssertEqual(l.nameWidth, 390, accuracy: 0.5)
    }
    func testColumnAtXAndDivider() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size"], widths: [:])
        XCTAssertEqual(l.column(atX: 5), "name")
        XCTAssertEqual(l.column(atX: 595), "size")
        XCTAssertEqual(l.resizeDivider(atX: l.xRange(of: "name")!.upperBound, tolerance: 4), "name")
        XCTAssertNil(l.resizeDivider(atX: 300, tolerance: 4))
    }
    func testWidthOverridePersisted() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size"], widths: ["size": 120])
        XCTAssertEqual(l.xRange(of: "size").map { $0.upperBound - $0.lowerBound }, 120)
    }
}
