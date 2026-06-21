import AppKit

// MARK: - FileListView

/// NSScrollView shell that composes `FileListHeaderView` (non-scrolling, top) and
/// `FileListBodyView` (documentView, scrollable body).
///
/// **Exposed interface mirrors `FileTableView`** so that `PanelViewController` can swap
/// in `FileListView` with minimal changes (Task 11).
///
/// Layout strategy:
/// - In `.full` mode: the header (22 pt high) is pinned as a *floating* sibling view
///   ABOVE the clip view, and `contentInsets.top` is set to 22 so the body's content
///   starts below it.
/// - In `.brief` / `.thumbnails` mode: the header is hidden and `contentInsets.top = 0`.
/// - On resize: the header width tracks the scroll view width via `setFrame`.
final class FileListView: NSScrollView {

    // MARK: - Sub-views

    let body: FileListBodyView
    let headerView: FileListHeaderView

    private static let headerHeight: CGFloat = 22

    // MARK: - Initialiser

    override init(frame frameRect: NSRect) {
        body = FileListBodyView(frame: NSRect(x: 0, y: 0, width: frameRect.width, height: 10))
        headerView = FileListHeaderView(
            frame: NSRect(x: 0, y: 0, width: frameRect.width, height: Self.headerHeight)
        )
        super.init(frame: frameRect)

        // --- Scroll view configuration ---
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        // Take full control of content insets: otherwise the automatic adjustment
        // (default on) overrides our manual top inset back to 0, so the reserved
        // space under the floating header vanishes and the header covers row 0
        // (the ".." entry). With this off, applyViewMode's contentInsets.top sticks.
        automaticallyAdjustsContentInsets = false

        // Body is the document view (flipped, scrollable).
        documentView = body

        // Header is a floating subview of the scroll view itself (not of the clip
        // view), so it stays pinned at the top while the body scrolls underneath.
        headerView.autoresizingMask = [.width]
        addSubview(headerView, positioned: .above, relativeTo: nil)

        // Wire header callbacks.
        headerView.onSort = { [weak self] colID in
            guard let self = self else { return }
            // Forward to the panel via the FileTableViewDelegate didClickColumn.
            self.fileDelegate?.fileTableView(self.firstResponderTarget,
                                             didClickColumn: colID)
        }
        headerView.onLayoutChanged = { [weak self] in
            guard let self = self else { return }
            self.body.reloadLayout()
            self.body.needsDisplay = true
            self.headerView.needsDisplay = true
        }

        // Apply initial viewMode (full) — sets insets + header visibility.
        applyViewMode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    override func layout() {
        super.layout()
        positionHeader()
        // Keep body width in sync with the clip view width so columns fill.
        syncBodyWidth()
    }

    /// Positions the header at the very top of the scroll view bounds (full-width, fixed height).
    private func positionHeader() {
        let h = Self.headerHeight
        headerView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
    }

    /// Ensures body frame width matches the visible content width (so owner-drawn
    /// columns fill the panel edge-to-edge — same as `resizeFrame()` in the body).
    private func syncBodyWidth() {
        let clipW = contentSize.width
        if body.frame.width != clipW {
            var f = body.frame
            f.size.width = clipW
            body.setFrameSize(f.size)
        }
    }

    /// Applies header visibility and content insets for the active view mode.
    private func applyViewMode() {
        let showHeader = (body.viewMode == .full)
        headerView.isHidden = !showHeader
        if showHeader {
            contentInsets = NSEdgeInsets(top: Self.headerHeight, left: 0, bottom: 0, right: 0)
        } else {
            contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        // Force layout update.
        needsLayout = true
    }

    // MARK: - Public interface (FileTableView parity)

    // --- Model forwarding ---

    var items: [FileItem] {
        get { body.items }
        set { body.items = newValue }
    }

    var selectedItems: Set<UUID> {
        get { body.selectedItems }
        set { body.selectedItems = newValue }
    }

    var cursorIndex: Int {
        get { body.cursorIndex }
        set { body.cursorIndex = newValue }
    }

    var isActivePanel: Bool {
        get { body.isActivePanel }
        set {
            body.isActivePanel = newValue
        }
    }

    var expandedPaths: Set<String> {
        get { body.expandedPaths }
        set { body.expandedPaths = newValue }
    }

    weak var fileDelegate: FileTableViewDelegate? {
        get { body.fileDelegate }
        set { body.fileDelegate = newValue }
    }

    var viewMode: FileViewMode {
        get { body.viewMode }
        set {
            body.viewMode = newValue
            applyViewMode()   // sets headerView.isHidden + content insets
        }
    }

    // --- Sort indicator (matches old updateSortIndicator(column:ascending:)) ---

    /// Mirrors `FileTableView.updateSortIndicator(column:ascending:)`.
    func updateSortIndicator(column identifier: String, ascending: Bool) {
        body.sortColumnID = identifier
        body.sortAscending = ascending
        headerView.sortColumnID = identifier
        headerView.sortAscending = ascending
        body.needsDisplay = true
        headerView.needsDisplay = true
    }

    // --- Rename ---

    func beginRename(row: Int) {
        body.beginRename(row: row)
    }

    // --- Scroll helpers ---

    /// Scrolls just enough to keep `row` visible (mirrors FileTableView.ensureRowVisible).
    func ensureRowVisible(_ row: Int) {
        guard row >= 0, row < body.items.count else { return }
        body.scrollToRowVisible(row)
    }

    /// Scrolls so `row` is at the top of the viewport (mirrors FileTableView.scrollRowToTop).
    func scrollRowToTop(_ row: Int) {
        let count = body.items.count
        guard count > 0 else { return }
        let target = max(0, min(row, count - 1))
        let geo = body.geometry
        let clipView = contentView
        // The row should land just BELOW the floating header, so the topmost valid
        // origin is -contentInsets.top (the header height in .full mode). NSClipView's
        // constrainBoundsRect clamps the top to 0 — ignoring the inset — which left
        // the ".." row (row 0) mostly hidden under the header. Use constrainBoundsRect
        // only for the BOTTOM limit, and allow the inset-aware top ourselves.
        let desired = CGFloat(target) * geo.rowHeight - contentInsets.top
        let bottomClamped = clipView.constrainBoundsRect(
            NSRect(origin: NSPoint(x: 0, y: desired), size: clipView.bounds.size)).origin.y
        let y = max(-contentInsets.top, min(desired, bottomClamped))
        clipView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(clipView)
    }

    /// Index of the first fully-visible row at the top of the viewport.
    var topVisibleRow: Int {
        let visibleOriginY = documentVisibleRect.minY
        let geo = body.geometry
        guard geo.rowHeight > 0 else { return 0 }
        let row = Int(visibleOriginY / geo.rowHeight)
        return max(0, min(row, max(0, body.items.count - 1)))
    }

    // --- Context menu (mirroring PanelViewController's tableView.menu = contextMenu pattern) ---

    /// Setting this assigns the menu to `body.menu` so AppKit shows it on right-click.
    var contextMenu: NSMenu? {
        get { body.menu }
        set { body.menu = newValue }
    }

    /// The view to make first responder (body accepts keyboard input).
    var firstResponderTarget: NSView { body }

    /// Forward clickedRow from body.
    var clickedRow: Int { body.clickedRow }

    /// Local file URLs the context menu's Services submenu acts on (forwarded to
    /// the body, which is the first responder and vends them via NSServicesMenuRequestor).
    var serviceURLs: [URL] {
        get { body.serviceURLs }
        set { body.serviceURLs = newValue }
    }

    /// Rect of `row` in `firstResponderTarget` (= body) coordinates — used to pop
    /// the keyboard-invoked context menu at the cursor row (mirrors NSTableView.rect(ofRow:)).
    func rectOfRow(_ row: Int) -> NSRect {
        body.geometry.rowRect(row, width: body.bounds.width)
    }

    // --- Layout reload (mirrors FileTableView.reloadLayout) ---

    func reloadLayout() {
        body.reloadLayout()
        body.needsDisplay = true
        headerView.needsDisplay = true
    }

    // --- Parity helpers PanelViewController / MainViewController call ---

    /// Re-applies the active language to the column header titles. The owner-drawn
    /// header draws each title through `tr()` on every draw, so a redraw is all that
    /// is needed (mirrors FileTableView.relocalize, called on a live language switch).
    func relocalize() {
        headerView.needsDisplay = true
    }

    /// Moves the cursor to the first item whose name starts with `char` (type-ahead).
    /// Mirrors FileTableView.jumpToLetter.
    func jumpToLetter(_ char: Character) {
        let lower = char.lowercased().first ?? char
        for (i, item) in body.items.enumerated()
        where item.name != ".." && item.name.lowercased().first == lower {
            body.cursorIndex = i
            fileDelegate?.fileTableViewDidChangeCursor(firstResponderTarget, to: i)
            ensureRowVisible(i)
            return
        }
    }
}
