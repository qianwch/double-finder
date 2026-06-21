import AppKit

/// Pure-value row-geometry math for the owner-drawn file list.
///
/// Coordinates are **flipped** (top-left origin, y increases downward):
/// row `r` occupies `y ∈ [r*rowHeight, (r+1)*rowHeight)`.
struct FileRowGeometry {

    let mode: FileViewMode
    let iconSize: CGFloat

    /// Computed row height that matches `FileTableView.tableView(_:heightOfRow:)`.
    var rowHeight: CGFloat {
        switch mode {
        case .full:       return iconSize + 4
        case .brief:      return iconSize + 2
        case .thumbnails: return 56
        }
    }

    // MARK: - Row rect

    /// The NSRect for a given row at the given list width.
    func rowRect(_ row: Int, width: CGFloat) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * rowHeight, width: width, height: rowHeight)
    }

    // MARK: - Hit testing

    /// Returns the row index containing `y`, or `nil` if out of bounds.
    func rowAt(y: CGFloat, count: Int) -> Int? {
        guard y >= 0, count > 0 else { return nil }
        let row = Int(y / rowHeight)
        guard row < count else { return nil }
        return row
    }

    // MARK: - Visible range

    /// Returns the closed range of row indices that intersect `rect`, clamped
    /// to `0...count-1`.  Returns `nil` when `count == 0` or the range is empty.
    func visibleRows(in rect: NSRect, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        let first = max(0, Int(floor(rect.minY / rowHeight)))
        let last  = min(count - 1, Int(ceil(rect.maxY / rowHeight)) - 1)
        guard first <= last else { return nil }
        return first...last
    }

    // MARK: - Disclosure triangle rect

    /// A ~12 pt square for the expand/collapse triangle, indented by `depth`.
    ///
    /// Constants:
    /// - Leading margin: 2 pt
    /// - Per-depth indent: 12 pt
    /// - Square size: 12 pt
    func disclosureRect(row: Int, depth: Int) -> NSRect {
        let size: CGFloat = 12
        let leadingMargin: CGFloat = 2
        let indentPerLevel: CGFloat = 12
        let x = leadingMargin + CGFloat(depth) * indentPerLevel
        let rowY = CGFloat(row) * rowHeight
        let y = rowY + (rowHeight - size) / 2   // vertically centred
        return NSRect(x: x, y: y, width: size, height: size)
    }
}
