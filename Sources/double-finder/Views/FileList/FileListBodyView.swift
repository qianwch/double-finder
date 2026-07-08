import AppKit
import UniformTypeIdentifiers

// MARK: - FileListBodyView

/// Owner-drawn NSView that paints all visible file rows in a single `draw(_:)`
/// pass — the Double Commander (TDrawGrid) approach.  Only the dirty rect is
/// iterated; cursor/selection changes invalidate only the affected row rects.
///
/// Renders all three view modes (full / brief / thumbnails) in `draw(_:)`.
final class FileListBodyView: NSView {

    // MARK: - Public model

    var items: [FileItem] = [] {
        didSet {
            reloadLayout()
            // Keep cached icons for files still present (a same-directory refresh
            // on focus-regain / DirectoryWatcher must NOT wipe every icon and
            // flash placeholders); drop icons for files no longer listed so the
            // cache stays bounded when navigating to a different directory.
            iconProvider.retainCached(paths: Set(items.map(\.path)))
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

    /// Local file URLs the context menu's Services submenu should act on. Set by
    /// the menu builder just before the menu shows; vended via NSServicesMenuRequestor.
    var serviceURLs: [URL] = []

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
        // Accept file drops from Finder / other apps / the other panel.
        registerForDraggedTypes([.fileURL])
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

    /// Sizes the document view to fill at least the visible scroll area. The height
    /// is `max(contentHeight, clipHeight)` — NOT just the content — so the blank space
    /// below a short file list still belongs to THIS view (not the scroll-view
    /// background). That makes a click in that blank area reach `mouseDown` and
    /// activate the panel (see the "click below the last row" branch there).
    /// Called on data reload (`reloadLayout`) and on panel resize (`FileListView.layout`).
    func resizeFrame() {
        let clip = enclosingScrollView?.contentSize ?? bounds.size
        let w = max(clip.width, 480)
        let contentH = CGFloat(items.count) * geometry.rowHeight
        let newSize = NSSize(width: w, height: max(contentH, clip.height))
        if frame.size != newSize { setFrameSize(newSize) }
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
        let currentViewMode = viewMode
        let colorByType = AppSettings.colorByType
        let viewWidth = bounds.width

        // 3. Visible rows.
        guard let range = geo.visibleRows(in: dirtyRect, count: items.count) else { return }

        // Shared text attributes.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        let side = iconSizePoints
        // Thumbnail side for .thumbnails mode (match FileTableView's 44pt side).
        let thumbSide: CGFloat = 44

        switch currentViewMode {
        case .full:
            drawFull(range: range, geo: geo, para: para, side: side,
                     colorByType: colorByType, viewWidth: viewWidth)
        case .brief:
            drawBrief(range: range, geo: geo, para: para, side: side,
                      colorByType: colorByType, viewWidth: viewWidth)
        case .thumbnails:
            drawThumbnails(range: range, geo: geo, para: para, thumbSide: thumbSide,
                           colorByType: colorByType, viewWidth: viewWidth)
        }

        // 5. Post-draw: prefetch visible icons/thumbnails, cancel offscreen.
        let visibleItems = Array(items[range])
        let visiblePaths = Set(visibleItems.map { $0.path })
        let wantThumbs = (currentViewMode == .thumbnails)
        let prefetchSide = wantThumbs ? thumbSide : side
        iconProvider.prefetch(visibleItems, side: prefetchSide, thumbnails: wantThumbs)
        iconProvider.cancelOffscreen(keepPaths: visiblePaths)
    }

    // MARK: - Shared row leading (disclosure triangle + icon)

    /// Draws the disclosure triangle (expandable folders only) and the row icon,
    /// reserving the triangle gutter for EVERY row so icons line up whether or not
    /// the row has a triangle (files used to sit ~14pt left of folders). Returns the
    /// x at which the name text should start. Used by both full and brief modes.
    private func drawLeading(item: FileItem, row: Int, geo: FileRowGeometry,
                             side: CGFloat) -> CGFloat {
        // The triangle slot is reserved for all rows; the icon always begins just
        // past it, so files and folders align.
        let triRect = geo.disclosureRect(row: row, depth: item.depth)
        let iconLeft = triRect.maxX + 2

        if item.isDirectory && item.name != ".." {
            let isExpanded = expandedPaths.contains(item.path)
            let symbolName = isExpanded ? "chevron.down" : "chevron.right"
            // Tint the chevron so it has real contrast on the row background — a
            // plain template symbol draws near-black and is invisible in dark mode.
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
            if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = sym.size
                let r = NSRect(x: triRect.midX - s.width / 2, y: triRect.midY - s.height / 2,
                               width: s.width, height: s.height)
                // respectFlipped: this view is flipped; the palette-colored (bitmap)
                // chevron would otherwise draw upside-down (chevron.down → up).
                sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0,
                         respectFlipped: true, hints: nil)
            }
        }

        if item.name != ".." {
            let yMid = geo.rowRect(row, width: bounds.width).minY + (geo.rowHeight - side) / 2
            let iconImg = iconProvider.icon(for: item, side: side, wantThumbnail: false)
            let alpha: CGFloat = item.isHidden ? 0.5 : 1.0
            // respectFlipped: this view is flipped and the cached icon is a
            // bitmap, which would otherwise draw upside-down.
            iconImg.draw(in: NSRect(x: iconLeft, y: yMid, width: side, height: side),
                         from: .zero, operation: .sourceOver, fraction: alpha,
                         respectFlipped: true, hints: nil)
        }
        return iconLeft + side + 4
    }

    // MARK: - Full mode drawing

    private func drawFull(range: ClosedRange<Int>, geo: FileRowGeometry,
                          para: NSMutableParagraphStyle, side: CGFloat,
                          colorByType: Bool, viewWidth: CGFloat) {
        let optionalIDs = AppSettings.visibleColumns
        let layout = FileColumnLayout(
            totalWidth: viewWidth,
            visibleOptionalIDs: optionalIDs,
            // Honor user-resized widths so the body's columns stay aligned with the
            // header (FileListHeaderView builds its layout from the same dictionary).
            widths: AppSettings.columnWidths
        )
        let metaAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]

        for row in range {
            let item = items[row]
            let rowRect = geo.rowRect(row, width: viewWidth)
            let selected = selectedItems.contains(item.id)
            let cursor = row == cursorIndex

            // Row highlight.
            if let bg = rowBackground(selected: selected, cursor: cursor,
                                       active: isActivePanel, odd: row % 2 == 1) {
                bg.setFill()
                rowRect.fill()
            }

            // Name column.
            if let nameRange = layout.xRange(of: "name") {
                let textLeft = drawLeading(item: item, row: row, geo: geo, side: side)
                let textRight = nameRange.upperBound - 4
                let textWidth = max(0, textRight - textLeft)
                let textY = rowRect.minY + (geo.rowHeight - 14) / 2
                let textRect = NSRect(x: textLeft, y: textY, width: textWidth, height: geo.rowHeight)

                let nameAttr = makeNameAttr(item: item, para: para, colorByType: colorByType)
                (item.name as NSString).draw(in: textRect, withAttributes: nameAttr)
            }

            // Visible optional columns.
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
    }

    // MARK: - Brief mode drawing (icon + name only, compact rows)

    private func drawBrief(range: ClosedRange<Int>, geo: FileRowGeometry,
                           para: NSMutableParagraphStyle, side: CGFloat,
                           colorByType: Bool, viewWidth: CGFloat) {
        for row in range {
            let item = items[row]
            let rowRect = geo.rowRect(row, width: viewWidth)
            let selected = selectedItems.contains(item.id)
            let cursor = row == cursorIndex

            // Row highlight.
            if let bg = rowBackground(selected: selected, cursor: cursor,
                                       active: isActivePanel, odd: row % 2 == 1) {
                bg.setFill()
                rowRect.fill()
            }

            // Disclosure triangle + icon (gutter reserved for all rows so they align).
            let textLeft = drawLeading(item: item, row: row, geo: geo, side: side)

            // Name text — spans full remaining width.
            let textRight = viewWidth - 4
            let textWidth = max(0, textRight - textLeft)
            let textY = rowRect.minY + (geo.rowHeight - 14) / 2
            let textRect = NSRect(x: textLeft, y: textY, width: textWidth, height: geo.rowHeight)

            let nameAttr = makeNameAttr(item: item, para: para, colorByType: colorByType)
            (item.name as NSString).draw(in: textRect, withAttributes: nameAttr)
        }
    }

    // MARK: - Thumbnails mode drawing (large rows with async QL thumbnails)

    private func drawThumbnails(range: ClosedRange<Int>, geo: FileRowGeometry,
                                para: NSMutableParagraphStyle, thumbSide: CGFloat,
                                colorByType: Bool, viewWidth: CGFloat) {
        let leadingMargin: CGFloat = 4
        let iconTextGap: CGFloat = 8

        for row in range {
            let item = items[row]
            let rowRect = geo.rowRect(row, width: viewWidth)
            let selected = selectedItems.contains(item.id)
            let cursor = row == cursorIndex

            // Row highlight.
            if let bg = rowBackground(selected: selected, cursor: cursor,
                                       active: isActivePanel, odd: row % 2 == 1) {
                bg.setFill()
                rowRect.fill()
            }

            // Thumbnail (or placeholder) — centered vertically in the row.
            let thumbX = leadingMargin
            let thumbY = rowRect.minY + (geo.rowHeight - thumbSide) / 2
            let thumbRect = NSRect(x: thumbX, y: thumbY, width: thumbSide, height: thumbSide)

            if item.name != ".." {
                // wantThumbnail: true triggers QL thumbnail resolution asynchronously.
                let iconImg = iconProvider.icon(for: item, side: thumbSide, wantThumbnail: !item.isDirectory)
                let alpha: CGFloat = item.isHidden ? 0.5 : 1.0
                iconImg.draw(in: thumbRect, from: .zero, operation: .sourceOver, fraction: alpha,
                             respectFlipped: true, hints: nil)
            }

            // Name text — drawn to the right of the thumbnail.
            let textLeft = thumbX + thumbSide + iconTextGap
            let textRight = viewWidth - 4
            let textWidth = max(0, textRight - textLeft)
            // Centre the text vertically in the tall row.
            let textY = rowRect.minY + (geo.rowHeight - 14) / 2
            let textRect = NSRect(x: textLeft, y: textY, width: textWidth, height: geo.rowHeight)

            let nameAttr = makeNameAttr(item: item, para: para, colorByType: colorByType)
            (item.name as NSString).draw(in: textRect, withAttributes: nameAttr)
        }
    }

    // MARK: - Shared name attribute builder

    private func makeNameAttr(item: FileItem, para: NSMutableParagraphStyle,
                              colorByType: Bool) -> [NSAttributedString.Key: Any] {
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
        return [
            .font: nameFont,
            .foregroundColor: nameColor.withAlphaComponent(nameColor.alphaComponent * nameAlpha),
            .paragraphStyle: para
        ]
    }

    // MARK: - Highlight colour helper (verbatim parity with NCRowView.drawBackground)

    /// Returns the background colour for a row, or `nil` for no fill (even + unselected + no cursor).
    func rowBackground(selected: Bool, cursor: Bool, active: Bool, odd: Bool) -> NSColor? {
        if selected {
            if active {
                return NSColor.selectedContentBackgroundColor.withAlphaComponent(0.4)
            } else {
                return NSColor.unemphasizedSelectedContentBackgroundColor
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
        // Directories show no size until one is computed (Space → recursive size);
        // once `calculatedSize` is set, formattedSize renders it.
        case "size":    return (item.isDirectory && item.calculatedSize == nil) ? "" : item.formattedSize
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

    // MARK: - Inline-rename timer (mirrors NCTableView.renameWorkItem)

    private var renameWorkItem: DispatchWorkItem?

    // MARK: - Right-click tracking

    /// Index of the last right-clicked (or context-menu) row — mirrors NSTableView.clickedRow.
    var clickedRow: Int = -1

    // MARK: - Input — keyboard

    override func keyDown(with event: NSEvent) {
        if fileDelegate != nil {
            // In production: forward the entire event up the responder chain so
            // MainViewController.handleKeyDown can handle arrows/enter/space/etc.
            // Bench shortcut: unmodified 'r' calls beginRename when onModeSwitch is
            // wired (which only happens in the bench harness, never in production).
            if event.keyCode == 15,
               event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
               onModeSwitch != nil {
                beginRename(row: cursorIndex)
                return
            }
            nextResponder?.keyDown(with: event)
        } else {
            // Bench path (no delegate wired): handle arrow keys + view-mode switches
            // directly so the bench stays interactive.
            switch event.keyCode {
            case 125: onArrow?(1)                       // down
            case 126: onArrow?(-1)                      // up
            case 18: onModeSwitch?(.full)               // key "1" → Full
            case 19: onModeSwitch?(.brief)              // key "2" → Brief
            case 20: onModeSwitch?(.thumbnails)         // key "3" → Thumbnails
            case 15:                                    // key "r" → trigger rename at cursor (bench)
                beginRename(row: cursorIndex)
            default:  super.keyDown(with: event)
            }
        }
    }

    // MARK: - Input — mouse (left button)

    override func mouseDown(with event: NSEvent) {
        renameWorkItem?.cancel(); renameWorkItem = nil
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        guard let row = geometry.rowAt(y: p.y, count: items.count) else {
            // Click below the last row: activate this panel.
            if let d = fileDelegate {
                d.fileTableViewWantsActivation(self)
            }
            return
        }

        let item = items[row]

        // --- Disclosure triangle hit-test (full / brief only; not thumbnails) ---
        if viewMode != .thumbnails,
           item.isDirectory, item.name != "..",
           let d = fileDelegate {
            let triRect = geometry.disclosureRect(row: row, depth: item.depth)
            if triRect.contains(p) {
                d.fileTableView(self, didToggleExpand: item)
                return
            }
        }

        // --- Double-click ---
        if event.clickCount == 2 {
            if let d = fileDelegate {
                d.fileTableView(self, didDoubleClickItem: item)
            } else {
                onDoubleClickRow?(row)
            }
            return
        }

        // --- Single click ---
        // Capture pre-click state for the slow-double-click rename check.
        let wasCurrent = row == cursorIndex && selectedItems.count <= 1
        let mods = event.modifierFlags
        let noChord = mods.intersection([.command, .shift, .control, .option]).isEmpty

        if let d = fileDelegate {
            d.fileTableView(self, didClickRow: row,
                            extend: mods.contains(.shift),
                            toggle: mods.contains(.command))
        } else {
            onClickRow?(row, mods.contains(.shift), mods.contains(.command))
        }

        // --- Track mouse to distinguish drag from plain release ---
        // Mirrors NCTableView: a release schedules an inline rename (slow-click); a
        // movement past the threshold starts a file drag — but only for a row that
        // is actually draggable (a real local file). For ".." / SFTP / archive rows
        // the drag is suppressed (like the old view), so a slow click on them still
        // reaches the rename path.
        let draggable = item.name != ".." && FileManager.default.fileExists(atPath: item.path)
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                // Slow-double-click → begin inline rename (Finder/TC style).
                if wasCurrent, noChord, item.name != "..", fileDelegate != nil {
                    let wi = DispatchWorkItem { [weak self] in
                        self?.beginRename(row: row)
                    }
                    renameWorkItem = wi
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + NSEvent.doubleClickInterval, execute: wi)
                }
                return
            }
            // Drag detection threshold (4 pt) — only for draggable rows.
            if draggable {
                let d = hypot(next.locationInWindow.x - start.x,
                              next.locationInWindow.y - start.y)
                if d > 4 {
                    renameWorkItem?.cancel(); renameWorkItem = nil
                    startFileDrag(originRow: row, event: next)
                    return
                }
            }
        }
    }

    // MARK: - Input — right mouse (context menu setup)

    override func rightMouseDown(with event: NSEvent) {
        renameWorkItem?.cancel(); renameWorkItem = nil
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        if let row = geometry.rowAt(y: p.y, count: items.count) {
            clickedRow = row
            // Move cursor to right-clicked row and activate this panel.
            if let d = fileDelegate {
                d.fileTableView(self, didClickRow: row, extend: false, toggle: false)
                d.fileTableViewWantsActivation(self)
            } else {
                onClickRow?(row, false, false)
            }
        } else {
            clickedRow = -1
            fileDelegate?.fileTableViewWantsActivation(self)
        }

        // The context NSMenu is built + attached by FileListView (Task 10).
        // For now, fall through to the default right-click / menu handling.
        super.rightMouseDown(with: event)
    }

    // MARK: - Inline rename (Task 7)

    /// The live NSTextField overlay while a rename is in progress.
    private var renameField: NSTextField?
    /// Row currently being renamed (-1 means none).
    private var renamingRow: Int = -1
    /// Original name captured when the rename started.
    private var renamingOriginalName: String = ""
    /// Local key monitor removed when the rename ends.
    private var renameKeyMonitor: Any?

    /// Starts an inline rename for `row`.
    ///
    /// - Positions an `NSTextField` overlay exactly over the drawn name text.
    /// - Commits on Return, cancels on Esc or focus-loss.
    /// - If another rename is already in progress it is committed first.
    /// - Only one field at a time; no rename for "..".
    public func beginRename(row: Int) {
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        guard item.name != ".." else { return }

        // If already renaming a different row, commit it first.
        if renamingRow >= 0 { endRename(commit: true) }

        // Make sure the row is scrolled into view so we can position the field.
        scrollToRowVisible(row)

        // --- Compute the text field frame ---
        // We reproduce the same origin/size as the name-text string in draw().
        let viewWidth = bounds.width
        let geo = geometry
        let rowRect = geo.rowRect(row, width: viewWidth)

        // Determine how far the icon starts (matches draw logic for each mode).
        let iconLeft: CGFloat
        if viewMode != .thumbnails {
            if item.isDirectory && item.name != ".." {
                let triRect = geo.disclosureRect(row: row, depth: item.depth)
                iconLeft = triRect.maxX + 2
            } else {
                let leadingMargin: CGFloat = 2
                let indentPerLevel: CGFloat = 12
                iconLeft = leadingMargin + CGFloat(item.depth) * indentPerLevel
            }
        } else {
            // Thumbnails: icon lives on the left with a 4-pt margin.
            iconLeft = 4
        }

        let iconSide = (viewMode == .thumbnails) ? CGFloat(44) : iconSizePoints
        // Text starts right after the icon (parity with all three draw* methods).
        let textLeft = (item.name == "..") ? iconLeft : (iconLeft + iconSide + 4)

        // Right boundary depends on the view mode.
        let textRight: CGFloat
        if viewMode == .full {
            // Use the name column's right boundary (FileColumnLayout).
            let optionalIDs = AppSettings.visibleColumns
            let layout = FileColumnLayout(totalWidth: viewWidth,
                                         visibleOptionalIDs: optionalIDs,
                                         widths: [:])
            if let nameRange = layout.xRange(of: "name") {
                textRight = nameRange.upperBound - 4
            } else {
                textRight = viewWidth - 4
            }
        } else {
            textRight = viewWidth - 4
        }

        let fieldWidth = max(40, textRight - textLeft)
        // Align with where the name baseline is drawn (parity with draw()).
        let fieldHeight: CGFloat = 20
        let fieldY = rowRect.minY + (geo.rowHeight - fieldHeight) / 2

        let fieldFrame = NSRect(x: textLeft, y: fieldY, width: fieldWidth, height: fieldHeight)

        // --- Build the NSTextField ---
        let tf = NSTextField(frame: fieldFrame)
        tf.stringValue = item.name
        tf.font = item.isDirectory
            ? NSFont.boldSystemFont(ofSize: 12)
            : NSFont.systemFont(ofSize: 12)
        tf.isBordered = true
        tf.bezelStyle = .squareBezel
        tf.useSingleLineScrolling()
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.textColor = .labelColor
        tf.focusRingType = .default
        tf.delegate = self          // self conforms via the extension below
        addSubview(tf)

        renamingRow = row
        renamingOriginalName = item.name
        renameField = tf
        window?.makeFirstResponder(tf)

        // Select the base name (without extension) for files — Finder/TC style.
        // For directories select the full name (no extension concept).
        if let editor = tf.currentEditor() {
            let ns = item.name as NSString
            let base = ns.deletingPathExtension
            let selLen: Int
            if item.isDirectory || base.isEmpty || base == item.name {
                selLen = item.name.count
            } else {
                selLen = base.count
            }
            editor.selectedRange = NSRange(location: 0, length: selLen)
        }

        // Function-key monitor: F3-F8 during rename cancel + forward the key.
        renameKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.renamingRow >= 0 else { return event }
            let fnKeys: Set<UInt16> = [99, 118, 96, 97, 98, 100]   // F3 F4 F5 F6 F7 F8
            guard fnKeys.contains(event.keyCode) else { return event }
            self.endRename(commit: false)
            // Forward after tear-down so the panel gets the key event.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let win = self.window else { return }
                _ = (win.contentViewController as? MainViewController)?.handleKeyDown(event)
            }
            return nil
        }
    }

    // MARK: - Rename end helpers

    /// Commits or cancels the current rename and removes the overlay field.
    private func endRename(commit: Bool) {
        guard let tf = renameField, renamingRow >= 0 else { return }

        let original = renamingOriginalName
        let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = renamingRow

        // Clear state before callbacks so re-entrant calls are no-ops.
        renamingRow = -1
        renamingOriginalName = ""
        renameField = nil
        if let m = renameKeyMonitor { NSEvent.removeMonitor(m); renameKeyMonitor = nil }

        tf.delegate = nil
        tf.removeFromSuperview()

        // Restore keyboard focus to this view (mirrors FileCellView.endRename).
        window?.makeFirstResponder(self)

        if commit, !newName.isEmpty, newName != original,
           row < items.count {
            fileDelegate?.fileTableView(self, didRename: items[row], to: newName)
        }
    }

    // MARK: - Standalone callbacks (used when fileDelegate == nil; ignored in production)

    var onClickRow: ((_ row: Int, _ extend: Bool, _ toggle: Bool) -> Void)?
    var onDoubleClickRow: ((Int) -> Void)?
    /// Arrow-key callback used by the bench when `fileDelegate == nil`.
    var onArrow: ((_ delta: Int) -> Void)?
    /// Called when the bench requests a view mode switch (keys 1/2/3).
    var onModeSwitch: ((_ mode: FileViewMode) -> Void)?
    /// Drop callback used by the bench when `fileDelegate == nil`.
    var onDropFiles: ((_ urls: [URL], _ move: Bool) -> Void)?
}

// MARK: - Drag source (NSDraggingSource)

extension FileListBodyView: NSDraggingSource {

    /// Mirrors NCTableView.startFileDrag exactly: drag the whole selection if
    /// the origin row is in it, otherwise just the clicked row.
    private func startFileDrag(originRow: Int, event: NSEvent) {
        let origin = items[originRow]
        let toDrag: [FileItem] = selectedItems.contains(origin.id)
            ? items.filter { selectedItems.contains($0.id) && $0.name != ".." }
            : (origin.name != ".." ? [origin] : [])
        let valid = toDrag.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { return }   // SFTP/archive entries have no real file URL

        var dragItems: [NSDraggingItem] = []
        for fileItem in valid {
            let di = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: fileItem.path))
            let icon = NSWorkspace.shared.icon(forFile: fileItem.path)
            icon.size = NSSize(width: 28, height: 28)
            // Position the drag image at the item's row rect origin.
            if let rowIdx = items.firstIndex(where: { $0.id == fileItem.id }) {
                var frame = geometry.rowRect(rowIdx, width: bounds.width)
                frame.size = NSSize(width: 28, height: 28)
                di.setDraggingFrame(frame, contents: icon)
            }
            dragItems.append(di)
        }
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    /// Mirrors NCTableView: copy+move within app, copy-only outside.
    public func draggingSession(_ session: NSDraggingSession,
                                sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : .copy
    }
}

// MARK: - Drop destination (NSDraggingDestination)

extension FileListBodyView {

    private func canAcceptDrop(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    /// Mirrors NCTableView.dropOperation(for:) exactly.
    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop(sender) else { return [] }
        let mask = sender.draggingSourceOperationMask
        // Cmd forces move within the app; default is copy.
        if NSEvent.modifierFlags.contains(.command), mask.contains(.move) { return .move }
        return mask.contains(.copy) ? .copy : (mask.contains(.move) ? .move : .copy)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let move = dropOperation(for: sender) == .move
        if let d = fileDelegate {
            d.fileTableView(self, didDropFiles: urls, move: move)
        } else {
            onDropFiles?(urls, move)
        }
        return true
    }
}

// MARK: - Scroll helper (used by bench)

extension FileListBodyView {
    func scrollToRowVisible(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        scrollToVisible(geometry.rowRect(row, width: bounds.width))
    }
}

// MARK: - System Services support
//
// Lets the macOS Services menu (Finder-style) act on the selected files. The
// body view is the first responder, so AppKit walks the responder chain here
// to discover what the selection can vend and which services apply. The context
// menu stashes the selection's local file URLs in `serviceURLs` (from the same
// panelState selection the rest of the menu uses) just before showing.
extension FileListBodyView: NSServicesMenuRequestor {
    /// Legacy filenames pasteboard type — advertised/written alongside file-url so
    /// services that declare only it (iTerm2, Double Commander, …) also appear.
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let sendType = sendType,
           sendType == .fileURL || sendType == Self.filenamesType,
           returnType == nil,
           !serviceURLs.isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !serviceURLs.isEmpty else { return false }
        pboard.clearContents()
        pboard.addTypes([Self.filenamesType], owner: nil)
        var ok = pboard.writeObjects(serviceURLs as [NSURL])
        if pboard.setPropertyList(serviceURLs.map { $0.path }, forType: Self.filenamesType) {
            ok = true
        }
        return ok
    }

    func readSelection(from pboard: NSPasteboard) -> Bool { false }   // we only send, never receive
}

// MARK: - NSTextFieldDelegate (inline rename)

extension FileListBodyView: NSTextFieldDelegate {

    /// Return/Enter → commit.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endRename(commit: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        return false
    }

    /// Focus-loss → commit (matches FileCellView.controlTextDidEndEditing).
    func controlTextDidEndEditing(_ obj: Notification) {
        if renamingRow >= 0 { endRename(commit: true) }
    }
}
