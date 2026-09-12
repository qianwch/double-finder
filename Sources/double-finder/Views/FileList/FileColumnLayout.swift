import CoreGraphics

/// Pure-value column geometry for the owner-drawn file list.
/// No AppKit views, no UserDefaults — fully deterministic and unit-testable.
struct FileColumnLayout {

    /// Built-in optional columns (beyond Name). Tuple: column id, header title, default width.
    static let builtInColumns: [(id: String, title: String, width: CGFloat)] = [
        ("size", "Size", 80), ("date", "Modified", 130),
        ("added", "Date Added", 130), ("created", "Date Created", 130),
        ("kind", "Kind", 130), ("perms", "Permissions", 100),
    ]

    /// Every optional column the user can show/hide via the header menu: the
    /// built-ins, then the columns of active content plugins ("plugin.*" ids,
    /// see `PluginColumnRegistry`). Computed, so enabling a plugin adds its
    /// columns to the chooser without a restart.
    static var optionalColumns: [(id: String, title: String, width: CGFloat)] {
        builtInColumns + PluginColumnRegistry.columns.map { ($0.id, $0.title, $0.width) }
    }

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

    // MARK: - Reordering (drag a header title)

    /// Where a dragged optional column would land if dropped at `x`: a slot
    /// index into the optional-column list (0 = right after Name, n = last).
    /// The boundary between two slots is the midpoint of each column, so the
    /// insertion line flips when the cursor passes a column's centre. Name is
    /// pinned first: no slot exists to its left.
    func dropSlot(atX x: CGFloat) -> Int {
        var left: CGFloat = 0
        for (i, col) in columns.enumerated() {
            let mid = left + col.width / 2
            if i > 0, x < mid { return i - 1 }
            left += col.width
        }
        return max(0, columns.count - 1)
    }

    /// X coordinate of the insertion line for `slot` (the left edge of the
    /// optional column at that slot, or the right edge of the last column).
    func dropLineX(forSlot slot: Int) -> CGFloat {
        var x: CGFloat = 0
        for (i, col) in columns.enumerated() {
            if i == slot + 1 { return x }
            x += col.width
        }
        return x
    }

    /// Moves `id` inside an ordered id list to `slot` (an insertion index in
    /// the list BEFORE removal, as `dropSlot` returns). Unknown id → unchanged.
    static func moved(_ ids: [String], id: String, toSlot slot: Int) -> [String] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        var out = ids
        out.remove(at: from)
        var target = slot > from ? slot - 1 : slot
        target = max(0, min(out.count, target))
        out.insert(id, at: target)
        return out
    }

    /// Where a column being turned on should go: right after the last visible
    /// column that precedes it in the canonical catalogue (front when none),
    /// so the user's own ordering of the other columns is preserved (a plain
    /// canonical re-sort would undo every drag-reorder on each toggle).
    static func inserted(_ ids: [String], adding id: String, canonical: [String]) -> [String] {
        guard !ids.contains(id) else { return ids }
        let rank = canonical.firstIndex(of: id) ?? Int.max
        var out = ids
        if let last = ids.lastIndex(where: { (canonical.firstIndex(of: $0) ?? Int.max) < rank }) {
            out.insert(id, at: last + 1)
        } else {
            out.insert(id, at: 0)
        }
        return out
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
