import AppKit

// MARK: - FileListBodyView

/// Owner-drawn NSView that paints all visible file rows in a single `draw(_:)`
/// pass — the Double Commander (TDrawGrid) approach.  Only the dirty rect is
/// iterated; cursor/selection changes invalidate only the affected row rects.
///
/// **Current scope: Full-mode only.**  Brief and thumbnails are Task 5.
final class FileListBodyView: NSView {

    // MARK: - Public model

    var items: [FileItem] = [] {
        didSet {
            reloadLayout()
            iconProvider.clear()
            if !items.isEmpty {
                let side = iconSizePoints
                iconProvider.prefetch(items, side: side, thumbnails: false)
            }
            needsDisplay = true
        }
    }

    var selectedItems: Set<UUID> = [] {
        didSet {
            // Invalidate only rows whose selection membership flipped.
            let changed = oldValue.symmetricDifference(selectedItems)
            for (i, item) in items.enumerated() where changed.contains(item.id) {
                invalidateRow(i)
            }
        }
    }

    var cursorIndex: Int = 0 {
        didSet {
            guard cursorIndex != oldValue else { return }
            invalidateRow(oldValue)
            invalidateRow(cursorIndex)
        }
    }

    var isActivePanel: Bool = false { didSet { needsDisplay = true } }

    /// Paths of folders currently expanded in place (drives the disclosure triangle).
    var expandedPaths: Set<String> = [] { didSet { needsDisplay = true } }

    var viewMode: FileViewMode = .full {
        didSet {
            if viewMode != oldValue {
                iconSizePoints = CGFloat(AppSettings.iconSize)
                geometry = FileRowGeometry(mode: viewMode, iconSize: iconSizePoints)
                resizeFrame()
                needsDisplay = true
            }
        }
    }

    var sortColumnID: String? = nil
    var sortAscending: Bool = true

    weak var fileDelegate: FileTableViewDelegate?

    // MARK: - Private state

    /// Icon size in points — cached once so draw/per-row never touches UserDefaults.
    private(set) var iconSizePoints: CGFloat = CGFloat(AppSettings.iconSize)

    /// Row geometry recomputed whenever viewMode or iconSize changes.
    var geometry: FileRowGeometry

    /// Async icon/thumbnail provider with bitmap cache.
    private let iconProvider = FileIconProvider()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        geometry = FileRowGeometry(mode: .full, iconSize: CGFloat(AppSettings.iconSize))
        super.init(frame: frameRect)
        iconProvider.onReady = { [weak self] path in
            self?.invalidateRows(forPath: path)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - NSView overrides

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Layout helpers

    /// Refreshes cached layout values and resizes the frame.
    func reloadLayout() {
        iconSizePoints = CGFloat(AppSettings.iconSize)
        geometry = FileRowGeometry(mode: viewMode, iconSize: iconSizePoints)
        resizeFrame()
    }

    private func resizeFrame() {
        let w = max(enclosingScrollView?.contentSize.width ?? bounds.width, 480)
        let h = CGFloat(items.count) * geometry.rowHeight
        setFrameSize(NSSize(width: w, height: h))
    }

    private func invalidateRow(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        setNeedsDisplay(geometry.rowRect(row, width: bounds.width))
    }

    private func invalidateRows(forPath path: String) {
        for (i, item) in items.enumerated() where item.path == path {
            invalidateRow(i)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 1. Background fill.
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        guard !items.isEmpty else { return }

        // 2. Compute layout once per draw — NOT per row. Read all UserDefaults-backed
        // settings ONCE here, never inside the row loop (per-row UserDefaults reads
        // are exactly the hot-loop cost this owner-drawn rewrite exists to remove).
        let geo = geometry  // already cached; just alias for clarity
        let optionalIDs = AppSettings.visibleColumns
        let colorByType = AppSettings.colorByType
        let layout = FileColumnLayout(
            totalWidth: bounds.width,
            visibleOptionalIDs: optionalIDs,
            widths: [:]
        )
        let viewWidth = bounds.width

        // 3. Visible rows.
        guard let range = geo.visibleRows(in: dirtyRect, count: items.count) else { return }

        // Shared text attributes.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let metaAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]

        let side = iconSizePoints

        for row in range {
            let item = items[row]
            let rowRect = geo.rowRect(row, width: viewWidth)
            let selected = selectedItems.contains(item.id)
            let cursor = row == cursorIndex

            // 4a. Row highlight.
            if let bg = rowBackground(selected: selected, cursor: cursor,
                                       active: isActivePanel, odd: row % 2 == 1) {
                bg.setFill()
                rowRect.fill()
            }

            // 4b. Name column.
            if let nameRange = layout.xRange(of: "name") {
                let nameLeft = nameRange.lowerBound
                // Disclosure triangle (expandable directories, not "..").
                var iconLeft = nameLeft
                if item.isDirectory && item.name != ".." {
                    let triRect = geo.disclosureRect(row: row, depth: item.depth)
                    iconLeft = triRect.maxX + 2
                    // Draw SF Symbol chevron.
                    let isExpanded = expandedPaths.contains(item.path)
                    let symbolName = isExpanded ? "chevron.down" : "chevron.right"
                    if let sym = NSImage(systemSymbolName: symbolName,
                                         accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
                        let symSize = sym.size
                        let symRect = NSRect(
                            x: triRect.midX - symSize.width / 2,
                            y: triRect.midY - symSize.height / 2,
                            width: symSize.width, height: symSize.height
                        )
                        sym.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    }
                } else {
                    // For ".." and files, still indent by depth (usually 0).
                    let leadingMargin: CGFloat = 2
                    let indentPerLevel: CGFloat = 12
                    iconLeft = nameLeft + leadingMargin + CGFloat(item.depth) * indentPerLevel
                }

                // Icon.
                let yMid = rowRect.minY + (geo.rowHeight - side) / 2
                if item.name != ".." {
                    let iconImg = iconProvider.icon(for: item, side: side, wantThumbnail: false)
                    let iconRect = NSRect(x: iconLeft, y: yMid, width: side, height: side)
                    let alpha: CGFloat = item.isHidden ? 0.5 : 1.0
                    iconImg.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha)
                }

                // Name text.
                let textLeft = iconLeft + side + 4
                let textRight = nameRange.upperBound - 4
                let textWidth = max(0, textRight - textLeft)
                let textY = rowRect.minY + (geo.rowHeight - 14) / 2
                let textRect = NSRect(x: textLeft, y: textY, width: textWidth, height: geo.rowHeight)

                var nameColor: NSColor
                if colorByType {
                    nameColor = FileTypeColor.color(name: item.name, isDirectory: item.isDirectory, isSymlink: item.isSymlink)
                } else if item.isSymlink {
                    nameColor = .systemBlue
                } else {
                    nameColor = .labelColor
                }
                let nameAlpha: CGFloat = item.isHidden ? 0.5 : 1.0
                let nameFont: NSFont = item.isDirectory
                    ? NSFont.boldSystemFont(ofSize: 12)
                    : NSFont.systemFont(ofSize: 12)
                let nameAttr: [NSAttributedString.Key: Any] = [
                    .font: nameFont,
                    .foregroundColor: nameColor.withAlphaComponent(nameColor.alphaComponent * nameAlpha),
                    .paragraphStyle: para
                ]
                (item.name as NSString).draw(in: textRect, withAttributes: nameAttr)
            }

            // 4c. Visible optional columns (uses the `optionalIDs` hoisted above).
            for colID in optionalIDs {
                guard let xRange = layout.xRange(of: colID) else { continue }
                let text = metaText(for: item, column: colID)
                guard !text.isEmpty else { continue }

                let alpha: CGFloat = item.isHidden ? 0.5 : 1.0
                var attr = metaAttr
                if alpha < 1.0, let color = attr[.foregroundColor] as? NSColor {
                    attr[.foregroundColor] = color.withAlphaComponent(alpha)
                }

                let colLeft = xRange.lowerBound + 4
                let colWidth = (xRange.upperBound - xRange.lowerBound) - 8
                let colY = rowRect.minY + (geo.rowHeight - 13) / 2
                let colRect = NSRect(x: colLeft, y: colY, width: max(0, colWidth), height: geo.rowHeight)
                (text as NSString).draw(in: colRect, withAttributes: attr)
            }
        }

        // 5. Post-draw: prefetch visible icons, cancel offscreen.
        let visibleItems = Array(items[range])
        let visiblePaths = Set(visibleItems.map { $0.path })
        iconProvider.prefetch(visibleItems, side: side, thumbnails: false)
        iconProvider.cancelOffscreen(keepPaths: visiblePaths)
    }

    // MARK: - Highlight colour helper (verbatim parity with NCRowView.drawBackground)

    /// Returns the background colour for a row, or `nil` for no fill (even + unselected + no cursor).
    func rowBackground(selected: Bool, cursor: Bool, active: Bool, odd: Bool) -> NSColor? {
        if selected {
            if active {
                return NSColor.selectedContentBackgroundColor.withAlphaComponent(0.4)
            } else {
                return NSColor.secondarySelectedControlColor
            }
        } else if cursor {
            if active {
                return NSColor.selectedContentBackgroundColor.withAlphaComponent(0.7)
            } else {
                return NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3)
            }
        } else if odd {
            return NSColor.labelColor.withAlphaComponent(0.05)
        }
        return nil
    }

    // MARK: - Meta text (parity with FileTableView.metaText)

    private func metaText(for item: FileItem, column: String) -> String {
        if item.name == ".." { return "" }
        switch column {
        case "size":    return item.isDirectory ? "" : item.formattedSize
        case "date":    return item.formattedDate
        case "added":   return item.formatted(item.dateAdded)
        case "created": return item.formatted(item.dateCreated)
        case "kind":    return item.kind
        case "perms":
            return item.permissions.isEmpty
                ? LocalFS.permissions(for: item.path)
                : item.permissions
        default:        return ""
        }
    }

    // MARK: - viewDidMoveToWindow / live layout

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            reloadLayout()
        }
    }

    // MARK: - Input (basic keyboard for bench)

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onArrow?(1)     // down
        case 126: onArrow?(-1)    // up
        default:  super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let row = geometry.rowAt(y: p.y, count: items.count) {
            if event.clickCount == 2 {
                onDoubleClickRow?(row)
            } else {
                onClickRow?(row,
                            event.modifierFlags.contains(.shift),
                            event.modifierFlags.contains(.command))
            }
        }
    }

    // MARK: - Bench callbacks (wired in CanvasBench; ignored in production)

    var onClickRow: ((_ row: Int, _ extend: Bool, _ toggle: Bool) -> Void)?
    var onDoubleClickRow: ((Int) -> Void)?
    var onArrow: ((_ delta: Int) -> Void)?
}

// MARK: - Scroll helper (used by bench)

extension FileListBodyView {
    func scrollToRowVisible(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        scrollToVisible(geometry.rowRect(row, width: bounds.width))
    }
}
