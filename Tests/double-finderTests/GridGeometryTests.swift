import XCTest
@testable import double_finder

/// Brief-mode multi-column grid math (column-major flow, horizontal scroll).
final class GridGeometryTests: XCTestCase {
    /// iconSize 16 → brief rowHeight 18; viewport 90 → 5 rows per column.
    private var g: FileRowGeometry {
        var g = FileRowGeometry(mode: .brief, iconSize: 16)
        g.viewportHeight = 90
        return g
    }
    private let colW = FileRowGeometry.briefColumnWidth

    func testRowsPerColumn() {
        XCTAssertEqual(g.rowsPerColumn, 5)
        var tall = FileRowGeometry(mode: .brief, iconSize: 16)
        tall.viewportHeight = 0
        XCTAssertEqual(tall.rowsPerColumn, 1, "pre-layout floor is 1, never 0")
        XCTAssertEqual(FileRowGeometry(mode: .full, iconSize: 16).rowsPerColumn, 1)
    }

    func testRowRectColumnMajor() {
        XCTAssertEqual(g.rowRect(0, width: 999),
                       NSRect(x: 0, y: 0, width: colW, height: 18))
        XCTAssertEqual(g.rowRect(4, width: 999),
                       NSRect(x: 0, y: 72, width: colW, height: 18))     // last in col 0
        XCTAssertEqual(g.rowRect(5, width: 999),
                       NSRect(x: colW, y: 0, width: colW, height: 18))   // wraps to col 1
        XCTAssertEqual(g.rowRect(12, width: 999),
                       NSRect(x: 2 * colW, y: 36, width: colW, height: 18))
    }

    func testHitTestInvertsRowRect() {
        for row in 0..<23 {
            let rect = g.rowRect(row, width: 0)
            let mid = NSPoint(x: rect.midX, y: rect.midY)
            XCTAssertEqual(g.rowAt(point: mid, count: 23), row, "row \(row)")
        }
        // Below the last grid row (gap under row 4) → nil.
        XCTAssertNil(g.rowAt(point: NSPoint(x: 10, y: 91), count: 23))
        // Column beyond the item count → nil.
        XCTAssertNil(g.rowAt(point: NSPoint(x: colW * 10 + 5, y: 5), count: 23))
        XCTAssertNil(g.rowAt(point: NSPoint(x: -3, y: 5), count: 23))
    }

    func testVisibleRowsCoversDirtyColumns() {
        // Dirty rect spanning columns 1–2 → indices 5...14 (clamped to count).
        let rect = NSRect(x: colW + 5, y: 0, width: colW, height: 90)
        XCTAssertEqual(g.visibleRows(in: rect, count: 100), 5...14)
        XCTAssertEqual(g.visibleRows(in: rect, count: 8), 5...7)   // clamp to count
        XCTAssertNil(g.visibleRows(in: rect, count: 0))
    }

    func testContentSize() {
        let clip = NSSize(width: 400, height: 90)
        // 12 items / 5 per column → 3 columns.
        XCTAssertEqual(g.contentSize(count: 12, clipSize: clip),
                       NSSize(width: 3 * colW, height: 90))
        // Few items: width never shrinks below the clip.
        XCTAssertEqual(g.contentSize(count: 2, clipSize: clip),
                       NSSize(width: 400, height: 90))
        XCTAssertEqual(g.contentSize(count: 0, clipSize: clip),
                       NSSize(width: 400, height: 90))
    }

    func testDisclosureRectOffsetsByCell() {
        let r = g.disclosureRect(row: 5, depth: 0)   // col 1, first row
        XCTAssertEqual(r.minX, colW + 2)
        XCTAssertEqual(r.minY, (18 - 12) / 2)
    }
}
