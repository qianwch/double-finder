import AppKit

/// Owner-drawn column header for the file list (Full mode).
///
/// Responsibilities:
/// - Draws column titles, sort arrow on the active sort column, and column separators.
/// - Click a column title → `onSort(id)` (caller handles direction toggle + re-sort).
/// - Drag a column's right-edge divider → resize that optional column, persist via
///   `AppSettings.columnWidths`, fire `onLayoutChanged()`.
/// - Right-click → column-chooser `NSMenu` (toggle `AppSettings.visibleColumns`,
///   fire `onLayoutChanged()`).
///
/// The view uses `FileColumnLayout` for all geometry so its columns are pixel-perfect
/// with `FileListBodyView` which uses the same layout object.
final class FileListHeaderView: NSView {

    // MARK: - Public API

    /// The column that currently carries the sort indicator (nil = none).
    var sortColumnID: String? { didSet { needsDisplay = true } }

    /// True = ascending (▲), false = descending (▼).
    var sortAscending: Bool = true { didSet { needsDisplay = true } }

    /// Called when the user clicks a column title. The caller should toggle the
    /// sort direction when the same column is clicked twice, then re-sort its items.
    var onSort: ((String) -> Void)?

    /// Called after a drag-to-resize or chooser change so the owner can relayout
    /// (e.g. resize the body view's frame, call setNeedsDisplay).
    var onLayoutChanged: (() -> Void)?

    // MARK: - Drawing constants

    private let headerHeight: CGFloat = 22
    private let minColumnWidth: CGFloat = 40
    private let dividerTolerance: CGFloat = 4

    // MARK: - Drag state

    private var dragColumnID: String? = nil
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    // MARK: - Cursor tracking

    private var trackingArea: NSTrackingArea?

    // MARK: - Layout (rebuilt in draw and on resize)

    /// Build the layout from current settings without reading defaults more than once.
    private func makeLayout() -> FileColumnLayout {
        FileColumnLayout(
            totalWidth: bounds.width,
            visibleOptionalIDs: AppSettings.visibleColumns,
            widths: AppSettings.columnWidths
        )
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Tracking area (resize cursor on hover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Read UserDefaults once per draw (not per column).
        let layout = makeLayout()

        // --- Background ---
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // Apply a subtle gradient-like look similar to NSTableHeaderView.
        let headerColor: NSColor
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            headerColor = NSColor(white: 0.22, alpha: 1.0)
        } else {
            headerColor = NSColor(white: 0.88, alpha: 1.0)
        }
        headerColor.setFill()
        bounds.fill()

        // --- Text attributes (computed once) ---
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let titleColor = NSColor.secondaryLabelColor
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: titleColor,
        ]
        let arrowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]

        // --- Draw each column ---
        for col in layout.columns {
            guard let range = layout.xRange(of: col.id) else { continue }
            let colRect = NSRect(
                x: range.lowerBound, y: 0,
                width: range.upperBound - range.lowerBound, height: bounds.height
            )

            // Title string
            let title = tr(col.title)
            let titleSize = (title as NSString).size(withAttributes: titleAttrs)

            // Reserve space for arrow if this is the sort column
            let isSortCol = col.id == sortColumnID
            let arrowStr: String = isSortCol ? (sortAscending ? "▲" : "▼") : ""
            let arrowSize = isSortCol ? (arrowStr as NSString).size(withAttributes: arrowAttrs) : .zero
            let arrowGap: CGFloat = isSortCol ? 3 : 0

            // Left-align title with a small inset (like NSTableHeaderCell)
            let inset: CGFloat = 6
            let availWidth = colRect.width - 2 * inset - (isSortCol ? arrowSize.width + arrowGap : 0)
            let titleX = colRect.minX + inset
            let titleY = (bounds.height - titleSize.height) / 2

            let titleRect = NSRect(x: titleX, y: titleY,
                                   width: min(titleSize.width, availWidth), height: titleSize.height)
            // Clip to column width to avoid overflow
            NSGraphicsContext.current?.saveGraphicsState()
            colRect.insetBy(dx: inset, dy: 0).clip()
            (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)
            NSGraphicsContext.current?.restoreGraphicsState()

            // Sort arrow (right of title)
            if isSortCol {
                let arrowX = titleRect.maxX + arrowGap
                let arrowY = (bounds.height - arrowSize.height) / 2
                let arrowRect = NSRect(x: arrowX, y: arrowY,
                                      width: arrowSize.width, height: arrowSize.height)
                (arrowStr as NSString).draw(in: arrowRect, withAttributes: arrowAttrs)
            }

            // Column separator (right edge, except after the last column)
            if col.id != layout.columns.last?.id {
                let sepX = range.upperBound - 0.5
                let sepColor = NSColor.separatorColor
                sepColor.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 0.5
                path.move(to: NSPoint(x: sepX, y: 2))
                path.line(to: NSPoint(x: sepX, y: bounds.height - 2))
                path.stroke()
            }
        }

        // --- Bottom border ---
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.lineWidth = 0.5
        border.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        border.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        border.stroke()
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let layout = makeLayout()

        // Check for divider drag first
        if let divID = layout.resizeDivider(atX: pt.x, tolerance: dividerTolerance) {
            dragColumnID = divID
            dragStartX = pt.x
            let range = layout.xRange(of: divID)!
            dragStartWidth = range.upperBound - range.lowerBound
            return
        }

        // Column click → sort
        if let colID = layout.column(atX: pt.x) {
            onSort?(colID)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divID = dragColumnID, !divID.isEmpty else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let delta = pt.x - dragStartX
        let newWidth = max(minColumnWidth, dragStartWidth + delta)

        // Update persisted widths
        var widths = AppSettings.columnWidths
        widths[divID] = newWidth
        AppSettings.columnWidths = widths

        needsDisplay = true
        onLayoutChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        dragColumnID = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let layout = makeLayout()
        if layout.resizeDivider(atX: pt.x, tolerance: dividerTolerance) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    // MARK: - Right-click: column chooser menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = buildChooserMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func buildChooserMenu() -> NSMenu {
        let menu = NSMenu()
        let visible = Set(AppSettings.visibleColumns)
        for spec in FileTableView.optionalColumns {
            let item = NSMenuItem(title: tr(spec.title), action: #selector(toggleColumn(_:)),
                                  keyEquivalent: "")
            item.representedObject = spec.id
            item.state = visible.contains(spec.id) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let colID = sender.representedObject as? String else { return }
        var visible = AppSettings.visibleColumns
        if visible.contains(colID) {
            visible.removeAll { $0 == colID }
        } else {
            // Maintain the canonical order from optionalColumns.
            let canonicalOrder = FileTableView.optionalColumns.map { $0.id }
            visible.append(colID)
            visible.sort { canonicalOrder.firstIndex(of: $0) ?? 0 < canonicalOrder.firstIndex(of: $1) ?? 0 }
        }
        AppSettings.visibleColumns = visible
        needsDisplay = true
        onLayoutChanged?()
    }
}
