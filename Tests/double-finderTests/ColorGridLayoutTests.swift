import XCTest
@testable import double_finder

/// Reflow geometry for the Appearance pane's colour-well grids.
final class ColorGridLayoutTests: XCTestCase {
    private let cell: CGFloat = 127     // label + gap + well, roughly the real value
    private let gap: CGFloat = 24

    // MARK: - Column count

    func testNarrowWidthFallsBackToOneColumn() {
        XCTAssertEqual(ColorGridLayout.columns(count: 8, availableWidth: 130, cellWidth: cell, gap: gap), 1)
        // Even narrower than a single cell: still one, never zero.
        XCTAssertEqual(ColorGridLayout.columns(count: 8, availableWidth: 40, cellWidth: cell, gap: gap), 1)
    }

    func testWidthForExactlyTwoColumns() {
        let exact = cell * 2 + gap                     // 278
        XCTAssertEqual(ColorGridLayout.columns(count: 8, availableWidth: exact, cellWidth: cell, gap: gap), 2)
        // One point short of fitting the second column.
        XCTAssertEqual(ColorGridLayout.columns(count: 8, availableWidth: exact - 1, cellWidth: cell, gap: gap), 1)
    }

    func testWidthForThreeColumns() {
        let exact = cell * 3 + gap * 2                 // 429
        XCTAssertEqual(ColorGridLayout.columns(count: 8, availableWidth: exact, cellWidth: cell, gap: gap), 3)
    }

    func testColumnsNeverExceedItemCount() {
        XCTAssertEqual(ColorGridLayout.columns(count: 3, availableWidth: 2000, cellWidth: cell, gap: gap), 3)
        XCTAssertEqual(ColorGridLayout.columns(count: 1, availableWidth: 2000, cellWidth: cell, gap: gap), 1)
    }

    func testDegenerateInputs() {
        XCTAssertEqual(ColorGridLayout.columns(count: 0, availableWidth: 500, cellWidth: cell, gap: gap), 1)
        XCTAssertEqual(ColorGridLayout.columns(count: 8, availableWidth: 500, cellWidth: 0, gap: gap), 1)
    }

    // MARK: - Rows and placement

    func testRowsRoundUp() {
        XCTAssertEqual(ColorGridLayout.rows(count: 8, columns: 3), 3)
        XCTAssertEqual(ColorGridLayout.rows(count: 8, columns: 2), 4)
        XCTAssertEqual(ColorGridLayout.rows(count: 8, columns: 1), 8)
        XCTAssertEqual(ColorGridLayout.rows(count: 0, columns: 3), 0)
        XCTAssertEqual(ColorGridLayout.rows(count: 3, columns: 0), 3)   // clamped to 1 column
    }

    /// Folding must keep the vertical reading order: the first column holds the
    /// first N items top-to-bottom, not every other item.
    func testFillsColumnFirst() {
        let rows = ColorGridLayout.rows(count: 8, columns: 2)           // 4
        let placed = (0..<8).map { ColorGridLayout.position(index: $0, rows: rows) }
        XCTAssertEqual(placed[0].column, 0); XCTAssertEqual(placed[0].row, 0)
        XCTAssertEqual(placed[3].column, 0); XCTAssertEqual(placed[3].row, 3)
        XCTAssertEqual(placed[4].column, 1); XCTAssertEqual(placed[4].row, 0)
        XCTAssertEqual(placed[7].column, 1); XCTAssertEqual(placed[7].row, 3)
    }

    func testOddCountLeavesTheLastColumnShort() {
        let rows = ColorGridLayout.rows(count: 3, columns: 2)           // 2
        XCTAssertEqual(rows, 2)
        XCTAssertEqual(ColorGridLayout.position(index: 0, rows: rows).column, 0)
        XCTAssertEqual(ColorGridLayout.position(index: 1, rows: rows).column, 0)
        XCTAssertEqual(ColorGridLayout.position(index: 2, rows: rows).column, 1)
        XCTAssertEqual(ColorGridLayout.position(index: 2, rows: rows).row, 0)
    }

    func testOriginStepsByCellAndRow() {
        let origin = ColorGridLayout.origin(index: 5, rows: 4, cellWidth: 100, gap: 20, rowHeight: 30)
        XCTAssertEqual(origin.x, 120)    // second column
        XCTAssertEqual(origin.y, 30)     // second row
    }

    func testHeightTracksTheColumnCount() {
        XCTAssertEqual(ColorGridLayout.height(count: 8, columns: 1, rowHeight: 30), 240)
        XCTAssertEqual(ColorGridLayout.height(count: 8, columns: 2, rowHeight: 30), 120)
        XCTAssertEqual(ColorGridLayout.height(count: 8, columns: 3, rowHeight: 30), 90)
    }
}
