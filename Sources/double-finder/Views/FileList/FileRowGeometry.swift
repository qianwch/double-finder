import AppKit

/// Pure-value row-geometry math for the owner-drawn file list.
///
/// Coordinates are **flipped** (top-left origin, y increases downward).
/// full / thumbnails are single-column lists: row `r` occupies
/// `y ∈ [r*rowHeight, (r+1)*rowHeight)`. brief is a TC-style multi-column
/// grid: items flow top-to-bottom, then wrap into the next column to the
/// right (column-major), and the panel scrolls horizontally. `viewportHeight`
/// (the clip-view height) drives rows-per-column and must be set by the view
/// layer before grid math is used.
struct FileRowGeometry {

    let mode: FileViewMode
    let iconSize: CGFloat
    /// Line height of the name font. Rows grow past the icon to fit it when the
    /// list font is larger than the icon (0 = icon-only sizing).
    var textHeight: CGFloat = 0
    /// Clip-view height; only the brief grid reads it. 0 until first layout.
    var viewportHeight: CGFloat = 0

    /// Fixed column width of the brief grid (TC uses fixed-width columns too).
    static let briefColumnWidth: CGFloat = 220

    var isGrid: Bool { mode == .brief }

    /// Computed row height that matches `FileTableView.tableView(_:heightOfRow:)`.
    var rowHeight: CGFloat {
        switch mode {
        case .full:       return max(iconSize + 4, textHeight + 6)
        case .brief:      return max(iconSize + 2, textHeight + 4)
        case .thumbnails: return 56
        }
    }

    /// Rows stacked in one grid column (≥1 even before layout).
    var rowsPerColumn: Int {
        guard isGrid else { return 1 }
        return max(1, Int(viewportHeight / rowHeight))
    }

    // MARK: - Row rect

    /// The NSRect for a given row. `width` is the list width (single-column
    /// modes span it; the grid uses the fixed column width instead).
    func rowRect(_ row: Int, width: CGFloat) -> NSRect {
        if isGrid {
            let rpc = rowsPerColumn
            let col = row / rpc
            let r = row % rpc
            return NSRect(x: CGFloat(col) * Self.briefColumnWidth,
                          y: CGFloat(r) * rowHeight,
                          width: Self.briefColumnWidth, height: rowHeight)
        }
        return NSRect(x: 0, y: CGFloat(row) * rowHeight, width: width, height: rowHeight)
    }

    // MARK: - Hit testing

    /// Returns the row index containing `point`, or `nil` if out of bounds.
    /// Single-column modes only consult `y`; the grid needs both axes.
    func rowAt(point: NSPoint, count: Int) -> Int? {
        guard count > 0, point.y >= 0 else { return nil }
        if isGrid {
            guard point.x >= 0 else { return nil }
            let r = Int(point.y / rowHeight)
            guard r < rowsPerColumn else { return nil }   // gap below the last grid row
            let row = Int(point.x / Self.briefColumnWidth) * rowsPerColumn + r
            return row < count ? row : nil
        }
        let row = Int(point.y / rowHeight)
        return row < count ? row : nil
    }

    // MARK: - Visible range

    /// Returns the closed range of row indices that intersect `rect`, clamped
    /// to `0...count-1`. Grid ranges cover whole columns (column-major indices
    /// are contiguous per column, so a horizontal slice is one closed range).
    func visibleRows(in rect: NSRect, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        if isGrid {
            let rpc = rowsPerColumn
            let firstCol = max(0, Int(floor(rect.minX / Self.briefColumnWidth)))
            let lastCol = Int(ceil(rect.maxX / Self.briefColumnWidth)) - 1
            guard lastCol >= firstCol else { return nil }
            let first = min(count - 1, firstCol * rpc)
            let last = min(count - 1, (lastCol + 1) * rpc - 1)
            guard first <= last else { return nil }
            return first...last
        }
        let first = max(0, Int(floor(rect.minY / rowHeight)))
        let last  = min(count - 1, Int(ceil(rect.maxY / rowHeight)) - 1)
        guard first <= last else { return nil }
        return first...last
    }

    // MARK: - Content size

    /// Document-view size for `count` items inside a clip view of `clipSize`.
    /// Both dimensions cover at least the clip so clicks in blank space still
    /// land on the body view.
    func contentSize(count: Int, clipSize: NSSize) -> NSSize {
        if isGrid {
            let rpc = rowsPerColumn
            let cols = count == 0 ? 0 : (count + rpc - 1) / rpc
            return NSSize(width: max(clipSize.width, CGFloat(cols) * Self.briefColumnWidth),
                          height: clipSize.height)
        }
        return NSSize(width: max(clipSize.width, 480),
                      height: max(CGFloat(count) * rowHeight, clipSize.height))
    }

    // MARK: - Disclosure triangle rect

    /// A ~12 pt square for the expand/collapse triangle, indented by `depth`,
    /// relative to the row's cell origin (grid-aware).
    ///
    /// Constants:
    /// - Leading margin: 2 pt
    /// - Per-depth indent: 12 pt
    /// - Square size: 12 pt
    func disclosureRect(row: Int, depth: Int) -> NSRect {
        let size: CGFloat = 12
        let leadingMargin: CGFloat = 2
        let indentPerLevel: CGFloat = 12
        let origin = rowRect(row, width: 0).origin
        let x = origin.x + leadingMargin + CGFloat(depth) * indentPerLevel
        let y = origin.y + (rowHeight - size) / 2   // vertically centred
        return NSRect(x: x, y: y, width: size, height: size)
    }
}
