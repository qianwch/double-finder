import Foundation

/// Geometry for the colour-well grids in Settings ▸ Appearance: how many
/// columns fit the current width, and where each labelled well lands.
///
/// Pure value logic (no AppKit views, no UserDefaults) so it can be unit
/// tested — same split as `FileColumnLayout` / `FileRowGeometry`.
enum ColorGridLayout {
    /// How many columns of `cellWidth` fit in `availableWidth` with `gap`
    /// between them. Always at least 1, never more than there are items.
    static func columns(count: Int, availableWidth: CGFloat,
                        cellWidth: CGFloat, gap: CGFloat) -> Int {
        guard count > 0, cellWidth > 0 else { return 1 }
        // n columns need n*cellWidth + (n-1)*gap, i.e. (width + gap) / (cell + gap).
        let fit = Int(floor((availableWidth + gap) / (cellWidth + gap)))
        return max(1, min(count, fit))
    }

    /// Rows needed once the column count is known.
    static func rows(count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        let cols = max(1, columns)
        return (count + cols - 1) / cols
    }

    /// Column/row of one item. Fills **column-first** (top to bottom, then the
    /// next column) so the original vertical reading order survives folding.
    static func position(index: Int, rows: Int) -> (column: Int, row: Int) {
        guard rows > 0 else { return (0, 0) }
        return (index / rows, index % rows)
    }

    /// Total height for the grid.
    static func height(count: Int, columns: Int, rowHeight: CGFloat) -> CGFloat {
        CGFloat(rows(count: count, columns: columns)) * rowHeight
    }

    /// Origin (top-left, flipped coordinates) of the cell at `index`.
    static func origin(index: Int, rows: Int, cellWidth: CGFloat,
                       gap: CGFloat, rowHeight: CGFloat) -> CGPoint {
        let pos = position(index: index, rows: rows)
        return CGPoint(x: CGFloat(pos.column) * (cellWidth + gap),
                       y: CGFloat(pos.row) * rowHeight)
    }
}
