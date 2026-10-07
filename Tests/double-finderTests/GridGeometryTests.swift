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

/// Thumbnail tiles flow left-to-right and adapt to both panel width and zoom.
final class ThumbnailGridGeometryTests: XCTestCase {
    private func geometry(width: CGFloat = 600, icon: CGFloat = 24) -> FileRowGeometry {
        var g = FileRowGeometry(mode: .thumbnails, iconSize: icon, textHeight: 16)
        g.viewportWidth = width
        return g
    }

    func testColumnsAdaptToWidthAndZoom() {
        let normal = geometry()
        XCTAssertGreaterThan(normal.columnsPerRow, 1)
        XCTAssertGreaterThan(geometry(width: 1000).columnsPerRow, normal.columnsPerRow)
        XCTAssertLessThan(geometry(icon: 48).columnsPerRow, normal.columnsPerRow)
        XCTAssertEqual(geometry(width: 1).columnsPerRow, 1)
        XCTAssertEqual(geometry(width: 0).columnsPerRow, 1)
        XCTAssertGreaterThan(geometry(icon: 48).rowHeight, normal.rowHeight)
        XCTAssertGreaterThan(geometry(icon: 48).thumbnailSide, normal.thumbnailSide)
    }

    func testRowMajorRectsAndHitTesting() {
        let g = geometry()
        let columns = g.columnsPerRow
        XCTAssertEqual(g.rowRect(1, width: 600).minY, 0)
        XCTAssertGreaterThan(g.rowRect(1, width: 600).minX, 0)
        XCTAssertEqual(g.rowRect(columns, width: 600).minX, 0)
        XCTAssertEqual(g.rowRect(columns, width: 600).minY, g.rowHeight)
        for row in 0..<(columns + 2) {
            let rect = g.rowRect(row, width: 600)
            XCTAssertEqual(g.rowAt(point: NSPoint(x: rect.midX, y: rect.midY), count: columns + 2), row)
            XCTAssertLessThanOrEqual(rect.maxX, 600.001)
            let icon = g.thumbnailRect(row: row)
            let name = g.thumbnailNameRect(row: row)
            XCTAssertGreaterThanOrEqual(name.minY, icon.maxY)
            XCTAssertTrue(rect.contains(icon))
            XCTAssertTrue(rect.contains(name))
        }
        XCTAssertNil(g.rowAt(point: NSPoint(x: -1, y: 0), count: 30))
        XCTAssertNil(g.rowAt(point: NSPoint(x: 600, y: 0), count: 30))
        let empty = g.rowRect(columns + 2, width: 600)
        XCTAssertNil(g.rowAt(point: NSPoint(x: empty.midX, y: empty.midY), count: columns + 2))
    }

    func testVisibleRowsAndContentHeight() {
        let g = geometry()
        let columns = g.columnsPerRow
        let rect = NSRect(x: 0, y: g.rowHeight, width: 600, height: g.rowHeight)
        XCTAssertEqual(g.visibleRows(in: rect, count: 100), columns...(2 * columns - 1))
        XCTAssertEqual(g.visibleRows(in: rect, count: columns + 1), columns...columns)
        XCTAssertNil(g.visibleRows(in: rect, count: 0))
        XCTAssertNil(g.visibleRows(in: .zero, count: 100))
        XCTAssertNil(g.visibleRows(in: NSRect(x: 0, y: 10000, width: 600, height: 30), count: 2))
        let clip = NSSize(width: 600, height: 100)
        XCTAssertEqual(g.contentSize(count: columns + 1, clipSize: clip),
                       NSSize(width: 600, height: 2 * g.rowHeight))
        XCTAssertEqual(g.contentSize(count: 0, clipSize: clip), clip)
    }
}
