import CoreGraphics

/// Pure-value column geometry for the owner-drawn file list.
/// No AppKit views, no UserDefaults — fully deterministic and unit-testable.
struct FileColumnLayout {

    /// Optional columns (beyond Name) the user can show/hide via the header menu.
    /// Tuple: column id, header title, default width.
    static let optionalColumns: [(id: String, title: String, width: CGFloat)] = [
        ("size", "Size", 80), ("date", "Modified", 130),
        ("added", "Date Added", 130), ("created", "Date Created", 130),
        ("kind", "Kind", 130), ("perms", "Permissions", 100),
    ]

    struct Col {
        let id: String
        let title: String
        var width: CGFloat
        let isName: Bool
    }

    /// Ordered columns: Name first (flexible), then visible optionals.
    private(set) var columns: [Col]

    /// Width of the Name column (= totalWidth − Σ optional widths, min 120).
    var nameWidth: CGFloat { columns.first?.width ?? 0 }

    // MARK: - Init

    init(totalWidth: CGFloat, visibleOptionalIDs: [String], widths: [String: CGFloat]) {
        // Build lookup from optionalColumns (same struct, static let).
        let optMeta: [String: (title: String, defaultWidth: CGFloat)] = {
            var d: [String: (String, CGFloat)] = [:]
            for col in Self.optionalColumns {
                d[col.id] = (col.title, col.width)
            }
            return d
        }()

        // Compute optional columns in the order declared by visibleOptionalIDs.
        var optionalCols: [Col] = []
        var sumOptional: CGFloat = 0
        for id in visibleOptionalIDs {
            guard let meta = optMeta[id] else { continue }
            let w = widths[id] ?? meta.defaultWidth
            optionalCols.append(Col(id: id, title: meta.title, width: w, isName: false))
            sumOptional += w
        }

        // Name column: flexible, clamped to minimum 120.
        let nameW = max(120, totalWidth - sumOptional)
        let nameCol = Col(id: "name", title: "Name", width: nameW, isName: true)

        columns = [nameCol] + optionalCols
    }

    // MARK: - Geometry queries

    /// The x-range [left, right) expressed as a ClosedRange for a given column id.
    func xRange(of id: String) -> ClosedRange<CGFloat>? {
        var x: CGFloat = 0
        for col in columns {
            let right = x + col.width
            if col.id == id {
                return x...right
            }
            x = right
        }
        return nil
    }

    /// Returns the id of the column whose x-range contains `atX`.
    func column(atX: CGFloat) -> String? {
        var x: CGFloat = 0
        for col in columns {
            let right = x + col.width
            if atX >= x && atX < right {
                return col.id
            }
            x = right
        }
        // Hit exactly the last right edge → belongs to last column.
        if let last = columns.last, atX == x {
            return last.id
        }
        return nil
    }

    /// Returns the column id whose RIGHT edge is within `tolerance` of `atX` (for drag-to-resize).
    /// Only non-last columns are resizable (resizing the last column from its right edge is not meaningful).
    func resizeDivider(atX: CGFloat, tolerance: CGFloat) -> String? {
        var x: CGFloat = 0
        // We check all columns except the last (no right-edge divider past the last column).
        for i in 0..<columns.count - 1 {
            let col = columns[i]
            let right = x + col.width
            if abs(atX - right) <= tolerance {
                return col.id
            }
            x = right
        }
        return nil
    }
}
