import XCTest
@testable import double_finder

final class FileRowGeometryTests: XCTestCase {

    // MARK: - rowHeight

    func testRowHeightFull() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        XCTAssertEqual(g.rowHeight, 28, "full: iconSize + 4")
    }

    func testRowHeightBrief() {
        let g = FileRowGeometry(mode: .brief, iconSize: 24)
        XCTAssertEqual(g.rowHeight, 26, "brief: iconSize + 2")
    }

    func testRowHeightThumbnails() {
        let g = FileRowGeometry(mode: .thumbnails, iconSize: 24)
        XCTAssertEqual(g.rowHeight, 56, "thumbnails: fixed 56")
    }

    func testRowHeightFullCustomIconSize() {
        let g = FileRowGeometry(mode: .full, iconSize: 32)
        XCTAssertEqual(g.rowHeight, 36, "full with iconSize=32: 32+4")
    }

    // MARK: - rowRect

    func testRowRectRow0() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let rect = g.rowRect(0, width: 200)
        XCTAssertEqual(rect.origin.x, 0)
        XCTAssertEqual(rect.origin.y, 0, "row 0 starts at y=0")
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, g.rowHeight)
    }

    func testRowRectRow1() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let rect = g.rowRect(1, width: 300)
        XCTAssertEqual(rect.origin.y, g.rowHeight, "row 1 starts at y=rowHeight")
        XCTAssertEqual(rect.height, g.rowHeight)
    }

    func testRowRectRow3() {
        let g = FileRowGeometry(mode: .brief, iconSize: 16)
        let rh = g.rowHeight  // 18
        let rect = g.rowRect(3, width: 400)
        XCTAssertEqual(rect.origin.y, 3 * rh, accuracy: 0.001)
        XCTAssertEqual(rect.height, rh, accuracy: 0.001)
    }

    // MARK: - rowAt

    func testRowAtMiddleOfRow1() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        // y = 1.5 * rowHeight falls in row 1
        let y = 1.5 * g.rowHeight
        XCTAssertEqual(g.rowAt(y: y, count: 10), 1)
    }

    func testRowAtNegativeY() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        XCTAssertNil(g.rowAt(y: -5, count: 10), "negative y → nil")
    }

    func testRowAtYBeyondCount() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        // y lands on row 10 but count=10 means max valid row index is 9
        let y = 10.0 * g.rowHeight + 1
        XCTAssertNil(g.rowAt(y: y, count: 10), "row index >= count → nil")
    }

    func testRowAtExactlyZero() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        XCTAssertEqual(g.rowAt(y: 0, count: 5), 0)
    }

    func testRowAtLastPixelOfRow0() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let y = g.rowHeight - 0.001
        XCTAssertEqual(g.rowAt(y: y, count: 5), 0)
    }

    func testRowAtZeroCount() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        XCTAssertNil(g.rowAt(y: 0, count: 0), "count=0 → nil")
    }

    // MARK: - visibleRows

    func testVisibleRowsBasic() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let rh = g.rowHeight
        // rect spanning rows 1 and 2
        let rect = NSRect(x: 0, y: rh, width: 200, height: rh * 2)
        let range = g.visibleRows(in: rect, count: 10)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 1)
        XCTAssertEqual(range?.upperBound, 2)
    }

    func testVisibleRowsClampedToCount() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let rh = g.rowHeight
        // rect that would go past row 4 if count were large
        let rect = NSRect(x: 0, y: 0, width: 200, height: rh * 20)
        let range = g.visibleRows(in: rect, count: 5)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 0)
        XCTAssertEqual(range?.upperBound, 4, "clamped to count-1 = 4")
    }

    func testVisibleRowsZeroCount() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let rect = NSRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertNil(g.visibleRows(in: rect, count: 0), "count=0 → nil")
    }

    func testVisibleRowsEmptyRect() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        // A zero-height rect that covers no full row
        let rect = NSRect(x: 0, y: 0, width: 200, height: 0)
        // first = 0, last = ceil(0/rh)-1 = -1 → empty → nil
        XCTAssertNil(g.visibleRows(in: rect, count: 10), "empty rect → nil")
    }

    func testVisibleRowsClampsLower() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        // rect starting before y=0
        let rect = NSRect(x: 0, y: -g.rowHeight, width: 200, height: g.rowHeight * 3)
        let range = g.visibleRows(in: rect, count: 10)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 0, "first row clamped to 0")
    }

    // MARK: - disclosureRect

    func testDisclosureRectDepth0WithinRowY() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let rowR = g.rowRect(2, width: 400)
        let dr = g.disclosureRect(row: 2, depth: 0)
        XCTAssertGreaterThanOrEqual(dr.minY, rowR.minY, "disclosure minY >= row minY")
        XCTAssertLessThanOrEqual(dr.maxY, rowR.maxY, "disclosure maxY <= row maxY")
    }

    func testDisclosureRectShiftsRightWithDepth() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let dr0 = g.disclosureRect(row: 0, depth: 0)
        let dr1 = g.disclosureRect(row: 0, depth: 1)
        let dr2 = g.disclosureRect(row: 0, depth: 2)
        XCTAssertLessThan(dr0.minX, dr1.minX, "depth 1 is right of depth 0")
        XCTAssertLessThan(dr1.minX, dr2.minX, "depth 2 is right of depth 1")
    }

    func testDisclosureRectIsSmall() {
        let g = FileRowGeometry(mode: .full, iconSize: 24)
        let dr = g.disclosureRect(row: 0, depth: 0)
        XCTAssertGreaterThan(dr.width, 0)
        XCTAssertLessThanOrEqual(dr.width, 20, "disclosure rect should be small (~12pt)")
        XCTAssertLessThanOrEqual(dr.height, 20)
    }
}
